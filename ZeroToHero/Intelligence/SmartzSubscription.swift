// Buying The Smartz Subscription, in every Asteria app. Each app sells the same plans as its own App Store products
// ("<bundle id>.smartz.<tier>", one subscription group per app); a purchase is sent to Asteria's server, which checks
// it with Apple and gives the Asteria Account that plan in every app and at smartz.chat. The apps themselves are free.
//
// The plans are offered when someone signs in to their Asteria Account without one (in the kit's sign-in sheet, or
// `noteSignedIn()` from an app's own sign-in), and when they run out of today's Smartz tokens (an upgrade if they
// already have a plan). They appear over whatever is on screen.
//
// StoreKit: purchases carry the account's appAccountToken (so one can't be claimed by another account); every
// verified transaction is sent to the server and finished only once the server has it (StoreKit delivers it again
// otherwise); Restore Purchases syncs with the App Store and sends what's current.
import Foundation
import Observation
import StoreKit

@MainActor @Observable
public final class SmartzSubscription {
    public static let shared = SmartzSubscription()

    /// Why the plans are on screen.
    public enum Offer: String, Identifiable, Sendable {
        /// Just signed in, without a plan.
        case signedIn
        /// Out of today's tokens.
        case limit
        public var id: String { rawValue }
    }

    /// The plans to show now: setting it shows them over whatever is on screen (SmartzPlansPresenter).
    public var offer: Offer? {
        didSet { if let offer { SmartzPlansPresenter.present(offer); self.offer = nil } }
    }
    /// This app's plans from the App Store, fewest tokens first. Empty where the App Store isn't available (a copy
    /// of the Mac app from the web, say).
    public private(set) var products: [Product] = []
    public private(set) var loadedProducts = false
    /// What the server says this account has.
    public private(set) var status: Status?
    /// Signed in to an Asteria Account (plans belong to one).
    public private(set) var hasAccount = false
    public private(set) var working = false
    public var problem: String?

    @ObservationIgnored private var updates: Task<Void, Never>?
    @ObservationIgnored private var lastLimitOffer: Date?

    nonisolated public struct Plan: Decodable, Sendable, Equatable {
        public let productID: String
        /// The app it's billed through (a bundle ID).
        public let app: String
        public let tier: String
        public let tierName: String
        public let expiresAt: Date
        public let autoRenew: Bool
        public let renewsTo: String?
    }

    nonisolated public struct Status: Decodable, Sendable, Equatable {
        public let tier: String?
        public let tierName: String?
        public let tokensPerDay: Int
        /// "store" (bought), "set" (given to this account), or "default".
        public let source: String
        public let plan: Plan?
        public let accountToken: String
    }

    // MARK: Products

    nonisolated static var bundleID: String { Bundle.main.bundleIdentifier ?? "" }

    nonisolated public static func productID(_ tier: String) -> String { bundleID + ".smartz." + tier.lowercased() }

    /// The plan a product is ("…smartz.legit" → Legit).
    nonisolated public static func plan(for productID: String) -> SmartzPlans.Plan? {
        guard let range = productID.range(of: ".smartz.") else { return nil }
        let key = productID[range.upperBound...].lowercased()
        return SmartzPlans.all.first { $0.id.lowercased() == key }
    }

    /// The names people know the apps by, for "billed through Post".
    nonisolated public static func appName(_ bundleID: String) -> String {
        switch bundleID {
        case "technology.asteria.wire": "Smartz"
        case "technology.asteria.post": "Post"
        case "technology.asteria.browse": "Asteria Browse"
        case "technology.asteria.foodandmood": "Food and Mood"
        case "technology.asteria.box": "Box"
        case "technology.asteria.zerotohero": "Swift: Zero to Hero"
        case "technology.asteria.timeclock": "Asteria Timeclock"
        default: "another Asteria app"
        }
    }

    /// Billed through another Asteria app: change it there, or in the App Store's subscriptions.
    public var billedElsewhere: Bool { status?.plan.map { $0.app != Self.bundleID } ?? false }

    public static let manageURL = URL(string: "https://apps.apple.com/account/subscriptions")!
    public static let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!

    // MARK: Starting

    /// At launch (Smartz.configure): take purchases and renewals as they come, and keep the server current.
    func start() {
        guard updates == nil else { return }
        updates = Task.detached(priority: .background) {
            for await update in Transaction.updates {
                await SmartzSubscription.shared.take(update)
            }
        }
        NotificationCenter.default.addObserver(forName: Smartz.accountDidChange, object: nil, queue: .main) { _ in
            Task { @MainActor in await SmartzSubscription.shared.refresh(sendingEntitlements: true) }
        }
        Task { await refresh(sendingEntitlements: true) }
    }

    /// Asks the App Store for the plans again.
    public func reloadProducts() async {
        loadedProducts = false
        products = []
        await refresh()
    }

    /// The App Store's products and the server's view of the account.
    public func refresh(sendingEntitlements: Bool = false) async {
        if !loadedProducts || products.isEmpty {
            let ids = SmartzPlans.all.filter { $0.id != "havenot" }.map { Self.productID($0.id) }
            products = ((try? await Product.products(for: ids)) ?? []).sorted { $0.price < $1.price }
            loadedProducts = true
        }
        hasAccount = await IntelligenceClient.shared.hasAccount()
        guard hasAccount else { status = nil; return }
        if sendingEntitlements {
            var signed: [String] = []
            for await entitlement in Transaction.currentEntitlements {
                if case .verified(let transaction) = entitlement, transaction.productType == .autoRenewable,
                   Self.plan(for: transaction.productID) != nil {
                    signed.append(entitlement.jwsRepresentation)
                }
            }
            if !signed.isEmpty, let sent = try? await Self.send(signed) { status = sent; await SmartzUsage.shared.refresh(); return }
        }
        status = try? await Self.fetchStatus()
    }

    // MARK: Buying

    /// After a purchase (from `@Environment(\.purchase)`): send it to the server, then finish it.
    public func handle(_ result: Product.PurchaseResult) async {
        switch result {
        case .success(let verification):
            await take(verification, fromPurchase: true)
        case .pending:
            problem = "Your purchase is waiting for approval. Your plan starts once it's approved."
        case .userCancelled:
            break
        @unknown default:
            break
        }
    }

    /// The purchase options that tie a purchase to this Asteria Account.
    public func purchaseOptions() async -> Set<Product.PurchaseOption> {
        if status == nil { status = try? await Self.fetchStatus() }
        guard let token = status.flatMap({ UUID(uuidString: $0.accountToken) }) else { return [] }
        return [.appAccountToken(token)]
    }

    /// Can buy here: signed in, the App Store has the plans, and no plan is billed through another app.
    public var canBuy: Bool { !products.isEmpty && hasAccount && !billedElsewhere }

    private func take(_ verification: VerificationResult<Transaction>, fromPurchase: Bool = false) async {
        guard case .verified(let transaction) = verification else {
            if fromPurchase { problem = "The App Store couldn't confirm that purchase. Try Restore Purchases." }
            return
        }
        guard Self.plan(for: transaction.productID) != nil else { await transaction.finish(); return }
        working = true
        defer { working = false }
        do {
            status = try await Self.send([verification.jwsRepresentation])
            await transaction.finish()
            await SmartzUsage.shared.refresh()
        } catch {
            // Not finished: StoreKit gives it to us again (Transaction.updates) until the server has it.
            if fromPurchase { problem = Smartz.message(for: error) }
        }
    }

    /// Restore Purchases: sync with the App Store, then send what's current.
    public func restore() async {
        working = true
        defer { working = false }
        do {
            try await AppStore.sync()
            await refresh(sendingEntitlements: true)
            if status?.plan == nil { problem = "There's no Smartz Subscription to restore on this Apple Account." }
        } catch StoreKitError.userCancelled {
        } catch {
            problem = "Couldn't reach the App Store. Try again in a moment."
        }
    }

    // MARK: Offering

    /// Signed in to the Asteria Account: offer a plan if it has none.
    public func noteSignedIn() {
        Task {
            await refresh(sendingEntitlements: true)
            guard status?.plan == nil, !upgrades.isEmpty else { return }
            try? await Task.sleep(for: .seconds(1))  // let the sign-in screen go first
            offer = .signedIn
        }
    }

    /// Out of today's tokens: offer a plan, or a bigger one (not every time the limit is hit in a row).
    nonisolated static func noteLimit() {
        Task { @MainActor in
            let me = SmartzSubscription.shared
            if let last = me.lastLimitOffer, Date.now.timeIntervalSince(last) < 300 { return }
            if me.status == nil { await me.refresh() }
            me.lastLimitOffer = .now
            await SmartzUsage.shared.refresh()
            await me.refresh()
            if (SmartzUsage.shared.tier.flatMap(SmartzPlans.rank) ?? 0) >= SmartzPlans.all.count - 1 { return }  // the biggest plan already
            me.offer = .limit
        }
    }

    /// Shows the plans now (a "Get More" button), whenever it was last offered.
    public func showPlans(_ reason: Offer = .limit) {
        offer = reason
    }

    /// The plans worth offering: everything above the account's tokens a day.
    public var upgrades: [Product] {
        let current = SmartzUsage.shared.known ? SmartzUsage.shared.tokensPerDay : 0
        return products.filter { (Self.plan(for: $0.id)?.tokens ?? 0) > current }
    }

    // MARK: Server

    nonisolated static func fetchStatus() async throws -> Status {
        try IntelligenceClient.decoder.decode(Status.self, from: await IntelligenceClient.shared.json("GET", "smartz/subscription", body: nil as [String: String]?))
    }

    nonisolated static func send(_ signed: [String]) async throws -> Status {
        struct Body: Encodable { let transactions: [String] }
        return try IntelligenceClient.decoder.decode(Status.self, from: await IntelligenceClient.shared.json("POST", "smartz/subscription", body: Body(transactions: signed)))
    }
}

extension SmartzPlans {
    /// A plan's place, from Havenot (0) to How? (8).
    nonisolated static func rank(_ id: String) -> Int? {
        all.firstIndex { $0.id.lowercased() == id.lowercased() }
    }
}
