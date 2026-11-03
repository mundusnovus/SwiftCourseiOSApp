// Settings on both platforms: appearance, reading, iCloud, Apple Intelligence, progress, and the honest about block.
import SwiftUI
import ZeroToHeroKit

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage("accent") private var accent = AccentChoice.sea.rawValue
    @AppStorage("editorFontSize") private var fontSize = 14.0
    @AppStorage("shareWithSiri") private var shareWithSiri = true
    @AppStorage("usePrivateCloudCompute") private var usePCC = false
    @State private var confirmReset = false

    private var choice: AccentChoice { AccentChoice(rawValue: accent) ?? .sea }

    var body: some View {
        #if os(macOS)
        Form { panes }
            .formStyle(.grouped)
            .frame(width: 540, height: 620)
            .appTint()
        #else
        NavigationStack {
            Form { panes }
                .navigationTitle("Settings")
                .navigationBarTitleDisplayMode(.inline)
                .tint(choice.color)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
                .confirmationDialog("Start the course again?", isPresented: $confirmReset, titleVisibility: .visible) {
                    Button("Forget my progress and code", role: .destructive) { model.store.resetAll() }
                } message: {
                    Text("Every finished lesson and all your code will be forgotten. This cannot be undone.")
                }
        }
        #endif
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

        Section {
            HStack {
                Label(Intelligence.statusSentence, systemImage: "apple.intelligence")
                    .foregroundStyle(Intelligence.isAvailable ? .primary : .secondary)
                    .font(.reading(.callout))
                Spacer()
            }
            Toggle("Use Private Cloud Compute when needed", isOn: $usePCC)
                .disabled(!Intelligence.privateCloudAvailable)
            Text(Intelligence.privateCloudAvailable
                 ? "Heavier explanations can use Apple's Private Cloud Compute. Requests stay private to you and count against Apple's daily limit."
                 : "Private Cloud Compute needs Apple's managed entitlement. Until it is granted, every feature runs on this device.")
                .font(.reading(.caption)).foregroundStyle(.secondary)
            Toggle("Share lessons with Siri and Spotlight", isOn: $shareWithSiri)
                .onChange(of: shareWithSiri) { _, _ in
                    Task { await SpotlightIndex.refresh() }
                }
        } header: {
            Text("Apple Intelligence")
        } footer: {
            Text("Vocabulary, code and errors stay on this device. Nothing is sent to Asteria.")
        }

        Section("Progress") {
            LabeledContent("Lessons done", value: "\(model.doneCount) of \(model.course.lessons.count)")
            LabeledContent("Streak", value: "\(model.store.streak) days")
            LabeledContent("Milestones", value: "\(model.store.badges.count) of \(Achievements.all.count)")
            Button("Start the course again…", role: .destructive) { confirmReset = true }
        }

        Section {
            HStack(alignment: .firstTextBaseline) {
                Wordmark(size: 20)
                Spacer()
                Text(version).font(.reading(.caption)).foregroundStyle(.secondary).monospacedDigit()
            }
            Text("A complete Swift course for iPhone, iPad and Mac. 161 lessons, on-device checking, and no account.")
                .font(.reading(.callout)).foregroundStyle(.secondary)
            if let privacy = URL(string: "https://asteria.technology/privacy/") {
                Link("Privacy", destination: privacy)
            }
            if let license = URL(string: "https://asteria.technology/license/") {
                Link("Asteria License", destination: license)
            }
        } header: {
            Text("About")
        } footer: {
            Text("© 2026 Asteria Technology. Swift and Apple Intelligence are Apple's.")
        }
    }

    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "2"
        return "\(short) (\(build))"
    }
}
