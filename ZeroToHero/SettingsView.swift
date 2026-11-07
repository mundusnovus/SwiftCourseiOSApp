// Settings on both platforms: appearance, reading, iCloud, Smartz, progress, and the honest about block.
import SwiftUI
import AppIntents
import ZeroToHeroKit

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage("accent") private var accent = AccentChoice.sea.rawValue
    @AppStorage("editorFontSize") private var fontSize = 14.0
    @AppStorage("shareWithSiri") private var shareWithSiri = true
    @State private var confirmReset = false

    private var choice: AccentChoice { AccentChoice(rawValue: accent) ?? .sea }

    var body: some View {
        #if os(macOS)
        form
            .formStyle(.grouped)
            .frame(width: 540, height: 680)
            .appTint()
        #else
        NavigationStack {
            form
                .navigationTitle("Settings")
                .navigationBarTitleDisplayMode(.inline)
                .tint(choice.color)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        #endif
    }

    /// The reset confirmation lives on the form itself, so the button works on the Mac as well as on iPhone and iPad.
    private var form: some View {
        Form { panes }
            .confirmationDialog("Start the course again?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Forget my progress and code", role: .destructive) { model.store.resetAll() }
            } message: {
                Text(model.store.inCloud
                     ? "Every finished lesson, your code and your milestones will be forgotten on all your devices. Lessons you made stay. This cannot be undone."
                     : "Every finished lesson, your code and your milestones will be forgotten. Lessons you made stay. This cannot be undone.")
            }
    }

    @ViewBuilder private var panes: some View {
        Section("Appearance") {
            HStack(spacing: 10) {
                ForEach(AccentChoice.allCases) { item in
                    Button {
                        accent = item.rawValue
                    } label: {
                        Circle().fill(item.color).frame(width: 26, height: 26)
                            .overlay(Circle().strokeBorder(.primary.opacity(choice == item ? 0.8 : 0), lineWidth: 2))
                            .padding(3)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(item.name)
                    .accessibilityAddTraits(choice == item ? .isSelected : [])
                }
                Spacer()
            }
        }

        Section {
            Slider(value: $fontSize, in: 11...24, step: 1) {
                Text("Code size: \(Int(fontSize)) pt")
            }
        } header: {
            Text("Editor")
        } footer: {
            Text("The code editor is always dark, like Xcode's default.")
        }

        Section {
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.store.inCloud ? "Progress is in your iCloud" : "Progress is on this device")
                        .font(.reading(.body, weight: .medium))
                    Text(model.store.inCloud
                         ? "Signed in with the same Apple Account, your iPhone, iPad and Mac show the same lessons, code and badges."
                         : "This build has no iCloud entitlement, or iCloud is unavailable. Everything is saved locally and works offline.")
                        .font(.reading(.caption)).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: model.store.inCloud ? "icloud.fill" : "internaldrive").foregroundStyle(Palette.sea)
            }
        } header: {
            Text("iCloud")
        }

        AsteriaAccountSection { ZTHChats.smartz.forgetOnThisDevice() }
        SmartzSettingsSection()
        SmartzVoiceSection()
        SmartzLearningSection()

        Section {
            Toggle("Share lessons with Siri and Spotlight", isOn: $shareWithSiri)
                .onChange(of: shareWithSiri) { _, _ in
                    Task { await SpotlightIndex.refresh() }
                }
            VStack(alignment: .leading, spacing: 6) {
                Text("Try saying").font(.reading(.caption, weight: .semibold)).foregroundStyle(.secondary)
                ForEach(["“Continue my Swift course in Swift Zero to Hero”",
                         "“What's next in Swift Zero to Hero”",
                         "“How far am I in Swift Zero to Hero”",
                         "“Show my milestones in Swift Zero to Hero”"], id: \.self) { phrase in
                    Text(phrase).font(.reading(.callout))
                }
            }
            .padding(.vertical, 2)
            #if os(iOS)
            ShortcutsLink()
            #endif
        } header: {
            Text("Siri and Shortcuts")
        } footer: {
            Text(shareWithSiri ? "Lesson titles are in Spotlight so Siri can open them." : "Lessons are removed from Spotlight. Siri phrases still work.")
        }

        Section("Progress") {
            LabeledContent("Lessons done", value: "\(model.doneCount) of \(model.course.lessons.count)")
            LabeledContent("Exercise checking", value: runnerText)
            LabeledContent("Streak", value: "\(model.store.streak) days")
            LabeledContent("Milestones", value: "\(model.store.badges.count) of \(Achievements.all.count)")
            Button("Start the course again…", role: .destructive) { confirmReset = true }
        }

        Section {
            HStack(alignment: .center, spacing: 12) {
                Image("IconArt").resizable().interpolation(.high).frame(width: 52, height: 52)
                    .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
                    .accessibilityHidden(true)
                Wordmark(size: 20)
                Spacer()
                Text(version).font(.reading(.caption)).foregroundStyle(.secondary).monospacedDigit()
            }
            Text("A complete Swift course for iPhone, iPad and Mac. \(model.course.lessons.count) lessons, on-device checking, and no account.")
                .font(.reading(.callout)).foregroundStyle(.secondary)
            if let privacy = URL(string: "https://learn.asteria.technology/privacy/") {
                Link("Privacy", destination: privacy)
            }
            if let license = URL(string: "https://learn.asteria.technology/license/") {
                Link("Asteria License", destination: license)
            }
        } header: {
            Text("About")
        } footer: {
            Text("© 2026 Asteria Technology. Swift and Smartz are Apple's.")
        }
    }

    private var runnerText: String {
        switch model.runnerState {
        case .looking: "Looking…"
        case .ready: "Swift compiler on this Mac"
        case .device: "On-device engine"
        case .unavailable: "Unavailable"
        }
    }

    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.0.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "6"
        return "\(short) (\(build))"
    }
}
