// Connectors: MCP servers Smartz can use in every Asteria app (Notion, Linear, GitHub, DeepWiki, any server by its
// URL). The list and the sign-ins live in the Keychain group every Asteria app shares, synced with iCloud Keychain, so a
// connector added in one app is in all of them, on all your devices. Each app keeps its own copy of a connector's tool
// list (fetched the first time it's needed). In a chat with Smartz, the few tools closest to what was asked are handed
// to the model; tools turn their JSON Schema into a dynamic generation schema, so Smartz fills in real arguments.
// Connectors are your accounts: only Smartz, in your own chats, uses them.
import Foundation
import FoundationModels
import NaturalLanguage
import Observation

/// A connected MCP server. Its tokens are kept apart (SmartzConnectorTokens).
nonisolated public struct SmartzConnector: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var url: String
    public var symbol: String
    /// "none", "oauth", "token", "google"
    public var auth: String
    public var catalogID: String?
    public var enabled: Bool
    /// OAuth client id you supplied (Google Workspace, Slack, HubSpot, Box).
    public var clientID: String?
    public var createdAt: Date

    public init(id: String = UUID().uuidString.lowercased(), name: String, url: String, symbol: String, auth: String,
                catalogID: String?, enabled: Bool = true, clientID: String? = nil, createdAt: Date = .now) {
        self.id = id; self.name = name; self.url = url; self.symbol = symbol; self.auth = auth; self.catalogID = catalogID
        self.enabled = enabled; self.clientID = clientID; self.createdAt = createdAt
    }

    public var endpoint: SmartzConnectorEndpoint { SmartzConnectorEndpoint(id: id, url: url, auth: auth) }
}

@MainActor @Observable
public final class SmartzConnectors {
    public static let shared = SmartzConnectors()

    public private(set) var list: [SmartzConnector] = []
    /// Each connector's tools, as this app last fetched them.
    public private(set) var tools: [String: [SmartzMCPToolInfo]] = [:]
    /// What's happening with each connector: "Signing in…", "12 tools", an error.
    public private(set) var status: [String: String] = [:]
    public private(set) var busy: Set<String> = []
    /// "Using Notion…", while a connector is working on an answer.
    public var activity: String?

    private init() {
        load()
    }

    // MARK: Storage

    private static let listKey = "connectors"

    private var toolsURL: URL {
        let folder = URL.applicationSupportDirectory.appending(path: "SmartzConnectors", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appending(path: "tools.json")
    }

    /// Reads the shared list again (another Asteria app may have changed it).
    public func load() {
        list = (SmartzVault.readJSON([SmartzConnector].self, Self.listKey) ?? []).sorted { $0.createdAt < $1.createdAt }
        if let data = try? Data(contentsOf: toolsURL), let cached = try? JSONDecoder().decode([String: [SmartzMCPToolInfo]].self, from: data) {
            tools = cached.filter { id, _ in list.contains { $0.id == id } }
        }
    }

    private func save() {
        SmartzVault.writeJSON(list, Self.listKey)
        if let data = try? JSONEncoder().encode(tools) { try? data.write(to: toolsURL, options: .atomic) }
    }

    private func upsert(_ connector: SmartzConnector) {
        if let index = list.firstIndex(where: { $0.id == connector.id }) { list[index] = connector } else { list.append(connector) }
        save()
    }

    // MARK: Adding

    /// Adds a directory entry (signing in if it needs it) and loads its tools.
    @discardableResult
    public func add(_ entry: SmartzConnectorEntry, secret: String? = nil, url: String? = nil) async throws -> SmartzConnector {
        let given = url?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let address = (given.isEmpty ? entry.url : given).trimmingCharacters(in: .whitespacesAndNewlines)
        let auth: String = switch entry.auth {
        case .none, .personalURL: "none"
        case .oauth: "oauth"
        case .token: "token"
        case .google, .clientID: "google"
        }
        var connector = list.first { $0.catalogID == entry.id }
            ?? SmartzConnector(name: entry.name, url: address, symbol: entry.symbol, auth: auth, catalogID: entry.id)
        connector.url = address
        connector.auth = auth
        let secret = secret?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        busy.insert(connector.id)
        defer { busy.remove(connector.id) }
        do {
            switch entry.auth {
            case .token:
                guard !secret.isEmpty else { throw SmartzMCPAuth.AuthError.needsClientID }
                SmartzConnectorTokens.save(SmartzConnectorTokens(accessToken: secret), for: connector.id)
            case .google, .clientID:
                guard !secret.isEmpty else { throw SmartzMCPAuth.AuthError.needsClientID }
                connector.clientID = secret
                status[connector.id] = "Signing in…"
                try await SmartzMCPAuth.signIn(connectorID: connector.id, serverURL: address, catalog: entry, clientID: secret)
            case .oauth:
                status[connector.id] = "Signing in…"
                try await SmartzMCPAuth.signIn(connectorID: connector.id, serverURL: address, resourceMetadata: nil, name: entry.name)
            case .none, .personalURL:
                break
            }
            upsert(connector)
            try await refreshTools(connector)
        } catch {
            status[connector.id] = error.localizedDescription
            throw error
        }
        return connector
    }

    /// Any MCP server by its URL. If it asks for a sign-in, the app does the OAuth dance.
    @discardableResult
    public func addCustom(name: String, url: String, token: String?) async throws -> SmartzConnector {
        let address = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = URL(string: address), parsed.scheme == "https" || parsed.host == "localhost" else {
            throw SmartzMCPError.server("Use the server's full https:// address.")
        }
        let token = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var connector = SmartzConnector(name: title.isEmpty ? parsed.host ?? "Connector" : title, url: address,
                                        symbol: "puzzlepiece.extension", auth: token.isEmpty ? "none" : "token", catalogID: nil)
        if !token.isEmpty { SmartzConnectorTokens.save(SmartzConnectorTokens(accessToken: token), for: connector.id) }
        busy.insert(connector.id)
        defer { busy.remove(connector.id) }
        do {
            upsert(connector)
            try await refreshTools(connector)
        } catch SmartzMCPError.needsSignIn(let metadata) {
            connector.auth = "oauth"
            upsert(connector)
            status[connector.id] = "Signing in…"
            try await SmartzMCPAuth.signIn(connectorID: connector.id, serverURL: address, resourceMetadata: metadata, name: connector.name)
            try await refreshTools(connector)
        }
        return connector
    }

    /// Adds a connector made elsewhere (the Smartz app's connectors from before 27.2.7), with its tokens and the tools
    /// it last listed.
    public func adopt(_ connector: SmartzConnector, tokens: Data?, tools known: [SmartzMCPToolInfo] = []) {
        guard !list.contains(where: { $0.id == connector.id || ($0.catalogID != nil && $0.catalogID == connector.catalogID) }) else { return }
        if let tokens, let decoded = try? JSONDecoder().decode(SmartzConnectorTokens.self, from: tokens) {
            SmartzConnectorTokens.save(decoded, for: connector.id)
        }
        if !known.isEmpty { tools[connector.id] = known }
        upsert(connector)
    }

    public func refreshTools(_ connector: SmartzConnector) async throws {
        status[connector.id] = "Connecting…"
        await SmartzMCPClient.shared.forget(connector.url)
        do {
            let fetched = try await SmartzMCPClient.shared.listTools(connector.endpoint)
            tools[connector.id] = fetched
            status[connector.id] = fetched.count == 1 ? "1 tool" : "\(fetched.count) tools"
            save()
        } catch {
            status[connector.id] = error.localizedDescription
            throw error
        }
    }

    /// Signs in again (after a token was revoked or expired for good).
    public func reconnect(_ connector: SmartzConnector) async {
        busy.insert(connector.id)
        defer { busy.remove(connector.id) }
        do {
            if connector.auth == "oauth" {
                try await SmartzMCPAuth.signIn(connectorID: connector.id, serverURL: connector.url, resourceMetadata: nil, name: connector.name)
            } else if connector.auth == "google", let entry = SmartzConnectorCatalog.entry(connector.catalogID), let client = connector.clientID {
                try await SmartzMCPAuth.signIn(connectorID: connector.id, serverURL: connector.url, catalog: entry, clientID: client)
            }
            try await refreshTools(connector)
        } catch {
            status[connector.id] = error.localizedDescription
        }
    }

    public func setEnabled(_ connector: SmartzConnector, _ on: Bool) {
        var changed = connector
        changed.enabled = on
        upsert(changed)
    }

    public func remove(_ connector: SmartzConnector) {
        SmartzConnectorTokens.save(nil, for: connector.id)
        list.removeAll { $0.id == connector.id }
        tools[connector.id] = nil
        status[connector.id] = nil
        save()
    }

    // MARK: Using them

    /// The connectors' tools closest to what was asked, at most `limit` (a few, so the model isn't handed dozens).
    public func tools(for message: String, limit: Int = 4) async -> [any Tool] {
        load()
        let enabled = list.filter(\.enabled)
        guard !enabled.isEmpty, limit > 0 else { return [] }
        for connector in enabled where tools[connector.id] == nil {
            try? await refreshTools(connector)  // first use in this app
        }
        let asked = message.lowercased()
        var scored: [(SmartzConnectorTool, Double)] = []
        for connector in enabled {
            let named = asked.contains(connector.name.lowercased())
            for info in tools[connector.id] ?? [] {
                guard let tool = SmartzConnectorTool(info, connector: connector) else { continue }
                let about = "\(connector.name) \(info.title ?? info.name.replacingOccurrences(of: "_", with: " ")) \(info.description.prefix(200))"
                scored.append((tool, Self.similarity(asked, about) + (named ? 0.5 : 0)))
            }
        }
        return scored.filter { $0.1 > 0.3 }.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    /// How close two texts are in meaning (Apple's sentence embeddings), or by shared words where there are none.
    nonisolated static func similarity(_ a: String, _ b: String) -> Double {
        if let embedding = NLEmbedding.sentenceEmbedding(for: .english) {
            let distance = embedding.distance(between: a, and: String(b.prefix(400)))
            if distance.isFinite { return max(0, 1 - distance / 2) }
        }
        let stop: Set<String> = ["the", "a", "an", "to", "of", "and", "or", "in", "on", "for", "my", "me", "is", "it", "what", "with", "can", "you"]
        let words = { (text: String) in Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 2 && !stop.contains($0) }) }
        let left = words(a), right = words(b)
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        return Double(left.intersection(right).count) / Double(min(left.count, right.count)) * 0.8
    }
}

// MARK: MCP tools as FoundationModels tools

nonisolated public struct SmartzConnectorTool: Tool {
    public typealias Arguments = GeneratedContent

    public let name: String
    public let description: String
    public let parameters: GenerationSchema
    let endpoint: SmartzConnectorEndpoint
    let toolName: String
    let connectorName: String
    /// The schema couldn't be mapped, so the model passes JSON text in one "arguments" field instead.
    let wrapped: Bool

    public init?(_ info: SmartzMCPToolInfo, connector: SmartzConnector) {
        self.endpoint = connector.endpoint
        self.toolName = info.name
        self.connectorName = connector.name
        let prefix = connector.name.lowercased().filter { $0.isLetter || $0.isNumber }.prefix(12)
        let raw = "\(prefix)_\(info.name)".map { $0.isLetter || $0.isNumber || $0 == "_" ? $0 : "_" }
        self.name = String(String(raw).prefix(60))
        self.description = "\(connector.name): \((info.title ?? info.description).prefix(260))"
        let json = (try? JSONSerialization.jsonObject(with: Data(info.inputSchema.utf8))) as? [String: Any] ?? [:]
        if let root = SmartzSchemaMapper.object(json, name: self.name, depth: 0), let schema = try? GenerationSchema(root: root, dependencies: []) {
            self.parameters = schema
            self.wrapped = false
        } else {
            let fallback = DynamicGenerationSchema(name: self.name, properties: [
                .init(name: "arguments", description: "The tool's arguments as a JSON object, following: \(info.inputSchema.prefix(600))",
                      schema: DynamicGenerationSchema(type: String.self)),
            ])
            guard let schema = try? GenerationSchema(root: fallback, dependencies: []) else { return nil }
            self.parameters = schema
            self.wrapped = true
        }
    }

    public func call(arguments: GeneratedContent) async throws -> String {
        let name = connectorName
        await MainActor.run { SmartzConnectors.shared.activity = "Using \(name)…" }
        defer { Task { @MainActor in SmartzConnectors.shared.activity = nil } }
        var json = arguments.jsonString
        if wrapped, let text = try? arguments.value(String.self, forProperty: "arguments") { json = text }
        do {
            let result = try await SmartzMCPClient.shared.callTool(endpoint, name: toolName, argumentsJSON: json)
            return String(result.prefix(6_000))
        } catch SmartzMCPError.needsSignIn {
            return "\(connectorName) needs you to sign in again (Settings › Smartz › Connectors)."
        } catch {
            return "\(connectorName) couldn't do that: \(error.localizedDescription)"
        }
    }
}

/// JSON Schema (what MCP tools declare) → the dynamic schemas Smartz generates against.
nonisolated enum SmartzSchemaMapper {
    static func object(_ json: [String: Any], name: String, depth: Int) -> DynamicGenerationSchema? {
        let properties = json["properties"] as? [String: Any] ?? [:]
        guard properties.count <= 24 else { return nil }
        let required = Set(json["required"] as? [String] ?? [])
        var mapped: [DynamicGenerationSchema.Property] = []
        for key in properties.keys.sorted() {
            guard let spec = properties[key] as? [String: Any] else { continue }
            guard let schema = map(spec, name: "\(name)_\(key)", depth: depth + 1) else { return nil }
            mapped.append(.init(name: key, description: (spec["description"] as? String).map { String($0.prefix(200)) },
                                schema: schema, isOptional: !required.contains(key)))
        }
        return DynamicGenerationSchema(name: name, description: (json["description"] as? String).map { String($0.prefix(200)) }, properties: mapped)
    }

    static func map(_ spec: [String: Any], name: String, depth: Int) -> DynamicGenerationSchema? {
        guard depth < 5 else { return nil }
        var type = spec["type"] as? String
        if type == nil, let types = spec["type"] as? [String] { type = types.first { $0 != "null" } }
        if type == nil, let options = (spec["anyOf"] ?? spec["oneOf"]) as? [[String: Any]],
           let first = options.first(where: { ($0["type"] as? String) != "null" }) {
            return map(first, name: name, depth: depth)
        }
        if let choices = spec["enum"] as? [String], !choices.isEmpty { return DynamicGenerationSchema(name: name, anyOf: choices) }
        switch type {
        case "string": return DynamicGenerationSchema(type: String.self)
        case "integer": return DynamicGenerationSchema(type: Int.self)
        case "number": return DynamicGenerationSchema(type: Double.self)
        case "boolean": return DynamicGenerationSchema(type: Bool.self)
        case "array":
            let items = (spec["items"] as? [String: Any]).flatMap { map($0, name: name + "_item", depth: depth + 1) } ?? DynamicGenerationSchema(type: String.self)
            return DynamicGenerationSchema(arrayOf: items, maximumElements: (spec["maxItems"] as? Int) ?? 20)
        case "object", nil:
            if spec["properties"] == nil { return type == nil ? DynamicGenerationSchema(type: String.self) : nil }
            return object(spec, name: name, depth: depth)
        default: return DynamicGenerationSchema(type: String.self)
        }
    }
}
