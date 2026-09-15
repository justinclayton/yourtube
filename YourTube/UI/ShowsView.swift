import SwiftUI
import SwiftData

/// The library view of show-like content: Continue Watching, Up Next, and
/// Your Shows, top to bottom.
///
/// Up Next is the user's earmark list (see `UpNextQueue`). It's never filled
/// in by the app and the order is the user's own, so the section offers no
/// "play all" and no sorting: just the cards, and an Edit sheet for moving
/// or removing them by hand.
///
/// Built on a ScrollView rather than a List on purpose: List keeps a
/// selected-row state for its links, and when a section reflows (a grid
/// row becoming a single card after a removal) it re-applied that state to
/// whatever row took the old one's place and pushed it unasked.
struct ShowsView: View {
    @Query(
        filter: #Predicate<Video> { $0.savedForLaterAt != nil },
        sort: [SortDescriptor(\Video.upNextOrder), SortDescriptor(\Video.savedForLaterAt)]
    )
    private var upNext: [Video]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 28) {
                    ContinueWatchingSection()
                    UpNextSection(videos: upNext)
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

/// Adaptive: one entry is a full-width card, two or more a two-column grid,
/// so nothing hides off-screen and a long list doesn't wall off the shows
/// beneath it.
private struct UpNextSection: View {
    @Environment(AppServices.self) private var services
    @Query private var subscriptions: [Subscription]
    @State private var isEditing = false
    let videos: [Video]

    private var avatars: [String: String] {
        Dictionary(subscriptions.compactMap { sub in sub.thumbnailURL.map { (sub.channelId, $0) } },
                   uniquingKeysWith: { first, _ in first })
    }

    var body: some View {
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
            if videos.isEmpty {
                emptyHint
            } else if videos.count == 1, let video = videos.first {
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

    private func card(_ video: Video, size: EpisodeCard.Size) -> some View {
        NavigationLink(value: video) {
            EpisodeCard(video: video, avatarURL: avatars[video.channelId], size: size)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Remove from Up Next", systemImage: "bookmark.slash", role: .destructive) {
                remove(video)
            }
        }
    }

    private var emptyHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Nothing earmarked")
                .font(.subheadline.weight(.semibold))
            Text("Up Next is yours to build. Earmark a video with the bookmark button in the player, and it waits here until you've watched it.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func remove(_ video: Video) {
        try? services.upNext.remove(video)
    }
}

/// Plain rows with drag handles, since a grid can't be reordered by hand.
private struct UpNextEditSheet: View {
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @Query(
        filter: #Predicate<Video> { $0.savedForLaterAt != nil },
        sort: [SortDescriptor(\Video.upNextOrder), SortDescriptor(\Video.savedForLaterAt)]
    )
    private var upNext: [Video]

    var body: some View {
        NavigationStack {
            List {
                ForEach(upNext) { video in
                    VideoRow(video: video)
                }
                .onMove { source, destination in
                    try? services.upNext.move(fromOffsets: source, toOffset: destination)
                }
                .onDelete { offsets in
                    for video in offsets.map({ upNext[$0] }) {
                        try? services.upNext.remove(video)
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
