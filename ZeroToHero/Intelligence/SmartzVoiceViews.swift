// Smartz's voice on screen: audio mode (a spoken conversation around a glowing orb), the microphone's level, and the
// voice settings every app shares (the voice, reading answers aloud, the expressive voice).
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: Audio mode

/// A spoken conversation with the chat's agent: it listens, notices when you've finished, answers aloud, and stops when
/// you talk over it. Everything said lands in the chat as text too.
public struct SmartzAudioModeView: View {
    let chats: SmartzChats
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var voice: SmartzVoice { .shared }

    public init(chats: SmartzChats) { self.chats = chats }

    public var body: some View {
        VStack(spacing: 24) {
            HStack {
                SmartzTokensBadge()
                Spacer()
                Button { finish() } label: {
                    Image(systemName: "xmark").font(.headline).padding(12).background(.white.opacity(0.12), in: .circle)
                }
                .accessibilityLabel("End Conversation")
                .keyboardShortcut(.cancelAction)
            }
            Spacer(minLength: 0)
            SmartzOrb(phase: voice.phase, level: voice.level, reduceMotion: reduceMotion)
                .frame(width: 230, height: 230)
                .contentShape(.circle)
                .onTapGesture { voice.tapOrb() }
                .accessibilityElement()
                .accessibilityLabel(status)
                .accessibilityHint(hint)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { voice.tapOrb() }
            VStack(spacing: 10) {
                Text(status).font(.title2.weight(.semibold))
                Text(words)
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .lineLimit(5)
                    .frame(maxWidth: 520)
                    .animation(.default, value: words)
            }
            .padding(.horizontal)
            Spacer(minLength: 0)
            HStack(spacing: 48) {
                Button { voice.tapOrb() } label: {
                    Image(systemName: voice.phase == .listening ? "checkmark" : "hand.raised.fill")
                        .font(.title2).frame(width: 64, height: 64).background(.white.opacity(0.12), in: .circle)
                }
                .disabled(voice.phase == .hearing || voice.phase == .idle || (voice.phase == .listening && !voice.hearingSpeech))
                .accessibilityLabel(voice.phase == .listening ? "Done Talking" : "Interrupt")
                Button { finish() } label: {
                    Image(systemName: "phone.down.fill")
                        .font(.title2).frame(width: 64, height: 64).background(.red, in: .circle)
                }
                .accessibilityLabel("End Conversation")
            }
            .buttonStyle(.plain)
            if let problem = voice.problem {
                Text(problem).font(.footnote).foregroundStyle(.white.opacity(0.7)).multilineTextAlignment(.center)
                #if os(iOS)
                if voice.microphoneDenied, let settings = URL(string: UIApplication.openSettingsURLString) {
                    Button("Open Settings") { openURL(settings) }
                        .buttonStyle(.bordered)
                        .tint(.white)
                }
                #endif
            }
        }
        .padding(24)
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            LinearGradient(colors: [Color(red: 0.03, green: 0.04, blue: 0.10), Color(red: 0.07, green: 0.05, blue: 0.16)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        }
        .environment(\.colorScheme, .dark)
        .task { await voice.enterAudioMode(chats) }
        .onDisappear { voice.leaveAudioMode() }
    }

    private var status: String {
        switch voice.phase {
        case .listening: voice.hearingSpeech ? "Listening…" : "Go ahead, I'm listening"
        case .hearing: "Got it…"
        case .thinking: "Thinking…"
        case .speaking: chats.agent.name
        case .idle: voice.problem == nil ? "Starting…" : "Couldn't start"
        }
    }

    private var hint: String {
        switch voice.phase {
        case .speaking, .thinking: "Interrupts and listens to you."
        case .listening: "Ends your turn."
        default: ""
        }
    }

    /// What you're saying while you talk; what Smartz is saying while it speaks.
    private var words: String {
        switch voice.phase {
        case .listening, .hearing: return voice.liveWords
        case .thinking: return voice.liveWords
        case .speaking:
            let reply = chats.answering == chats.current && !chats.draft.isEmpty ? chats.draft
                : chats.currentMessages.last(where: { $0.role == .assistant })?.text ?? ""
            let visible = SmartzSpeech.visible(reply)
            return visible.count > 320 ? "…" + String(visible.suffix(320)) : visible
        case .idle: return ""
        }
    }

    private func finish() {
        voice.leaveAudioMode()
        dismiss()
    }
}

/// The orb: it swells with your voice while listening, and breathes while Smartz thinks and speaks.
public struct SmartzOrb: View {
    let phase: SmartzVoice.Phase
    let level: Float
    var reduceMotion = false

    public init(phase: SmartzVoice.Phase, level: Float, reduceMotion: Bool = false) {
        self.phase = phase
        self.level = level
        self.reduceMotion = reduceMotion
    }

    private static let colors: [Color] = [Color(red: 0.25, green: 0.88, blue: 0.95), Color(red: 0.55, green: 0.42, blue: 1.0),
                                          Color(red: 0.32, green: 0.20, blue: 0.78), Color(red: 0.25, green: 0.88, blue: 0.95)]

    public var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let breathing: Double = switch phase {
            case .speaking: 0.05 * sin(time * 6) + 0.035 * sin(time * 9.7)
            case .thinking, .hearing: 0.03 * sin(time * 2.6)
            default: 0
            }
            let scale = 0.86 + (phase == .listening ? Double(level) * 0.32 : 0) + (reduceMotion ? 0 : breathing)
            let angle = Angle.degrees(reduceMotion ? 0 : time * (phase == .thinking ? 90 : 24))
            ZStack {
                Circle()
                    .fill(AngularGradient(colors: Self.colors, center: .center, angle: angle))
                    .blur(radius: 28)
                    .opacity(phase == .idle ? 0.25 : 0.65)
                    .scaleEffect(scale * 1.12)
                Circle()
                    .fill(AngularGradient(colors: Self.colors, center: .center, angle: angle))
                    .overlay {
                        Circle().fill(RadialGradient(colors: [.white.opacity(0.45), .clear], center: .init(x: 0.35, y: 0.3),
                                                     startRadius: 0, endRadius: 90))
                    }
                    .overlay { Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1) }
                    .scaleEffect(scale)
                    .opacity(phase == .idle ? 0.5 : 1)
            }
            .animation(.easeOut(duration: 0.12), value: level)
        }
    }
}

/// Five bars that move with the microphone's level.
public struct SmartzLevelBars: View {
    let level: Float

    public init(level: Float) { self.level = level }

    public var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<5) { index in
                let weight: Float = [0.55, 0.8, 1, 0.8, 0.55][index]
                Capsule()
                    .fill(.tint)
                    .frame(width: 3, height: CGFloat(5 + 18 * max(0.08, level * weight)))
            }
        }
        .frame(height: 24)
        .animation(.easeOut(duration: 0.1), value: level)
        .accessibilityHidden(true)
    }
}

// MARK: Settings

/// Smartz's voice in an app's settings: the voice, reading answers aloud, and the expressive voice. They follow the
/// Asteria Account between apps.
public struct SmartzVoiceSection: View {
    private var voice: SmartzVoice { .shared }

    public init() {}

    public var body: some View {
        Section {
            NavigationLink { SmartzVoicePicker() } label: {
                LabeledContent("Voice", value: voice.voiceName)
            }
            Toggle(isOn: Binding(get: { voice.autoSpeak }, set: { voice.setAutoSpeak($0) })) {
                Label("Read Answers Aloud", systemImage: "speaker.wave.2")
            }
            Toggle(isOn: Binding(get: { voice.expressive }, set: { voice.setExpressive($0) })) {
                Label("Expressive Voice", systemImage: "theatermasks")
            }
        } header: {
            Text("Smartz's Voice")
        } footer: {
            Text("Reading an answer aloud costs about 1 Smartz token per 250 characters (twice that with the expressive voice, which can laugh, sigh or whisper where it fits). Talking to Smartz costs under a token a minute. Answers you've heard before replay for free.")
        }
        .disabled(!Smartz.isOn)
        .task {
            await voice.pull()
            await voice.loadVoices()
        }
    }
}

/// The voices Smartz can speak in, with a sample of each. Smartz's own voice comes first.
public struct SmartzVoicePicker: View {
    private var voice: SmartzVoice { .shared }
    @State private var loaded = false

    public init() {}

    public var body: some View {
        List {
            ForEach(voice.voices) { option in
                let chosen = (voice.voiceID ?? voice.defaultVoiceID) == option.id
                let own = option.id == voice.defaultVoiceID
                HStack(spacing: 12) {
                    Button { voice.setVoice(option.id) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.name).font(.headline)
                                let detail = own ? option.description : (option.detail.isEmpty ? option.description : option.detail)
                                if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                            }
                            Spacer()
                            if chosen { Image(systemName: "checkmark").foregroundStyle(.tint).fontWeight(.semibold) }
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(chosen ? .isSelected : [])
                    Button { voice.preview(option) } label: {
                        Image(systemName: voice.previewing == option.id ? "stop.circle.fill" : "play.circle").font(.title2)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(voice.previewing == option.id ? "Stop Sample" : "Play a Sample of \(option.name)")
                }
            }
        }
        .overlay {
            if voice.voices.isEmpty {
                if loaded {
                    ContentUnavailableView("Voices aren't available", systemImage: "speaker.slash",
                                           description: Text("Check your connection and try again."))
                } else {
                    ProgressView()
                }
            }
        }
        .navigationTitle("Voice")
        .task {
            await voice.loadVoices()
            loaded = true
        }
        .onDisappear { voice.stopPreview() }
    }
}
