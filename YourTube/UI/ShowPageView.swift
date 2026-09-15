import SwiftUI
import SwiftData

/// Placeholder show page: the destination behind a poster in Your Shows.
///
/// It shows what the catalogue already knows — the art, the source, how many
/// episodes there are and how many are unwatched — and says plainly that the
/// rest is coming. The real page (cadence, Play next, Mark all watched, the
/// episode list with its segment toggle and retention footer) is issue #23,
/// which replaces this file's body and keeps the same entry point.
struct ShowPageView: View {
    @Environment(AppServices.self) private var services
    let show: Show

    @Query private var subscriptions: [Subscription]
    @State private var episodeCount = 0
    @State private var unwatchedCount = 0

    private var subscription: Subscription? {
        subscriptions.first { $0.channelId == show.channelId }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top, spacing: 16) {
                    ChannelArt(
                        url: subscription?.thumbnailURL,
                        title: show.title,
                        seed: show.channelId
                    )
                    .frame(width: 120, height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                    VStack(alignment: .leading, spacing: 6) {
                        Text(show.title)
                            .font(.title3.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(show.sourceDescription(channelTitle: subscription?.title ?? show.title))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("\(episodeCount) episodes · \(unwatchedCount) unwatched")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("The show page is still being built")
                        .font(.subheadline.weight(.semibold))
                    Text("Cadence, Play next, Mark all watched, and the episode list arrive with the show page itself. Until then the episodes are in the Feed and Channels tabs as usual.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding()
        }
        .navigationTitle(show.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let episodes = (try? services.shows.episodes(of: show)) ?? []
            episodeCount = episodes.count
            unwatchedCount = episodes.filter { !$0.isWatched }.count
        }
    }
}
