// The screens every Asteria app shares: chatting with Smartz (or an app's own agent), the Asteria Account (sign in,
// make one, sign out, delete it), today's Smartz tokens, and The Smartz Subscription. Voice and audio mode are in
// SmartzVoiceViews.swift; what Smartz knows and the wiki in SmartzBrainViews.swift.
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: Chat

/// A chat with an agent: the open conversation, a list of earlier chats, and a composer with photos and files, the
/// microphone and audio mode. `accessory` goes beside the text field.
public struct SmartzChatView<Accessory: View>: View {
    @Bindable var chats: SmartzChats
    let accessory: Accessory
    let signIn: (() -> Void)?
    @State private var text = ""
    @State private var showingThreads = false
    @State private var showingKnows = false
    @State private var renaming = false
    @State private var newTitle = ""
    @State private var harvested: SmartzHarvest?
    @State private var harvestProblem: String?
    @State private var talking = false
    @State private var transcribing = false
    @State private var attachments: [SmartzAttachment] = []
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var choosingPhotos = false
    @State private var choosingFiles = false
    @State private var attachProblem: String?
    @State private var dropping = false
    @FocusState private var focused: Bool

    private var voice: SmartzVoice { .shared }
    private var usage: SmartzUsage { .shared }

    public init(chats: SmartzChats, signIn: (() -> Void)? = nil, @ViewBuilder accessory: () -> Accessory = { EmptyView() }) {
        self.chats = chats
        self.signIn = signIn
        self.accessory = accessory()
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if chats.currentMessages.isEmpty && (chats.answering == nil || chats.answering != chats.current) {
                            welcome
                        }
                        ForEach(chats.currentMessages) { message in
                            MessageRow(chats: chats, message: message, isLast: message.id == chats.currentMessages.last?.id,
                                       isLastQuestion: message.id == chats.currentMessages.last(where: { $0.role == .user })?.id,
                                       edit: editLast)
                                .id(message.id)
                        }
                        if let answering = chats.answering, answering == chats.current {
                            Bubble(text: chats.draft.isEmpty ? (SmartzConnectors.shared.activity ?? "…") : SmartzSpeech.visible(chats.draft), mine: false,
                                   symbol: chats.agent.symbol, working: true).id("draft")
                        }
                        if let error = chats.error {
                            Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
                            if usage.known && usage.tokensLeft == 0 {
                                // Out of today's tokens: the plans, whenever they were last offered.
                                Button { SmartzSubscription.shared.showPlans() } label: {
                                    Label("Get More Smartz Tokens", systemImage: "circle.hexagongrid.fill")
                                }
                                .font(.footnote.bold()).buttonStyle(.borderless).padding(.horizontal)
                            }
                        }
                        if let problem = voice.problem, !talking {
                            Button { voice.problem = nil } label: {
                                Label(problem, systemImage: "speaker.slash").font(.footnote).foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain).padding(.horizontal)
                        }
                        Color.clear.frame(height: 4).id("bottom")
                    }
                    .padding(.vertical, 12)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: chats.currentMessages.count) { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
                .onChange(of: chats.draft) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            if usage.runningLow {
                Label("You've used most of today's Smartz tokens (\(usage.tokensLeft) left). An answer that's started always finishes.",
                      systemImage: "gauge.with.dots.needle.67percent")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal).padding(.bottom, 6)
            }
            if !chats.syncing, Smartz.isOn {
                HStack(spacing: 8) {
                    Image(systemName: "icloud.slash")
                    Text("Sign in to your Asteria Account to keep chats on all your devices.").font(.caption)
                    if let signIn { Button("Sign In", action: signIn).font(.caption.bold()).foregroundStyle(.tint) }
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal).padding(.bottom, 6)
            }
            if !attachments.isEmpty { attachmentStrip }
            if let attachProblem {
                Button { self.attachProblem = nil } label: {
                    Label(attachProblem, systemImage: "paperclip.badge.ellipsis").font(.caption).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain).padding(.horizontal).padding(.bottom, 4)
            }
            composer
        }
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 18).strokeBorder(.tint, style: StrokeStyle(lineWidth: 2, dash: [8]))
                    .overlay { Label("Attach to your message", systemImage: "paperclip").font(.headline).foregroundStyle(.tint) }
                    .padding(8).allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in attach(urls); return !urls.isEmpty } isTargeted: { dropping = $0 }
        .photosPicker(isPresented: $choosingPhotos, selection: $photoItems, maxSelectionCount: 4, matching: .images)
        .onChange(of: photoItems) { _, items in loadPhotos(items) }
        .fileImporter(isPresented: $choosingFiles, allowedContentTypes: SmartzFiles.types, allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { attach(urls) }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button { showingThreads = true } label: { Label("Chats", systemImage: "list.bullet") }
            }
            ToolbarItem(placement: .automatic) {
                Button { chats.newThread(); focused = true } label: { Label("New Chat", systemImage: "square.and.pencil") }
            }
            ToolbarItem(placement: .automatic) { more }
        }
        .sheet(isPresented: $showingThreads) {
            NavigationStack { SmartzChatList(chats: chats) { showingThreads = false } }
                #if os(macOS)
                .frame(minWidth: 380, minHeight: 460)
                #endif
        }
        .sheet(isPresented: $showingKnows) {
            NavigationStack {
                SmartzKnowsView()
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingKnows = false } } }
            }
            #if os(macOS)
            .frame(minWidth: 420, minHeight: 520)
            #endif
        }
        .alert("Rename Chat", isPresented: $renaming) {
            TextField("Title", text: $newTitle)
            Button("Save") { if let id = chats.current { Task { await chats.rename(id, to: newTitle) } } }
            Button("Cancel", role: .cancel) {}
        }
        .alert(harvested.map(Self.harvestTitle) ?? "", isPresented: Binding(get: { harvested != nil }, set: { if !$0 { harvested = nil } }),
               presenting: harvested) { _ in
            Button("See What Smartz Knows") { showingKnows = true }
            Button("OK", role: .cancel) {}
        } message: { harvest in
            Text(Self.harvestMessage(harvest))
        }
        .alert("Couldn't Harvest", isPresented: Binding(get: { harvestProblem != nil }, set: { if !$0 { harvestProblem = nil } })) {
            if let signIn, harvestProblem?.contains("Sign in") == true { Button("Sign In", action: signIn) }
            Button("OK", role: .cancel) {}
        } message: {
            Text(harvestProblem ?? "")
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $talking) { SmartzAudioModeView(chats: chats) }
        #else
        .sheet(isPresented: $talking) { SmartzAudioModeView(chats: chats).frame(minWidth: 420, minHeight: 540) }
        #endif
        .task { await chats.refresh() }
    }

    #if os(macOS)
    /// On the Mac: centred, with the suggestions as cards in a grid, in a column that reads well in a wide window.
    private var welcome: some View {
        VStack(spacing: 18) {
            Image(systemName: chats.agent.symbol)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 64, height: 64)
                .glassEffect(in: .circle)
            Text(chats.agent.greeting)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
            if !chats.agent.suggestions.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], spacing: 12) {
                    ForEach(chats.agent.suggestions, id: \.self) { suggestion in
                        Button { chats.send(suggestion) } label: {
                            VStack(alignment: .leading, spacing: 10) {
                                Image(systemName: "arrow.up.right").font(.callout.weight(.semibold)).foregroundStyle(.tint)
                                Text(suggestion).font(.callout).multilineTextAlignment(.leading).foregroundStyle(.primary)
                                Spacer(minLength: 0)
                            }
                            .frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)
                            .padding(14)
                            .background(.quaternary.opacity(0.55), in: .rect(cornerRadius: 14))
                            .contentShape(.rect(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: 680)
            }
            SmartzTokensBadge()
        }
        .padding(.horizontal, 24)
        .padding(.top, 56)
        .frame(maxWidth: .infinity)
    }
    #else
    private var welcome: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: chats.agent.symbol).font(.system(size: 34, weight: .semibold)).foregroundStyle(.tint)
            Text(chats.agent.greeting).font(.title3.weight(.semibold))
            if !chats.agent.suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(chats.agent.suggestions, id: \.self) { suggestion in
                        Button { chats.send(suggestion) } label: {
                            Text(suggestion).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            SmartzTokensBadge()
        }
        .padding()
    }
    #endif

    private var more: some View {
        Menu {
            Toggle(isOn: Binding(get: { voice.autoSpeak }, set: { voice.setAutoSpeak($0) })) {
                Label("Read Answers Aloud", systemImage: "speaker.wave.2")
            }
            Toggle(isOn: $chats.thinkHarder) { Label("Think Harder", systemImage: "brain") }
            if chats.agent.learns {
                Section {
                    Button { harvest() } label: { Label("Harvest This Chat", systemImage: "leaf") }
                        .disabled(chats.currentMessages.isEmpty || chats.harvesting)
                    Button { showingKnows = true } label: { Label("What Smartz Knows", systemImage: "brain.head.profile") }
                }
            }
            if let id = chats.current, !chats.currentMessages.isEmpty {
                Section {
                    ShareLink(item: SmartzChatExport(title: chats.currentThread?.title ?? "", markdown: chats.markdown(id)),
                              preview: SharePreview(chats.currentThread?.title.isEmpty == false ? chats.currentThread!.title : "Chat with \(chats.agent.name)")) {
                        Label("Export as Markdown", systemImage: "square.and.arrow.up")
                    }
                    Button { newTitle = chats.currentThread?.title ?? ""; renaming = true } label: { Label("Rename", systemImage: "pencil") }
                    Button { chats.togglePin(id) } label: {
                        chats.currentThread?.pinnedAt == nil ? Label("Pin", systemImage: "pin") : Label("Unpin", systemImage: "pin.slash")
                    }
                }
            }
        } label: {
            Label("More", systemImage: "ellipsis.circle")
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if voice.dictating || transcribing {
                dictation
            } else {
                accessory
                attachMenu
                TextField("Message \(chats.agent.name)", text: $text, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($focused)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 20))
                    .onSubmit(send)
                if chats.answering != nil {
                    Button { chats.stop() } label: { Image(systemName: "stop.circle.fill").font(.title) }
                        .accessibilityLabel("Stop")
                } else if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty && SmartzVoice.canListen && Smartz.canOffer {
                    Button { dictate() } label: { Image(systemName: "mic").font(.title2) }
                        .accessibilityLabel("Dictate")
                        .padding(.bottom, 6)
                    Button { talk() } label: { Image(systemName: "waveform.circle.fill").font(.title) }
                        .accessibilityLabel("Talk with \(chats.agent.name)")
                } else {
                    Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title) }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty)
                        .accessibilityLabel("Send")
                        .keyboardShortcut(.return, modifiers: .command)
                }
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    /// Listening for a message: the words as they're heard, then Smartz's transcript in the composer.
    private var dictation: some View {
        HStack(spacing: 10) {
            Button { voice.cancelDictation() } label: { Image(systemName: "xmark.circle.fill").font(.title2).foregroundStyle(.secondary) }
                .accessibilityLabel("Cancel")
                .disabled(transcribing)
            if transcribing {
                ProgressView().controlSize(.small)
                Text("Writing it down…").foregroundStyle(.secondary)
            } else {
                SmartzLevelBars(level: voice.level)
                Text(voice.liveWords.isEmpty ? "Listening…" : voice.liveWords)
                    .lineLimit(3)
                    .foregroundStyle(voice.liveWords.isEmpty ? .secondary : .primary)
            }
            Spacer(minLength: 0)
            Button { finishDictation() } label: { Image(systemName: "checkmark.circle.fill").font(.title) }
                .accessibilityLabel("Done")
                .disabled(transcribing)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 22))
    }

    private func send() {
        let message = text
        let sending = attachments
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !sending.isEmpty, chats.answering == nil else { return }
        text = ""
        attachments = []
        attachProblem = nil
        chats.send(message, images: sending.compactMap(\.image), files: sending.compactMap(\.file))
    }

    // MARK: Photos and files

    private var attachMenu: some View {
        Menu {
            Button("Photos", systemImage: "photo.on.rectangle") { choosingPhotos = true }
            Button("Files", systemImage: "doc") { choosingFiles = true }
        } label: {
            Image(systemName: "plus.circle").font(.title2)
        }
        .menuIndicator(.hidden)
        .accessibilityLabel("Attach Photos or Files")
        .padding(.bottom, 6)
        .disabled(attachments.count >= SmartzFiles.maxAttachments)
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    HStack(spacing: 6) {
                        if let image = attachment.image {
                            Image(decorative: image, scale: 1).resizable().scaledToFill()
                                .frame(width: 34, height: 34).clipShape(.rect(cornerRadius: 7))
                        } else {
                            Image(systemName: "doc.text").font(.title3).foregroundStyle(.tint).frame(width: 34, height: 34)
                        }
                        Text(attachment.isPhoto ? "Photo" : attachment.name).font(.caption).lineLimit(1).frame(maxWidth: 140, alignment: .leading)
                        Button { attachments.removeAll { $0.id == attachment.id } } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(attachment.isPhoto ? "photo" : attachment.name)")
                    }
                    .padding(.leading, 4).padding(.trailing, 8).padding(.vertical, 4)
                    .background(.quaternary.opacity(0.6), in: .capsule)
                }
            }
            .padding(.horizontal, 14)
        }
        .padding(.top, 4)
    }

    private func attach(_ urls: [URL]) {
        var problems: [String] = []
        for url in urls {
            guard attachments.count < SmartzFiles.maxAttachments else { problems.append("You can attach up to \(SmartzFiles.maxAttachments) at a time."); break }
            do {
                let attachment = try SmartzFiles.load(url)
                if attachment.isPhoto && attachments.filter(\.isPhoto).count >= 4 { problems.append("Up to 4 photos at a time."); continue }
                attachments.append(attachment)
            } catch {
                problems.append(error.localizedDescription)
            }
        }
        attachProblem = problems.first
        if !attachments.isEmpty { focused = true }
    }

    private func loadPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        photoItems = []
        Task {
            for item in items {
                guard attachments.filter(\.isPhoto).count < 4, attachments.count < SmartzFiles.maxAttachments else { break }
                if let data = try? await item.loadTransferable(type: Data.self), let image = SmartzFiles.picture(data) {
                    attachments.append(SmartzAttachment(name: "Photo", image: image, file: nil))
                } else {
                    attachProblem = "That photo couldn't be opened."
                }
            }
            focused = true
        }
    }

    private func dictate() {
        Task {
            guard await SmartzPrompt.ensurePermission() else { return }
            await voice.startDictation()
        }
    }

    private func finishDictation() {
        transcribing = true
        Task {
            if let words = await voice.finishDictation() {
                text = text.isEmpty ? words : text + " " + words
                focused = true
            }
            transcribing = false
        }
    }

    private func talk() {
        Task {
            guard await SmartzPrompt.ensurePermission() else { return }
            talking = true
        }
    }

    private func editLast() {
        if let old = chats.editLast() {
            text = old
            focused = true
        }
    }

    private func harvest() {
        Task {
            do { harvested = try await chats.harvest() } catch { harvestProblem = Smartz.message(for: error) }
        }
    }

    static func harvestTitle(_ harvest: SmartzHarvest) -> String {
        harvest.memories == 0 && harvest.pages.isEmpty ? "Nothing New to Learn" : "Smartz Learned from This Chat"
    }

    static func harvestMessage(_ harvest: SmartzHarvest) -> String {
        var parts: [String] = []
        if harvest.memories > 0 { parts.append(harvest.memories == 1 ? "1 new memory" : "\(harvest.memories) new memories") }
        if !harvest.pages.isEmpty { parts.append("Wiki: " + harvest.pages.map(\.title).joined(separator: ", ")) }
        if harvest.skills > 0 { parts.append(harvest.skills == 1 ? "Shared 1 skill with Smartz" : "Shared \(harvest.skills) skills with Smartz") }
        return ([harvest.summary] + parts).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// A message, with what you can do with it: read it aloud, copy it, answer again, edit your last question.
    struct MessageRow: View {
        let chats: SmartzChats
        let message: SmartzChatMessage
        let isLast: Bool
        let isLastQuestion: Bool
        let edit: () -> Void
        private var voice: SmartzVoice { .shared }

        init(chats: SmartzChats, message: SmartzChatMessage, isLast: Bool, isLastQuestion: Bool, edit: @escaping () -> Void) {
            self.chats = chats; self.message = message; self.isLast = isLast; self.isLastQuestion = isLastQuestion; self.edit = edit
        }

        private var mine: Bool { message.role == .user }
        private var reading: Bool { voice.speakingID == message.id }

        var body: some View {
            VStack(alignment: mine ? .trailing : .leading, spacing: 4) {
                Bubble(text: SmartzSpeech.visible(message.text), mine: mine, symbol: chats.agent.symbol)
                    .contextMenu {
                        Button { Self.copy(SmartzSpeech.visible(message.text)) } label: { Label("Copy", systemImage: "doc.on.doc") }
                        if !mine, Smartz.isOn {
                            Button { voice.toggle(id: message.id, text: message.text) } label: {
                                reading ? Label("Stop Reading", systemImage: "stop.circle") : Label("Read Aloud", systemImage: "speaker.wave.2")
                            }
                        }
                        if !mine, isLast, chats.canRegenerate {
                            Button { chats.regenerate() } label: { Label("Answer Again", systemImage: "arrow.clockwise") }
                        }
                        if mine, isLastQuestion, chats.answering == nil, !SmartzChats.hasPhotos(message.text), !SmartzChats.hasFiles(message.text) {
                            Button(action: edit) { Label("Edit", systemImage: "pencil") }
                        }
                    }
                if mine {
                    if isLastQuestion, chats.answering == nil, !SmartzChats.hasPhotos(message.text), !SmartzChats.hasFiles(message.text) {
                        Button(action: edit) { Image(systemName: "pencil") }
                            .accessibilityLabel("Edit")
                            .font(.caption).foregroundStyle(.secondary).buttonStyle(.borderless)
                            .padding(.trailing, 16)
                    }
                } else {
                    actions
                }
            }
            .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
        }

        private var actions: some View {
            HStack(spacing: 16) {
                if Smartz.isOn {
                    Button { voice.toggle(id: message.id, text: message.text) } label: {
                        if reading && voice.waitingForSound {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: reading ? "stop.circle" : "speaker.wave.2")
                                .symbolEffect(.variableColor.iterative, isActive: reading)
                        }
                    }
                    .accessibilityLabel(reading ? "Stop Reading" : "Read Aloud")
                }
                Button { Self.copy(SmartzSpeech.visible(message.text)) } label: { Image(systemName: "doc.on.doc") }
                    .accessibilityLabel("Copy")
                if isLast, chats.canRegenerate {
                    Button { chats.regenerate() } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("Answer Again")
                }
                if let tokens = message.tokens {
                    Text(Self.cost(tokens)).monospacedDigit().accessibilityLabel("Cost \(Self.cost(tokens))")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .buttonStyle(.borderless)
            .padding(.leading, 42)
        }

        static func cost(_ tokens: Double) -> String {
            tokens < 0.05 ? "under 0.1 token" : tokens.formatted(.number.precision(.fractionLength(0...1))) + (tokens == 1 ? " token" : " tokens")
        }

        static func copy(_ text: String) {
            #if canImport(UIKit)
            UIPasteboard.general.string = text
            #elseif canImport(AppKit)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            #endif
        }
    }

    struct Bubble: View {
        let text: String
        let mine: Bool
        let symbol: String
        var working = false

        var body: some View {
            HStack(alignment: .top, spacing: 8) {
                if mine { Spacer(minLength: 48) } else {
                    Image(systemName: symbol).foregroundStyle(.tint).frame(width: 22).padding(.top, 8)
                        .symbolEffect(.pulse, isActive: working)
                }
                Text(Self.rendered(text))
                    .textSelection(.enabled)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .foregroundStyle(mine ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                    .background(mine ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary.opacity(0.5)), in: .rect(cornerRadius: 18))
                if !mine { Spacer(minLength: 24) }
            }
            .padding(.horizontal, 12)
        }

        static func rendered(_ text: String) -> AttributedString {
            (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        }
    }
}

/// A chat as a Markdown file, for the share sheet.
nonisolated struct SmartzChatExport: Transferable {
    let title: String
    let markdown: String

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .utf8PlainText) { Data($0.markdown.utf8) }
            .suggestedFileName { ($0.title.isEmpty ? "Chat with Smartz" : $0.title) + ".md" }
    }
}

/// Earlier chats with an agent from every Asteria app (and smartz.chat): pinned first, then newest, with search.
public struct SmartzChatList: View {
    @Bindable var chats: SmartzChats
    let done: () -> Void
    @State private var query = ""
    @State private var renaming: SmartzChatThread?
    @State private var newTitle = ""

    public init(chats: SmartzChats, done: @escaping () -> Void) {
        self.chats = chats
        self.done = done
    }

    public var body: some View {
        let shown = chats.threads(matching: query)
        List {
            ForEach(shown) { thread in
                Button {
                    Task { await chats.open(thread.id) }
                    done()
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            if thread.pinnedAt != nil { Image(systemName: "pin.fill").font(.caption).foregroundStyle(.tint) }
                            Text(thread.title.isEmpty ? "New chat" : thread.title).font(.headline).lineLimit(1)
                        }
                        Text(thread.preview).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                        Text(thread.app.isEmpty ? thread.updatedAt.formatted(.relative(presentation: .named))
                             : "\(thread.app) · \(thread.updatedAt.formatted(.relative(presentation: .named)))")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                .swipeActions {
                    Button("Delete", role: .destructive) { Task { await chats.delete(thread.id) } }
                    Button(thread.pinnedAt == nil ? "Pin" : "Unpin") { chats.togglePin(thread.id) }.tint(.orange)
                }
                .contextMenu {
                    Button { chats.togglePin(thread.id) } label: {
                        thread.pinnedAt == nil ? Label("Pin", systemImage: "pin") : Label("Unpin", systemImage: "pin.slash")
                    }
                    Button { newTitle = thread.title; renaming = thread } label: { Label("Rename", systemImage: "pencil") }
                    Button("Delete", systemImage: "trash", role: .destructive) { Task { await chats.delete(thread.id) } }
                }
            }
        }
        .searchable(text: $query, prompt: "Search chats")
        .overlay {
            if shown.isEmpty {
                if query.isEmpty {
                    ContentUnavailableView("No chats yet", systemImage: chats.agent.symbol,
                                           description: Text("Chats with \(chats.agent.name) from every Asteria app appear here."))
                } else {
                    ContentUnavailableView.search(text: query)
                }
            }
        }
        .alert("Rename Chat", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $newTitle)
            Button("Save") { if let thread = renaming { Task { await chats.rename(thread.id, to: newTitle) } } }
            Button("Cancel", role: .cancel) {}
        }
        .navigationTitle("Chats with \(chats.agent.name)")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done", action: done) }
            ToolbarItem(placement: .primaryAction) {
                Button { chats.newThread(); done() } label: { Label("New Chat", systemImage: "square.and.pencil") }
            }
        }
        .refreshable { await chats.refresh() }
    }
}

// MARK: Tokens and the subscription

/// "48 of 64 tokens left today · Dedicated".
public struct SmartzTokensBadge: View {
    private var usage = SmartzUsage.shared

    public init() {}

    public var body: some View {
        if usage.known {
            Label {
                Text("\(usage.tokensLeft) of \(usage.tokensPerDay) Smartz tokens left today" + (usage.tierName.map { " · \($0)" } ?? ""))
            } icon: { Image(systemName: "circle.hexagongrid.fill") }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

/// The tiers of The Smartz Subscription: tokens a day, and the price a month.
nonisolated public enum SmartzPlans {
    public struct Plan: Identifiable, Hashable, Sendable {
        public let id: String
        public let name: String
        public let price: String
        public let tokens: Int
    }

    public static let all: [Plan] = [
        Plan(id: "havenot", name: "Havenot", price: "Free", tokens: 2),
        Plan(id: "easyGoing", name: "Easy Going", price: "$4.07", tokens: 8),
        Plan(id: "casual", name: "Casual", price: "$8.13", tokens: 16),
        Plan(id: "serious", name: "Serious", price: "$16.27", tokens: 32),
        Plan(id: "dedicated", name: "Dedicated", price: "$32.54", tokens: 64),
        Plan(id: "legit", name: "Legit", price: "$65.07", tokens: 128),
        Plan(id: "pro", name: "Pro", price: "$130.15", tokens: 256),
        Plan(id: "literallyInsane", name: "Literally Insane", price: "$260.30", tokens: 512),
        Plan(id: "how", name: "How?", price: "$520.60", tokens: 1_024),
    ]
}

/// The Smartz Subscription in Settings: today's tokens, the plans, buying and managing.
public struct SmartzSubscriptionView: View {
    public init() {}

    public var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Text("Smartz tokens pay for Smartz in every Asteria app (Smartz, Post, Browse, Box, Food and Mood, Timeclock, and Swift: Zero to Hero) and at smartz.chat. Your tokens refresh at midnight UTC, and one plan covers every app.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                SmartzPlanList()
            }
            .padding(20)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("The Smartz Subscription")
        .task { await SmartzUsage.shared.refresh(); await SmartzSubscription.shared.refresh() }
    }
}

// MARK: The Asteria Account

/// The Asteria Account in an app's settings: who's signed in, today's tokens, the subscription, signing out and
/// deleting the account; or signing in and making one.
public struct AsteriaAccountSection: View {
    private var account = AsteriaID.shared
    @State private var sheet: AsteriaSignInView.Mode?
    @State private var deleting = false
    let onSignOut: () -> Void

    public init(onSignOut: @escaping () -> Void = {}) { self.onSignOut = onSignOut }

    public var body: some View {
        Section {
            if let username = account.username {
                LabeledContent("Signed in as", value: "@" + username)
                SmartzTokensBadge()
                NavigationLink { SmartzSubscriptionView() } label: {
                    LabeledContent("The Smartz Subscription", value: SmartzSubscription.shared.status?.plan?.tierName ?? SmartzUsage.shared.tierName ?? "")
                }
                Button("Sign Out") { account.signOut(); onSignOut() }
                Button("Delete Asteria Account…", role: .destructive) { deleting = true }
            } else {
                Button { sheet = .signIn } label: { Label("Sign In with Your Asteria Account", systemImage: "person.crop.circle") }
                Button { sheet = .signUp } label: { Label("Make an Asteria Account", systemImage: "person.crop.circle.badge.plus") }
            }
        } header: {
            Text("Asteria Account")
        } footer: {
            // The sheets hang off the footer, one view: on the Section, a Form copies them onto every row, which
            // presented them several times at once and closed the Settings sheet they were in.
            Text(account.isSignedIn
                 ? "Your Asteria Account works in every Asteria app, with the same tokens and chats with Smartz."
                 : "One account for every Asteria app: your Smartz tokens and your chats with Smartz follow you everywhere. It's also your Asteria Post account.")
                .sheet(item: $sheet) { mode in AsteriaSignInView(mode: mode) }
                .sheet(isPresented: $deleting) { AsteriaDeleteAccountView { onSignOut() } }
        }
    }
}

/// Signing in with a username and password, or making an Asteria Account.
public struct AsteriaSignInView: View {
    public enum Mode: String, Identifiable { case signIn, signUp; public var id: String { rawValue } }

    @Environment(\.dismiss) private var dismiss
    @State var mode: Mode
    @State private var name = ""
    @State private var username = ""
    @State private var email = ""
    @State private var password = ""
    @State private var check: AsteriaID.UsernameCheck?
    @State private var working = false
    @State private var problem: String?
    /// Signed in (or made): the form gives way to a confirmation, and Done closes the sheet. Closing it straight away
    /// collided with the system's "Save Password?" prompt, which left a sheet that wouldn't close.
    @State private var welcomed: String?
    @State private var offeringPlans = false

    public init(mode: Mode = .signIn) { _mode = State(initialValue: mode) }

    public var body: some View {
        NavigationStack {
            if let welcomed {
                ScrollView {
                    VStack(spacing: 14) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 56))
                            .foregroundStyle(.tint)
                        Text(mode == .signUp ? "Welcome, @\(welcomed)" : "Signed in as @\(welcomed)")
                            .font(.title3.bold())
                        Text("Your Asteria Account works in every Asteria app, with the same Smartz tokens and chats with Smartz.")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                        if offeringPlans {
                            // Signing in is when the plans are offered (an account that has one isn't asked).
                            Text("Get More from Smartz").font(.headline).padding(.top, 10)
                            SmartzPlanList(onlyUpgrades: true)
                        }
                        if offeringPlans {
                            Button { dismiss() } label: { Text("Not Now").bold().frame(maxWidth: 280) }
                                .buttonStyle(.bordered).controlSize(.large).padding(.top, 6)
                        } else {
                            Button { dismiss() } label: { Text("Done").bold().frame(maxWidth: 280) }
                                .buttonStyle(.borderedProminent).controlSize(.large).padding(.top, 6)
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity)
                }
                .navigationTitle(mode == .signIn ? "Asteria Account" : "Make an Asteria Account")
                .task {
                    let store = SmartzSubscription.shared
                    await store.refresh(sendingEntitlements: true)
                    offeringPlans = store.status?.plan == nil && !store.upgrades.isEmpty
                }
            } else {
                form
            }
        }
        #if os(macOS)
        .frame(minWidth: 400, minHeight: 420)
        #endif
    }

    private var form: some View {
        Form {
            Section {
                if mode == .signUp { TextField("Name", text: $name).textContentType(.name) }
                TextField("Username", text: $username)
                    .textContentType(mode == .signUp ? .username : .username)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                if mode == .signUp {
                    TextField("Email", text: $email).textContentType(.emailAddress)
                        #if os(iOS)
                        .keyboardType(.emailAddress).textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                }
                SecureField("Password", text: $password).textContentType(mode == .signUp ? .newPassword : .password)
            } footer: {
                if mode == .signUp, let check, !username.isEmpty {
                    Text(check.available ? "@\(check.username) is free." : (check.reason ?? "That username is taken."))
                        .foregroundStyle(check.available ? Color.secondary : Color.red)
                } else if mode == .signIn {
                    Text("Your username, like maya. The same one you use in Smartz and Post.")
                }
            }
            if let problem { Section { Text(problem).foregroundStyle(.red) } }
            Section {
                Button(action: submit) {
                    HStack {
                        Text(mode == .signIn ? "Sign In" : "Make Account").bold()
                        if working { Spacer(); ProgressView() }
                    }
                }
                .disabled(!ready || working)
                Button(mode == .signIn ? "New here? Make an Asteria Account" : "Already have one? Sign in") {
                    mode = mode == .signIn ? .signUp : .signIn
                    problem = nil
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(mode == .signIn ? "Asteria Account" : "Make an Asteria Account")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        .task(id: username) {
            guard mode == .signUp, !username.isEmpty else { check = nil; return }
            try? await Task.sleep(for: .milliseconds(400))
            check = await AsteriaID.check(username: username)
        }
    }

    private var ready: Bool {
        guard !username.trimmingCharacters(in: .whitespaces).isEmpty, password.count >= 8 || (mode == .signIn && !password.isEmpty) else { return false }
        return mode == .signIn || (!name.trimmingCharacters(in: .whitespaces).isEmpty && email.contains("@") && check?.available != false)
    }

    private func submit() {
        working = true
        problem = nil
        Task {
            do {
                if mode == .signIn {
                    try await AsteriaID.shared.signIn(username: username, password: password)
                } else {
                    try await AsteriaID.shared.signUp(name: name, username: username, email: email, password: password)
                }
                welcomed = AsteriaID.shared.username ?? AsteriaID.username(fromHandle: username)
            } catch {
                problem = error.localizedDescription
            }
            working = false
        }
    }
}

/// Deleting the Asteria Account, with the password typed again.
public struct AsteriaDeleteAccountView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var working = false
    @State private var problem: String?
    let deleted: () -> Void

    public init(deleted: @escaping () -> Void = {}) { self.deleted = deleted }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("This deletes your Asteria Account everywhere: your Asteria Post account and posts, your bots' usernames, your Smartz tokens, your chats with Smartz in every app, and what apps sync through it, like Timeclock's hours. It can't be undone.")
                    if SmartzUsage.shared.subscribed {
                        Text("Deleting your account doesn't cancel The Smartz Subscription: the App Store bills it. Cancel it in your App Store subscriptions first.")
                            .foregroundStyle(.orange)
                        Link("Manage Subscriptions", destination: SmartzSubscription.manageURL)
                    }
                    SecureField("Password", text: $password).textContentType(.password)
                }
                if let problem { Section { Text(problem).foregroundStyle(.red) } }
                Section {
                    Button(role: .destructive) {
                        working = true
                        Task {
                            do {
                                try await AsteriaID.shared.deleteAccount(password: password)
                                deleted()
                                dismiss()
                            } catch { problem = error.localizedDescription }
                            working = false
                        }
                    } label: {
                        HStack { Text("Delete My Asteria Account").bold(); if working { Spacer(); ProgressView() } }
                    }
                    .disabled(password.isEmpty || working)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Delete Account")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 400, minHeight: 320)
        #endif
    }
}
