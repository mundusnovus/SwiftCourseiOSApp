// Asteria Intelligence: Asteria Technology's AI, the same in every Asteria app. It is a FoundationModels language model
// (AsteriaIntelligenceModel), so apps use it exactly like Apple's: LanguageModelSession, tools, @Generable answers,
// streaming. Requests go to Asteria's gateway at asteria.technology/intelligence, which holds the model provider's key.
//
// The shared files are AsteriaIntelligence*.swift in Asteria Search. Asteria, Post and Food and Mood keep copies
// (their tools/sync-intelligence.sh); Browse uses the package.
//
// Before anything is sent, the person says yes once (AsteriaIntelligencePermission.swift), as App Review guideline
// 5.1.2(i) asks of apps that share data with an AI service. An app that never asked can't send anything.
import Foundation
import FoundationModels
import Synchronization

/// Whether Asteria Intelligence can answer right now, in words a person can act on.
nonisolated public enum IntelligenceStatus: Sendable, Equatable {
    case available, needsPermission, turnedOff, unavailable

    public var explanation: String {
        switch self {
        case .available: "Ready"
        case .needsPermission: "Turn on Asteria Intelligence to use this."
        case .turnedOff: "Asteria Intelligence is off. Turn it on in Settings to use this."
        case .unavailable: "Asteria Intelligence isn't available right now."
        }
    }
}

nonisolated public enum AsteriaIntelligence {
    /// How an app with an account proves who is asking, so the person's daily allowance follows them across apps.
    /// Apps without one are checked with App Attest instead.
    public enum Credential: Sendable {
        /// An Asteria relay token (Asteria).
        case account(String)
        /// An Asteria Post access token (Post).
        case post(String)
    }

    struct Settings: Sendable {
        var server = URL(string: "https://asteria.technology/intelligence/v1")!
        var appName = "Asteria"
        var privacyURL = URL(string: "https://asteria.technology/privacy/")!
        var credential: (@Sendable () async -> Credential?)?
        var developmentKey: String?
    }

    static let settings = Mutex(Settings())

    /// Call once at launch. `credential` gives the signed-in account's token, or nil when there's none.
    public static func configure(appName: String, privacyURL: URL, credential: (@Sendable () async -> Credential?)? = nil) {
        settings.withLock {
            $0.appName = appName
            $0.privacyURL = privacyURL
            $0.credential = credential
        }
        #if DEBUG
        // Development: -intelligence-server http://localhost:8080/v1/intelligence -intelligence-dev-key <key>
        let arguments = ProcessInfo.processInfo.arguments
        func value(after flag: String) -> String? {
            arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        }
        settings.withLock {
            if let server = value(after: "-intelligence-server").flatMap(URL.init(string:)) { $0.server = server }
            $0.developmentKey = value(after: "-intelligence-dev-key")
        }
        #endif
    }

    /// The signed-in account changed (signed in, out, or deleted): start a new session with it, and refresh tokens
    /// and chats.
    public static func accountChanged() {
        Task {
            await IntelligenceClient.shared.reset()
            await AsteriaUsage.shared.refresh()
            await MainActor.run { NotificationCenter.default.post(name: accountDidChange, object: nil) }
        }
    }

    public static let accountDidChange = Notification.Name("AsteriaIntelligence.accountDidChange")

    /// The model, for `LanguageModelSession(model: AsteriaIntelligence.model, …)`.
    public static var model: AsteriaIntelligenceModel { AsteriaIntelligenceModel() }

    /// How much an app should put in one request. The model reads far more; this keeps answers quick and the daily
    /// allowance from going in one long chat.
    public static let contextSize = 96_000

    public static var appName: String { settings.withLock { $0.appName } }
    public static var privacyURL: URL { settings.withLock { $0.privacyURL } }

    // MARK: Permission

    public enum Permission: String, Sendable { case notAsked, granted, declined }

    static let permissionKey = "AsteriaIntelligence.permission"

    public static var permission: Permission {
        get { UserDefaults.standard.string(forKey: permissionKey).flatMap(Permission.init(rawValue:)) ?? .notAsked }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: permissionKey) }
    }

    /// The person said yes and hasn't turned it off.
    public static var isOn: Bool { permission == .granted }

    public static var status: IntelligenceStatus {
        switch permission {
        case .granted: .available
        case .notAsked: .needsPermission
        case .declined: .turnedOff
        }
    }

    /// Features can show their button whenever this is true: the first use asks for permission.
    public static var canOffer: Bool { permission != .declined }

    // MARK: Words

    /// Apple's recommended phrase for a locale other than U.S. English, so answers come in the person's language.
    public static var localeInstruction: String {
        let locale = Locale.current
        return Locale.Language(identifier: "en_US").isEquivalent(to: locale.language) ? "" : " The person's locale is \(locale.identifier)."
    }

    /// A sentence for any error from a session using Asteria Intelligence.
    public static func message(for error: Error) -> String {
        if let error = error as? AsteriaIntelligenceError { return error.localizedDescription }
        if let error = error as? LanguageModelError {
            switch error {
            case .rateLimited(let limited): return limited.debugDescription.isEmpty ? "Asteria Intelligence is busy. Try again in a moment." : limited.debugDescription
            case .contextSizeExceeded: return "That's more than Asteria Intelligence can read at once."
            case .guardrailViolation, .refusal: return "Asteria Intelligence won't help with that one."
            case .timeout: return "That took too long. Try again?"
            default: return "Asteria Intelligence couldn't finish that. Try again in a moment."
            }
        }
        if String(describing: error).contains("decodingFailure") { return "Asteria Intelligence's answer didn't come out right. Try again?" }
        if error is CancellationError { return "Stopped." }
        if (error as? URLError)?.code == .notConnectedToInternet { return AsteriaIntelligenceError.offline.localizedDescription }
        return "Asteria Intelligence couldn't finish that. Try again in a moment."
    }
}

/// Today's Asteria tokens: one token is a cent of Asteria Intelligence. Signed-in accounts get their tier's tokens
/// (The Asteria Subscription); apps without an account get a per-device allowance.
@MainActor @Observable
public final class AsteriaUsage {
    public static let shared = AsteriaUsage()

    public private(set) var tokensPerDay = 0
    public private(set) var tokensUsed = 0
    public private(set) var signedIn = false
    public private(set) var tier: String?
    public private(set) var tierName: String?
    public private(set) var resetsAt: Date?
    public private(set) var known = false

    public var tokensLeft: Int { max(0, tokensPerDay - tokensUsed) }

    nonisolated struct Report: Decodable, Sendable {
        let tokensPerDay: Int?
        let tokensUsed: Int?
        let signedIn: Bool?
        let tier: String?
        let tierName: String?
        let resetsAt: Date?
    }

    func apply(_ report: Report) {
        tokensPerDay = report.tokensPerDay ?? tokensPerDay
        tokensUsed = report.tokensUsed ?? tokensUsed
        signedIn = report.signedIn ?? signedIn
        tier = report.tier
        tierName = report.tierName
        resetsAt = report.resetsAt
        known = report.tokensPerDay != nil
    }

    /// Asks the gateway (after the person has turned Asteria Intelligence on).
    public func refresh() async {
        guard AsteriaIntelligence.isOn, let report = try? await IntelligenceClient.shared.usage() else { return }
        apply(report)
    }
}

nonisolated public enum AsteriaIntelligenceError: LocalizedError, Sendable, Equatable {
    /// The person hasn't said yes (or turned it off).
    case notAllowed
    case offline
    case unavailable(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notAllowed: "Asteria Intelligence is off. Turn it on in Settings to use this."
        case .offline: "Asteria Intelligence needs an internet connection."
        case .unavailable(let message), .failed(let message): message
        }
    }
}
