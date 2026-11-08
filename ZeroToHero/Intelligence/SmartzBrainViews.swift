// What Smartz knows, on screen: the memories it made from chats you harvested, your wiki (private unless you publish it
// at smartz.chat/<username>), and unified intelligence (off unless you turn it on). Every app can show these; the
// Smartz app gives the wiki its own tab.
import SwiftUI

/// Everything Smartz has learned about you: memories and wiki pages. Delete any of it, or all of it.
public struct SmartzKnowsView: View {
    @State private var memories: [SmartzMemory] = []
    @State private var pages: [SmartzWikiPage] = []
    @State private var loading = true
    @State private var problem: String?
    @State private var confirmingForget = false
    @State private var teaching = ""

    public init() {}

    public var body: some View {
        List {
            if let problem {
                Section { Label(problem, systemImage: "person.crop.circle.badge.exclamationmark").foregroundStyle(.secondary) }
            }
            Section {
                TextField("Teach Smartz something", text: $teaching, axis: .vertical)
                    .onSubmit(teach)
                Button("Remember This", systemImage: "plus", action: teach)
                    .disabled(teaching.trimmingCharacters(in: .whitespacesAndNewlines).count < 4)
            } footer: {
                Text("Like \"I'm vegetarian\" or \"Keep answers short\".")
            }
            Section {
                ForEach(memories) { memory in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(memory.text)
                        Text([memory.app, memory.createdAt.formatted(date: .abbreviated, time: .omitted)].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .swipeActions { Button("Forget", role: .destructive) { forget(memory) } }
                    .contextMenu { Button("Forget", systemImage: "trash", role: .destructive) { forget(memory) } }
                }
                if memories.isEmpty && !loading && problem == nil {
                    Text("Nothing yet. Harvest a chat with Smartz, in any app, and it remembers what matters from it.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Memories")
            } footer: {
                Text("Smartz uses these in your chats with it, in every Asteria app and at smartz.chat. Only you can see them.")
            }
            Section("Wiki") {
                ForEach(pages) { page in
                    NavigationLink(page.title) { SmartzWikiPageView(page: page) }
                }
                if pages.isEmpty && !loading && problem == nil {
                    Text("Pages appear here as Smartz learns from your chats.").foregroundStyle(.secondary)
                }
            }
            if !memories.isEmpty {
                Section {
                    Button("Forget All Memories", role: .destructive) { confirmingForget = true }
                }
            }
        }
        .navigationTitle("What Smartz Knows")
        .overlay { if loading && memories.isEmpty && pages.isEmpty { ProgressView() } }
        .refreshable { await load() }
        .task { await load() }
        .confirmationDialog("Forget everything Smartz remembers about you?", isPresented: $confirmingForget, titleVisibility: .visible) {
            Button("Forget All Memories", role: .destructive) {
                Task {
                    try? await SmartzBrain.forgetEverything()
                    await load()
                }
            }
        } message: {
            Text("Your memories go for good. Your wiki pages stay until you delete them.")
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            async let memoryList = SmartzBrain.memories()
            async let wiki = SmartzBrain.wiki()
            memories = try await memoryList
            pages = try await wiki.pages
            problem = nil
        } catch {
            problem = Smartz.message(for: error)
        }
    }

    private func teach() {
        let text = teaching.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 4 else { return }
        teaching = ""
        Task {
            do {
                try await SmartzBrain.remember([(kind: "fact", text: text)])
                await load()
            } catch {
                problem = Smartz.message(for: error)
            }
        }
    }

    private func forget(_ memory: SmartzMemory) {
        memories.removeAll { $0.id == memory.id }
        Task { try? await SmartzBrain.forget(memory: memory.id) }
    }
}

/// Your Smartz wiki: pages Smartz writes, as time goes on, about what you've discussed, and the harvests (from every
/// Asteria app) that wrote them. Private unless you publish it. It refreshes when you come back to the app, so a harvest
/// in another app shows up here.
public struct SmartzWikiView: View {
    @Environment(\.scenePhase) private var phase
    @State private var pages: [SmartzWikiPage] = []
    @State private var harvests: [SmartzHarvestRecord] = []
    @State private var settings = SmartzSettings()
    @State private var query = ""
    @State private var loading = true
    @State private var problem: String?

    public init() {}

    public var body: some View {
        let shown = query.isEmpty ? pages : pages.filter { $0.title.localizedStandardContains(query) }
        container { sections(shown) }
        .searchable(text: $query, prompt: "Search your wiki")
        .overlay {
            if shown.isEmpty && !loading {
                if query.isEmpty {
                    ContentUnavailableView("Your wiki is empty", systemImage: "book.closed",
                                           description: Text("Harvest a chat with Smartz in any Asteria app, and Smartz writes pages about what you discussed."))
                } else {
                    ContentUnavailableView.search(text: query)
                }
            }
        }
        .navigationTitle("Wiki")
        .task { await load() }
        .refreshable { await load() }
        .onChange(of: phase) { _, now in if now == .active { Task { await load() } } }
        .onReceive(NotificationCenter.default.publisher(for: SmartzBrain.didLearn)) { _ in Task { await load() } }
    }

    /// Grouped sections on the Mac, like its settings; a list on iPhone and iPad.
    @ViewBuilder private func container<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        #if os(macOS)
        Form { content() }.formStyle(.grouped)
        #else
        List { content() }
        #endif
    }

    @ViewBuilder private func sections(_ shown: [SmartzWikiPage]) -> some View {
            Section {
                Toggle(isOn: Binding(get: { settings.wikiPublic }, set: { on in publish(on) })) {
                    Label("Publish at smartz.chat", systemImage: "globe")
                }
                .toggleStyle(.switch)
                if settings.wikiPublic, let url = settings.publicURL {
                    Link(destination: url) {
                        Label(url.absoluteString.replacingOccurrences(of: "https://", with: ""), systemImage: "link")
                    }
                    ShareLink(item: url) { Label("Share Your Wiki", systemImage: "square.and.arrow.up") }
                }
            } footer: {
                Text(settings.wikiPublic
                     ? "Anyone with the link can read your wiki. Turn this off and it's private again at once."
                     : "Your wiki is private: only you can read it. Publish it to let anyone read it at smartz.chat.")
            }
            if let problem {
                Section { Text(problem).foregroundStyle(.secondary) }
            }
            if !harvests.isEmpty && query.isEmpty {
                Section {
                    ForEach(harvests.prefix(3)) { harvest in SmartzHarvestRow(harvest: harvest) }
                    if harvests.count > 3 {
                        NavigationLink("All Harvests (\(harvests.count))") { SmartzHarvestsView(harvests: harvests) }
                    }
                } header: {
                    Text("Recent Harvests")
                } footer: {
                    Text("Harvest a chat with Smartz in any Asteria app, and what Smartz learned shows up here.")
                }
            }
            Section(pages.isEmpty ? "" : "Pages") {
                ForEach(shown) { page in
                    NavigationLink { SmartzWikiPageView(page: page, onDelete: { pages.removeAll { $0.slug == page.slug } }) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(page.title).font(.headline)
                            Text("Updated " + page.updatedAt.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            async let wiki = SmartzBrain.wiki()
            async let current = SmartzBrain.settings()
            async let recent = SmartzBrain.harvests()
            pages = try await wiki.pages
            settings = try await current
            harvests = (try? await recent) ?? harvests
            problem = nil
        } catch {
            problem = Smartz.message(for: error)
        }
    }

    private func publish(_ on: Bool) {
        let before = settings
        settings.wikiPublic = on
        Task {
            do { settings = try await SmartzBrain.update(wikiPublic: on) } catch {
                settings = before
                problem = Smartz.message(for: error)
            }
        }
    }
}

/// One harvest: where it was, what Smartz took from it, and which pages it wrote.
public struct SmartzHarvestRow: View {
    let harvest: SmartzHarvestRecord

    public init(harvest: SmartzHarvestRecord) { self.harvest = harvest }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "leaf").foregroundStyle(.tint).accessibilityHidden(true)
                Text(harvest.title.isEmpty ? "A chat with Smartz" : harvest.title).font(.headline).lineLimit(1)
            }
            if !harvest.summary.isEmpty { Text(harvest.summary).font(.subheadline).foregroundStyle(.secondary).lineLimit(3) }
            Text(details).font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    private var details: String {
        var parts = [harvest.app.isEmpty ? nil : "In \(harvest.app)", harvest.createdAt.formatted(.relative(presentation: .named))].compactMap { $0 }
        if harvest.memories > 0 { parts.append(harvest.memories == 1 ? "1 memory" : "\(harvest.memories) memories") }
        if !harvest.pages.isEmpty { parts.append("Wiki: " + harvest.pages.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }
}

/// Every harvest, from every Asteria app.
struct SmartzHarvestsView: View {
    let harvests: [SmartzHarvestRecord]
    var body: some View {
        List(harvests) { SmartzHarvestRow(harvest: $0) }
            .navigationTitle("Harvests")
    }
}

/// One wiki page: read it, change it, or delete it.
public struct SmartzWikiPageView: View {
    let page: SmartzWikiPage
    let onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var body_: String?
    @State private var title: String
    @State private var editing = false
    @State private var draft = ""
    @State private var confirmingDelete = false
    @State private var problem: String?

    public init(page: SmartzWikiPage, onDelete: @escaping () -> Void = {}) {
        self.page = page
        self.onDelete = onDelete
        _title = State(initialValue: page.title)
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let problem { Text(problem).foregroundStyle(.secondary) }
                if let text = body_ {
                    SmartzMarkdown(text: text)
                } else if problem == nil {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .padding()
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { draft = body_ ?? ""; editing = true } label: { Label("Edit", systemImage: "pencil") }
                        .disabled(body_ == nil)
                    Button(role: .destructive) { confirmingDelete = true } label: { Label("Delete Page", systemImage: "trash") }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $editing) {
            NavigationStack {
                TextEditor(text: $draft)
                    .font(.body.monospaced())
                    .padding(.horizontal)
                    .navigationTitle("Edit \(title)")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { editing = false } }
                        ToolbarItem(placement: .confirmationAction) { Button("Save") { save() } }
                    }
            }
            #if os(macOS)
            .frame(minWidth: 520, minHeight: 480)
            #endif
        }
        .confirmationDialog("Delete \(title)?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete Page", role: .destructive) {
                Task {
                    try? await SmartzBrain.delete(page: page.slug)
                    onDelete()
                    dismiss()
                }
            }
        } message: {
            Text("Smartz may write it again if you harvest more chats about it.")
        }
        .task {
            do {
                let full = try await SmartzBrain.page(page.slug)
                body_ = full.body ?? ""
                title = full.title
            } catch {
                problem = Smartz.message(for: error)
            }
        }
    }

    private func save() {
        let text = draft
        editing = false
        body_ = text
        Task {
            do { _ = try await SmartzBrain.save(page: page.slug, title: title, body: text) } catch { problem = Smartz.message(for: error) }
        }
    }
}

/// Markdown laid out for reading: headings, lists, quotes and paragraphs (inline styles and links included).
public struct SmartzMarkdown: View {
    let text: String

    public init(text: String) { self.text = text }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Self.blocks(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let line):
                    Text(Self.inline(line)).font(level <= 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline).padding(.top, 6)
                case .bullet(let line):
                    HStack(alignment: .firstTextBaseline, spacing: 8) { Text("•"); Text(Self.inline(line)) }
                case .quote(let line):
                    Text(Self.inline(line)).italic().foregroundStyle(.secondary).padding(.leading, 12)
                        .overlay(alignment: .leading) { Rectangle().fill(.tint).frame(width: 3) }
                case .paragraph(let line):
                    Text(Self.inline(line))
                }
            }
        }
        .textSelection(.enabled)
    }

    enum Block { case heading(Int, String), bullet(String), quote(String), paragraph(String) }

    static func blocks(_ text: String) -> [Block] {
        text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return nil }
            if line.hasPrefix("#") {
                let level = line.prefix(while: { $0 == "#" }).count
                return .heading(level, line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces))
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") { return .bullet(String(line.dropFirst(2))) }
            if line.hasPrefix(">") { return .quote(line.dropFirst().trimmingCharacters(in: .whitespaces)) }
            return .paragraph(line)
        }
    }

    static func inline(_ line: String) -> AttributedString {
        (try? AttributedString(markdown: line, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(line)
    }
}

/// What Smartz learns and shares, in an app's settings: what it knows, and unified intelligence.
public struct SmartzLearningSection: View {
    @State private var settings: SmartzSettings?

    public init() {}

    public var body: some View {
        Section {
            NavigationLink { SmartzKnowsView() } label: { Label("What Smartz Knows", systemImage: "brain.head.profile") }
            NavigationLink { SmartzConnectorsView() } label: {
                LabeledContent {
                    let count = SmartzConnectors.shared.list.count
                    Text(count == 0 ? "" : "\(count)")
                } label: { Label("Connectors", systemImage: "puzzlepiece.extension") }
            }
            if let settings {
                Toggle(isOn: Binding(get: { settings.unified }, set: { on in share(on) })) {
                    Label("Unified Intelligence", systemImage: "point.3.connected.trianglepath.dotted")
                }
            }
        } header: {
            Text("Learning and Connectors")
        } footer: {
            Text("Connectors let Smartz use your other services (Notion, Linear, GitHub and more) in your chats with it. Smartz learns about you only from chats you harvest, and keeps what it learns private. With Unified Intelligence on, your harvests also teach Smartz general skills, like a good way to plan a trip, that make it better for everyone. Skills never carry anything personal, and nothing is shared unless you turn this on.")
        }
        .disabled(!Smartz.isOn)
        .task { if Smartz.isOn { settings = try? await SmartzBrain.settings() } }
    }

    private func share(_ on: Bool) {
        let before = settings
        settings?.unified = on
        Task {
            do { settings = try await SmartzBrain.update(unified: on) } catch { settings = before }
        }
    }
}
