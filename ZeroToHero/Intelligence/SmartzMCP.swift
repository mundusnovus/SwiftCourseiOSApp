// The Model Context Protocol, for connectors in every Asteria app: the client (JSON-RPC 2.0 over Streamable HTTP,
// with sessions and bearer tokens) and signing in, as the MCP authorization spec describes (protected resource
// metadata, dynamic client registration, PKCE in Apple's secure web sheet). Each app signs in as itself (its bundle ID
// is its callback scheme); the tokens go in the Keychain group every Asteria app shares, synced with iCloud Keychain,
// so a connector added in one app works in the others and on your other devices. Moved here from the Smartz app.
import AuthenticationServices
import CryptoKit
import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// A tool a connector offers.
nonisolated public struct SmartzMCPToolInfo: Codable, Sendable, Hashable, Identifiable {
    public var id: String { name }
    public var name: String
    public var title: String?
    public var description: String
    /// The tool's JSON Schema for its arguments, as JSON text.
    public var inputSchema: String
    public var readOnly: Bool?
}

nonisolated public enum SmartzMCPError: LocalizedError {
    case needsSignIn(resourceMetadata: URL?)
    case server(String)
    case badResponse
    public var errorDescription: String? {
        switch self {
        case .needsSignIn: "This connector needs you to sign in."
        case .server(let message): message
        case .badResponse: "The connector sent back something unexpected."
        }
    }
}

actor SmartzMCPClient {
    static let protocolVersion = "2025-06-18"
    static let shared = SmartzMCPClient()

    private var sessions: [String: String] = [:]        // connector URL → Mcp-Session-Id
    private var initialized: Set<String> = []
    private var nextID = 1

    private let urlSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 45
        return URLSession(configuration: config)
    }()

    /// Everything the connector offers (every page of tools/list).
    func listTools(_ server: SmartzConnectorEndpoint) async throws -> [SmartzMCPToolInfo] {
        try await ensureInitialized(server)
        var tools: [SmartzMCPToolInfo] = []
        var cursor: String?
        repeat {
            var params: [String: Any] = [:]
            if let cursor { params["cursor"] = cursor }
            let result = try await call(server, method: "tools/list", params: params)
            for item in result["tools"] as? [[String: Any]] ?? [] {
                guard let name = item["name"] as? String else { continue }
                let schema = (try? JSONSerialization.data(withJSONObject: item["inputSchema"] ?? ["type": "object"])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
                let annotations = item["annotations"] as? [String: Any]
                tools.append(SmartzMCPToolInfo(name: name, title: item["title"] as? String ?? annotations?["title"] as? String,
                                               description: (item["description"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                                               inputSchema: schema, readOnly: annotations?["readOnlyHint"] as? Bool))
            }
            cursor = result["nextCursor"] as? String
        } while cursor != nil && tools.count < 500
        return tools
    }

    /// Calls a tool. Returns its text (and a note if the tool itself reported an error).
    func callTool(_ server: SmartzConnectorEndpoint, name: String, argumentsJSON: String) async throws -> String {
        try await ensureInitialized(server)
        let arguments = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) ?? [:]
        let result = try await call(server, method: "tools/call", params: ["name": name, "arguments": arguments])
        var parts: [String] = []
        for item in result["content"] as? [[String: Any]] ?? [] {
            switch item["type"] as? String {
            case "text": if let text = item["text"] as? String { parts.append(text) }
            case "resource":
                if let resource = item["resource"] as? [String: Any] {
                    parts.append((resource["text"] as? String) ?? "[\(resource["uri"] as? String ?? "resource")]")
                }
            case "resource_link": parts.append("[\(item["name"] as? String ?? "link"): \(item["uri"] as? String ?? "")]")
            case "image": parts.append("[an image]")
            default: break
            }
        }
        if parts.isEmpty, let structured = result["structuredContent"],
           let data = try? JSONSerialization.data(withJSONObject: structured) {
            parts.append(String(decoding: data, as: UTF8.self))
        }
        let text = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if result["isError"] as? Bool == true { return "The tool reported a problem: \(text)" }
        return text.isEmpty ? "(The tool returned nothing.)" : text
    }

    func forget(_ url: String) {
        sessions[url] = nil
        initialized.remove(url)
    }

    // MARK: Plumbing

    private func ensureInitialized(_ server: SmartzConnectorEndpoint) async throws {
        guard !initialized.contains(server.url) else { return }
        _ = try await call(server, method: "initialize", params: [
            "protocolVersion": Self.protocolVersion,
            "capabilities": [String: Any](),
            "clientInfo": ["name": "Smartz", "title": "Smartz in \(Smartz.appName)", "version": Self.appVersion],
        ], initializing: true)
        try? await notify(server, method: "notifications/initialized")
        initialized.insert(server.url)
    }

    /// The app's version (versions are named after the iOS release they ship with).
    nonisolated static var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "27.2" }

    private func headers(_ server: SmartzConnectorEndpoint, token: String?) -> [String: String] {
        #if os(macOS)
        let platform = "macOS"
        #else
        let platform = "iOS"
        #endif
        var headers = ["Content-Type": "application/json", "Accept": "application/json, text/event-stream",
                       "MCP-Protocol-Version": Self.protocolVersion, "User-Agent": "Smartz/\(Self.appVersion) (\(platform))"]
        if let session = sessions[server.url] { headers["Mcp-Session-Id"] = session }
        if let token { headers["Authorization"] = "Bearer \(token)" }
        return headers
    }

    private func notify(_ server: SmartzConnectorEndpoint, method: String) async throws {
        guard let url = URL(string: server.url) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let token = try await server.token()
        for (key, value) in headers(server, token: token) { request.setValue(value, forHTTPHeaderField: key) }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "method": method])
        _ = try await urlSession.data(for: request)
    }

    private func call(_ server: SmartzConnectorEndpoint, method: String, params: [String: Any], initializing: Bool = false, retried: Bool = false) async throws -> [String: Any] {
        guard let url = URL(string: server.url) else { throw SmartzMCPError.badResponse }
        let id = nextID
        nextID += 1
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let token = try await server.token()
        for (key, value) in headers(server, token: token) { request.setValue(value, forHTTPHeaderField: key) }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SmartzMCPError.badResponse }
        if http.statusCode == 401 || http.statusCode == 403 {
            if !retried, token != nil, try await server.refresh() { return try await call(server, method: method, params: params, initializing: initializing, retried: true) }
            throw SmartzMCPError.needsSignIn(resourceMetadata: Self.resourceMetadata(http))
        }
        if http.statusCode == 404, !initializing, sessions[server.url] != nil, !retried {
            // The server forgot our session: start again.
            forget(server.url)
            try await ensureInitialized(server)
            return try await call(server, method: method, params: params, retried: true)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw SmartzMCPError.server("The connector answered \(http.statusCode).")
        }
        if let session = http.value(forHTTPHeaderField: "Mcp-Session-Id") { sessions[server.url] = session }
        let message: [String: Any]
        if http.value(forHTTPHeaderField: "Content-Type")?.contains("text/event-stream") == true {
            message = Self.eventStreamMessage(data, id: id) ?? [:]
        } else {
            message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        }
        if let error = message["error"] as? [String: Any] {
            throw SmartzMCPError.server(error["message"] as? String ?? "The connector couldn't do that.")
        }
        guard let result = message["result"] as? [String: Any] else { throw SmartzMCPError.badResponse }
        return result
    }

    /// The JSON-RPC response with our id, from a text/event-stream body.
    static func eventStreamMessage(_ data: Data, id: Int) -> [String: Any]? {
        let text = String(decoding: data, as: UTF8.self)
        var found: [String: Any]?
        var buffer = ""
        func flush() {
            guard !buffer.isEmpty else { return }
            if let object = (try? JSONSerialization.jsonObject(with: Data(buffer.utf8))) as? [String: Any] {
                if (object["id"] as? Int) == id || (object["id"] as? String) == String(id) || (found == nil && object["result"] != nil) { found = object }
            }
            buffer = ""
        }
        for line in text.components(separatedBy: .newlines) {
            if line.hasPrefix("data:") {
                buffer += line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            } else if line.isEmpty {
                flush()
            }
        }
        flush()
        return found
    }

    static func resourceMetadata(_ response: HTTPURLResponse) -> URL? {
        guard let header = response.value(forHTTPHeaderField: "WWW-Authenticate"),
              let range = header.range(of: #"resource_metadata="([^"]+)""#, options: .regularExpression) else { return nil }
        let value = header[range].replacingOccurrences(of: "resource_metadata=", with: "").replacingOccurrences(of: "\"", with: "")
        return URL(string: value)
    }
}

/// What the client needs to reach one connector: its address and how to get a token. Sendable, so tools can carry it.
nonisolated public struct SmartzConnectorEndpoint: Sendable, Hashable {
    let id: String
    let url: String
    let auth: String

    func token() async throws -> String? {
        switch auth {
        case "none": return nil
        case "token": return SmartzConnectorTokens.read(id)?.accessToken
        default: return try await SmartzMCPAuth.validToken(for: id)
        }
    }

    /// Tries a refresh after a 401. True if there's a new token to retry with.
    func refresh() async throws -> Bool {
        guard auth != "none", auth != "token" else { return false }
        return (try? await SmartzMCPAuth.refresh(id)) != nil
    }
}

// MARK: Tokens

/// A connector's tokens, in the shared Keychain group (synced with iCloud Keychain).
nonisolated struct SmartzConnectorTokens: Codable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
    var tokenEndpoint: String?
    var clientID: String?
    var clientSecret: String?
    var resource: String?
    var scope: String?

    static func read(_ id: String) -> SmartzConnectorTokens? { SmartzVault.readJSON(SmartzConnectorTokens.self, "connector.\(id)") }
    static func save(_ tokens: SmartzConnectorTokens?, for id: String) {
        if let tokens { SmartzVault.writeJSON(tokens, "connector.\(id)") } else { SmartzVault.delete("connector.\(id)") }
    }
}

/// What every Asteria app shares in the Keychain, synced with iCloud Keychain: connectors and their sign-ins. Where
/// the shared group isn't available (a copy of a Mac app from the web), it's this app's own login keychain.
nonisolated enum SmartzVault {
    static let service = "technology.asteria.smartz"

    private static var shared: Bool { AsteriaID.Keychain.dataProtection && groupWorks }
    private static let groupWorks: Bool = {
        var probe = base("probe", shared: true)
        probe[kSecReturnData as String] = false
        let status = SecItemCopyMatching(probe as CFDictionary, nil)
        return status != errSecMissingEntitlement
    }()

    static func base(_ account: String, shared: Bool) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        if shared {
            query[kSecUseDataProtectionKeychain as String] = true
            query[kSecAttrAccessGroup as String] = AsteriaID.Keychain.sharedGroup
            query[kSecAttrSynchronizable as String] = kCFBooleanTrue
        }
        return query
    }

    static func read(_ account: String) -> Data? {
        var query = base(account, shared: shared)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func readJSON<T: Decodable>(_ type: T.Type, _ account: String) -> T? {
        read(account).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    static func write(_ data: Data, _ account: String) {
        let query = base(account, shared: shared)
        let update: [String: Any] = [kSecValueData as String: data]
        if SecItemUpdate(query as CFDictionary, update as CFDictionary) == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func writeJSON<T: Encodable>(_ value: T, _ account: String) {
        if let data = try? JSONEncoder().encode(value) { write(data, account) }
    }

    static func delete(_ account: String) {
        SecItemDelete(base(account, shared: shared) as CFDictionary)
    }
}

// MARK: Signing in

nonisolated public enum SmartzMCPAuth {
    /// This app's bundle ID: the callback scheme a service sends you back to.
    public nonisolated static var appID: String { Bundle.main.bundleIdentifier ?? "technology.asteria.wire" }
    public nonisolated static var redirectURI: String { appID + ":/oauth/callback" }

    nonisolated struct AuthServer: Sendable {
        var authorizationEndpoint: URL
        var tokenEndpoint: URL
        var registrationEndpoint: URL?
        var scopes: [String]
    }

    nonisolated public enum AuthError: LocalizedError {
        case noAuthServer, registrationFailed(String), cancelled, tokenFailed(String), needsClientID
        public var errorDescription: String? {
            switch self {
            case .noAuthServer: "This connector didn't say how to sign in."
            case .registrationFailed(let why): "Smartz couldn't register with this service (\(why))."
            case .cancelled: "Sign-in was cancelled."
            case .tokenFailed(let why): "Sign-in didn't finish (\(why))."
            case .needsClientID: "This service needs an OAuth client ID (see the connector's setup notes)."
            }
        }
    }

    // MARK: Tokens

    nonisolated static func validToken(for id: String) async throws -> String? {
        guard let tokens = SmartzConnectorTokens.read(id) else { return nil }
        if let expires = tokens.expiresAt, expires < .now.addingTimeInterval(60), tokens.refreshToken != nil {
            return try await refresh(id)?.accessToken ?? tokens.accessToken
        }
        return tokens.accessToken
    }

    @discardableResult
    nonisolated static func refresh(_ id: String) async throws -> SmartzConnectorTokens? {
        guard var tokens = SmartzConnectorTokens.read(id), let refresh = tokens.refreshToken,
              let endpoint = tokens.tokenEndpoint.flatMap(URL.init(string:)) else { return nil }
        var form = ["grant_type": "refresh_token", "refresh_token": refresh]
        if let client = tokens.clientID { form["client_id"] = client }
        if let secret = tokens.clientSecret { form["client_secret"] = secret }
        if let resource = tokens.resource { form["resource"] = resource }
        let json = try await post(endpoint, form: form)
        guard let access = json["access_token"] as? String else { return nil }
        tokens.accessToken = access
        if let newRefresh = json["refresh_token"] as? String { tokens.refreshToken = newRefresh }
        tokens.expiresAt = (json["expires_in"] as? Double).map { Date.now.addingTimeInterval($0) }
        SmartzConnectorTokens.save(tokens, for: id)
        return tokens
    }

    // MARK: Signing in

    /// The full OAuth sign-in for an MCP server that supports discovery and dynamic client registration.
    @MainActor
    static func signIn(connectorID: String, serverURL: String, resourceMetadata: URL?, name: String) async throws {
        let server = try await discover(serverURL: serverURL, resourceMetadata: resourceMetadata)
        let (clientID, secret) = try await register(server, name: name)
        try await authorize(connectorID: connectorID, server: server, clientID: clientID, clientSecret: secret,
                            redirect: redirectURI, scheme: appID, resource: serverURL)
    }

    /// Sign-in with a client ID you registered yourself (Google Workspace, Slack, HubSpot, Box).
    @MainActor
    static func signIn(connectorID: String, serverURL: String, catalog: SmartzConnectorEntry, clientID: String) async throws {
        guard let authorize = catalog.authorizeURL.flatMap(URL.init(string:)), let token = catalog.tokenURL.flatMap(URL.init(string:)) else {
            throw AuthError.noAuthServer
        }
        let server = AuthServer(authorizationEndpoint: authorize, tokenEndpoint: token, registrationEndpoint: nil, scopes: catalog.scopes)
        // Google's iOS clients redirect to the reversed client ID.
        let isGoogle = catalog.auth == .google
        let reversed = clientID.split(separator: ".").reversed().joined(separator: ".")
        let scheme = isGoogle ? reversed : appID
        let redirect = isGoogle ? "\(reversed):/oauth2redirect" : redirectURI
        try await self.authorize(connectorID: connectorID, server: server, clientID: clientID, clientSecret: nil, redirect: redirect,
                                 scheme: scheme, resource: isGoogle ? nil : serverURL)
    }

    nonisolated static func discover(serverURL: String, resourceMetadata: URL?) async throws -> AuthServer {
        guard let server = URL(string: serverURL), let host = server.host else { throw AuthError.noAuthServer }
        let origin = "\(server.scheme ?? "https")://\(host)\(server.port.map { ":\($0)" } ?? "")"
        var candidates: [URL] = []
        if let resourceMetadata { candidates.append(resourceMetadata) }
        let path = server.path == "/" ? "" : server.path
        candidates += ["\(origin)/.well-known/oauth-protected-resource\(path)", "\(origin)/.well-known/oauth-protected-resource"].compactMap(URL.init(string:))
        var issuer = origin
        var scopes: [String] = []
        for url in candidates {
            if let json = try? await get(url), let servers = json["authorization_servers"] as? [String], let first = servers.first {
                issuer = first
                scopes = json["scopes_supported"] as? [String] ?? []
                break
            }
        }
        guard let issuerURL = URL(string: issuer.hasSuffix("/") ? String(issuer.dropLast()) : issuer), let issuerHost = issuerURL.host else { throw AuthError.noAuthServer }
        let issuerOrigin = "\(issuerURL.scheme ?? "https")://\(issuerHost)\(issuerURL.port.map { ":\($0)" } ?? "")"
        let issuerPath = issuerURL.path == "/" ? "" : issuerURL.path
        let metadataURLs = ["\(issuerOrigin)/.well-known/oauth-authorization-server\(issuerPath)",
                            "\(issuerOrigin)/.well-known/openid-configuration\(issuerPath)",
                            "\(issuer)/.well-known/oauth-authorization-server",
                            "\(issuer)/.well-known/openid-configuration"].compactMap(URL.init(string:))
        for url in metadataURLs {
            guard let json = try? await get(url), let authorize = (json["authorization_endpoint"] as? String).flatMap(URL.init(string:)),
                  let token = (json["token_endpoint"] as? String).flatMap(URL.init(string:)) else { continue }
            let supported = json["scopes_supported"] as? [String] ?? []
            return AuthServer(authorizationEndpoint: authorize, tokenEndpoint: token,
                              registrationEndpoint: (json["registration_endpoint"] as? String).flatMap(URL.init(string:)),
                              scopes: scopes.isEmpty ? supported.filter { ["offline_access"].contains($0) } : scopes)
        }
        // Older servers: the endpoints at their default paths on the MCP server's own origin.
        guard let authorize = URL(string: "\(origin)/authorize"), let token = URL(string: "\(origin)/token") else { throw AuthError.noAuthServer }
        return AuthServer(authorizationEndpoint: authorize, tokenEndpoint: token, registrationEndpoint: URL(string: "\(origin)/register"), scopes: scopes)
    }

    nonisolated static func register(_ server: AuthServer, name: String) async throws -> (String, String?) {
        guard let endpoint = server.registrationEndpoint else { throw AuthError.needsClientID }
        var body: [String: Any] = ["client_name": "Smartz in \(Smartz.appName)", "redirect_uris": [redirectURI],
                                   "grant_types": ["authorization_code", "refresh_token"],
                                   "response_types": ["code"], "token_endpoint_auth_method": "none",
                                   "client_uri": "https://asteria.technology/smartz/", "software_id": appID,
                                   "software_version": SmartzMCPClient.appVersion]
        if !server.scopes.isEmpty { body["scope"] = server.scopes.joined(separator: " ") }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0), let id = json["client_id"] as? String else {
            throw AuthError.registrationFailed(json["error_description"] as? String ?? json["error"] as? String ?? "\((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        return (id, json["client_secret"] as? String)
    }

    @MainActor
    private static func authorize(connectorID: String, server: AuthServer, clientID: String, clientSecret: String?, redirect: String,
                                  scheme: String, resource: String?) async throws {
        let verifier = randomString(64)
        let challenge = base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = randomString(24)
        guard var parts = URLComponents(url: server.authorizationEndpoint, resolvingAgainstBaseURL: false) else { throw AuthError.noAuthServer }
        var items = parts.queryItems ?? []
        items += [URLQueryItem(name: "response_type", value: "code"), URLQueryItem(name: "client_id", value: clientID),
                  URLQueryItem(name: "redirect_uri", value: redirect), URLQueryItem(name: "code_challenge", value: challenge),
                  URLQueryItem(name: "code_challenge_method", value: "S256"), URLQueryItem(name: "state", value: state)]
        if !server.scopes.isEmpty { items.append(URLQueryItem(name: "scope", value: server.scopes.joined(separator: " "))) }
        if let resource { items.append(URLQueryItem(name: "resource", value: resource)) }
        if server.authorizationEndpoint.host?.contains("google") == true {
            items += [URLQueryItem(name: "access_type", value: "offline"), URLQueryItem(name: "prompt", value: "consent")]
        }
        parts.queryItems = items
        guard let url = parts.url else { throw AuthError.noAuthServer }
        let callback = try await SmartzWebSignIn.run(url: url, scheme: scheme)
        let query = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard query.first(where: { $0.name == "state" })?.value == state else { throw AuthError.tokenFailed("the reply didn't match") }
        if let error = query.first(where: { $0.name == "error" })?.value {
            throw error == "access_denied" ? AuthError.cancelled : AuthError.tokenFailed(error)
        }
        guard let code = query.first(where: { $0.name == "code" })?.value else { throw AuthError.tokenFailed("no code") }
        var form = ["grant_type": "authorization_code", "code": code, "redirect_uri": redirect, "client_id": clientID, "code_verifier": verifier]
        if let clientSecret { form["client_secret"] = clientSecret }
        if let resource { form["resource"] = resource }
        let json = try await post(server.tokenEndpoint, form: form)
        guard let access = json["access_token"] as? String else {
            throw AuthError.tokenFailed(json["error_description"] as? String ?? json["error"] as? String ?? "no token")
        }
        SmartzConnectorTokens.save(SmartzConnectorTokens(accessToken: access, refreshToken: json["refresh_token"] as? String,
                                                         expiresAt: (json["expires_in"] as? Double).map { Date.now.addingTimeInterval($0) },
                                                         tokenEndpoint: server.tokenEndpoint.absoluteString, clientID: clientID, clientSecret: clientSecret,
                                                         resource: resource, scope: json["scope"] as? String), for: connectorID)
    }

    // MARK: HTTP

    nonisolated private static func get(_ url: URL) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 12
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw SmartzMCPError.badResponse }
        return (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    nonisolated private static func post(_ url: URL, form: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        request.httpBody = Data(form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }.joined(separator: "&").utf8)
        let (data, _) = try await URLSession(configuration: .ephemeral).data(for: request)
        if let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { return json }
        // A few servers answer form-encoded.
        let text = String(decoding: data, as: UTF8.self)
        var out: [String: Any] = [:]
        for pair in text.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
            if kv.count == 2 { out[kv[0]] = kv[1] }
        }
        return out
    }

    nonisolated private static func randomString(_ count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return String(base64URL(Data(bytes)).prefix(count))
    }

    nonisolated static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

/// Apple's secure sign-in sheet, as one async call.
@MainActor
final class SmartzWebSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    private static var current: SmartzWebSignIn?
    private var session: ASWebAuthenticationSession?

    static func run(url: URL, scheme: String) async throws -> URL {
        let runner = SmartzWebSignIn()
        current = runner
        defer { current = nil }
        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callback: .customScheme(scheme)) { callback, error in
                if let callback { continuation.resume(returning: callback) }
                else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin { continuation.resume(throwing: SmartzMCPAuth.AuthError.cancelled) }
                else { continuation.resume(throwing: error ?? SmartzMCPAuth.AuthError.cancelled) }
            }
            session.presentationContextProvider = runner
            session.prefersEphemeralWebBrowserSession = false
            runner.session = session
            if !session.start() { continuation.resume(throwing: SmartzMCPAuth.AuthError.cancelled) }
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            #if canImport(UIKit)
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            return scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor(windowScene: scenes.first!)
            #else
            return NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
            #endif
        }
    }
}
