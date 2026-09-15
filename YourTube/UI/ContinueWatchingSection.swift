import SwiftUI
import SwiftData

/// The top section of the Shows tab: videos you started and haven't finished,
/// most recently played first.
///
/// It's filled by the app, not by hand (that's Up Next's job), and it empties
/// itself: a video passing 90% is marked watched and drops out. When there's
/// nothing in progress the section renders nothing at all, so a tab you've
/// never watched from doesn't carry an empty heading.
///
/// Cards are the same `EpisodeCard` shape Up Next uses, and adapt the same
/// way — one item full width, two or more a two-column grid — so the tab
/// reads as one calm column.
struct ContinueWatchingSection: View {
    @Query(
        filter: #Predicate<Video> { $0.resumePositionSeconds != nil && !$0.isWatched },
        sort: [SortDescriptor(\Video.lastPlayedAt, order: .reverse)]
    )
    private var videos: [Video]
    @Query private var subscriptions: [Subscription]

    private var avatars: [String: String] {
        Dictionary(subscriptions.compactMap { sub in sub.thumbnailURL.map { (sub.channelId, $0) } },
                   uniquingKeysWith: { first, _ in first })
    }

    var body: some View {
        if !videos.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Continue Watching")
                    .font(.title3.weight(.semibold))
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
        }
    }

    private func card(_ video: Video, size: EpisodeCard.Size) -> some View {
        NavigationLink(value: video) {
            EpisodeCard(
                video: video,
                avatarURL: avatars[video.channelId],
                size: size,
                progress: video.playbackFraction
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
