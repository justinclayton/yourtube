import SwiftUI
import SwiftData

/// Your Shows: the library grid at the foot of the Shows tab.
///
/// Three columns of square channel avatars with the show's name set beneath in
/// full, never truncated, and an unwatched count in the corner. A poster
/// carries only the avatar and the name — no caption, no duration, no date —
/// so a show can't be mistaken for the episode cards above it, which are
/// wider, two to a row, and carry all of that.
///
/// The chips above the grid are the feed's chips, Priority included, and a
/// show appears under every category its channel carries. Priority shows are
/// pinned to the front of whatever the chips leave, so the tag means the same
/// thing here as it does on the feed.
struct YourShowsSection: View {
    @AppStorage(SettingsKeys.showsCategory) private var showsCategory = ""

    @Query(sort: \Show.title) private var records: [Show]
    @Query private var subscriptions: [Subscription]
    @Query private var rules: [ChannelRule]
    @Query(sort: [SortDescriptor(\VideoCollection.sortOrder), SortDescriptor(\VideoCollection.name)])
    private var categories: [VideoCollection]
    /// Every non-Short video, counted per show here rather than with a fetch
    /// per poster; Shorts are never episodes, so they never reach a badge.
    @Query(filter: #Predicate<Video> { !$0.isLikelyShort }) private var episodes: [Video]

    /// The catalogue, tombstones for "not a show" excluded.
    private var shows: [Show] { records.filter(\.isActive) }

    private var chipNames: [String] {
        categories.map(\.name) + [CategoryManager.uncategorizedName]
    }

    /// Falls back to "All" when the remembered category has since been
    /// deleted, so a stale selection never greets you with an empty grid.
    private var selectedCategory: Binding<String> {
        Binding(
            get: { chipNames.contains(showsCategory) ? showsCategory : "" },
            set: { showsCategory = $0 }
        )
    }

    private var ruleByChannel: [String: ChannelRule] {
        Dictionary(rules.map { ($0.channelId, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private var avatars: [String: String] {
        Dictionary(subscriptions.compactMap { sub in sub.thumbnailURL.map { (sub.channelId, $0) } },
                   uniquingKeysWith: { first, _ in first })
    }

    /// The chips filter; Priority sorts what's left to the front.
    private var visibleShows: [Show] {
        let selected = selectedCategory.wrappedValue
        let rules = ruleByChannel
        let filtered = shows.filter { show in
            guard !selected.isEmpty else { return true }
            let rule = rules[show.channelId]
            if selected == CategoryManager.uncategorizedName {
                return rule?.topicCollections.isEmpty ?? true
            }
            return rule?.collections.contains { $0.name == selected } ?? false
        }
        return filtered.enumerated()
            .sorted { a, b in
                let (pa, pb) = (rules[a.element.channelId]?.isPriority ?? false,
                                rules[b.element.channelId]?.isPriority ?? false)
                return pa == pb ? a.offset < b.offset : pa
            }
            .map(\.element)
    }

    private var unwatchedCounts: [String: Int] {
        ShowManager.unwatchedCounts(from: episodes, shows: shows)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your Shows")
                .font(.title3.weight(.semibold))
            if shows.isEmpty {
                emptyHint
            } else {
                // Full-bleed chips: the section is inset by the tab's padding,
                // and a chip row that stops short of the edge looks clipped.
                CategoryChips(names: chipNames, selected: selectedCategory)
                    .padding(.horizontal, -16)
                if visibleShows.isEmpty {
                    Text("No shows in \(selectedCategory.wrappedValue).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    grid
                }
            }
        }
    }

    private var grid: some View {
        let counts = unwatchedCounts
        return LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3),
            alignment: .leading,
            spacing: 18
        ) {
            ForEach(visibleShows) { show in
                // The show page is its own slice; this link is the hook it
                // replaces. See issue #23.
                //
                // Value-based (`navigationDestination(for: Show.self)` on
                // the tab's NavigationStack), not a plain
                // `NavigationLink { ShowPageView(...) }`: mixing that
                // view-builder style with the value-based pushes inside
                // ShowPageView (its episode rows push `Video`) made SwiftUI
                // double-push whenever an episode was tapped — see #46.
                NavigationLink(value: show) {
                    ShowPoster(
                        show: show,
                        avatarURL: avatars[show.channelId],
                        unwatched: counts[show.id] ?? 0
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
    }

    private var emptyHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No shows yet")
                .font(.subheadline.weight(.semibold))
            Text("Mark a channel as a show in Channels — swipe it, long-press it, or use its Categories sheet — and it appears here with a count of what you haven't watched.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// One poster: a square of channel art, an unwatched badge, and the show's
/// full name beneath. Deliberately the opposite of `EpisodeCard` — three to a
/// row, square, and carrying nothing but the name — so the eye never reads a
/// show as a video.
struct ShowPoster: View {
    let show: Show
    let avatarURL: String?
    let unwatched: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ChannelArt(url: avatarURL, title: show.title, seed: show.channelId)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if unwatched > 0 { badge }
                }
            Text(show.title)
                .font(.caption.weight(.medium))
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// No badge at all at zero: a show you're caught up on should look calm.
    private var badge: some View {
        Text("\(unwatched)")
            .font(.caption2.weight(.bold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.tint, in: Capsule())
            .padding(5)
    }
}
