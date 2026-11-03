// Milestones, and a share card for Messages and social. Nothing leaves the device unless the person shares it.
import SwiftUI
import ZeroToHeroKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct AchievementsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Achievement?
    @AppStorage("accent") private var accentRaw = AccentChoice.sea.rawValue

    private let columns = [GridItem(.adaptive(minimum: 132), spacing: 14)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    summary
                    ForEach([Achievement.Tier.bronze, .silver, .gold, .platinum], id: \.self) { tier in
                        let badges = Achievements.all.filter { $0.tier == tier }
                        VStack(alignment: .leading, spacing: 12) {
                            Text(tier.name.uppercased())
                                .font(.reading(.caption, weight: .bold)).tracking(1.2)
                                .foregroundStyle(tier == .platinum ? Palette.emphasis : .secondary)
                            LazyVGrid(columns: columns, spacing: 14) {
                                ForEach(badges) { badge in
                                    Button { selected = badge } label: {
                                        badgeTile(badge, earned: model.store.badges.contains(badge.id))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
            }
            .background(.background)
            .navigationTitle("Milestones")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .onAppear {
                #if DEBUG
                if Demo.arguments.contains("-share") { selected = Achievements.byID("first-step") }
                #endif
            }
            .sheet(item: $selected) { badge in
                BadgeDetail(badge: badge, earned: model.store.badges.contains(badge.id))
                    .presentationDetents([.medium, .large])
            }
        }
        .appTint()
    }

    private var summary: some View {
        GlassCard(tint: Palette.gold) {
            HStack(spacing: 18) {
                Image(systemName: "trophy.fill").symbol().font(.system(size: 38)).foregroundStyle(Palette.gold)
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(model.store.badges.count) of \(Achievements.all.count) milestones")
                        .font(.reading(.title3, weight: .semibold))
                    Text("\(model.store.streak) day streak · best \(model.store.bestStreak) · \(model.doneCount) lessons done")
                        .font(.reading(.callout)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func badgeTile(_ badge: Achievement, earned: Bool) -> some View {
        VStack(spacing: 8) {
            BadgeMedal(badge: badge, earned: earned)
            Text(badge.title)
                .font(.reading(.callout, weight: .semibold))
                .foregroundStyle(earned ? .primary : .secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            Text(earned ? "Earned" : "Locked")
                .font(.reading(.caption2)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(.background.opacity(0.7), in: .rect(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(earned ? Palette.gold.opacity(0.35) : Color.secondary.opacity(0.2)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(badge.title). \(badge.detail). \(earned ? "Earned" : "Not yet earned")")
    }
}

struct BadgeDetail: View {
    @Environment(AppModel.self) private var model
    let badge: Achievement
    let earned: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                BadgeMedal(badge: badge, earned: earned, size: 108)
                Text(badge.title).font(.reading(.title, weight: .bold))
                Text(badge.detail).font(.reading(.body)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Text(badge.tier.name).font(.reading(.caption, weight: .semibold))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Palette.gold.opacity(0.15), in: .capsule)
                if earned { ShareMilestoneButton(badge: badge).padding(.top, 6) }
                Text(dateText)
                    .font(.reading(.footnote)).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(24)
            .frame(maxWidth: .infinity)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .appTint()
        }
    }

    private var dateText: String {
        guard earned else { return "Keep going. It is closer than it looks." }
        guard let date = model.store.earnedDate(badge.id) else { return "Earned" }
        return "Earned on \(date.formatted(date: .long, time: .omitted))"
    }
}

struct BadgeMedal: View {
    let badge: Achievement
    let earned: Bool
    var size: CGFloat = 58

    var body: some View {
        Image(systemName: earned ? badge.symbol : "lock.fill")
            .symbol()
            .font(.system(size: size / 2))
            .foregroundStyle(earned ? Palette.gold : Color.secondary)
            .frame(width: size, height: size)
            .background((earned ? Palette.gold : Color.secondary).opacity(0.12), in: .circle)
            .accessibilityHidden(true)
    }
}

/// Shares the 1080 by 1350 card. The card is drawn once when the button appears, not on every redraw.
struct ShareMilestoneButton: View {
    @Environment(AppModel.self) private var model
    let badge: Achievement
    var compact = false
    @State private var image: ShareImage?

    var body: some View {
        Group {
            if let image {
                ShareLink(item: image, preview: SharePreview("\(badge.title) — Swift: Zero to Hero", image: image)) {
                    Label(compact ? "Share" : "Share this milestone", systemImage: "square.and.arrow.up")
                }
                .accessibilityLabel("Share \(badge.title)")
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .buttonStyle(.glassProminent)
        .task(id: badge.id) {
            image = ShareCard(badge: badge, streak: model.store.streak, lessons: model.doneCount,
                              total: model.course.lessons.count).render()
        }
    }
}

/// Shown the moment a milestone is earned, so sharing it is one tap away.
struct NewMilestonesSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        let badges = model.store.lastEarned
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    Text(badges.count == 1 ? "New milestone" : "\(badges.count) new milestones")
                        .font(.reading(.title3, weight: .bold))
                    if badges.count == 1, let badge = badges.first {
                        VStack(spacing: 10) {
                            BadgeMedal(badge: badge, earned: true, size: 96)
                                .scaleEffect(appeared || reduceMotion ? 1 : 0.6)
                                .opacity(appeared || reduceMotion ? 1 : 0)
                            Text(badge.title).font(.reading(.title2, weight: .bold))
                            Text(badge.detail).font(.reading(.body)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            ShareMilestoneButton(badge: badge)
                        }
                    } else {
                        ForEach(badges) { badge in
                            HStack(spacing: 14) {
                                BadgeMedal(badge: badge, earned: true, size: 52)
                                    .scaleEffect(appeared || reduceMotion ? 1 : 0.6)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(badge.title).font(.reading(.headline, weight: .semibold))
                                    Text(badge.detail).font(.reading(.callout)).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                ShareMilestoneButton(badge: badge, compact: true)
                            }
                            .accessibilityElement(children: .contain)
                        }
                    }
                }
                .padding(28)
                .frame(maxWidth: .infinity)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Keep going") { dismiss() } }
            }
            .onAppear {
                withAnimation(.spring(duration: 0.5, bounce: 0.4)) { appeared = true }
                AccessibilityNotification.Announcement("New milestone: " + badges.map(\.title).joined(separator: ", ")).post()
            }
            .appTint()
        }
        .presentationDetents(model.store.lastEarned.count > 2 ? [.large] : [.medium, .large])
    }
}

/// A 4:5 card, 1080 by 1350, that reads well in Messages and on social.
struct ShareCard: View {
    let badge: Achievement
    let streak: Int
    let lessons: Int
    let total: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Asteria").font(.asteria(44)).foregroundStyle(.white)
                Text("Zero to Hero").font(.system(size: 34, weight: .semibold)).foregroundStyle(.white.opacity(0.75))
            }
            Spacer()
            Image(systemName: badge.symbol)
                .renderingMode(.template)
                .font(.system(size: 150, weight: .semibold))
                .foregroundStyle(Palette.gold)
                .padding(.bottom, 30)
            Text(badge.tier.name.uppercased())
                .font(.system(size: 22, weight: .bold)).tracking(4)
                .foregroundStyle(Palette.gold)
                .padding(.bottom, 10)
            Text(badge.title)
                .font(.system(size: 64, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
            Text(badge.detail)
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(.white.opacity(0.8))
                .padding(.top, 10)
            Spacer()
            HStack(spacing: 28) {
                stat("\(streak)", "day streak")
                stat("\(lessons)/\(total)", "lessons")
                Spacer()
            }
            Text("Swift: Zero to Hero · iOS 27 · macOS 27")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
                .padding(.top, 24)
        }
        .padding(64)
        .frame(width: 1080, height: 1350, alignment: .leading)
        .background(
            LinearGradient(colors: [Palette.seaDeep, Palette.night], startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .overlay(alignment: .topTrailing) {
            Circle().fill(Palette.sea.opacity(0.35)).frame(width: 420).blur(radius: 80).offset(x: 120, y: -120)
        }
        .clipShape(.rect(cornerRadius: 0))
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 40, weight: .bold)).foregroundStyle(.white)
            Text(label).font(.system(size: 20)).foregroundStyle(.white.opacity(0.6))
        }
    }

    @MainActor func render() -> ShareImage {
        let renderer = ImageRenderer(content: self)
        // The card is already 1080 by 1350 points. Scale 1 keeps the exported PNG at that exact size.
        renderer.scale = 1
        #if os(macOS)
        if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff), let data = rep.representation(using: .png, properties: [:]) {
            return ShareImage(data: data)
        }
        #else
        if let image = renderer.uiImage, let data = image.pngData() { return ShareImage(data: data) }
        #endif
        return ShareImage(data: Data())
    }
}

struct ShareImage: Transferable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { $0.data }
    }
}
