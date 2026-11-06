// The Asteria Account in every Asteria app: sign in with a username and password (the plain username, like "maya";
// the account lives on Asteria Post's server as maya.post.asteria.technology), or make one, with no invite code. The
// account carries the person's Asteria tokens (The Asteria Subscription) and their Asteria chats into every app.
//
// Signing in once signs in every Asteria app on the device: the app that has the password makes a sign-in for each of
// the others and leaves it in the shared Keychain group, and each takes its own on its next launch. (Each app needs
// its own: the server rotates a sign-in's refresh token when it's used.) Asteria and Post keep their own account code
// and read the same items.
import Foundation
import Observation
import Security

/// One app's sign-in to the Asteria Account (an AT Protocol session on Asteria Post's server).
nonisolated public struct AsteriaIDSession: Codable, Sendable, Hashable {
    public var did: String
    public var handle: String
    public var accessJwt: String
    public var refreshJwt: String
    public var email: String?
    /// The server it belongs to (Post reads this).
    public var service: String? = AsteriaID.server.absoluteString

    /// The plain username: "maya" for maya.post.asteria.technology.
    public var username: String { AsteriaID.username(fromHandle: handle) }
}

@MainActor @Observable
public final class AsteriaID {
    public static let shared = AsteriaID()

    public private(set) var session: AsteriaIDSession?
    public var isSignedIn: Bool { session != nil }
    public var username: String? { session?.username }

    @ObservationIgnored private var refreshing: Task<AsteriaIDSession?, Never>?

    /// Asteria Post's server, which holds every Asteria Account.
    public nonisolated static var server: URL {
        #if DEBUG
        if let url = launchValue("-pds").flatMap(URL.init(string:)) { return url }
        #endif
        return URL(string: "https://post.asteria.technology")!
    }

    /// Asteria's account server (usernames, sign-ups, deleting an account).
    public nonisolated static var relay: URL {
        #if DEBUG
        if let url = launchValue("-relay").flatMap(URL.init(string:)) { return url }
        #endif
        return URL(string: "https://asteria.technology/wire")!
    }

    nonisolated static func launchValue(_ flag: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
    }

    /// The Asteria apps that share a sign-in on a device (each takes its own handoff).
    public nonisolated static let apps = ["technology.asteria.browse", "technology.asteria.foodandmood", "technology.asteria.box",
                                          "technology.asteria.zerotohero"]

    private init() {
        session = Keychain.readJSON(AsteriaIDSession.self, Self.ownItem)
        if session == nil, let handoff = Keychain.readJSON(AsteriaIDSession.self, Self.handoffItem(Bundle.main.bundleIdentifier ?? ""), shared: true) {
            Keychain.write(nil, Self.handoffItem(Bundle.main.bundleIdentifier ?? ""), shared: true)
            adopt(handoff)
        }
    }

    // MARK: Names

    /// "@Maya" or "maya.post.asteria.technology" → "maya".
    public nonisolated static func username(fromHandle typed: String) -> String {
        var name = typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if name.hasPrefix("@") { name.removeFirst() }
        for suffix in [".post.asteria.technology", ".post"] where name.hasSuffix(suffix) { name = String(name.dropLast(suffix.count)) }
        return name
    }

    /// What to sign in with: the full handle for a username, or an email address as typed.
    nonisolated static func identifier(for typed: String) -> String {
        let name = username(fromHandle: typed)
        return name.contains("@") || name.contains(".") ? name : name + ".post.asteria.technology"
    }

    // MARK: Signing in, up and out

    /// Signs in with a username (or email) and password.
    public func signIn(username typed: String, password: String) async throws {
        let session = try await Self.createSession(identifier: Self.identifier(for: typed), password: password)
        adopt(session)
        await handOff(identifier: Self.identifier(for: typed), password: password)
        _ = try? await Self.register(token: session.accessJwt, displayName: nil)
    }

    nonisolated public struct UsernameCheck: Decodable, Sendable { public let username: String; public let available: Bool; public let reason: String? }

    /// Whether a username is free, and why not.
    public nonisolated static func check(username: String) async -> UsernameCheck? {
        let name = Self.username(fromHandle: username)
        guard !name.isEmpty, let escaped = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return try? await request(relay.appending(path: "v1/usernames/\(escaped)"), method: "GET", body: nil as [String: String]?, as: UsernameCheck.self)
    }

    /// Makes a new Asteria Account (no invite code: the account server makes one for this sign-up).
    public func signUp(name: String, username typed: String, email: String, password: String) async throws {
        let username = Self.username(fromHandle: typed)
        struct Code: Decodable { let handle: String; let inviteCode: String? }
        let code = try await Self.request(Self.relay.appending(path: "v1/signup"), method: "POST", body: ["username": username], as: Code.self)
        var body = ["handle": code.handle, "email": email.trimmingCharacters(in: .whitespaces), "password": password]
        if let invite = code.inviteCode { body["inviteCode"] = invite }
        let session = try await Self.request(Self.server.appending(path: "xrpc/com.atproto.server.createAccount"), method: "POST",
                                             body: body, as: AsteriaIDSession.self)
        adopt(session)
        _ = try? await Self.register(token: session.accessJwt, displayName: name.trimmingCharacters(in: .whitespaces))
        await handOff(identifier: code.handle, password: password)
    }

    /// Signs out of this app (the other apps stay signed in).
    public func signOut() {
        session = nil
        Keychain.write(nil, Self.ownItem)
        AsteriaIntelligence.accountChanged()
    }

    /// Deletes the Asteria Account everywhere: Asteria, Post, every app's sign-in, tokens and chats. Needs the
    /// password again.
    public func deleteAccount(password: String) async throws {
        guard let handle = session?.handle else { return }
        let fresh = try await Self.createSession(identifier: handle, password: password)
        _ = try await Self.requestRaw(Self.relay.appending(path: "v1/accounts/delete"), method: "POST", body: ["pdsToken": fresh.accessJwt])
        for app in Self.apps { Keychain.write(nil, Self.handoffItem(app), shared: true) }
        Keychain.write(nil, "post.handoff", shared: true)
        signOut()
    }

    /// A current access token for Asteria Intelligence, refreshed when it's about to expire. Nil when signed out or
    /// the sign-in has ended.
    public func accessToken() async -> String? {
        guard let session else { return nil }
        guard let expires = Self.expiry(session.accessJwt) else { return session.accessJwt }
        if expires.timeIntervalSinceNow > 300 { return session.accessJwt }
        if let refreshing { return await refreshing.value?.accessJwt }
        let task = Task { () -> AsteriaIDSession? in
            do {
                let fresh = try await Self.request(Self.server.appending(path: "xrpc/com.atproto.server.refreshSession"), method: "POST",
                                                   body: nil as [String: String]?, bearer: session.refreshJwt, as: AsteriaIDSession.self)
                return fresh
            } catch let failure as Failure where failure.status == 400 || failure.status == 401 {
                return nil  // the sign-in ended (signed out elsewhere, password changed)
            } catch {
                return session  // offline: keep it and try again later
            }
        }
        refreshing = task
        let fresh = await task.value
        refreshing = nil
        if let fresh {
            if fresh != session { adopt(fresh, announce: false) }
            return fresh.accessJwt
        }
        signOut()
        return nil
    }

    private func adopt(_ session: AsteriaIDSession, announce: Bool = true) {
        var session = session
        session.service = Self.server.absoluteString
        self.session = session
        Keychain.writeJSON(session, Self.ownItem)
        if announce { AsteriaIntelligence.accountChanged() }
    }

    /// Makes a sign-in for each other Asteria app on this device (Post too) and leaves it in the shared Keychain, so
    /// they're signed in the next time they open. Asteria and Post call this after their own sign-ins.
    public func handOff(identifier: String, password: String) async {
        let mine = Bundle.main.bundleIdentifier ?? ""
        for app in Self.apps where app != mine && Keychain.readJSON(AsteriaIDSession.self, Self.handoffItem(app), shared: true) == nil {
            guard let session = try? await Self.createSession(identifier: identifier, password: password) else { return }
            if !Keychain.writeJSON(session, Self.handoffItem(app), shared: true) { return }  // no shared group in this build
        }
        if mine != "technology.asteria.post", let session = try? await Self.createSession(identifier: identifier, password: password) {
            Keychain.writeJSON(session, "post.handoff", shared: true)
        }
    }

    // MARK: Server calls

    nonisolated public struct Failure: LocalizedError, Sendable {
        public let status: Int
        public let message: String
        public var errorDescription: String? { message }
    }

    static var ownItem: String { "asteria.id" }
    static func handoffItem(_ bundle: String) -> String { "handoff." + bundle }

    nonisolated static func createSession(identifier: String, password: String) async throws -> AsteriaIDSession {
        do {
            return try await request(server.appending(path: "xrpc/com.atproto.server.createSession"), method: "POST",
                                     body: ["identifier": identifier, "password": password], as: AsteriaIDSession.self)
        } catch let failure as Failure where failure.status == 401 || failure.status == 400 {
            throw Failure(status: failure.status, message: "That username and password don't match an Asteria Account.")
        }
    }

    @discardableResult
    nonisolated static func register(token: String, displayName: String?) async throws -> Data {
        var body = ["pdsToken": token]
        if let displayName, !displayName.isEmpty { body["displayName"] = displayName }
        return try await requestRaw(relay.appending(path: "v1/accounts"), method: "POST", body: body)
    }

    nonisolated static func request<T: Decodable, B: Encodable>(_ url: URL, method: String, body: B?, bearer: String? = nil, as: T.Type) async throws -> T {
        let data = try await requestRaw(url, method: method, body: body, bearer: bearer)
        return try JSONDecoder().decode(T.self, from: data)
    }

    nonisolated static func requestRaw<B: Encodable>(_ url: URL, method: String, body: B?, bearer: String? = nil) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        let data: Data, response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: request) } catch {
            throw Failure(status: 0, message: "Asteria couldn't be reached. Check your connection.")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = (try? JSONDecoder().decode(RelayBody.self, from: data))?.error?.message
                ?? (try? JSONDecoder().decode(PDSBody.self, from: data))?.message
                ?? "Something went wrong. Try again in a moment."
            throw Failure(status: status, message: message)
        }
        return data
    }

    nonisolated struct PDSBody: Decodable { let error: String?; let message: String? }
    nonisolated struct RelayBody: Decodable { struct Inner: Decodable { let message: String? }; let error: Inner? }

    /// When a JWT expires (its `exp` claim), without checking its signature.
    nonisolated static func expiry(_ jwt: String) -> Date? {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var base64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64), let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = (claims["exp"] as? Double) ?? (claims["exp"] as? Int).map(Double.init) else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    // MARK: Keychain

    /// This app's own items, plus the shared group every Asteria app can read (KZFR2T5L2A.technology.asteria.account).
    /// A build without the shared group just can't hand off; signing in still works.
    nonisolated enum Keychain {
        static let service = "technology.asteria.id"
        static let sharedService = "technology.asteria.account"
        static let sharedGroup = "KZFR2T5L2A.technology.asteria.account"

        /// A Mac app signed without a provisioning profile (Developer ID) can't use the data protection keychain; it
        /// keeps its own items in the login keychain instead, and can't share.
        static let dataProtection: Bool = {
            #if os(macOS)
            let probe: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                        kSecAttrAccount as String: "probe", kSecUseDataProtectionKeychain as String: true]
            return SecItemCopyMatching(probe as CFDictionary, nil) != errSecMissingEntitlement
            #else
            return true
            #endif
        }()

        static func base(_ account: String, shared: Bool) -> [String: Any] {
            var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                        kSecAttrService as String: shared ? sharedService : service,
                                        kSecAttrAccount as String: account]
            if dataProtection { query[kSecUseDataProtectionKeychain as String] = true }
            if shared { query[kSecAttrAccessGroup as String] = sharedGroup }
            return query
        }

        static func readJSON<T: Decodable>(_ type: T.Type, _ account: String, shared: Bool = false) -> T? {
            if shared && !dataProtection { return nil }
            var query = base(account, shared: shared)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
            return try? JSONDecoder().decode(T.self, from: data)
        }

        @discardableResult
        static func writeJSON<T: Encodable>(_ value: T, _ account: String, shared: Bool = false) -> Bool {
            write(try? JSONEncoder().encode(value), account, shared: shared)
        }

        @discardableResult
        static func write(_ data: Data?, _ account: String, shared: Bool = false) -> Bool {
            if shared && !dataProtection { return false }
            let query = base(account, shared: shared)
            SecItemDelete(query as CFDictionary)
            guard let data else { return true }
            var add = query
            add[kSecValueData as String] = data
            if dataProtection { add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly }
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
    }
}
