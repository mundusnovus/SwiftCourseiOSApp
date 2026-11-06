// The screens every Asteria app shares: chatting with Asteria (or an app's own agent), the Asteria Account (sign in,
// make one, sign out, delete it), today's Asteria tokens, and The Asteria Subscription.
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: Chat

/// A chat with an agent: the open conversation, a list of earlier chats, and a composer. `accessory` goes beside the
/// text field (a microphone, a photo button).
public struct AsteriaChatView<Accessory: View>: View {
    @Bindable var chats: AsteriaChats
    let accessory: Accessory
    let signIn: (() -> Void)?
    @State private var text = ""
    @State private var showingThreads = false
    @FocusState private var focused: Bool

    public init(chats: AsteriaChats, signIn: (() -> Void)? = nil, @ViewBuilder accessory: () -> Accessory = { EmptyView() }) {
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
                            Bubble(text: message.text, mine: message.role == .user, symbol: chats.agent.symbol).id(message.id)
                        }
                        if let answering = chats.answering, answering == chats.current {
                            Bubble(text: chats.draft.isEmpty ? "…" : chats.draft, mine: false, symbol: chats.agent.symbol, working: true).id("draft")
                        }
                        if let error = chats.error {
                            Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
                        }
                        Color.clear.frame(height: 4).id("bottom")
                    }
                    .padding(.vertical, 12)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: chats.currentMessages.count) { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
                .onChange(of: chats.draft) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            if !chats.syncing, AsteriaIntelligence.isOn {
                HStack(spacing: 8) {
                    Image(systemName: "icloud.slash")
                    Text("Sign in to your Asteria Account to keep chats on all your devices.").font(.caption)
                    if let signIn { Button("Sign In", action: signIn).font(.caption.bold()).foregroundStyle(.tint) }
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal).padding(.bottom, 6)
            }
            composer
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button { showingThreads = true } label: { Label("Chats", systemImage: "list.bullet") }
            }
            ToolbarItem(placement: .automatic) {
                Button { chats.newThread(); focused = true } label: { Label("New Chat", systemImage: "square.and.pencil") }
            }
        }
        .sheet(isPresented: $showingThreads) {
            NavigationStack { AsteriaChatList(chats: chats) { showingThreads = false } }
                #if os(macOS)
                .frame(minWidth: 380, minHeight: 460)
                #endif
        }
        .task { await chats.refresh() }
    }

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
            AsteriaTokensBadge()
        }
        .padding()
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            accessory
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
            } else {
                Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title) }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Send")
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func send() {
        let message = text
        text = ""
        chats.send(message)
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

/// Earlier chats with an agent, newest first, from every Asteria app.
public struct AsteriaChatList: View {
    @Bindable var chats: AsteriaChats
    let done: () -> Void

    public init(chats: AsteriaChats, done: @escaping () -> Void) {
        self.chats = chats
        self.done = done
    }

    public var body: some View {
        List {
            ForEach(chats.threads.filter { !(chats.messages[$0.id] ?? []).isEmpty || !$0.preview.isEmpty }) { thread in
                Button {
                    Task { await chats.open(thread.id) }
                    done()
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(thread.title.isEmpty ? "New chat" : thread.title).font(.headline).lineLimit(1)
                        Text(thread.preview).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                        Text(thread.app.isEmpty ? thread.updatedAt.formatted(.relative(presentation: .named))
                             : "\(thread.app) · \(thread.updatedAt.formatted(.relative(presentation: .named)))")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                .swipeActions { Button("Delete", role: .destructive) { Task { await chats.delete(thread.id) } } }
                .contextMenu { Button("Delete", systemImage: "trash", role: .destructive) { Task { await chats.delete(thread.id) } } }
            }
        }
        .overlay {
            if chats.threads.allSatisfy({ (chats.messages[$0.id] ?? []).isEmpty && $0.preview.isEmpty }) {
                ContentUnavailableView("No chats yet", systemImage: chats.agent.symbol, description: Text("Chats with \(chats.agent.name) from every Asteria app appear here."))
            }
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
public struct AsteriaTokensBadge: View {
    private var usage = AsteriaUsage.shared

    public init() {}

    public var body: some View {
        if usage.known {
            Label {
                Text("\(usage.tokensLeft) of \(usage.tokensPerDay) Asteria tokens left today" + (usage.tierName.map { " · \($0)" } ?? ""))
            } icon: { Image(systemName: "circle.hexagongrid.fill") }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

/// The tiers of The Asteria Subscription: tokens a day, and the price a month.
nonisolated public enum AsteriaPlans {
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

public struct AsteriaSubscriptionView: View {
    private var usage = AsteriaUsage.shared

    public init() {}

    public var body: some View {
        Form {
            Section {
                AsteriaTokensBadge()
                Text("Asteria tokens pay for Asteria Intelligence in every Asteria app: Asteria, Post, Browse, Box, Food and Mood, and Swift: Zero to Hero. Your tokens refresh at midnight UTC.")
                    .font(.callout)
            }
            Section {
                ForEach(AsteriaPlans.all) { plan in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(plan.name).font(.headline)
                            Text("\(plan.tokens) tokens a day").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if plan.id == usage.tier {
                            Label("Yours", systemImage: "checkmark.circle.fill").labelStyle(.titleAndIcon).foregroundStyle(.tint).font(.callout.bold())
                        } else {
                            Text(plan.price == "Free" ? "Free" : "\(plan.price)/mo").foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
            } header: {
                Text("The Asteria Subscription")
            } footer: {
                Text("During the beta, every Asteria Account is on Dedicated, free. Plans go on sale soon, and one plan covers every Asteria app.")
            }
        }
        .navigationTitle("The Asteria Subscription")
        .task { await usage.refresh() }
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
                AsteriaTokensBadge()
                NavigationLink("The Asteria Subscription") { AsteriaSubscriptionView() }
                Button("Sign Out") { account.signOut(); onSignOut() }
                Button("Delete Asteria Account…", role: .destructive) { deleting = true }
            } else {
                Button { sheet = .signIn } label: { Label("Sign In with Your Asteria Account", systemImage: "person.crop.circle") }
                Button { sheet = .signUp } label: { Label("Make an Asteria Account", systemImage: "person.crop.circle.badge.plus") }
            }
        } header: {
            Text("Asteria Account")
        } footer: {
            Text(account.isSignedIn
                 ? "Your Asteria Account works in every Asteria app, with the same tokens and chats with Asteria."
                 : "One account for every Asteria app: your Asteria tokens and your chats with Asteria follow you everywhere. It's also your Asteria Post account.")
        }
        .sheet(item: $sheet) { mode in AsteriaSignInView(mode: mode) }
        .sheet(isPresented: $deleting) { AsteriaDeleteAccountView { onSignOut() } }
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

    public init(mode: Mode = .signIn) { _mode = State(initialValue: mode) }

    public var body: some View {
        NavigationStack {
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
                        Text("Your username, like maya. The same one you use in Asteria and Post.")
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
        #if os(macOS)
        .frame(minWidth: 400, minHeight: 420)
        #endif
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
                dismiss()
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
                    Text("This deletes your Asteria Account everywhere: your Asteria Post account and posts, your bots' usernames, your Asteria tokens, and your chats with Asteria in every app. It can't be undone.")
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
