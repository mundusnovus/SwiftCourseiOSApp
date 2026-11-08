// Connectors on screen, in every Asteria app: the ones you've added (with their tools), the directory of hosted MCP
// servers to add in a tap, and any other server by its URL. Moved here from the Smartz app.
import SwiftUI

public struct SmartzConnectorsView: View {
    @State private var adding: SmartzConnectorEntry?
    @State private var showCustom = false
    @State private var search = ""
    @Environment(\.scenePhase) private var phase
    private var hub: SmartzConnectors { .shared }

    public init() {}

    private var connectedIDs: Set<String> { Set(hub.list.compactMap(\.catalogID)) }

    public var body: some View {
        List {
            if !hub.list.isEmpty {
                Section("Connected") {
                    ForEach(hub.list) { connector in
                        NavigationLink { SmartzConnectorDetail(id: connector.id) } label: {
                            HStack(spacing: 12) {
                                SmartzConnectorIcon(symbol: connector.symbol)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(connector.name).font(.headline)
                                    Text(hub.status[connector.id] ?? summary(connector))
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                if hub.busy.contains(connector.id) { ProgressView() }
                                else if !connector.enabled { Text("Off").font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
            }
            ForEach(SmartzConnectorEntry.Category.allCases, id: \.self) { category in
                let entries = SmartzConnectorCatalog.entries.filter { $0.category == category && !connectedIDs.contains($0.id) && matches($0) }
                if !entries.isEmpty {
                    Section(category.rawValue) {
                        ForEach(entries) { entry in
                            Button { adding = entry } label: {
                                HStack(spacing: 12) {
                                    SmartzConnectorIcon(symbol: entry.symbol)
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(entry.name).font(.headline).foregroundStyle(.primary)
                                            SmartzAuthBadge(auth: entry.auth)
                                        }
                                        Text(entry.blurb).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                    Spacer()
                                    Image(systemName: "plus.circle.fill").foregroundStyle(.tint).font(.title3)
                                }
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            Section {
                Button("Add a Server by URL", systemImage: "link.badge.plus") { showCustom = true }
            } footer: {
                Text("Connectors use the Model Context Protocol. Smartz uses them only in your own chats with it, in every Asteria app. They and their sign-ins are kept in your iCloud Keychain, never on Asteria's servers.")
            }
        }
        .navigationTitle("Connectors")
        .searchable(text: $search, prompt: "Search connectors")
        .sheet(item: $adding) { entry in SmartzAddConnectorSheet(entry: entry) }
        .sheet(isPresented: $showCustom) { SmartzCustomConnectorSheet() }
        .onAppear { hub.load() }
        .onChange(of: phase) { _, now in if now == .active { hub.load() } }
    }

    private func summary(_ connector: SmartzConnector) -> String {
        guard let tools = hub.tools[connector.id] else { return "Ready" }
        return tools.count == 1 ? "1 tool" : "\(tools.count) tools"
    }

    private func matches(_ entry: SmartzConnectorEntry) -> Bool {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return true }
        return entry.name.lowercased().contains(query) || entry.blurb.lowercased().contains(query)
    }
}

struct SmartzConnectorIcon: View {
    var symbol: String
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(.tint)
            .frame(width: 38, height: 38)
            .glassEffect(in: .rect(cornerRadius: 10))
            .accessibilityHidden(true)
    }
}

private struct SmartzAuthBadge: View {
    var auth: SmartzConnectorEntry.Auth
    var body: some View {
        let (text, color): (String, Color) = switch auth {
        case .none: ("Open", .green)
        case .oauth: ("Sign in", .accentColor)
        case .token: ("Token", .orange)
        case .google, .clientID: ("Your client ID", .orange)
        case .personalURL: ("Your URL", .orange)
        }
        Text(text).font(.caption2.weight(.semibold)).foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(color.opacity(0.12), in: .capsule)
    }
}

private struct SmartzAddConnectorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let entry: SmartzConnectorEntry
    @State private var secret = ""
    @State private var url = ""
    @State private var working = false
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        SmartzConnectorIcon(symbol: entry.symbol)
                        VStack(alignment: .leading) {
                            Text(entry.name).font(.title3.weight(.semibold))
                            Text(entry.blurb).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    if !entry.url.isEmpty { Text(entry.url).font(.caption.monospaced()).foregroundStyle(.secondary) }
                }
                switch entry.auth {
                case .none:
                    Section { Text("No account needed. Smartz can use it straight away.") }
                case .oauth:
                    Section { Text("You'll sign in with \(entry.name) in a secure Apple sheet. Smartz registers itself with \(entry.name); your password never comes to Asteria.") }
                case .token:
                    Section {
                        SecureField("Token", text: $secret)
                    } footer: { Text(entry.help ?? "") }
                case .google, .clientID:
                    Section {
                        TextField("OAuth client ID", text: $secret)
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                            .autocorrectionDisabled()
                    } footer: { Text(entry.help ?? "") }
                case .personalURL:
                    Section {
                        TextField("https://", text: $url)
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            #endif
                            .autocorrectionDisabled()
                    } footer: { Text(entry.help ?? "") }
                }
                if let problem { Section { Text(problem).foregroundStyle(.red) } }
            }
            .formStyle(.grouped)
            .navigationTitle("Add \(entry.name)")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if working { ProgressView() } else {
                        Button(entry.auth == .oauth || entry.auth == .google || entry.auth == .clientID ? "Sign In" : "Add", action: add)
                            .disabled(needsInput && secret.trimmingCharacters(in: .whitespaces).isEmpty && url.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 380)
        #endif
    }

    private var needsInput: Bool { [.token, .google, .clientID, .personalURL].contains(entry.auth) }

    private func add() {
        working = true
        problem = nil
        Task {
            defer { working = false }
            do {
                try await SmartzConnectors.shared.add(entry, secret: secret, url: url)
                dismiss()
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}

private struct SmartzCustomConnectorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var url = ""
    @State private var token = ""
    @State private var working = false
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    TextField("https://example.com/mcp", text: $url)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                        .autocorrectionDisabled()
                    SecureField("Bearer token (optional)", text: $token)
                } footer: {
                    Text("Any remote MCP server that speaks Streamable HTTP. If it asks you to sign in, Smartz does it with OAuth.")
                }
                if let problem { Section { Text(problem).foregroundStyle(.red) } }
            }
            .formStyle(.grouped)
            .navigationTitle("Add a Server")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if working { ProgressView() } else {
                        Button("Add", action: add).disabled(url.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 320)
        #endif
    }

    private func add() {
        working = true
        problem = nil
        Task {
            defer { working = false }
            do {
                try await SmartzConnectors.shared.addCustom(name: name, url: url, token: token)
                dismiss()
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}

/// One connector: on or off, its address, its tools, signing in again, removing it.
public struct SmartzConnectorDetail: View {
    @Environment(\.dismiss) private var dismiss
    let id: String
    private var hub: SmartzConnectors { .shared }

    public init(id: String) { self.id = id }

    public var body: some View {
        if let connector = hub.list.first(where: { $0.id == id }) {
            List {
                Section {
                    Toggle("On", isOn: Binding(get: { connector.enabled }, set: { hub.setEnabled(connector, $0) }))
                    LabeledContent("Address", value: connector.url).font(.footnote)
                    if let status = hub.status[connector.id] { Text(status).font(.footnote).foregroundStyle(.secondary) }
                    Button("Refresh Tools", systemImage: "arrow.clockwise") { Task { try? await hub.refreshTools(connector) } }
                    if connector.auth == "oauth" || connector.auth == "google" {
                        Button("Sign In Again", systemImage: "person.badge.key") { Task { await hub.reconnect(connector) } }
                    }
                } footer: {
                    Text("Smartz can use it in your chats with it, in every Asteria app.")
                }
                let tools = hub.tools[connector.id] ?? []
                Section("Tools (\(tools.count))") {
                    ForEach(tools) { tool in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(tool.title ?? tool.name).font(.subheadline.weight(.semibold))
                                if tool.readOnly == true { Image(systemName: "eye").font(.caption2).foregroundStyle(.secondary).accessibilityLabel("Read only") }
                            }
                            Text(tool.description).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                        }
                    }
                }
                Section { Button("Remove \(connector.name)", role: .destructive) { hub.remove(connector); dismiss() } }
            }
            .navigationTitle(connector.name)
            .task { if hub.tools[connector.id] == nil { try? await hub.refreshTools(connector) } }
        } else {
            ContentUnavailableView("Removed", systemImage: "puzzlepiece.extension")
        }
    }
}
