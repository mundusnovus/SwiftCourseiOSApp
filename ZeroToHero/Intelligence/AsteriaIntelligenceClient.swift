// Talks to Asteria's gateway: gets an hour-long session (with the app's account, App Attest, or as an unattested app),
// then streams answers as server-sent events.
import CryptoKit
import Foundation
import FoundationModels
import Synchronization
#if canImport(DeviceCheck)
import DeviceCheck
#endif

nonisolated enum IntelligenceEvent: Sendable {
    case text(String)
    case reasoning(String)
    case toolCall(index: Int, id: String?, name: String?, arguments: String)
    case usage(prompt: Int, cached: Int, completion: Int, reasoning: Int)
}

actor IntelligenceClient {
    static let shared = IntelligenceClient()

    private var session: (token: String, expires: Date)?
    private var starting: Task<String, Error>?
    private let urls: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 600
        configuration.timeoutIntervalForResource = 900
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    // MARK: Sessions

    /// A session token, starting a session if there's none (one at a time).
    func token() async throws -> String {
        if let session, session.expires > Date.now.addingTimeInterval(60) { return session.token }
        if let starting { return try await starting.value }
        let task = Task { try await self.start() }
        starting = task
        defer { starting = nil }
        let token = try await task.value
        return token
    }

    private func forget() { session = nil }

    /// Starts over with whoever is signed in now.
    func reset() { session = nil }

    /// Today's tokens.
    func usage() async throws -> AsteriaUsage.Report {
        let data = try await json("GET", "usage", body: nil as [String: String]?)
        return try Self.decoder.decode(AsteriaUsage.Report.self, from: data)
    }

    static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
    static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()

    /// A JSON request with the session, starting a new session once if the old one expired.
    func json<B: Encodable>(_ method: String, _ path: String, body: B?, query: [URLQueryItem] = []) async throws -> Data {
        for attempt in 0..<2 {
            var components = URLComponents(url: url(path), resolvingAgainstBaseURL: false)!
            if !query.isEmpty { components.queryItems = query }
            var request = URLRequest(url: components.url!)
            request.httpMethod = method
            request.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
            if let body {
                request.httpBody = try Self.encoder.encode(body)
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            let (data, response) = try await data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 && attempt == 0 { forget(); continue }
            guard (200..<300).contains(status) else { throw Self.failure(status: status, data: data, response: response) }
            return data
        }
        throw AsteriaIntelligenceError.unavailable("Asteria Intelligence couldn't start. Try again in a moment.")
    }

    private func start() async throws -> String {
        let (configured, developmentKey) = AsteriaIntelligence.settings.withLock { ($0.credential, $0.developmentKey) }
        // Apps without their own account code use the shared Asteria Account (AsteriaID).
        let credential = configured ?? { await AsteriaID.shared.accessToken().map { .post($0) } }
        var body: [String: String]
        if let credential = await credential() {
            switch credential {
            case .account(let token): body = ["kind": "account", "token": token]
            case .post(let token): body = ["kind": "post", "token": token]
            }
        } else if let developmentKey {
            body = ["kind": "development", "devKey": developmentKey]
        } else if let attested = await attestedBody() {
            body = attested
        } else {
            body = ["kind": "anonymous"]
        }
        struct Started: Decodable { let token: String; let expiresAt: Date; let usage: AsteriaUsage.Report? }
        let started: Started
        do {
            started = try await post("session", body, as: Started.self)
        } catch AppAttestRetry.newKey {
            // The gateway doesn't know this key any more: attest a new one.
            UserDefaults.standard.removeObject(forKey: Self.keyIDKey)
            body = await attestedBody() ?? ["kind": "anonymous"]
            started = try await post("session", body, as: Started.self)
        } catch let error where body["kind"] == "account" || body["kind"] == "post" {
            // A sign-in that just expired shouldn't stop the feature: ask as this copy of the app instead.
            guard !(error is AsteriaIntelligenceError && (error as? AsteriaIntelligenceError) == .offline) else { throw error }
            body = await attestedBody() ?? ["kind": "anonymous"]
            started = try await post("session", body, as: Started.self)
        }
        session = (started.token, started.expiresAt)
        if let usage = started.usage { await AsteriaUsage.shared.apply(usage) }
        return started.token
    }

    // MARK: App Attest

    private static let keyIDKey = "AsteriaIntelligence.appAttestKey"
    private enum AppAttestRetry: Error { case newKey }

    /// An attestation (first time) or an assertion (after), over a fresh challenge. Nil where App Attest isn't
    /// available (simulators, most Macs), or if it fails: the app then asks as an unattested app.
    private func attestedBody() async -> [String: String]? {
        #if canImport(DeviceCheck) && !targetEnvironment(simulator)
        let service = DCAppAttestService.shared
        guard service.isSupported else { return nil }
        struct Challenge: Decodable { let challenge: String }
        guard let challenge = try? await post("challenge", [String: String](), as: Challenge.self),
              let challengeData = Data(base64Encoded: challenge.challenge) else { return nil }
        let clientDataHash = Data(SHA256.hash(data: challengeData))
        if let keyID = UserDefaults.standard.string(forKey: Self.keyIDKey),
           let assertion = try? await service.generateAssertion(keyID, clientDataHash: clientDataHash) {
            return ["kind": "assert", "keyID": keyID, "assertion": assertion.base64EncodedString(), "challenge": challenge.challenge]
        }
        guard let keyID = try? await service.generateKey(),
              let attestation = try? await service.attestKey(keyID, clientDataHash: clientDataHash) else { return nil }
        UserDefaults.standard.set(keyID, forKey: Self.keyIDKey)
        return ["kind": "attest", "keyID": keyID, "attestation": attestation.base64EncodedString(), "challenge": challenge.challenge]
        #else
        return nil
        #endif
    }

    // MARK: Requests

    private func url(_ path: String) -> URL {
        AsteriaIntelligence.settings.withLock { $0.server }.appending(path: path)
    }

    private func post<T: Decodable>(_ path: String, _ body: [String: String], as: T.Type) async throws -> T {
        var request = URLRequest(url: url(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404, body["kind"] == "assert" { throw AppAttestRetry.newKey }
        guard status == 200 else { throw Self.failure(status: status, data: data, response: response) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: data)
    }

    private func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        do { return try await urls.data(for: request) } catch let error as URLError where Self.offline.contains(error.code) {
            throw AsteriaIntelligenceError.offline
        }
    }

    private static let offline: Set<URLError.Code> = [.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff]

    /// One answer, as events. Starts a new session once if the old one expired.
    nonisolated func stream(_ body: Data) -> AsyncThrowingStream<IntelligenceEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.run(body) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(_ body: Data, yield: @Sendable (IntelligenceEvent) -> Void) async throws {
        for attempt in 0..<2 {
            var request = URLRequest(url: url("chat/completions"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            request.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
            request.httpBody = body
            let bytes: URLSession.AsyncBytes, response: URLResponse
            do { (bytes, response) = try await urls.bytes(for: request) } catch let error as URLError where Self.offline.contains(error.code) {
                throw AsteriaIntelligenceError.offline
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 && attempt == 0 { forget(); continue }
            guard status == 200 else {
                var data = Data()
                for try await byte in bytes { data.append(byte); if data.count > 65_536 { break } }
                throw Self.failure(status: status, data: data, response: response)
            }
            for try await line in bytes.lines {
                try Task.checkCancellation()
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" { break }
                for event in Self.events(in: Data(payload.utf8)) { yield(event) }
            }
            return
        }
        throw AsteriaIntelligenceError.unavailable("Asteria Intelligence couldn't start. Try again in a moment.")
    }

    /// The events in one server-sent chunk.
    static func events(in payload: Data) -> [IntelligenceEvent] {
        guard let chunk = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return [] }
        var events: [IntelligenceEvent] = []
        if let choices = chunk["choices"] as? [[String: Any]], let delta = choices.first?["delta"] as? [String: Any] {
            if let reasoning = delta["reasoning_content"] as? String, !reasoning.isEmpty { events.append(.reasoning(reasoning)) }
            if let text = delta["content"] as? String, !text.isEmpty { events.append(.text(text)) }
            for call in delta["tool_calls"] as? [[String: Any]] ?? [] {
                let function = call["function"] as? [String: Any]
                events.append(.toolCall(index: call["index"] as? Int ?? 0, id: call["id"] as? String, name: function?["name"] as? String,
                                        arguments: function?["arguments"] as? String ?? ""))
            }
        }
        if let usage = chunk["usage"] as? [String: Any], let prompt = usage["prompt_tokens"] as? Int {
            let cached = usage["prompt_cache_hit_tokens"] as? Int ?? (usage["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int ?? 0
            let reasoning = (usage["completion_tokens_details"] as? [String: Any])?["reasoning_tokens"] as? Int ?? 0
            events.append(.usage(prompt: prompt, cached: cached, completion: usage["completion_tokens"] as? Int ?? 0, reasoning: reasoning))
        }
        return events
    }

    /// The gateway's refusal as the error FoundationModels apps already handle.
    static func failure(status: Int, data: Data, response: URLResponse) -> Error {
        struct Body: Decodable { struct Inner: Decodable { let message: String? }; let error: Inner? }
        let message = (try? JSONDecoder().decode(Body.self, from: data))?.error?.message ?? ""
        switch status {
        case 429:
            let daily = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-Asteria-Limit") == "daily"
            return LanguageModelErrorBridge.rateLimited(message.isEmpty ? "Asteria Intelligence is busy. Try again in a moment." : message,
                                                        resets: daily ? IntelligenceClient.nextMidnightUTC() : nil)
        case 413: return LanguageModelErrorBridge.tooLong(message)
        case 403: return AsteriaIntelligenceError.unavailable(message.isEmpty ? "This copy of the app couldn't be verified." : message)
        case 503, 502: return AsteriaIntelligenceError.unavailable(message.isEmpty ? "Asteria Intelligence is busy. Try again in a moment." : message)
        default: return AsteriaIntelligenceError.failed(message.isEmpty ? "Asteria Intelligence couldn't finish that. Try again in a moment." : message)
        }
    }

    static func nextMidnightUTC() -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.nextDate(after: .now, matching: DateComponents(hour: 0, minute: 0), matchingPolicy: .nextTime) ?? .now.addingTimeInterval(86_400)
    }
}

nonisolated enum LanguageModelErrorBridge {
    static func rateLimited(_ message: String, resets: Date?) -> Error {
        LanguageModelError.rateLimited(.init(resetDate: resets, debugDescription: message))
    }
    static func tooLong(_ message: String) -> Error {
        LanguageModelError.contextSizeExceeded(.init(contextSize: AsteriaIntelligence.contextSize, tokenCount: 0,
                                                     debugDescription: message.isEmpty ? "That's more than Asteria Intelligence can read at once." : message))
    }
}
