// The window: the course in a sidebar, the lesson or the course home beside it. One layout for Mac, iPad and iPhone;
// on iPhone the split view collapses and opening a lesson moves to the detail column.
import SwiftUI
import ZeroToHeroKit

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var compactColumn: NavigationSplitViewColumn = .detail
    @AppStorage("accent") private var accentRaw = AccentChoice.sea.rawValue

    private var accent: Color { (AccentChoice(rawValue: accentRaw) ?? .sea).color }

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $model.columnVisibility, preferredCompactColumn: $compactColumn) {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 250, ideal: 300, max: 380)
        } detail: {
            Group {
                if let lesson = model.selectedLesson {
                    LessonView(lesson: lesson).id(lesson.id)
                } else {
                    HomeView()
                }
            }
            .toolbar { toolbar }
        }
        .tint(accent)
        .overlay(alignment: .bottom) { NoticeView() }
        .animation(.spring(duration: 0.35), value: model.notice)
        .sheet(isPresented: $model.showSettings) { SettingsView() }
        .sheet(isPresented: $model.showAchievements) { AchievementsView() }
        .sheet(isPresented: $model.showStudy) { StudySheet() }
        .onChange(of: model.selection) { _, _ in compactColumn = .detail }
        .onContinueUserActivity("technology.asteria.zerotohero.lesson") { activity in
            if let id = activity.userInfo?["lesson"] as? String, let lesson = model.course.lesson(id) {
                model.open(lesson)
            }
        }
        .task {
            AppRouter.open = { id in
                guard let id, let lesson = model.course.lesson(id) else { model.open(nil); return }
                model.open(lesson)
            }
            await model.findRunner()
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        #if os(iOS)
        ToolbarItem(placement: .topBarLeading) {
            Button("Lessons", systemImage: "list.bullet") {
                withAnimation { compactColumn = compactColumn == .detail ? .sidebar : .detail }
            }
            .accessibilityLabel("Lessons")
        }
        #endif
        ToolbarItemGroup(placement: .navigation) {
            Button("Previous lesson", systemImage: "chevron.left") { model.go(by: -1) }
                .disabled(model.selectedLesson.flatMap { model.course.neighbours(of: $0.id).previous } == nil)
                .accessibilityLabel("Previous lesson")
            Button("Next lesson", systemImage: "chevron.right") { model.go(by: 1) }
                .disabled(model.nextLesson == nil)
                .accessibilityLabel("Next lesson")
        }
        #if os(iOS)
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button("Make a lesson", systemImage: "apple.intelligence") { model.showStudy = true }
            Button("Achievements", systemImage: "trophy") { model.showAchievements = true }
            Button("Settings", systemImage: "gearshape") { model.showSettings = true }
        }
        #else
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Make a lesson", systemImage: "apple.intelligence") { model.showStudy = true }
            Button("Achievements", systemImage: "trophy") { model.showAchievements = true }
        }
        #endif
    }
}

struct NoticeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let notice = model.notice {
            Label(notice, systemImage: "checkmark.circle.fill")
                .font(.reading(.callout, weight: .semibold))
                .padding(.horizontal, 18).padding(.vertical, 10)
                .glassEffect(.regular, in: .capsule)
                .padding(.bottom, 24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .accessibilityAddTraits(.isStaticText)
        }
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @State private var expanded: Set<String> = []
    @State private var query = ""
    @AppStorage("accent") private var accentRaw = AccentChoice.sea.rawValue

    private var accent: Color { (AccentChoice(rawValue: accentRaw) ?? .sea).color }

    private var search: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            Section {
                header
                    .listRowInsets(EdgeInsets(top: 10, leading: 12, bottom: 8, trailing: 12))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .selectionDisabled()
            }
            Section {
                Button { model.open(nil) } label: {
                    HStack(spacing: 10) {
                        IconTile(symbol: "house.fill", tint: Palette.sea)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Course home").font(.reading(.body, weight: .semibold))
                            Text("\(model.doneCount) of \(model.course.lessons.count) lessons").font(.reading(.caption)).foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
            }

            ForEach(model.course.chapters) { chapter in
                let modules = chapter.modules.filter { search.isEmpty || !matching($0).isEmpty }
                if !modules.isEmpty {
                    Section {
                        ForEach(modules) { module in
                            DisclosureGroup(isExpanded: binding(for: module.id)) {
                                ForEach(matching(module)) { lesson in
                                    LessonRow(lesson: lesson).tag(lesson.id)
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    Text(module.title).lineLimit(2)
                                    Spacer()
                                    Text("\(model.store.count(in: module.lessons))/\(module.lessons.count)")
                                        .font(.reading(.caption2)).monospacedDigit().foregroundStyle(.secondary)
                                }
                            }
                        }
                    } header: {
                        Text(chapter.title)
                    }
                }
            }

            Section {
                footer
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .selectionDisabled()
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $query, placement: .automatic, prompt: "Find a lesson")
        #if os(iOS)
        .navigationTitle("Zero to Hero")
        #endif
        .onAppear { expandSelection() }
        .onChange(of: model.selection) { _, _ in expandSelection() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Wordmark(size: 20)
            HStack(spacing: 8) {
                ProgressView(value: model.progress).tint(accent)
                Text("\(Int(model.progress * 100))%")
                    .font(.reading(.caption, weight: .semibold)).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 4).padding(.vertical, 4)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Label("\(model.store.streak) day streak", systemImage: "flame.fill")
                .font(.reading(.caption, weight: .semibold))
                .foregroundStyle(model.store.streak > 0 ? Palette.emphasis : .secondary)
            Spacer()
            Button { model.showAchievements = true } label: {
                Label("\(model.store.badges.count)", systemImage: "trophy.fill")
                    .font(.reading(.caption, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Palette.emphasis)
            .accessibilityLabel("\(model.store.badges.count) achievements")
        }
        .padding(.horizontal, 4).padding(.vertical, 4)
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(get: { !search.isEmpty || expanded.contains(id) },
                set: { open in if open { expanded.insert(id) } else { expanded.remove(id) } })
    }

    private func matching(_ module: Module) -> [Lesson] {
        guard !search.isEmpty else { return module.lessons }
        if module.title.localizedStandardContains(search) { return module.lessons }
        return module.lessons.filter { $0.title.localizedStandardContains(search) }
    }

    private func expandSelection() {
        if let id = model.selection, let place = model.course.module(of: id) { expanded.insert(place.module.id) }
    }
}

struct LessonRow: View {
    @Environment(AppModel.self) private var model
    let lesson: Lesson

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: model.store.isDone(lesson.id) ? "checkmark.circle.fill" : lesson.type.symbol)
                .symbol()
                .foregroundStyle(model.store.isDone(lesson.id) ? Palette.sea : .secondary)
                .frame(width: 18)
            Text(lesson.title).font(.reading(.body)).lineLimit(2)
            Spacer(minLength: 4)
            if lesson.minutes >= 15 {
                Text("\(lesson.minutes)m").font(.reading(.caption2)).monospacedDigit().foregroundStyle(.tertiary)
            }
        }
        .accessibilityValue(model.store.isDone(lesson.id) ? "Done" : "")
    }
}

// MARK: - Home

struct HomeView: View {
    @Environment(AppModel.self) private var model
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var widthClass
    private var compact: Bool { widthClass == .compact }
    #else
    private var compact: Bool { false }
    #endif

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: compact ? 20 : 28) {
                hero
                if let next = model.nextLesson { continueCard(next) } else { finishedCard }
                todayCard
                badgesStrip
                chapters
                Text("Made by Asteria Technology. Open source under the Asteria License.")
                    .font(.reading(.footnote)).foregroundStyle(.tertiary).padding(.top, 8)
            }
            .padding(compact ? 20 : 36)
            .frame(maxWidth: 960, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(.background)
        .navigationTitle("")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 10) {
            Wordmark(size: 18)
                .padding(.bottom, 2)
            Text(model.course.versions.uppercased())
                .font(.reading(.caption, weight: .bold)).tracking(1.2)
                .foregroundStyle(Palette.emphasis)
            Text("Swift: Zero to Hero")
                .font(.reading(.largeTitle, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)
            Text(model.course.subtitle)
                .font(.reading(.title3)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 20) {
                ProgressRing(value: model.progress, size: compact ? 54 : 64)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(model.doneCount) of \(model.course.lessons.count) lessons")
                        .font(.reading(.headline, weight: .semibold))
                    Text("\(model.course.chapters.count) chapters · \(model.course.exerciseCount) exercises · \(model.course.quizCount) quizzes")
                        .font(.reading(.callout)).foregroundStyle(.secondary)
                }
            }
            .padding(.top, 6)
        }
    }

    private func continueCard(_ lesson: Lesson) -> some View {
        GlassCard(tint: Palette.sea) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.doneCount == 0 ? "START HERE" : "CONTINUE")
                        .font(.reading(.caption2, weight: .bold)).tracking(1)
                        .foregroundStyle(Palette.emphasis)
                    Text(lesson.title).font(.reading(.title3, weight: .semibold)).lineLimit(2)
                    if let place = model.course.module(of: lesson.id) {
                        Text("\(place.chapter.title) › \(place.module.title)")
                            .font(.reading(.caption)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Button { model.open(lesson) } label: {
                    Label(model.doneCount == 0 ? "Start" : "Resume", systemImage: "arrow.right")
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
            }
        }
    }

    private var finishedCard: some View {
        GlassCard(tint: Palette.gold) {
            HStack(spacing: 14) {
                Image(systemName: "trophy.fill").symbol().font(.largeTitle).foregroundStyle(Palette.gold)
                VStack(alignment: .leading, spacing: 4) {
                    Text("You finished the course.").font(.reading(.title3, weight: .semibold))
                    Text("Every lesson, every exercise, every quiz. That is Zero to Hero.")
                        .font(.reading(.callout)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var todayCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("TODAY").font(.reading(.caption2, weight: .bold)).tracking(1).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                if let next = model.nextLesson {
                    todayRow(icon: "play.fill", tint: Palette.sea, title: "Next lesson", detail: next.title) { model.open(next) }
                }
                todayRow(icon: "trophy.fill", tint: Palette.gold, title: "Milestones", detail: "\(model.store.badges.count) earned") {
                    model.showAchievements = true
                }
                todayRow(icon: "flame.fill", tint: Palette.alert, title: "Streak", detail: "\(model.store.streak) days") {
                    model.showAchievements = true
                }
            }
        }
    }

    private func todayRow(icon: String, tint: Color, title: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: icon).symbol().font(.title3).foregroundStyle(tint)
                Text(title).font(.reading(.caption, weight: .semibold)).foregroundStyle(.secondary)
                Text(detail).font(.reading(.callout, weight: .medium)).lineLimit(2).multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(.background.opacity(0.7), in: .rect(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.quaternary))
        }
        .buttonStyle(.plain)
    }

    private var badgesStrip: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("MILESTONES").font(.reading(.caption2, weight: .bold)).tracking(1).foregroundStyle(.secondary)
                Spacer()
                Button("See all") { model.showAchievements = true }.font(.reading(.caption, weight: .semibold))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Achievements.all.prefix(12)) { badge in
                        let earned = model.store.badges.contains(badge.id)
                        VStack(spacing: 6) {
                            Image(systemName: badge.symbol).symbol().font(.title3)
                                .foregroundStyle(earned ? Palette.gold : Color.secondary)
                                .frame(width: 44, height: 44)
                                .background((earned ? Palette.gold : Color.secondary).opacity(0.12), in: .circle)
                            Text(badge.title).font(.reading(.caption2, weight: .medium)).lineLimit(1)
                                .foregroundStyle(earned ? Color.primary : Color.secondary)
                        }
                        .frame(width: 72)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(badge.title), \(earned ? "earned" : "not yet earned")")
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var chapters: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("THE COURSE").font(.reading(.caption2, weight: .bold)).tracking(1).foregroundStyle(.secondary)
            ForEach(Array(model.course.chapters.enumerated()), id: \.offset) { index, chapter in
                chapterRow(index, chapter)
                if index < model.course.chapters.count - 1 { Divider() }
            }
        }
        .padding(18)
        .background(.background.opacity(0.7), in: .rect(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.quaternary))
    }

    private func chapterRow(_ index: Int, _ chapter: Chapter) -> some View {
        let done = model.store.count(in: chapter.lessons)
        return HStack(alignment: .top, spacing: 14) {
            Text(String(format: "%02d", index + 1))
                .font(.reading(.title3, weight: .bold)).monospacedDigit()
                .foregroundStyle(Palette.emphasis).frame(width: 34, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(chapter.title).font(.reading(.headline, weight: .semibold))
                Text(chapter.summary).font(.reading(.callout)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Text("\(done)/\(chapter.lessons.count)")
                .font(.reading(.caption, weight: .medium)).monospacedDigit().foregroundStyle(.secondary)
        }
    }
}

struct ProgressRing: View {
    let value: Double
    var size: CGFloat = 64

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 7)
            Circle()
                .trim(from: 0, to: max(0.001, min(value, 1)))
                .stroke(Palette.sea, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int(value * 100))%")
                .font(.reading(.caption, weight: .bold)).monospacedDigit()
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Course progress")
        .accessibilityValue("\(Int(value * 100)) percent")
    }
}
