import SwiftUI
import SwiftData

/// The library view of show-like content: Continue Watching, Up Next, and
/// Your Shows, top to bottom.
///
/// Up Next is the user's earmark list (see `WatchState`). It's never filled
/// in by the app and the order is the user's own, so the section offers no
/// "play all" and no sorting: just the cards, and an Edit sheet for moving
/// or removing them by hand.
///
/// Built on a ScrollView rather than a List on purpose: List keeps a
/// selected-row state for its links, and when a section reflows (a grid
/// row becoming a single card after a removal) it re-applied that state to
/// whatever row took the old one's place and pushed it unasked.
struct ShowsView: View {
    // No `@Query` of its own on purpose: a query is invalidated by any save
    // anywhere, and this view is the parent of the whole tab, so one here
    // re-created every section below it — including the sections on a tab
    // nobody was looking at. Each section owns the query it draws from
    // instead. See issue #66.

    @Environment(AppServices.self) private var services
    /// Per store, like every `@AppStorage` here: each channel's library is
    /// offered its suggestions once.
    @AppStorage(SettingsKeys.suggestionsOffered) private var suggestionsOffered = false
    /// How many channels the detector is suggesting, recounted after each
    /// save. A count rather than a query, for the reason above.
    @State private var suggestionCount = 0
    @State private var isPicking = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 28) {
                    ContinueWatchingSection()
                    UpNextSection()
                    YourShowsSection(suggestionCount: suggestionCount) { isPicking = true }
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
            .navigationTitle("Shows")
            .navigationDestination(for: Video.self) { video in
                PlayerView(video: video)
            }
            // Value-based, like the Video destination above: a show page
            // reached through a plain `NavigationLink { ShowPageView(...) }`
            // instead would mix navigation styles in this stack, and mixing
            // them is what caused issue #46 — tapping an episode inside a
            // show page double-pushed (the video, then a duplicate of the
            // show page on top of it), so the tap looked like it did nothing
            // and Back landed on the video instead of the show.
            .navigationDestination(for: Show.self) { show in
                ShowPageView(show: show)
            }
        }
        // Here rather than in Your Shows: that section sits at the foot of a
        // lazy stack and may not exist yet when the first suggestions land.
        .recomputingFromStore(id: 0) {
            suggestionCount = (try? services.suggestions.pendingCount()) ?? 0
            offerSuggestionsOnce()
        }
        .sheet(isPresented: $isPicking) {
            SuggestedShowsSheet()
        }
    }

    /// The Pick grid is put in front of you once, the first time there's
    /// anything in it: right after the upgrade hands the old grid back, or
    /// after a fresh install's first detector pass. Closing it counts as
    /// offered. After that it's only the footer row in Your Shows.
    private func offerSuggestionsOnce() {
        guard !suggestionsOffered, suggestionCount > 0, !isPicking else { return }
        suggestionsOffered = true
        isPicking = true
    }
}

/// Adaptive: one entry is a full-width card, two or more a two-column grid,
/// so nothing hides off-screen and a long list doesn't wall off the shows
/// beneath it.
private struct UpNextSection: View {
    @Environment(AppServices.self) private var services
    @Query(filter: WatchState.upNextPredicate, sort: WatchState.upNextSortDescriptors)
    private var videos: [Video]
    @Query private var subscriptions: [Subscription]
    @Query private var shows: [Show]
    @State private var isEditing = false

    private var avatars: [String: String] {
        Dictionary(subscriptions.compactMap { sub in sub.thumbnailURL.map { (sub.channelId, $0) } },
                   uniquingKeysWith: { first, _ in first })
    }

    var body: some View {
        if !videos.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Up Next")
                        .font(.title3.weight(.semibold))
                    Spacer()
                    if videos.count > 1 {
                        Button("Edit") { isEditing = true }
                            .font(.subheadline)
                    }
                }
                if videos.count == 1, let video = videos.first {
                    card(video, size: .large)
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2),
                              alignment: .leading, spacing: 16) {
                        ForEach(videos) { video in
                            card(video, size: .medium)
                                .frame(maxHeight: .infinity, alignment: .top)
                        }
                    }
                }
            }
            .sheet(isPresented: $isEditing) {
                UpNextEditSheet()
            }
        }
    }

    private func card(_ video: Video, size: EpisodeCard.Size) -> some View {
        NavigationLink(value: video) {
            EpisodeCard(
                video: video,
                avatarURL: avatars[video.channelId],
                size: size,
                show: ShowManager.show(containing: video, in: shows)
            )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Remove from Up Next", systemImage: "bookmark.slash", role: .destructive) {
                remove(video)
            }
        }
    }

    private func remove(_ video: Video) {
        try? services.watchState.remove(video)
    }
}

/// Plain rows with drag handles, since a grid can't be reordered by hand.
private struct UpNextEditSheet: View {
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @Query(filter: WatchState.upNextPredicate, sort: WatchState.upNextSortDescriptors)
    private var upNext: [Video]

    var body: some View {
        NavigationStack {
            List {
                ForEach(upNext) { video in
                    VideoRow(video: video)
                }
                .onMove { source, destination in
                    try? services.watchState.move(upNext, fromOffsets: source, toOffset: destination)
                }
                .onDelete { offsets in
                    for video in offsets.map({ upNext[$0] }) {
                        try? services.watchState.remove(video)
                    }
                }
            }
            .listStyle(.plain)
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Edit Up Next")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
