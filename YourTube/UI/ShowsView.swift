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

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 28) {
                    DormancyReviewSection()
                    ContinueWatchingSection()
                    UpNextSection()
                    YourShowsSection()
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
    }
}

/// Shows the automatic pass wants to drop because the channel's gone quiet,
/// but won't without asking first — see `ShowManager.applyAutomaticVerdicts`.
/// One banner per show, since more than one can go dormant independently and
/// each needs its own answer.
private struct DormancyReviewSection: View {
    @Query(filter: #Predicate<Show> { $0.pendingDormancyReview })
    private var pending: [Show]

    var body: some View {
        if !pending.isEmpty {
            VStack(spacing: 8) {
                ForEach(pending) { show in
                    DormancyReviewBanner(show: show)
                }
            }
        }
    }
}

/// "This channel's gone quiet — still a show?" Deliberately an inline banner
/// rather than a blocking alert, the way `ReauthBanner` in `FeedView` is: the
/// answer can wait, and it sits right above the show it's asking about.
private struct DormancyReviewBanner: View {
    @Environment(AppServices.self) private var services
    let show: Show

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "moon.zzz")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(show.title)
                    .font(.subheadline.weight(.semibold))
                Text(show.detectorReasons.first ?? "Hasn't posted in a while")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Remove") { resolve(keep: false) }
                .font(.subheadline)
            Button("Keep") { resolve(keep: true) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.secondary.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    /// Either answer resolves the review: `setIsShow` reaches `markAsShow` or
    /// `markAsNotAShow`, both of which clear `pendingDormancyReview` as part
    /// of recording the user's decision.
    private func resolve(keep: Bool) {
        try? services.shows.setIsShow(keep, channelId: show.channelId, channelTitle: show.title)
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
