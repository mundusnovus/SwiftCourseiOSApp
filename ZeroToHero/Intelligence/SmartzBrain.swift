// What Smartz knows about the person, made from chats they harvest in any app: memories and a wiki, both private until
// they publish the wiki at smartz.chat/<username>. Plus their Smartz settings, which follow the account (voice,
// auto-speak, expressive voice, unified intelligence). Needs a signed-in Asteria Account (AsteriaID).
import Foundation

nonisolated public struct SmartzMemory: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let kind: String
    public let text: String
    public let app: String
    public let createdAt: Date
}

nonisolated public struct SmartzWikiPage: Codable, Identifiable, Hashable, Sendable {
    public let slug: String
    public let title: String
    public var body: String?
    public let updatedAt: Date
    public var id: String { slug }
}

nonisolated public struct SmartzSettings: Codable, Equatable, Sendable {
    public var wikiPublic = false
    /// Share de-identified skills from harvests so Smartz gets better for everyone (off unless the person turns it on).
    public var unified = false
    public var voice: String?
    public var expressive = false
    public var autoSpeak = false
    public var publicURL: URL?
    public init() {}
}

nonisolated public struct SmartzHarvest: Codable, Sendable {
    public struct Page: Codable, Hashable, Sendable { public let slug: String; public let title: String }
    public let summary: String
    public let memories: Int
    public let pages: [Page]
    public let skills: Int
}

/// A harvest, from any Asteria app: what was learned, and where.
nonisolated public struct SmartzHarvestRecord: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    /// The app it was harvested in ("Post", "Food and Mood"…).
    public let app: String
    public let title: String
    public let summary: String
    /// The wiki pages it wrote or added to.
    public let pages: [String]
    public let memories: Int
    public let createdAt: Date
}

nonisolated public enum SmartzBrain {
    /// Smartz learned something here (a harvest): the wiki and what Smartz knows refresh.
    public static let didLearn = Notification.Name("Smartz.didLearn")

    nonisolated struct HarvestList: Decodable { let harvests: [SmartzHarvestRecord] }
    nonisolated struct MemoryList: Decodable { let memories: [SmartzMemory] }
    nonisolated struct PageList: Decodable { let pages: [SmartzWikiPage]; let publicURL: URL? }
    nonisolated struct Summary: Decodable { let summary: String }
    nonisolated struct Taught: Encodable { struct Item: Encodable { let kind: String; let text: String }; let memories: [Item]; let app: String }
    nonisolated struct Added: Decodable { let added: Int }
    nonisolated struct Transcript: Encodable { let transcript: String; let title: String; let app: String }
    nonisolated struct Update: Encodable { var wikiPublic: Bool?; var unified: Bool?; var voice: String?; var expressive: Bool?; var autoSpeak: Bool? }

    static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T { try IntelligenceClient.decoder.decode(type, from: data) }
    static let none: [String: String]? = nil

    /// Learns from a chat that's on the Asteria Account: memories, wiki pages, and (if the person shares) skills.
    public static func harvest(thread: String) async throws -> SmartzHarvest {
        let harvest = try decode(SmartzHarvest.self, await IntelligenceClient.shared.json("POST", "smartz/harvest", body: ["thread": thread, "app": Smartz.appName]))
        await learned()
        return harvest
    }

    /// Every harvest, from every Asteria app, newest first (the Smartz app's wiki shows them).
    public static func harvests() async throws -> [SmartzHarvestRecord] {
        try decode(HarvestList.self, await IntelligenceClient.shared.json("GET", "smartz/harvests", body: none)).harvests
    }

    @MainActor static func learned() { NotificationCenter.default.post(name: didLearn, object: nil) }

    /// Learns from a chat that lives only on this device (the Smartz app's end-to-end encrypted chats): the transcript,
    /// labelled by speaker, is read for this harvest and not kept; only what's learned is.
    public static func harvest(transcript: String, title: String) async throws -> SmartzHarvest {
        let body = Transcript(transcript: String(transcript.suffix(60_000)), title: String(title.prefix(120)), app: Smartz.appName)
        let harvest = try decode(SmartzHarvest.self, await IntelligenceClient.shared.json("POST", "smartz/harvest", body: body))
        await learned()
        return harvest
    }

    /// Remembers these (taught by the person, or remembered in a chat). Returns how many were new.
    @discardableResult
    public static func remember(_ memories: [(kind: String, text: String)]) async throws -> Int {
        guard !memories.isEmpty else { return 0 }
        var added = 0
        for start in stride(from: 0, to: memories.count, by: 500) {
            let batch = memories[start..<min(start + 500, memories.count)].map { Taught.Item(kind: $0.kind, text: $0.text) }
            added += try decode(Added.self, await IntelligenceClient.shared.json("POST", "smartz/memories", body: Taught(memories: batch, app: Smartz.appName))).added
        }
        return added
    }

    public static func memories() async throws -> [SmartzMemory] {
        try decode(MemoryList.self, await IntelligenceClient.shared.json("GET", "smartz/memories", body: none)).memories
    }

    public static func forget(memory id: String) async throws {
        _ = try await IntelligenceClient.shared.json("DELETE", "smartz/memories/\(id)", body: none)
    }

    public static func forgetEverything() async throws {
        _ = try await IntelligenceClient.shared.json("DELETE", "smartz/memories", body: none)
    }

    public static func wiki() async throws -> (pages: [SmartzWikiPage], publicURL: URL?) {
        let list = try decode(PageList.self, await IntelligenceClient.shared.json("GET", "smartz/wiki", body: none))
        return (list.pages, list.publicURL)
    }

    public static func page(_ slug: String) async throws -> SmartzWikiPage {
        try decode(SmartzWikiPage.self, await IntelligenceClient.shared.json("GET", "smartz/wiki/\(slug)", body: none))
    }

    public static func save(page slug: String, title: String, body: String) async throws -> SmartzWikiPage {
        try decode(SmartzWikiPage.self, await IntelligenceClient.shared.json("PUT", "smartz/wiki/\(slug)", body: ["title": title, "body": body]))
    }

    public static func delete(page slug: String) async throws {
        _ = try await IntelligenceClient.shared.json("DELETE", "smartz/wiki/\(slug)", body: none)
    }

    public static func settings() async throws -> SmartzSettings {
        try decode(SmartzSettings.self, await IntelligenceClient.shared.json("GET", "smartz/settings", body: none))
    }

    @discardableResult
    public static func update(wikiPublic: Bool? = nil, unified: Bool? = nil, voice: String? = nil, expressive: Bool? = nil, autoSpeak: Bool? = nil) async throws -> SmartzSettings {
        let body = Update(wikiPublic: wikiPublic, unified: unified, voice: voice, expressive: expressive, autoSpeak: autoSpeak)
        return try decode(SmartzSettings.self, await IntelligenceClient.shared.json("PUT", "smartz/settings", body: body))
    }

    /// A short summary of a long chat's older turns, so the chat keeps going without its whole history.
    static func summarize(_ text: String) async throws -> String {
        try decode(Summary.self, await IntelligenceClient.shared.json("POST", "smartz/summarize", body: ["text": text])).summary
    }
}
