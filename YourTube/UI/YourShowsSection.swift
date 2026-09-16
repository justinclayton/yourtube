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
    @Environment(AppServices.self) private var services
    @Environment(\.modelContext) private var modelContext
    @AppStorage(SettingsKeys.showsCategory) private var showsCategory = ""

    /// Everything the section draws, read out of the store in one pass.
    @State private var grid = ShowsGrid()

    /// Falls back to "All" when the remembered category has since been
    /// deleted, so a stale selection never greets you with an empty grid.
    private var selectedCategory: Binding<String> {
        Binding(
            get: { grid.chipNames.contains(showsCategory) ? showsCategory : "" },
            set: { showsCategory = $0 }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your Shows")
                .font(.title3.weight(.semibold))
            if !grid.isLoaded {
                // One frame, before the first read lands. Nothing rather than
                // the empty hint: "no shows yet" is a claim, and we don't know
                // yet.
                EmptyView()
            } else if !grid.hasShows {
                emptyHint
            } else {
                // Full-bleed chips: the section is inset by the tab's padding,
                // and a chip row that stops short of the edge looks clipped.
                CategoryChips(names: grid.chipNames, selected: selectedCategory)
                    .padding(.horizontal, -16)
                if grid.posters.isEmpty {
                    Text("No shows in \(selectedCategory.wrappedValue).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    posters
                }
            }
        }
        // The chip is the only thing besides the store itself the grid depends
        // on, so picking a category rebuilds it and nothing else does.
        .recomputingFromStore(id: showsCategory) {
            grid = (try? ShowsGrid.load(
                catalogue: services.shows,
                context: modelContext,
                category: showsCategory
            )) ?? grid
        }
    }

    private var posters: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3),
            alignment: .leading,
            spacing: 18
        ) {
            ForEach(grid.posters) { poster in
                // The show page is its own slice; this link is the hook it
                // replaces. See issue #23.
                //
                // Value-based (`navigationDestination(for: Show.self)` on
                // the tab's NavigationStack), not a plain
                // `NavigationLink { ShowPageView(...) }`: mixing that
                // view-builder style with the value-based pushes inside
                // ShowPageView (its episode rows push `Video`) made SwiftUI
                // double-push whenever an episode was tapped — see #46.
                NavigationLink(value: poster.show) {
                    ShowPoster(
                        show: poster.show,
                        avatarURL: poster.avatarURL,
                        unwatched: poster.unwatched
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

/// The grid's contents: the chips, the posters in the order they're drawn,
/// and each poster's badge — flattened out of the store in one pass.
///
/// Deliberately a snapshot rather than the four live queries this section used
/// to hold. A `@Query` is invalidated by any save anywhere, whether or not its
/// own results changed, so on a tab nobody was looking at they re-evaluated
/// this section's body every time a video was marked watched somewhere else —
/// and one of them fetched every non-Short video in the library to do it. See
/// issue #66. Nothing here is observed, so a hidden Shows tab is idle; a
/// visible one is rebuilt after each save by `recomputingFromStore(id:_:)`,
/// which is as live as a live query and costs nothing when the tab is away.
struct ShowsGrid {
    /// One poster, with its show's identity copied out so drawing the grid
    /// reads nothing from the store.
    struct Poster: Identifiable {
        let id: String
        /// The show itself, carried for the navigation value alone.
        let show: Show
        let avatarURL: String?
        let unwatched: Int
    }

    /// The feed's categories, Priority included, plus Uncategorized.
    var chipNames: [String] = [CategoryManager.uncategorizedName]
    /// Whether the catalogue holds anything at all, which is a different
    /// question from whether the chosen chip matches any of it.
    var hasShows = false
    /// The posters the chosen chip leaves, Priority first.
    var posters: [Poster] = []
    /// False until the first read lands, so the section doesn't claim there
    /// are no shows before it has looked.
    var isLoaded = false

    @MainActor
    static func load(
        catalogue: ShowManager,
        context: ModelContext,
        category: String
    ) throws -> ShowsGrid {
        var grid = ShowsGrid()
        grid.isLoaded = true
        let categories = try context.fetch(FetchDescriptor<VideoCollection>(sortBy: [
            SortDescriptor(\VideoCollection.sortOrder), SortDescriptor(\VideoCollection.name)
        ]))
        grid.chipNames = categories.map(\.name) + [CategoryManager.uncategorizedName]

        let shows = try catalogue.shows()
        grid.hasShows = !shows.isEmpty
        guard !shows.isEmpty else { return grid }

        let rules = try context.fetch(FetchDescriptor<ChannelRule>())
        let ruleByChannel = Dictionary(
            rules.map { ($0.channelId, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let subscriptions = try context.fetch(FetchDescriptor<Subscription>())
        let avatars = Dictionary(
            subscriptions.compactMap { sub in sub.thumbnailURL.map { (sub.channelId, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        let counts = try catalogue.unwatchedCounts(for: shows)

        // The chips filter; Priority sorts what's left to the front, so the
        // tag means the same thing here as it does on the feed.
        let selected = grid.chipNames.contains(category) ? category : ""
        let visible = shows.filter { show in
            guard !selected.isEmpty else { return true }
            let rule = ruleByChannel[show.channelId]
            if selected == CategoryManager.uncategorizedName {
                return rule?.topicCollections.isEmpty ?? true
            }
            return rule?.collections.contains { $0.name == selected } ?? false
        }
        grid.posters = visible.enumerated()
            .sorted { a, b in
                let (pa, pb) = (ruleByChannel[a.element.channelId]?.isPriority ?? false,
                                ruleByChannel[b.element.channelId]?.isPriority ?? false)
                return pa == pb ? a.offset < b.offset : pa
            }
            .map { _, show in
                Poster(
                    id: show.id,
                    show: show,
                    avatarURL: avatars[show.channelId],
                    unwatched: counts[show.id] ?? 0
                )
            }
        return grid
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
