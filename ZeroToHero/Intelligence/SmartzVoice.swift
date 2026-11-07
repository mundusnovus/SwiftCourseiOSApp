// Smartz's voice. Replies are read aloud by ElevenLabs through Asteria's gateway (Eleven v4 Turbo, or Eleven v4 for the
// expressive voice), in Smartz's own voice unless the person picks another. Audio streams as raw 24 kHz PCM, a sentence
// or a few at a time while the answer is still being written, so Smartz starts talking within a moment of answering.
// Pieces already heard come from a cache on the device, so replays are instant and free.
//
// Listening uses the microphone. Apple's on-device recognizer shows the words while they're said (that never leaves the
// device); ElevenLabs Scribe makes the text that's sent, and Apple's words stand in if Scribe can't.
//
// Audio mode is a spoken conversation: Smartz listens, notices when you've finished, answers aloud, and stops when you
// talk over it (echo cancellation keeps it from hearing itself). Speaking and listening use the same Smartz tokens as
// answers.
//
// Apps need NSMicrophoneUsageDescription (and NSSpeechRecognitionUsageDescription for the live words) in Info.plist, and
// on the Mac the com.apple.security.device.audio-input entitlement. Without the microphone string, listening isn't
// offered at all.
import AVFoundation
import CryptoKit
import Foundation
import Observation
import Speech

/// One of the voices Smartz can speak in. The first is Smartz's own.
nonisolated public struct SmartzVoiceOption: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let description: String
    public let preview: String?
    public let accent: String?
    public let gender: String?
    public let age: String?

    /// "American · Female · Young", for the voice picker.
    public var detail: String {
        [accent, gender, age].compactMap { $0 }.filter { !$0.isEmpty }
            .map { $0.replacingOccurrences(of: "_", with: " ").capitalized }.joined(separator: " · ")
    }
}

// MARK: What's said

nonisolated public enum SmartzSpeech {
    /// A reply as shown on screen: audio tags like [laughs], which only the voice acts on, are hidden.
    public static func visible(_ text: String) -> String {
        guard text.contains("[") else { return text }
        return text.replacingOccurrences(
            of: "\\[(laughs|laughing|sighs|whispers|whispering|shouting|excited|sarcastic|curious|crying|chuckles|gasps|pause)[^\\]\\n]{0,20}\\]\\s?",
            with: "", options: [.regularExpression, .caseInsensitive])
    }

    static let codeNote = "\n(The code is on screen.)\n"

    /// What can be read aloud so far: a finished code block becomes a short note, and an unfinished one (while the
    /// answer is still being written) holds back everything from it on.
    static func speakable(_ text: String, final: Bool) -> String {
        var out = ""
        var rest = text[...]
        while let open = rest.range(of: "```") {
            out += rest[..<open.lowerBound]
            let after = rest[open.upperBound...]
            guard let close = after.range(of: "```") else { return final ? out + codeNote : out }
            out += codeNote
            rest = after[close.upperBound...]
        }
        return out + rest
    }

    /// The pieces a reply is read aloud in: the first short, so speech starts quickly, then a few sentences each. A cut
    /// depends only on the text before it, so a reply split while it streams and the same reply split when it's done
    /// come out the same (and replays come from the cache). Until `final`, the unfinished end is held back.
    static func pieces(_ text: String, final: Bool) -> [String] {
        let characters = Array(text)
        var pieces: [String] = []
        var start = 0
        func cut(through end: Int) {
            let piece = String(characters[start...end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if piece.contains(where: { $0.isLetter || $0.isNumber }) { pieces.append(piece) }
            start = end + 1
        }
        for index in characters.indices {
            let character = characters[index]
            let length = index + 1 - start
            let ends = "。！？".contains(character) || character == "\n"
                || (".!?".contains(character) && index + 1 < characters.count && characters[index + 1].isWhitespace)
            if ends && length >= (pieces.isEmpty ? 60 : 300) {
                cut(through: index)
            } else if length >= 1_200 && character.isWhitespace {
                cut(through: index)  // no sentence end in sight
            }
        }
        if final, start < characters.count { cut(through: characters.count - 1) }
        return pieces
    }
}

/// Pieces already spoken, kept on the device (under about 120 MB) so a replay costs nothing.
nonisolated enum SpeechCache {
    static var folder: URL { URL.cachesDirectory.appending(path: "SmartzVoice", directoryHint: .isDirectory) }

    static func key(_ parts: [String]) -> String {
        SHA256.hash(data: Data(parts.joined(separator: "\u{1F}").utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func read(_ key: String) -> Data? { try? Data(contentsOf: folder.appending(path: key + ".pcm")) }

    static func write(_ data: Data, _ key: String) {
        guard data.count > 960 else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: folder.appending(path: key + ".pcm"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        prune()
    }

    /// Over the limit, pieces go until it's back under 90 MB. (No file dates: those need a declared reason in every
    /// app's privacy manifest, and for a cache of spoken replies which ones go first hardly matters.)
    static func prune() {
        let keys: Set<URLResourceKey> = [.fileSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys)) else { return }
        let sizes = files.map { ($0, (try? $0.resourceValues(forKeys: keys).fileSize) ?? 0) }
        var total = sizes.reduce(0) { $0 + $1.1 }
        guard total > 120 << 20 else { return }
        for (url, size) in sizes.shuffled() where total > 90 << 20 {
            try? FileManager.default.removeItem(at: url)
            total -= size
        }
    }

    static func clear() { try? FileManager.default.removeItem(at: folder) }
}

nonisolated struct SpeechRequest: Encodable, Sendable {
    let text: String
    let voice: String?
    let expressive: Bool
    let previousText: String?
}

/// A recording as Scribe hears it best without a codec: 16 kHz, mono, 16-bit WAV.
nonisolated enum WAV {
    static func encode(_ samples: [Float], from rate: Double) -> Data {
        let ratio = rate / 16_000
        let count = ratio > 0 ? Int(Double(samples.count) / ratio) : 0
        var pcm = [Int16](repeating: 0, count: count)
        for index in 0..<count {
            let begin = min(samples.count - 1, Int(Double(index) * ratio))
            let end = max(begin + 1, min(samples.count, Int(Double(index + 1) * ratio)))
            var sum: Float = 0
            for sample in samples[begin..<end] { sum += sample }
            pcm[index] = Int16(max(-1, min(1, sum / Float(end - begin))) * 32_767)
        }
        var data = Data(capacity: 44 + count * 2)
        func text(_ value: String) { data.append(contentsOf: Array(value.utf8)) }
        func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        text("RIFF"); u32(UInt32(36 + count * 2)); text("WAVE")
        text("fmt "); u32(16); u16(1); u16(1); u32(16_000); u32(32_000); u16(2); u16(16)
        text("data"); u32(UInt32(count * 2))
        for sample in pcm { u16(UInt16(bitPattern: sample)) }
        return data
    }
}

// MARK: Sound out

/// Plays 24 kHz, 16-bit mono PCM as it arrives.
@MainActor final class PCMPlayer {
    let engine: AVAudioEngine
    private let node = AVAudioPlayerNode()
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)!
    private var generation = 0
    private var pending = 0
    private var odd: UInt8?
    /// Everything scheduled has played.
    var drained: (() -> Void)?

    init(engine: AVAudioEngine) throws {
        self.engine = engine
        engine.attach(node)
        try engine.connectNode(node, to: engine.mainMixerNode, format: format)
    }

    var isPlaying: Bool { pending > 0 }

    func play(_ data: Data) throws {
        if !engine.isRunning { engine.prepare(); try engine.start() }
        var bytes = data
        if let odd { bytes.insert(odd, at: bytes.startIndex); self.odd = nil }
        if bytes.count % 2 == 1 { odd = bytes.removeLast() }
        let frames = bytes.count / 2
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let out = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        bytes.withUnsafeBytes { raw in
            for index in 0..<frames {
                out[index] = Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self))) / 32_768
            }
        }
        pending += 1
        let generation = self.generation
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.played(generation) }
        }
        if !node.isPlaying { try node.playAudio() }
    }

    /// After the engine restarted (a new route, like headphones).
    func resume() { if pending > 0, !node.isPlaying { try? node.playAudio() } }

    private func played(_ generation: Int) {
        guard generation == self.generation else { return }
        pending = max(0, pending - 1)
        if pending == 0 { drained?() }
    }

    func stop() {
        generation += 1
        pending = 0
        odd = nil
        node.stop()
    }
}

// MARK: Sound in

/// What the microphone hears, collected on the audio thread: the samples of this turn, how loud it is, and a copy for
/// Apple's live words.
nonisolated final class MicCapture: @unchecked Sendable {
    let format: AVAudioFormat
    var rate: Double { format.sampleRate }
    private let lock = NSLock()
    private var samples: [Float] = []
    private var keeping = false
    private var power: Float = 0
    private var request: SFSpeechAudioBufferRecognitionRequest?

    init(format: AVAudioFormat) { self.format = format }

    func receive(_ list: UnsafePointer<AudioBufferList>, frames: AVAudioFrameCount) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        let count = Int(frames)
        let channels = format.isInterleaved ? Int(format.channelCount) : 1
        guard count > 0, let first = buffers.first, let raw = first.mData else { return }
        var mono = [Float](repeating: 0, count: count)
        switch format.commonFormat {
        case .pcmFormatFloat32 where Int(first.mDataByteSize) >= count * channels * 4:
            let pointer = raw.assumingMemoryBound(to: Float.self)
            for index in 0..<count { mono[index] = pointer[index * channels] }
        case .pcmFormatInt16 where Int(first.mDataByteSize) >= count * channels * 2:
            let pointer = raw.assumingMemoryBound(to: Int16.self)
            for index in 0..<count { mono[index] = Float(pointer[index * channels]) / 32_768 }
        default:
            return
        }
        var sum: Float = 0
        for sample in mono { sum += sample * sample }
        lock.lock()
        power = (sum / Float(count)).squareRoot()
        if keeping, samples.count < Int(rate * 600) { samples.append(contentsOf: mono) }
        let request = self.request
        lock.unlock()
        if let request, let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) {
            copy.frameLength = frames
            let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
            for (from, to) in zip(buffers, destination) {
                if let bytes = from.mData, let into = to.mData { memcpy(into, bytes, Int(min(from.mDataByteSize, to.mDataByteSize))) }
            }
            request.append(copy)
        }
    }

    /// How loud it is now, from 0 (silence, -60 dB) to 1 (-5 dB and up).
    func level() -> Float {
        lock.lock(); defer { lock.unlock() }
        return max(0, min(1, (20 * log10(max(power, 0.000_001)) + 60) / 55))
    }

    /// Starts a new turn: forget what was heard and keep what comes.
    func begin() { lock.lock(); samples.removeAll(keepingCapacity: true); keeping = true; lock.unlock() }
    func pause() { lock.lock(); keeping = false; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return samples.count }

    /// Keeps only the last `count` samples (talking over Smartz: that's the start of the new turn).
    func keepOnlyLast(_ count: Int) {
        lock.lock()
        if samples.count > count { samples.removeFirst(samples.count - count) }
        keeping = true
        lock.unlock()
    }

    /// The turn's samples from `start`, without the last `trailing` (the silence that ended it); stops keeping.
    func take(from start: Int = 0, droppingLast trailing: Int = 0) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        keeping = false
        let end = max(start, samples.count - trailing)
        return start < end ? Array(samples[start..<end]) : []
    }

    func recognize(_ request: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock()
        let old = self.request
        self.request = request
        lock.unlock()
        old?.endAudio()
    }
}

/// The microphone on an engine (with echo cancellation for audio mode).
@MainActor final class Microphone {
    let engine: AVAudioEngine
    let capture: MicCapture
    let cancelsEcho: Bool
    private let sink: AVAudioSinkNode

    init(engine: AVAudioEngine, cancelEcho: Bool) throws {
        let input = engine.inputNode
        var echo = false
        if cancelEcho {
            echo = (try? input.setVoiceProcessingEnabled(true)) != nil && input.isVoiceProcessingEnabled
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw SmartzError.unavailable("There's no microphone to listen with.") }
        let capture = MicCapture(format: format)
        let sink = AVAudioSinkNode { _, frames, list -> OSStatus in
            capture.receive(list, frames: frames)
            return noErr
        }
        engine.attach(sink)
        try engine.connectNode(input, to: sink, format: format)
        self.engine = engine
        self.capture = capture
        self.sink = sink
        cancelsEcho = echo
    }
}

// MARK: The voice

@MainActor @Observable
public final class SmartzVoice {
    public static let shared = SmartzVoice()

    public enum Phase: Sendable, Equatable {
        case idle
        /// Listening to you (dictating, or waiting for you to talk in audio mode).
        case listening
        /// Working out what you said.
        case hearing
        /// Waiting for Smartz's answer, or its first sound.
        case thinking
        case speaking
    }

    public private(set) var phase: Phase = .idle
    /// The reply being read aloud.
    public private(set) var speakingID: String?
    /// Waiting for the first sound of `speakingID`.
    public private(set) var waitingForSound = false
    /// How loud the microphone is, 0 to 1.
    public private(set) var level: Float = 0
    /// What Apple's on-device recognizer has heard so far.
    public private(set) var liveWords = ""
    public private(set) var dictating = false
    /// In a spoken conversation.
    public private(set) var audioMode = false
    /// You've started talking (audio mode).
    public private(set) var hearingSpeech = false
    public var problem: String?
    /// The person said no to the microphone (Settings is where they can change it).
    public private(set) var microphoneDenied = false

    public private(set) var autoSpeak: Bool
    public private(set) var expressive: Bool
    /// The voice picked, or nil for Smartz's own.
    public private(set) var voiceID: String?
    public private(set) var voices: [SmartzVoiceOption] = []
    public private(set) var defaultVoiceID: String?
    /// The voice being previewed in the picker.
    public private(set) var previewing: String?

    private enum Keys {
        static let autoSpeak = "Smartz.autoSpeak", expressive = "Smartz.expressive", voice = "Smartz.voice"
    }

    @ObservationIgnored private var playback: PCMPlayer?
    @ObservationIgnored private var conversationPlayer: PCMPlayer?
    @ObservationIgnored private var microphone: Microphone?
    @ObservationIgnored private weak var conversation: SmartzChats?
    @ObservationIgnored private var queue: [String] = []
    @ObservationIgnored private var fed = 0
    @ObservationIgnored private var writing = false
    @ObservationIgnored private var lastPiece = ""
    @ObservationIgnored private var voiceOverride: String?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var meter: Task<Void, Never>?
    @ObservationIgnored private var usageRefresh: Task<Void, Never>?
    @ObservationIgnored private var recognition: SFSpeechRecognitionTask?
    @ObservationIgnored private var recognizer: SFSpeechRecognizer?
    @ObservationIgnored private var previewPlayer: AVPlayer?
    @ObservationIgnored private var startedAt = Date.distantPast
    @ObservationIgnored private var turn = Turn()

    private init() {
        let defaults = UserDefaults.standard
        autoSpeak = defaults.bool(forKey: Keys.autoSpeak)
        expressive = defaults.bool(forKey: Keys.expressive)
        voiceID = defaults.string(forKey: Keys.voice)
        let center = NotificationCenter.default
        center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] note in
            let engine = note.object as? AVAudioEngine
            MainActor.assumeIsolated { self?.engineChanged(engine) }
        }
        center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.previewing = nil }
        }
        #if os(iOS)
        // Another app (a call, say) took the audio: stop listening and speaking. Our own deactivation carries no
        // interruption, so it's ignored.
        center.addObserver(forName: AVAudioSession.didBecomeInactiveNotification, object: nil, queue: .main) { [weak self] note in
            let context = note.userInfo?[AVAudioSession.deactivationContextKey] as? AVAudioSession.DeactivationContext
            let interrupted = context?.interruptionContext != nil
            MainActor.assumeIsolated { if interrupted { self?.interrupted() } }
        }
        #endif
    }

    /// The app says why it wants the microphone, so it can listen.
    public static var canListen: Bool { Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil }
    static var canShowLiveWords: Bool { Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil }

    // MARK: Settings (they follow the Asteria Account)

    public func setAutoSpeak(_ on: Bool) {
        autoSpeak = on
        UserDefaults.standard.set(on, forKey: Keys.autoSpeak)
        push { try await SmartzBrain.update(autoSpeak: on) }
    }

    public func setExpressive(_ on: Bool) {
        expressive = on
        UserDefaults.standard.set(on, forKey: Keys.expressive)
        push { try await SmartzBrain.update(expressive: on) }
    }

    /// Picks a voice (nil: Smartz's own).
    public func setVoice(_ id: String?) {
        let chosen = id == defaultVoiceID ? nil : id
        voiceID = chosen
        UserDefaults.standard.set(chosen, forKey: Keys.voice)
        push { try await SmartzBrain.update(voice: chosen ?? "") }
    }

    private func push(_ change: @escaping @Sendable () async throws -> SmartzSettings) {
        guard Smartz.isOn else { return }
        Task { _ = try? await change() }
    }

    /// Takes the voice settings saved with the Asteria Account (signed in elsewhere, they come along).
    public func pull() async {
        guard Smartz.isOn, let settings = try? await SmartzBrain.settings() else { return }
        autoSpeak = settings.autoSpeak
        expressive = settings.expressive
        voiceID = settings.voice
        let defaults = UserDefaults.standard
        defaults.set(autoSpeak, forKey: Keys.autoSpeak)
        defaults.set(expressive, forKey: Keys.expressive)
        defaults.set(voiceID, forKey: Keys.voice)
    }

    public func loadVoices() async {
        guard Smartz.isOn, let list = try? await IntelligenceClient.shared.voices() else { return }
        voices = list.voices
        defaultVoiceID = list.defaultVoice
    }

    /// The voice Smartz speaks in now, by name.
    public var voiceName: String { voices.first { $0.id == (voiceID ?? defaultVoiceID) }?.name ?? "Smartz" }

    /// Plays a voice's sample: ElevenLabs' preview if it has one, else a line spoken in it (a fraction of a token).
    public func preview(_ voice: SmartzVoiceOption) {
        if previewing == voice.id { stopPreview(); return }
        stopPreview()
        stopSpeaking()
        previewing = voice.id
        if let url = voice.preview.flatMap(URL.init(string:)), url.scheme == "https" {
            #if os(iOS)
            try? configureSession(.playback)
            #endif
            let player = AVPlayer(url: url)
            previewPlayer = player
            player.play()
        } else {
            play(id: "preview-" + voice.id, text: "Hi, I'm Smartz. This is how I sound when I read my answers to you.", voice: voice.id)
        }
    }

    public func stopPreview() {
        previewPlayer?.pause()
        previewPlayer = nil
        if let previewing, speakingID == "preview-" + previewing { stopSpeaking() }
        previewing = nil
    }

    // MARK: Reading aloud

    /// Reads a finished reply aloud, or stops it if it's the one being read.
    public func toggle(id: String, text: String) {
        if speakingID == id { stopSpeaking() } else { play(id: id, text: text) }
    }

    public func play(id: String, text: String, voice: String? = nil) {
        guard Smartz.isOn else { return }
        if dictating { cancelDictation() }
        stopSpeaking()
        start(id, voice: voice)
        queue = SmartzSpeech.pieces(SmartzSpeech.speakable(text, final: true), final: true)
        fed = queue.count
        writing = false
        pump()
        settle()
    }

    /// Whether a reply that's starting in `chats` should be read aloud as it's written.
    func wantsToSpeak(in chats: SmartzChats) -> Bool {
        guard Smartz.isOn, !dictating else { return false }
        return audioMode ? conversation === chats : autoSpeak
    }

    /// A reply is starting and will be read aloud as it comes.
    func beginReply(_ id: String) {
        if !audioMode { stopPreview() }
        stopSpeaking()
        start(id, voice: nil)
        writing = true
        fed = 0
    }

    /// The reply so far, each time it grows: complete pieces go to be spoken.
    func feed(id: String, text: String) {
        guard speakingID == id, writing else { return }
        let pieces = SmartzSpeech.pieces(SmartzSpeech.speakable(text, final: false), final: false)
        guard pieces.count > fed else { return }
        queue += pieces[fed...]
        fed = pieces.count
        pump()
    }

    /// The reply is done (or stopped, or failed after `text`): the rest goes to be spoken.
    func finishFeed(id: String, text: String) {
        guard speakingID == id, writing else { return }
        let pieces = SmartzSpeech.pieces(SmartzSpeech.speakable(text, final: true), final: true)
        if pieces.count > fed { queue += pieces[fed...] }
        fed = pieces.count
        writing = false
        pump()
        settle()
    }

    /// Stops the reply `id` if it's the one being read (its answer was stopped).
    func stopReply(_ id: String) { if speakingID == id { stopSpeaking() } }

    public func stopSpeaking() {
        generation += 1
        worker?.cancel()
        worker = nil
        queue.removeAll()
        fed = 0
        writing = false
        lastPiece = ""
        voiceOverride = nil
        (audioMode ? conversationPlayer : playback)?.stop()
        let wasSpeaking = speakingID != nil
        speakingID = nil
        waitingForSound = false
        if !audioMode && !dictating {
            phase = .idle
            if wasSpeaking { releasePlayback() }
        }
    }

    private func start(_ id: String, voice: String?) {
        speakingID = id
        voiceOverride = voice
        waitingForSound = true
        lastPiece = ""
        phase = .thinking
        problem = nil
    }

    /// Fetches the next piece while the one before plays (speech is made faster than it's spoken).
    private func pump() {
        guard worker == nil, !queue.isEmpty, speakingID != nil else { return }
        let piece = queue.removeFirst()
        let previous = lastPiece
        lastPiece = piece
        let voice = voiceOverride ?? voiceID
        let request = SpeechRequest(text: piece, voice: voice, expressive: expressive, previousText: previous.isEmpty ? nil : String(previous.suffix(600)))
        let key = SpeechCache.key(["1", voice ?? "smartz", expressive ? "v4" : "turbo", previous, piece])
        let generation = self.generation
        worker = Task { [weak self] in
            await self?.fetch(request, key: key, generation: generation)
            guard let self, self.generation == generation else { return }
            self.worker = nil
            self.pump()
            self.settle()
        }
    }

    private func fetch(_ request: SpeechRequest, key: String, generation: Int) async {
        guard request.text.contains(where: { $0.isLetter || $0.isNumber }) else { return }
        if let cached = await Task.detached(priority: .userInitiated, operation: { SpeechCache.read(key) }).value {
            sound(cached, generation)
            return
        }
        guard let body = try? IntelligenceClient.encoder.encode(request) else { return }
        var audio = Data()
        do {
            for try await chunk in IntelligenceClient.shared.speech(body) {
                guard generation == self.generation else { return }
                audio.append(chunk)
                sound(chunk, generation)
            }
            let finished = audio
            Task.detached(priority: .utility) { SpeechCache.write(finished, key) }
            scheduleUsageRefresh()
        } catch {
            guard generation == self.generation, !(error is CancellationError) else { return }
            problem = Smartz.message(for: error)
            // The rest of this reply stays on screen, unread.
            queue.removeAll()
            writing = false
        }
    }

    private func sound(_ data: Data, _ generation: Int) {
        guard generation == self.generation else { return }
        do {
            try speaker().play(data)
            if waitingForSound {
                waitingForSound = false
                phase = .speaking
                if audioMode {
                    // Listen while speaking, so talking over Smartz stops it.
                    microphone?.capture.begin()
                    turn = Turn(floor: turn.floor)
                }
            }
        } catch {
            problem = "Smartz couldn't play sound just now."
            stopSpeaking()
        }
    }

    private func speaker() throws -> PCMPlayer {
        if audioMode, let conversationPlayer { return conversationPlayer }
        if let playback { return playback }
        #if os(iOS)
        try configureSession(.playback)
        #endif
        let player = try PCMPlayer(engine: AVAudioEngine())
        player.drained = { [weak self] in self?.settle() }
        playback = player
        return player
    }

    /// Done speaking when nothing's left to fetch, write or play.
    private func settle() {
        guard speakingID != nil, worker == nil, queue.isEmpty, !writing else { return }
        guard !((audioMode ? conversationPlayer : playback)?.isPlaying ?? false) else { return }
        let wasPreview = speakingID?.hasPrefix("preview-") == true
        speakingID = nil
        waitingForSound = false
        voiceOverride = nil
        if wasPreview { previewing = nil }
        if audioMode {
            listen()
        } else {
            phase = .idle
            releasePlayback()
        }
    }

    private func releasePlayback() {
        guard let playback, !playback.isPlaying else { return }
        playback.engine.stop()
        self.playback = nil
        releaseSession()
    }

    // MARK: Dictation (the composer's microphone)

    /// Starts listening for a message. What's heard shows in `liveWords` as it's said.
    public func startDictation() async {
        guard Smartz.isOn, Self.canListen, !dictating, !audioMode else { return }
        stopSpeaking()
        stopPreview()
        guard await allowMicrophone() else { return }
        await allowLiveWords()
        do {
            #if os(iOS)
            try configureSession(.dictation)
            #endif
            let engine = AVAudioEngine()
            let mic = try Microphone(engine: engine, cancelEcho: false)
            engine.prepare()
            try engine.start()
            microphone = mic
            startedAt = .now
            mic.capture.begin()
            dictating = true
            liveWords = ""
            phase = .listening
            startLiveWords(mic)
            startMeter()
        } catch {
            problem = "Smartz couldn't use the microphone."
            releaseSession()
        }
    }

    /// Stops listening and gives what was said (Scribe's text, else Apple's words), or nil if nothing was heard.
    public func finishDictation() async -> String? {
        guard dictating, let mic = microphone else { return nil }
        let samples = mic.capture.take()
        let rate = mic.capture.rate
        let words = liveWords
        tearDownMicrophone()
        dictating = false
        phase = .hearing
        let text = await hear(samples, rate: rate, fallback: words)
        if phase == .hearing { phase = .idle }
        liveWords = ""
        releaseSession()
        return text
    }

    public func cancelDictation() {
        guard dictating else { return }
        tearDownMicrophone()
        dictating = false
        liveWords = ""
        phase = .idle
        releaseSession()
    }

    /// What was said: Scribe hears the recording; Apple's on-device words stand in if it can't.
    private func hear(_ samples: [Float], rate: Double, fallback: String) async -> String? {
        let apple = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        guard samples.count > Int(rate * 0.3) else { return apple.isEmpty ? nil : apple }
        let wav = await Task.detached(priority: .userInitiated) { WAV.encode(samples, from: rate) }.value
        do {
            let heard = try await IntelligenceClient.shared.transcribe(wav, contentType: "audio/wav")
            scheduleUsageRefresh()
            let text = heard.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? (apple.isEmpty ? nil : apple) : text
        } catch {
            if apple.isEmpty { problem = Smartz.message(for: error) }
            return apple.isEmpty ? nil : apple
        }
    }

    // MARK: Audio mode

    /// Starts a spoken conversation in `chats`.
    public func enterAudioMode(_ chats: SmartzChats) async {
        guard Smartz.isOn, Self.canListen, !audioMode else { return }
        if dictating { cancelDictation() }
        stopSpeaking()
        stopPreview()
        releasePlayback()
        guard await allowMicrophone() else { return }
        await allowLiveWords()
        do {
            #if os(iOS)
            try configureSession(.conversation)
            #endif
            let engine = AVAudioEngine()
            let mic = try Microphone(engine: engine, cancelEcho: true)
            let player = try PCMPlayer(engine: engine)
            player.drained = { [weak self] in self?.settle() }
            engine.prepare()
            try engine.start()
            microphone = mic
            conversationPlayer = player
            conversation = chats
            startedAt = .now
            audioMode = true
            problem = nil
            turn = Turn()
            listen()
            startMeter()
        } catch {
            problem = "Smartz couldn't use the microphone."
            releaseSession()
        }
    }

    public func leaveAudioMode() {
        guard audioMode else { return }
        stopSpeaking()
        audioMode = false
        tearDownMicrophone()
        conversationPlayer = nil
        conversation = nil
        hearingSpeech = false
        liveWords = ""
        phase = .idle
        releaseSession()
    }

    /// The orb: while Smartz talks or thinks, stop it and listen; while you talk, you're done.
    public func tapOrb() {
        guard audioMode else { return }
        switch phase {
        case .speaking, .thinking: bargeIn(keepingLast: 0)
        case .listening: if turn.speechStart != nil { endTurn() }
        default: break
        }
    }

    private struct Turn {
        var floor: Float = -1
        var loud = 0
        var quiet = 0
        var speechStart: Int?
    }

    private func listen() {
        guard audioMode, let mic = microphone else { return }
        phase = .listening
        hearingSpeech = false
        liveWords = ""
        turn = Turn(floor: turn.floor)
        mic.capture.begin()
        startLiveWords(mic)
    }

    private func startMeter() {
        meter?.cancel()
        meter = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, let mic = self.microphone else { return }
                self.tick(mic)
            }
        }
    }

    private func tick(_ mic: Microphone) {
        let now = mic.capture.level()
        level = level * 0.4 + now * 0.6
        guard audioMode else { return }
        // The room's own sound, learned while nobody talks.
        if turn.floor < 0 || now < turn.floor {
            turn.floor = now
        } else if turn.speechStart == nil, phase == .listening, now < turn.floor + 0.1 {
            turn.floor += (now - turn.floor) * 0.05
        }
        switch phase {
        case .listening:
            let threshold = max(0.35, turn.floor + 0.15)
            if now >= threshold { turn.loud += 1; turn.quiet = 0 } else if now < threshold - 0.05 { turn.quiet += 1; turn.loud = 0 }
            if let start = turn.speechStart {
                // About a second of quiet ends your turn (or a minute of talking).
                if turn.quiet >= 18 || mic.capture.count - start > Int(mic.capture.rate * 60) { endTurn() }
            } else if turn.loud >= 3 {
                turn.speechStart = max(0, mic.capture.count - Int(mic.capture.rate * 0.5))
                hearingSpeech = true
            }
        case .speaking where mic.cancelsEcho:
            // Talking over Smartz: louder than its echo for a quarter of a second.
            if now >= max(0.5, turn.floor + 0.28) { turn.loud += 1 } else { turn.loud = 0 }
            if turn.loud >= 5 { bargeIn(keepingLast: 0.7) }
        default:
            break
        }
    }

    private func bargeIn(keepingLast seconds: Double) {
        guard audioMode, let mic = microphone else { return }
        let chats = conversation
        stopSpeaking()
        if chats?.answering != nil { chats?.stop() }
        phase = .listening
        liveWords = ""
        turn = Turn(floor: turn.floor)
        if seconds > 0 {
            mic.capture.keepOnlyLast(Int(mic.capture.rate * seconds))
            turn.speechStart = 0
            hearingSpeech = true
        } else {
            mic.capture.begin()
            hearingSpeech = false
        }
        startLiveWords(mic)
    }

    private func endTurn() {
        guard audioMode, let mic = microphone, let start = turn.speechStart else { return }
        let samples = mic.capture.take(from: start, droppingLast: Int(mic.capture.rate * 0.6))
        let rate = mic.capture.rate
        let words = liveWords
        stopLiveWords()
        turn.speechStart = nil
        hearingSpeech = false
        phase = .hearing
        let chats = conversation
        Task { [weak self] in
            guard let self else { return }
            let text = await self.hear(samples, rate: rate, fallback: words)
            guard self.audioMode, self.phase == .hearing, let chats else { return }
            guard let text, text.count > 1 else { self.listen(); return }
            // A stopped answer takes a moment to wind down.
            for _ in 0..<40 where chats.answering != nil { try? await Task.sleep(for: .milliseconds(50)) }
            guard self.audioMode, self.phase == .hearing else { return }
            self.liveWords = text
            self.phase = .thinking
            chats.send(text, spoken: true)
        }
    }

    // MARK: The microphone

    private func allowMicrophone() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            microphoneDenied = false
            return true
        case .denied:
            microphoneDenied = true
            problem = "Smartz can't hear you. Allow the microphone for \(Smartz.appName) in Settings."
            return false
        default:
            let allowed = await AVAudioApplication.requestRecordPermission()
            microphoneDenied = !allowed
            if !allowed { problem = "Smartz can't hear you. Allow the microphone for \(Smartz.appName) in Settings." }
            return allowed
        }
    }

    private func allowLiveWords() async {
        guard Self.canShowLiveWords, SFSpeechRecognizer.authorizationStatus() == .notDetermined else { return }
        _ = await withCheckedContinuation { (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }

    /// Apple's words as they're said, on the device only (nothing is sent to Apple).
    private func startLiveWords(_ mic: Microphone) {
        stopLiveWords()
        guard Self.canShowLiveWords, SFSpeechRecognizer.authorizationStatus() == .authorized,
              let recognizer = SFSpeechRecognizer(locale: .current) ?? SFSpeechRecognizer(),
              recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.addsPunctuation = true
        mic.capture.recognize(request)
        self.recognizer = recognizer
        recognition = recognizer.recognitionTask(with: request) { [weak self] result, _ in
            guard let text = result?.bestTranscription.formattedString else { return }
            Task { @MainActor in self?.heardLive(text) }
        }
    }

    private func heardLive(_ text: String) {
        guard phase == .listening, recognition != nil else { return }
        liveWords = text
    }

    private func stopLiveWords() {
        microphone?.capture.recognize(nil)
        recognition?.cancel()
        recognition = nil
        recognizer = nil
    }

    private func tearDownMicrophone() {
        meter?.cancel()
        meter = nil
        stopLiveWords()
        microphone?.engine.stop()
        microphone = nil
        level = 0
    }

    private func engineChanged(_ engine: AVAudioEngine?) {
        guard let engine, Date.now.timeIntervalSince(startedAt) > 1 else { return }
        if let playback, engine === playback.engine {
            try? engine.start()
            playback.resume()
        } else if let microphone, engine === microphone.engine {
            // A new microphone or headphones: start again with it.
            if audioMode, let chats = conversation {
                leaveAudioMode()
                Task { await enterAudioMode(chats) }
            } else if dictating {
                cancelDictation()
                problem = "The microphone changed. Try again."
            }
        }
    }

    private func interrupted() {
        leaveAudioMode()
        cancelDictation()
        stopSpeaking()
        stopPreview()
    }

    private func scheduleUsageRefresh() {
        usageRefresh?.cancel()
        usageRefresh = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await SmartzUsage.shared.refresh()
        }
    }

    // MARK: The audio session (iOS)

    #if os(iOS)
    private enum SessionUse { case playback, dictation, conversation }

    private func configureSession(_ use: SessionUse) throws {
        let session = AVAudioSession.sharedInstance()
        switch use {
        case .playback: try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        case .dictation: try session.setCategory(.playAndRecord, mode: .default, options: [.duckOthers, .defaultToSpeaker, .allowBluetoothHFP])
        case .conversation: try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.duckOthers, .defaultToSpeaker, .allowBluetoothHFP])
        }
        try session.setActive(true)
    }
    #endif

    private func releaseSession() {
        #if os(iOS)
        guard !audioMode, !dictating, playback == nil, previewPlayer == nil else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    /// Forgets the spoken pieces kept on this device (signing out, or deleting the account).
    public func forgetOnThisDevice() {
        stopSpeaking()
        Task.detached { SpeechCache.clear() }
    }
}
