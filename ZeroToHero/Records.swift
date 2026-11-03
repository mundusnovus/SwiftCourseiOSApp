// What is saved: progress, code, ticks, streaks and badges, in SwiftData on the device and in the person's own private
// iCloud. One container for the whole process.
//
// CloudKit mirroring rules: every property has a default, no unique constraints, no non-optional relationships.
import Foundation
import SwiftData
import CoreData
import Observation
import ZeroToHeroKit

@Model
final class LessonRecord {
    var lessonID: String = ""
    var doneAt: Date?
    var code: String?
    /// Comma-separated ticked checklist indices. A string mirrors to CloudKit with no relationship to manage.
    var tickList: String = ""
    var lastOpened: Date?

    init(lessonID: String) { self.lessonID = lessonID }

    var ticks: Set<Int> {
        get { Set(tickList.split(separator: ",").compactMap { Int($0) }) }
        set { tickList = newValue.sorted().map(String.init).joined(separator: ",") }
    }

    /// Folds in a copy of the same lesson made on another device. Nothing finished is lost: the earliest finish wins,
    /// ticks are combined, and the code from the device that opened the lesson last is kept.
    func merge(_ other: LessonRecord) {
        if let theirs = other.doneAt { doneAt = min(doneAt ?? theirs, theirs) }
        ticks = ticks.union(other.ticks)
        let mineIsNewer = (lastOpened ?? .distantPast) >= (other.lastOpened ?? .distantPast)
        if code == nil || (!mineIsNewer && other.code != nil) { code = other.code }
        lastOpened = [lastOpened, other.lastOpened].compactMap { $0 }.max()
    }
}

@Model
final class AchievementRecord {
    var achievementID: String = ""
    var earnedAt: Date = Date.now
    init(achievementID: String) { self.achievementID = achievementID }
}

@Model
final class ProfileRecord {
    var id: String = "me"
    var streak: Int = 0
    var bestStreak: Int = 0
    var lastActive: Date?
    var started: Date = Date.now
    init() {}

    /// Two devices that started offline each made a profile. Keep the longest history and the most recent day.
    func merge(_ other: ProfileRecord) {
        if (other.lastActive ?? .distantPast) > (lastActive ?? .distantPast) {
            lastActive = other.lastActive
            streak = other.streak
        } else if other.lastActive == lastActive {
            streak = max(streak, other.streak)
        }
        bestStreak = max(bestStreak, other.bestStreak, streak)
        started = min(started, other.started)
    }
}

extension Course {
    /// The course shipped in the app, decoded once for the window, Siri and Spotlight.
    static let app: Course = (try? Course.load()) ?? .fallback
}

@Model
final class CustomLessonRecord {
    var title: String = ""
    var summary: String = ""
    var body: String = ""
    var createdAt: Date = Date.now
    init(title: String, summary: String, body: String) {
        self.title = title
        self.summary = summary
        self.body = body
    }
}

enum Records {
    static let schema = Schema([LessonRecord.self, AchievementRecord.self, ProfileRecord.self, CustomLessonRecord.self])
    static let cloudContainer = "iCloud.technology.asteria.zerotohero"

    static func container() -> (container: ModelContainer, inCloud: Bool) {
        guard cloudKitAllowed else { return (local(), false) }
        do {
            let config = ModelConfiguration(schema: schema, cloudKitDatabase: .private(cloudContainer))
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-initCloudKitSchema") {
                do {
                    try initializeCloudKitSchema(at: config.url)
                    #if DEBUG
                    print("ZTH CloudKit: schema initialized in Development")
                    #endif
                } catch {
                    #if DEBUG
                    print("ZTH CloudKit: schema initialization failed: \(error)")
                    #endif
                }
            }
            #endif
            let container = try ModelContainer(for: schema, configurations: config)
            #if DEBUG
            print("ZTH CloudKit: container opened in iCloud")
            #endif
            return (container, true)
        } catch {
            #if DEBUG
            print("ZTH CloudKit: container failed, staying local: \(error)")
            #endif
            return (local(), false)
        }
    }

    /// CloudKit without its entitlement traps on a background queue, and no do/catch can stop it. Simulator builds and
    /// unsigned Mac builds have no usable entitlement, so they stay local and Settings says so.
    static var cloudKitAllowed: Bool {
        #if targetEnvironment(simulator)
        return false
        #elseif os(macOS) && DEBUG
        // A signed Debug Mac run can opt in for the one-time CloudKit schema initialisation. Unsigned builds never do.
        return ProcessInfo.processInfo.arguments.contains("-allowCloudKit")
            && (Bundle.main.object(forInfoDictionaryKey: "AsteriaCloudKit") as? String) != "NO"
        #else
        return (Bundle.main.object(forInfoDictionaryKey: "AsteriaCloudKit") as? String) != "NO"
        #endif
    }

    static func local() -> ModelContainer {
        let config = ModelConfiguration(schema: schema, cloudKitDatabase: .none)
        do { return try ModelContainer(for: schema, configurations: config) }
        catch { fatalError("Progress could not be stored on this device: \(error.localizedDescription)") }
    }

    static func inMemory() -> ModelContainer {
        let config = ModelConfiguration("Memory", schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        do { return try ModelContainer(for: schema, configurations: config) }
        catch { fatalError("An in-memory store could not be made: \(error.localizedDescription)") }
    }

    #if DEBUG
    static func initializeCloudKitSchema(at url: URL) throws {
        try autoreleasepool {
            let description = NSPersistentStoreDescription(url: url)
            description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(containerIdentifier: cloudContainer)
            description.shouldAddStoreAsynchronously = false
            guard let model = NSManagedObjectModel.makeManagedObjectModel(for: [LessonRecord.self, AchievementRecord.self,
                                                                               ProfileRecord.self, CustomLessonRecord.self]) else { return }
            let container = NSPersistentCloudKitContainer(name: "ZeroToHero", managedObjectModel: model)
            container.persistentStoreDescriptions = [description]
            var failure: Error?
            container.loadPersistentStores { _, error in failure = error }
            if let failure { throw failure }
            try container.initializeCloudKitSchema()
            if let store = container.persistentStoreCoordinator.persistentStores.first {
                try container.persistentStoreCoordinator.remove(store)
            }
        }
    }
    #endif
}

/// The one place that writes progress. Screens, Siri and the intents all come through here.
@Observable
@MainActor
final class LearnerStore {
    static let shared = LearnerStore()

    let container: ModelContainer
    let inCloud: Bool
    private let context: ModelContext
    private var records: [String: LessonRecord] = [:]
    private var profile: ProfileRecord

    private(set) var badges: Set<String> = []
    private var earnedAt: [String: Date] = [:]
    private(set) var custom: [CustomLessonRecord] = []
    /// Badges earned since the person last saw the celebration. The window shows them, then clears the list.
    private(set) var lastEarned: [Achievement] = []
    var errorMessage: String?
    /// Set when the person comes back after a week or more away; the "Back Again" badge reads it once.
    private var cameBack = false
    private var course: Course { .app }

    private init() {
        #if DEBUG
        if Demo.isOn {
            container = Records.inMemory()
            inCloud = false
            context = container.mainContext
            profile = ProfileRecord()
            context.insert(profile)
            load()
            if Demo.arguments.contains("-seedprogress") { seedDemoProgress() }
            return
        }
        #endif
        let made = Records.container()
        container = made.container
        inCloud = made.inCloud
        context = container.mainContext
        if let existing = try? context.fetch(FetchDescriptor<ProfileRecord>()).first {
            profile = existing
        } else {
            profile = ProfileRecord()
            context.insert(profile)
        }
        load()
        migrateLegacyProgressIfNeeded()
        if inCloud { watchRemoteChanges() }
    }

    #if DEBUG
    /// A few finished lessons and badges so screenshots and the review recording show the product at its best.
    private func seedDemoProgress() {
        for lesson in course.lessons.prefix(7) {
            let record = record(lesson.id)
            record.doneAt = .now.addingTimeInterval(-Double.random(in: 0...86400))
        }
        profile.streak = 4
        profile.bestStreak = 6
        profile.lastActive = Calendar.current.startOfDay(for: .now)
        for id in ["first-step", "hello-world", "first-pass", "five-lessons", "streak-3", "chapter-one"] {
            if !badges.contains(id) {
                context.insert(AchievementRecord(achievementID: id))
                badges.insert(id)
            }
        }
        save()
    }
    #endif

    /// Reads everything into memory. Two devices that worked offline can each have made a record for the same lesson,
    /// badge or profile; CloudKit keeps both, so copies are merged here and the extras deleted.
    private func load() {
        var merged = false

        var byLesson: [String: LessonRecord] = [:]
        for record in (try? context.fetch(FetchDescriptor<LessonRecord>())) ?? [] {
            guard let keep = byLesson[record.lessonID] else { byLesson[record.lessonID] = record; continue }
            keep.merge(record)
            context.delete(record)
            merged = true
        }
        records = byLesson

        var firstEarned: [String: AchievementRecord] = [:]
        for badge in (try? context.fetch(FetchDescriptor<AchievementRecord>())) ?? [] {
            guard let keep = firstEarned[badge.achievementID] else { firstEarned[badge.achievementID] = badge; continue }
            keep.earnedAt = min(keep.earnedAt, badge.earnedAt)
            context.delete(badge)
            merged = true
        }
        badges = Set(firstEarned.keys)
        earnedAt = firstEarned.mapValues(\.earnedAt)

        let profiles = (try? context.fetch(FetchDescriptor<ProfileRecord>())) ?? []
        if let keep = profiles.first(where: { $0 === profile }) ?? profiles.first {
            for other in profiles where other !== keep {
                keep.merge(other)
                context.delete(other)
                merged = true
            }
            profile = keep
        }

        custom = (try? context.fetch(FetchDescriptor<CustomLessonRecord>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))) ?? []
        if merged { save() }
    }

    /// CloudKit imports changes from the person's other devices in the background. Reload when it does, so the
    /// sidebar, badges and streak follow without a relaunch, and so a lesson is never given a second record.
    private func watchRemoteChanges() {
        Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .NSPersistentStoreRemoteChange) {
                try? await Task.sleep(for: .milliseconds(300))
                self?.refresh()
            }
        }
    }

    /// Re-reads the store. Called after an iCloud import and when the app comes to the front.
    func refresh() {
        load()
    }

    // MARK: Reading

    func record(_ id: Lesson.ID) -> LessonRecord {
        if let record = records[id] { return record }
        let record = LessonRecord(lessonID: id)
        context.insert(record)
        records[id] = record
        return record
    }

    func isDone(_ id: Lesson.ID) -> Bool { records[id]?.doneAt != nil }
    func code(for lesson: Lesson) -> String { records[lesson.id]?.code ?? lesson.seed ?? "" }
    func ticks(for id: Lesson.ID) -> Set<Int> { records[id]?.ticks ?? [] }
    func earnedDate(_ badge: String) -> Date? { earnedAt[badge] }

    /// When each finished lesson was finished, for the study plan.
    var doneDates: [Lesson.ID: Date] {
        records.reduce(into: [:]) { out, item in if let date = item.value.doneAt { out[item.key] = date } }
    }

    /// The lesson opened most recently on any of the person's devices, so Continue on the Mac picks up where the
    /// iPhone left off. Falls back to this device's own memory before anything has synced.
    var lastLesson: Lesson.ID? {
        records.values.filter { $0.lastOpened != nil }.max { ($0.lastOpened ?? .distantPast) < ($1.lastOpened ?? .distantPast) }?.lessonID
            ?? UserDefaults.standard.string(forKey: "lastLesson")
    }

    /// The streak as it stands today: a streak whose last day was before yesterday is already broken.
    var streak: Int {
        guard let last = profile.lastActive else { return 0 }
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: last), to: calendar.startOfDay(for: .now)).day ?? 0
        return days <= 1 ? profile.streak : 0
    }
    var bestStreak: Int { profile.bestStreak }

    func count(in lessons: [Lesson]) -> Int { lessons.filter { isDone($0.id) }.count }

    // MARK: Writing

    func open(_ id: Lesson.ID) {
        record(id).lastOpened = .now
        UserDefaults.standard.set(id, forKey: "lastLesson")
        touchStreak()
        save()
        if cameBack { evaluateBadges() }
    }

    func complete(_ id: Lesson.ID) {
        let record = record(id)
        if record.doneAt == nil { record.doneAt = .now }
        touchStreak()
        save()
        evaluateBadges()
    }

    func setCode(_ code: String, for id: Lesson.ID) {
        guard records[id]?.code != code else { return }
        record(id).code = code
        saveSoon()
    }

    func resetCode(for id: Lesson.ID) {
        record(id).code = nil
        save()
    }

    func toggle(tick: Int, for id: Lesson.ID) {
        var ticks = record(id).ticks
        if ticks.contains(tick) { ticks.remove(tick) } else { ticks.insert(tick) }
        record(id).ticks = ticks
        if !isDone(id) && ticks.count == 1 { touchStreak() }
        save()
    }

    /// Forgets lessons, code, ticks, streaks and badges. Lessons the person made with Apple Intelligence are theirs and
    /// stay; they can delete those one by one.
    func resetAll() {
        for record in records.values { context.delete(record) }
        for badge in (try? context.fetch(FetchDescriptor<AchievementRecord>())) ?? [] { context.delete(badge) }
        records = [:]
        badges = []
        earnedAt = [:]
        lastEarned = []
        profile.streak = 0
        profile.bestStreak = 0
        profile.lastActive = nil
        profile.started = .now
        UserDefaults.standard.removeObject(forKey: "lastLesson")
        save()
    }

    // MARK: Streak

    private func touchStreak() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        defer { saveSoon() }
        guard let last = profile.lastActive else {
            profile.lastActive = today
            profile.streak = 1
            profile.bestStreak = max(profile.bestStreak, 1)
            return
        }
        let lastDay = calendar.startOfDay(for: last)
        if lastDay == today { return }
        let gap = calendar.dateComponents([.day], from: lastDay, to: today).day ?? 0
        profile.streak = gap == 1 ? profile.streak + 1 : 1
        // Read before lastActive moves to today, or the gap is lost.
        if gap >= 7 { cameBack = true }
        profile.lastActive = today
        profile.bestStreak = max(profile.bestStreak, profile.streak)
    }

    // MARK: Badges

    func snapshot() -> ProgressSnapshot {
        var snapshot = ProgressSnapshot()
        snapshot.done = Set(records.values.filter { $0.doneAt != nil }.map(\.lessonID))
        snapshot.totalLessons = course.lessons.count
        snapshot.streak = profile.streak
        snapshot.hourOfDay = Calendar.current.component(.hour, from: .now)
        snapshot.daysSinceStart = Calendar.current.dateComponents([.day], from: profile.started, to: .now).day ?? 0
        snapshot.exercisesPassed = course.lessons.filter { $0.hasCode && snapshot.done.contains($0.id) }.count
        snapshot.quizzesPassed = course.lessons.filter { !$0.questions.isEmpty && snapshot.done.contains($0.id) }.count
        snapshot.labsDone = course.lessons.filter { $0.type == .lab && snapshot.done.contains($0.id) }.count

        var completedChapters: Set<String> = []
        for chapter in course.chapters where !chapter.lessons.isEmpty && chapter.lessons.allSatisfy({ snapshot.done.contains($0.id) }) {
            completedChapters.insert(chapter.title)
        }
        snapshot.chaptersDone = completedChapters.count
        snapshot.cameBackAfterBreak = cameBack
        snapshot.completedChapters = completedChapters
        return snapshot
    }

    func evaluateBadges() {
        let snapshot = snapshot()
        cameBack = false
        let earned = Achievements.earned(snapshot, course: course, completedChapters: snapshot.completedChapters)
        let new = earned.subtracting(badges)
        guard !new.isEmpty else { return }
        // Show them in the order the list defines, so the celebration reads bronze before silver.
        for badge in Achievements.all where new.contains(badge.id) {
            let record = AchievementRecord(achievementID: badge.id)
            context.insert(record)
            earnedAt[badge.id] = record.earnedAt
            lastEarned.append(badge)
        }
        badges.formUnion(new)
        save()
    }

    func clearNewBadges() { lastEarned = [] }

    // MARK: Extra lessons

    func addCustomLesson(title: String, summary: String, body: String) {
        context.insert(CustomLessonRecord(title: title, summary: summary, body: body))
        save()
        load()
    }

    func delete(_ lesson: CustomLessonRecord) {
        context.delete(lesson)
        save()
        load()
    }

    // MARK: Saving

    private func save() {
        do { try context.save() } catch { errorMessage = "Progress couldn't be saved: \(error.localizedDescription)" }
    }

    private var pending: Task<Void, Never>?
    private func saveSoon() {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            save()
        }
    }

    // MARK: Importing 1.0

    private func migrateLegacyProgressIfNeeded() {
        guard records.isEmpty else { return }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let file = support.appending(path: "Swift Zero to Hero/progress.json")
        guard let data = try? Data(contentsOf: file) else { return }
        struct Old: Decodable {
            var done: [String: Date] = [:]
            var code: [String: String] = [:]
            var ticks: [String: Set<Int>] = [:]
            var last: String?
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let old = try? decoder.decode(Old.self, from: data) else { return }
        for (id, date) in old.done {
            let record = record(id)
            record.doneAt = date
        }
        for (id, code) in old.code { record(id).code = code }
        for (id, ticks) in old.ticks { record(id).ticks = ticks }
        if let last = old.last { UserDefaults.standard.set(last, forKey: "lastLesson") }
        save()
        load()
    }
}

