// The Smartz Subscription on screen: the plans (with what each gives a day and the App Store's price), buying,
// upgrading, Restore Purchases and managing the subscription, and the words App Review asks for beside an
// auto-renewing subscription (what it is, how long, the price, how to cancel, the Terms of Use and Privacy Policy).
import StoreKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: Offering the plans

/// Shows the plans over whatever is on screen (a chat with Smartz in a sheet, Settings, anything), so an offer is never
/// hidden behind another sheet and no app has to place it. On iPhone and iPad it's a sheet on the topmost screen; on
/// the Mac, a sheet on the key window.
@MainActor
enum SmartzPlansPresenter {
    #if canImport(UIKit)
    private static weak var shown: UIViewController?

    static func present(_ offer: SmartzSubscription.Offer) {
        guard shown == nil, let top = topController() else { return }
        var host: UIHostingController<SmartzPlansView>!
        host = UIHostingController(rootView: SmartzPlansView(offer: offer, close: { host?.dismiss(animated: true) }, tint: Smartz.tint))
        host.modalPresentationStyle = .pageSheet
        host.sheetPresentationController?.detents = [.large()]
        shown = host
        top.present(host, animated: true)
    }

    private static func topController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.filter { $0.activationState == .foregroundActive }
        guard let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.first?.windows.first else { return nil }
        var top = window.rootViewController
        while let next = top?.presentedViewController, !next.isBeingDismissed { top = next }
        return top
    }
    #elseif canImport(AppKit)
    private static weak var shown: NSViewController?

    static func present(_ offer: SmartzSubscription.Offer) {
        guard shown == nil, let window = NSApplication.shared.keyWindow ?? NSApplication.shared.mainWindow,
              let content = window.attachedSheet?.contentViewController ?? window.contentViewController else { return }
        var host: NSHostingController<SmartzPlansView>!
        host = NSHostingController(rootView: SmartzPlansView(offer: offer, close: { if let host { content.dismiss(host) } }, tint: Smartz.tint))
        shown = host
        content.presentAsSheet(host)
    }
    #endif
}

// MARK: The plans

/// The plans as a sheet: after running out of tokens, after signing in, or from Settings.
public struct SmartzPlansView: View {
    @Environment(\.dismiss) private var dismiss
    let offer: SmartzSubscription.Offer?
    /// Closes it when it was shown by SmartzPlansPresenter (outside SwiftUI's own presentation).
    let close: (() -> Void)?
    /// The app's colour, when it's shown outside the app's views.
    let tint: Color?
    private var store: SmartzSubscription { .shared }
    private var usage: SmartzUsage { .shared }

    public init(offer: SmartzSubscription.Offer? = nil, close: (() -> Void)? = nil, tint: Color? = nil) {
        self.offer = offer; self.close = close; self.tint = tint
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    header
                    SmartzPlanList(onlyUpgrades: offer != nil)
                }
                .padding(20)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("The Smartz Subscription")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(offer == nil ? "Done" : "Not Now") { if let close { close() } else { dismiss() } } }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 600)
        #endif
        .tint(tint ?? .accentColor)
        .task { await usage.refresh(); await store.refresh() }
        .onChange(of: store.status?.plan?.productID) { old, new in
            // Bought: close the offer once the plan is on the account.
            if offer != nil, new != nil, new != old { if let close { close() } else { dismiss() } }
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "circle.hexagongrid.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 68, height: 68)
                .glassEffect(in: .circle)
            Text(title).font(.title2.bold()).multilineTextAlignment(.center)
            Text(subtitle).multilineTextAlignment(.center).foregroundStyle(.secondary)
        }
        .padding(.top, 8)
    }

    private var title: String {
        switch offer {
        case .limit?: "You've Used Today's Smartz Tokens"
        case .signedIn?: "Get More from Smartz"
        case nil: "The Smartz Subscription"
        }
    }

    private var subtitle: String {
        let refresh = usage.resetsAt.map { " They refresh \($0.formatted(.relative(presentation: .named)))." } ?? " They refresh at midnight UTC."
        switch offer {
        case .limit?:
            return (store.status?.plan == nil ? "Get more every day with a plan." : "Upgrade for more every day.") + refresh
        case .signedIn?:
            return "A plan gives you more Smartz tokens every day, in every Asteria app and at smartz.chat."
        case nil:
            return "Smartz tokens pay for Smartz in every Asteria app and at smartz.chat: answers, voice and listening. One plan covers them all."
        }
    }
}

/// The plans, with buying and the subscription's terms. `onlyUpgrades`: just the plans above today's tokens.
public struct SmartzPlanList: View {
    @Environment(\.purchase) private var purchase
    @Environment(\.openURL) private var openURL
    let onlyUpgrades: Bool
    @State private var buying: String?
    @State private var signingIn = false
    @State private var managing = false
    private var store: SmartzSubscription { .shared }
    private var usage: SmartzUsage { .shared }

    public init(onlyUpgrades: Bool = false) { self.onlyUpgrades = onlyUpgrades }

    private var signedIn: Bool { store.hasAccount || usage.signedIn || AsteriaID.shared.isSignedIn }

    public var body: some View {
        VStack(spacing: 14) {
            current
            if !signedIn {
                VStack(spacing: 8) {
                    Text("Plans belong to your Asteria Account, so they work in every Asteria app. Sign in to get one.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button { signingIn = true } label: { Text("Sign In or Make an Account").bold().frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                }
            } else if let plan = store.status?.plan, store.billedElsewhere {
                VStack(spacing: 8) {
                    Text("Your plan is billed through \(SmartzSubscription.appName(plan.app)). Change it there, or in your App Store subscriptions.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Manage Subscriptions") { openURL(SmartzSubscription.manageURL) }
                }
            }
            plans
            if let problem = store.problem {
                Label(problem, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.secondary)
                    .onTapGesture { store.problem = nil }
            }
            if signedIn && !store.products.isEmpty {
                HStack(spacing: 18) {
                    Button("Restore Purchases") { Task { await store.restore() } }
                    if store.status?.plan != nil && !store.billedElsewhere {
                        Button("Manage Subscription") { manage() }
                    }
                }
                .font(.callout)
                .disabled(store.working)
            }
            terms
        }
        .sheet(isPresented: $signingIn, onDismiss: { Task { await store.refresh(sendingEntitlements: true) } }) { AsteriaSignInView(mode: .signIn) }
        #if os(iOS)
        .manageSubscriptionsSheet(isPresented: $managing)
        #endif
    }

    /// Today's plan and tokens.
    private var current: some View {
        let name = usage.tierName ?? store.status?.tierName
        return VStack(spacing: 4) {
            if let plan = store.status?.plan {
                Text("Your plan: \(plan.tierName)").font(.headline)
                Text(plan.autoRenew ? "Renews \(plan.expiresAt.formatted(date: .abbreviated, time: .omitted))"
                                    : "Ends \(plan.expiresAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption).foregroundStyle(.secondary)
                if let next = plan.renewsTo.flatMap({ id in SmartzPlans.all.first { $0.id.lowercased() == id.lowercased() } }) {
                    Text("Switches to \(next.name) when it renews").font(.caption).foregroundStyle(.secondary)
                }
            } else if let name, usage.known {
                Text("You're on \(name): \(usage.tokensPerDay) tokens a day").font(.headline)
            }
            SmartzTokensBadge()
        }
        .frame(maxWidth: .infinity)
        .padding(14)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 16))
    }

    @ViewBuilder private var plans: some View {
        let shown = onlyUpgrades ? store.upgrades : store.products
        if !store.products.isEmpty {
            VStack(spacing: 10) {
                ForEach(shown, id: \.id) { product in row(product) }
                if shown.isEmpty {
                    Text("You're on the biggest plan. Your tokens refresh at midnight UTC.").font(.callout).foregroundStyle(.secondary)
                }
            }
        } else if store.loadedProducts {
            // No App Store here (a copy from the web): the plans, to buy in any Asteria app from the App Store.
            VStack(alignment: .leading, spacing: 8) {
                ForEach(SmartzPlans.all.filter { $0.id != "havenot" }) { plan in
                    HStack {
                        Text(plan.name).font(.headline)
                        Spacer()
                        Text("\(plan.tokens) tokens a day").foregroundStyle(.secondary)
                    }
                }
                Text(signedIn ? "The App Store's plans couldn't be loaded right now."
                              : "The App Store's plans couldn't be loaded here. A plan bought in any Asteria app works here once you're signed in.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Try Again") { Task { await store.reloadProducts() } }.font(.caption)
            }
            .padding(14)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 16))
        } else {
            ProgressView().padding()
        }
    }

    private func row(_ product: Product) -> some View {
        let plan = SmartzSubscription.plan(for: product.id)
        let mine = store.status?.plan?.productID == product.id
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(plan?.name ?? product.displayName).font(.headline)
                Text("\(plan?.tokens ?? 0) Smartz tokens a day").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if mine {
                Label("Your Plan", systemImage: "checkmark.circle.fill").font(.callout.bold()).foregroundStyle(.tint)
            } else {
                Button { buy(product) } label: {
                    if buying == product.id {
                        ProgressView().controlSize(.small).frame(minWidth: 90)
                    } else {
                        Text("\(product.displayPrice)\(Self.period(product))").monospacedDigit().bold().frame(minWidth: 90)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!store.canBuy || buying != nil || store.working)
                .accessibilityLabel("\(plan?.name ?? product.displayName), \(product.displayPrice)\(Self.period(product))")
            }
        }
        .padding(14)
        .background(.quaternary.opacity(mine ? 0.8 : 0.4), in: .rect(cornerRadius: 16))
    }

    static func period(_ product: Product) -> String {
        guard let period = product.subscription?.subscriptionPeriod else { return "" }
        switch (period.unit, period.value) {
        case (.month, 1): return " a month"
        case (.year, 1): return " a year"
        case (.week, 1): return " a week"
        default: return " every \(period.value) \(period.unit)"
        }
    }

    private var terms: some View {
        VStack(spacing: 8) {
            Text("Plans are monthly subscriptions that renew automatically. Payment is charged to your Apple Account when you confirm. A plan renews unless you turn off renewal at least 24 hours before the end of the month, and you can manage or cancel it in your App Store account settings. The apps are free; plans pay for Smartz.")
                .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack(spacing: 16) {
                Link("Terms of Use", destination: SmartzSubscription.termsURL)
                Link("Privacy Policy", destination: Smartz.privacyURL)
            }
            .font(.caption)
        }
        .padding(.top, 6)
    }

    private func buy(_ product: Product) {
        buying = product.id
        store.problem = nil
        Task {
            defer { buying = nil }
            do {
                let result = try await purchase(product, options: await store.purchaseOptions())
                await store.handle(result)
            } catch {
                store.problem = "The App Store couldn't finish that purchase. Try again in a moment."
            }
        }
    }

    private func manage() {
        #if os(iOS)
        managing = true
        #else
        openURL(SmartzSubscription.manageURL)
        #endif
    }
}
