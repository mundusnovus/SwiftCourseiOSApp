// Asking once before anything goes to Smartz, and the switch in each app's settings.
//
// Put `.smartzPermission()` on the app's root view. The first time a session asks Smartz
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
public final class SmartzPrompt {
    public static let shared = SmartzPrompt()

    public var isPresented = false
    /// Changes whenever the permission does, so views that show it refresh.
    public private(set) var revision = 0
    @ObservationIgnored private var waiting: [CheckedContinuation<Bool, Never>] = []
    @ObservationIgnored fileprivate var hosts = 0

    /// True when the person has said yes; asks them if they haven't been asked and can be.
    public nonisolated static func ensurePermission() async -> Bool {
        switch Smartz.permission {
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
        Smartz.permission = allowed ? .granted : .declined
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
    /// Hosts the one-time Smartz permission sheet. Put it on the app's root view.
    func smartzPermission() -> some View { modifier(SmartzPermissionHost()) }
}

struct SmartzPermissionHost: ViewModifier {
    @Bindable private var prompt = SmartzPrompt.shared

    func body(content: Content) -> some View {
        content
            .onAppear { prompt.hosts += 1 }
            .onDisappear { prompt.hosts -= 1 }
            .sheet(isPresented: $prompt.isPresented, onDismiss: { prompt.dismissedWithoutAnswer() }) {
                SmartzConsentView()
                    #if os(macOS)
                    .frame(width: 460)
                    #endif
                    .presentationDetents([.large])
                    .interactiveDismissDisabled(false)
            }
    }
}

/// What Smartz is and where requests go, with Turn On and Not Now.
public struct SmartzConsentView: View {
    @Environment(\.openURL) private var openURL
    /// Said yes before Smartz moved to Google (read once, so the note doesn't vanish while the sheet is up).
    @State private var renewal = Smartz.permissionIsRenewal

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
                        Text("Smartz")
                            .font(.largeTitle.bold())
                        Text("Smartz by Asteria, built into \(Smartz.appName).")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                        if renewal {
                            Text("Smartz now thinks with Gemini 4 Argon, Google's AI model. Here's where what you send goes now; turn Smartz on again to keep using it.")
                                .font(.callout)
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                    }
                    .padding(.top, 36)
                    Row(symbol: "arrow.up.message",
                        text: "When you use it, what you ask and anything you share with it, like a page, a chat, a file or a photo, goes to Asteria and is answered by Gemini 4 Argon, Google's AI model. With voice, what you say and what Smartz says go to ElevenLabs.")
                    Row(symbol: "hand.raised",
                        text: "Google doesn't use what you send to train its models, and keeps it for up to 55 days only to check for abuse. ElevenLabs handles voice under its own privacy policy. Asteria keeps your chats only when you sign in, sealed, so they follow you; what Smartz learns about you stays private unless you choose to share it.")
                    Row(symbol: "switch.2", text: "You can turn Smartz off at any time in Settings.")
                    Button("Privacy Policy") { openURL(Smartz.privacyURL) }
                        .font(.callout)
                }
                .padding(.horizontal, 28)
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            VStack(spacing: 10) {
                Button { SmartzPrompt.shared.set(true) } label: {
                    Text("Turn On Smartz").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Button("Not Now") { SmartzPrompt.shared.set(false) }
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
public struct SmartzSettingsSection: View {
    private var prompt = SmartzPrompt.shared

    public init() {}

    public var body: some View {
        let _ = prompt.revision
        Section {
            Toggle(isOn: Binding(get: { Smartz.isOn }, set: { prompt.set($0) })) {
                Label("Smartz", systemImage: "sparkles")
            }
            Link("Privacy Policy", destination: Smartz.privacyURL)
        } footer: {
            Text("Answers come from Gemini 4 Argon, Google's AI model. Google doesn't use what you send to train its models, and keeps it for up to 55 days only to check for abuse. Voice is by ElevenLabs, under its own privacy policy.")
        }
    }
}
