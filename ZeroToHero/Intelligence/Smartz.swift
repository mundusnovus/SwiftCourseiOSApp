// Smartz: Asteria Technology's AI, the same in every Asteria app. It is a FoundationModels language model
// (SmartzModel), so apps use it exactly like Apple's: LanguageModelSession, tools, @Generable answers,
// streaming. Requests go to Asteria's gateway at asteria.technology/intelligence, which holds Google's key and asks
// Gemini 4 Argon (since 27.2.8; DeepInfra before). Voice is ElevenLabs, through the same gateway (SmartzVoice.swift).
//
// The shared files are Smartz*.swift in Asteria Search (SmartzAccount.swift is the Asteria Account). Smartz, Post, Food and Mood, Box and
// Swift: Zero to Hero keep copies
// (their tools/sync-intelligence.sh); Browse uses the package.
//
// Before anything is sent, the person says yes once (SmartzPermission.swift), as App Review guideline
// 5.1.2(i) asks of apps that share data with an AI service. An app that never asked can't send anything. A yes is for
// the provider it named: one given before Google answered is asked for again, once.
import Foundation
import FoundationModels
import SwiftUI
import Synchronization

/// Whether Smartz can answer right now, in words a person can act on.
nonisolated public enum IntelligenceStatus: Sendable, Equatable {
    case available, needsPermission, turnedOff, unavailable

    public var explanation: String {
        switch self {
        case .available: "Ready"
        case .needsPermission: "Turn on Smartz to use this."
        case .turnedOff: "Smartz is off. Turn it on in Settings to use this."
        case .unavailable: "Smartz isn't available right now."
        }
    }
}

nonisolated public enum Smartz {
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
        var appName = "Smartz"
        var privacyURL = URL(string: "https://asteria.technology/privacy/")!
        var credential: (@Sendable () async -> Credential?)?
        var developmentKey: String?
        var tint: Color?
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
        #if os(iOS)
        // The button on top of the iPhone keyboard that hides it, for every field in the app (SmartzKeyboard.swift).
        Task { @MainActor in SmartzKeyboard.install() }
        #endif
        // The Smartz Subscription: purchases and renewals as they come (SmartzSubscription.swift).
        Task { @MainActor in SmartzSubscription.shared.start() }
    }

    /// The signed-in account changed (signed in, out, or deleted): start a new session with it, and refresh tokens
    /// and chats.
    public static func accountChanged() {
        Task {
            await IntelligenceClient.shared.reset()
            await SmartzUsage.shared.refresh()
            await MainActor.run { NotificationCenter.default.post(name: accountDidChange, object: nil) }
        }
    }

    public static let accountDidChange = Notification.Name("AsteriaIntelligence.accountDidChange")

    /// The model, for `LanguageModelSession(model: Smartz.model, …)`.
    public static var model: SmartzModel { SmartzModel() }

    /// The model for a conversation with Smartz: the gateway adds what Smartz knows about the person.
    public static func chatModel(thinkHarder: Bool = false) -> SmartzModel { SmartzModel(context: "chat", thinkHarder: thinkHarder) }

    /// How much an app should put in one request. The model reads far more; this keeps answers quick and the daily
    /// allowance from going in one long chat.
    public static let contextSize = 96_000

    public static var appName: String { settings.withLock { $0.appName } }

    /// The app's own colour, for what the kit shows outside the app's views (the plans when they're offered).
    public static var tint: Color? {
        get { settings.withLock { $0.tint } }
        set { settings.withLock { $0.tint = newValue } }
    }
    public static var privacyURL: URL { settings.withLock { $0.privacyURL } }

    // MARK: Permission

    public enum Permission: String, Sendable { case notAsked, granted, declined }

    static let permissionKey = "AsteriaIntelligence.permission"
    /// Who answers, as the consent sheet names them; a yes is kept with it. A yes given for someone else (DeepInfra,
    /// before 27.2.8, kept nothing here) counts as not asked, so the sheet comes back once and says what changed.
    static let providerKey = "AsteriaIntelligence.permissionProvider"
    static let provider = "google"

    public static var permission: Permission {
        get {
            let stored = storedPermission
            return stored == .granted && UserDefaults.standard.string(forKey: providerKey) != provider ? .notAsked : stored
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: permissionKey)
            UserDefaults.standard.set(provider, forKey: providerKey)
        }
    }

    private static var storedPermission: Permission {
        UserDefaults.standard.string(forKey: permissionKey).flatMap(Permission.init(rawValue:)) ?? .notAsked
    }

    /// Said yes before Smartz moved to Google, and not asked since: the sheet says what changed.
    public static var permissionIsRenewal: Bool {
        storedPermission == .granted && UserDefaults.standard.string(forKey: providerKey) != provider
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

    /// A sentence for any error from a session using Smartz.
    public static func message(for error: Error) -> String {
        if let error = error as? SmartzError { return error.localizedDescription }
        if let error = error as? LanguageModelError {
            switch error {
            case .rateLimited(let limited): return limited.debugDescription.isEmpty ? "Smartz is busy. Try again in a moment." : limited.debugDescription
            case .contextSizeExceeded: return "That's more than Smartz can read at once."
            case .guardrailViolation, .refusal: return "Smartz won't help with that one."
            case .timeout: return "That took too long. Try again?"
            default: return "Smartz couldn't finish that. Try again in a moment."
            }
        }
        if String(describing: error).contains("decodingFailure") { return "Smartz's answer didn't come out right. Try again?" }
        if error is CancellationError { return "Stopped." }
        if (error as? URLError)?.code == .notConnectedToInternet { return SmartzError.offline.localizedDescription }
        return "Smartz couldn't finish that. Try again in a moment."
    }
}

/// Today's Smartz tokens: one token is a cent of Smartz. Signed-in accounts get their tier's tokens
/// (The Smartz Subscription); apps without an account get a per-device allowance.
@MainActor @Observable
public final class SmartzUsage {
    public static let shared = SmartzUsage()

    public private(set) var tokensPerDay = 0
    /// Today's use as the gateway last said, plus what answers have cost since (to the cent).
    private var used: Double = 0
    public var tokensUsed: Int { Int(used.rounded(.up)) }
    public private(set) var signedIn = false
    public private(set) var tier: String?
    public private(set) var tierName: String?
    public private(set) var resetsAt: Date?
    public private(set) var known = false
    /// The account holds a plan bought in the App Store, billed through `planApp` (a bundle ID).
    public private(set) var subscribed = false
    public private(set) var planApp: String?

    public var tokensLeft: Int { max(0, Int((Double(tokensPerDay) - used).rounded(.down))) }
    /// Most of today's tokens are gone (80% or more): time for a heads-up, never a surprise.
    public var runningLow: Bool { known && tokensPerDay > 0 && used * 5 >= Double(tokensPerDay) * 4 }
    /// What the last answer cost, in Smartz tokens.
    public private(set) var lastAnswerTokens: Double?
    /// Everything answers have cost since launch, so a chat can tell what one reply cost (tool calls included).
    public private(set) var answerTokens: Double = 0

    func noteAnswer(tokens: Double) {
        lastAnswerTokens = tokens
        answerTokens += tokens
        used += tokens
    }

    nonisolated struct Report: Decodable, Sendable {
        let tokensPerDay: Int?
        let tokensUsed: Int?
        let signedIn: Bool?
        let tier: String?
        let tierName: String?
        let resetsAt: Date?
        var subscribed: Bool? = nil
        var planApp: String? = nil
    }

    func apply(_ report: Report) {
        tokensPerDay = report.tokensPerDay ?? tokensPerDay
        if let reported = report.tokensUsed { used = Double(reported) }
        signedIn = report.signedIn ?? signedIn
        tier = report.tier
        tierName = report.tierName
        resetsAt = report.resetsAt
        known = report.tokensPerDay != nil
        subscribed = report.subscribed ?? false
        planApp = report.planApp
    }

    /// Asks the gateway (after the person has turned Smartz on).
    public func refresh() async {
        guard Smartz.isOn, let report = try? await IntelligenceClient.shared.usage() else { return }
        apply(report)
    }
}

nonisolated public enum SmartzError: LocalizedError, Sendable, Equatable {
    /// The person hasn't said yes (or turned it off).
    case notAllowed
    case offline
    case unavailable(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notAllowed: "Smartz is off. Turn it on in Settings to use this."
        case .offline: "Smartz needs an internet connection."
        case .unavailable(let message), .failed(let message): message
        }
    }
}
