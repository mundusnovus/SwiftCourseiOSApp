// Asking once before anything goes to Asteria Intelligence, and the switch in each app's settings.
//
// Put `.asteriaIntelligencePermission()` on the app's root view. The first time a session asks Asteria Intelligence
// for anything while the app is open, the sheet appears and the request waits for the answer. With no sheet on
// screen (the app is in the background, or nothing hosts it), nothing is sent.
import Foundation
import Observation
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@MainActor @Observable
public final class AsteriaIntelligencePrompt {
    public static let shared = AsteriaIntelligencePrompt()

    public var isPresented = false
    /// Changes whenever the permission does, so views that show it refresh.
    public private(set) var revision = 0
    @ObservationIgnored private var waiting: [CheckedContinuation<Bool, Never>] = []
    @ObservationIgnored fileprivate var hosts = 0

    /// True when the person has said yes; asks them if they haven't been asked and can be.
    public nonisolated static func ensurePermission() async -> Bool {
        switch AsteriaIntelligence.permission {
        case .granted: return true
        case .declined: return false
        case .notAsked: return await shared.ask()
        }
    }

    private func ask() async -> Bool {
        guard hosts > 0, Self.appIsActive else { return false }
        return await withCheckedContinuation { continuation in
            waiting.append(continuation)
            isPresented = true
        }
    }

    /// The person's answer, from the sheet or from Settings.
    public func set(_ allowed: Bool) {
        AsteriaIntelligence.permission = allowed ? .granted : .declined
        revision += 1
        isPresented = false
        let resumed = waiting
        waiting = []
        for continuation in resumed { continuation.resume(returning: allowed) }
    }

    fileprivate func dismissedWithoutAnswer() {
        guard !waiting.isEmpty else { return }
        let resumed = waiting
        waiting = []
        for continuation in resumed { continuation.resume(returning: false) }  // not now: ask again next time
    }

    private static var appIsActive: Bool {
        #if canImport(UIKit) && !os(watchOS)
        UIApplication.shared.applicationState == .active
        #elseif canImport(AppKit)
        NSApplication.shared.isActive
        #else
        true
        #endif
    }
}

public extension View {
    /// Hosts the one-time Asteria Intelligence permission sheet. Put it on the app's root view.
    func asteriaIntelligencePermission() -> some View { modifier(AsteriaIntelligencePermissionHost()) }
}

struct AsteriaIntelligencePermissionHost: ViewModifier {
    @Bindable private var prompt = AsteriaIntelligencePrompt.shared

    func body(content: Content) -> some View {
        content
            .onAppear { prompt.hosts += 1 }
            .onDisappear { prompt.hosts -= 1 }
            .sheet(isPresented: $prompt.isPresented, onDismiss: { prompt.dismissedWithoutAnswer() }) {
                AsteriaIntelligenceConsentView()
                    #if os(macOS)
                    .frame(width: 460)
                    #endif
                    .presentationDetents([.large])
                    .interactiveDismissDisabled(false)
            }
    }
}

/// What Asteria Intelligence is and where requests go, with Turn On and Not Now.
public struct AsteriaIntelligenceConsentView: View {
    @Environment(\.openURL) private var openURL

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 10) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 40, weight: .semibold))
                            .foregroundStyle(.tint)
                            .accessibilityHidden(true)
                        Text("Asteria Intelligence")
                            .font(.largeTitle.bold())
                        Text("Frontier AI, built into \(AsteriaIntelligence.appName).")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 36)
                    Row(symbol: "arrow.up.message",
                        text: "When you use it, what you ask and anything you share with it, like a page, a chat or a photo, is sent to Asteria Technology and answered by our AI provider, which processes requests in China.")
                    Row(symbol: "hand.raised",
                        text: "We don't keep or log what you send. Our AI provider may keep it and use it to improve its services, under its own terms. Leave out anything you wouldn't want stored.")
                    Row(symbol: "switch.2", text: "You can turn Asteria Intelligence off at any time in Settings.")
                    Button("Privacy Policy") { openURL(AsteriaIntelligence.privacyURL) }
                        .font(.callout)
                }
                .padding(.horizontal, 28)
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            VStack(spacing: 10) {
                Button { AsteriaIntelligencePrompt.shared.set(true) } label: {
                    Text("Turn On Asteria Intelligence").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Button("Not Now") { AsteriaIntelligencePrompt.shared.set(false) }
                    .controlSize(.large)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 20)
            .frame(maxWidth: 560)
        }
    }

    private struct Row: View {
        let symbol: String
        let text: String
        var body: some View {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 32)
                    .accessibilityHidden(true)
                Text(text)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The switch for an app's settings: a Form section with the toggle, a line on where requests go, and the policy.
public struct AsteriaIntelligenceSettingsSection: View {
    private var prompt = AsteriaIntelligencePrompt.shared

    public init() {}

    public var body: some View {
        let _ = prompt.revision
        Section {
            Toggle(isOn: Binding(get: { AsteriaIntelligence.isOn }, set: { prompt.set($0) })) {
                Label("Asteria Intelligence", systemImage: "sparkles")
            }
            Link("Privacy Policy", destination: AsteriaIntelligence.privacyURL)
        } footer: {
            Text("Answers come from a large AI model. What you ask and share with it is sent to Asteria Technology and processed by our AI provider in China, which may keep it under its own terms. Asteria Technology doesn't keep it.")
        }
    }
}
