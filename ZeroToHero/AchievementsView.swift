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
            Image(systemName: earned ? badge.symbol : "lock.fill")
                .symbol()
                .font(.system(size: 26))
                .foregroundStyle(earned ? Palette.gold : Color.secondary)
                .frame(width: 58, height: 58)
                .background((earned ? Palette.gold : Color.secondary).opacity(0.12), in: .circle)
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
                Image(systemName: earned ? badge.symbol : "lock.fill")
                    .symbol()
                    .font(.system(size: 54))
                    .foregroundStyle(earned ? Palette.gold : Color.secondary)
                    .frame(width: 108, height: 108)
                    .background((earned ? Palette.gold : Color.secondary).opacity(0.12), in: .circle)
                Text(badge.title).font(.reading(.title, weight: .bold))
                Text(badge.detail).font(.reading(.body)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Text(badge.tier.name).font(.reading(.caption, weight: .semibold))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Palette.gold.opacity(0.15), in: .capsule)
                if earned {
                    ShareLink(item: shareImage(), preview: SharePreview("\(badge.title) — Swift: Zero to Hero", image: shareImage())) {
                        Label("Share this milestone", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.glassProminent)
                    .padding(.top, 6)
                }
                Text(earned ? "Earned \(dateText)" : "Keep going. It is closer than it looks.")
                    .font(.reading(.footnote)).foregroundStyle(.tertiary)
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
        model.store.badges.contains(badge.id) ? "on your course journey" : ""
    }

    private func shareImage() -> ShareImage {
        ShareCard(badge: badge, streak: model.store.streak, lessons: model.doneCount,
                  total: model.course.lessons.count, name: badge.title).render()
    }
}

/// A 4:5 card, 1080 by 1350, that reads well in Messages and on social.
struct ShareCard: View {
    let badge: Achievement
    let streak: Int
    let lessons: Int
    let total: Int
    let name: String

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
        renderer.scale = 2
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
