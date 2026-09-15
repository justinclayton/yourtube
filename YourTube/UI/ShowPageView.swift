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

                DetectorReasons(show: show)

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

/// Why the detector thought this channel was a show. Shown only for a guess:
/// a flag the user made by hand needs no justifying, and a guess that can't be
/// read can't be trusted or corrected.
struct DetectorReasons: View {
    let show: Show

    var body: some View {
        if show.flagOrigin == .heuristic, !show.detectorReasons.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label("Flagged as a show automatically", systemImage: "wand.and.stars")
                    .font(.subheadline.weight(.semibold))
                ForEach(show.detectorReasons, id: \.self) { reason in
                    Text("· \(reason)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Mark it \u{201C}Not a show\u{201D} in Channels if this is wrong; that decision sticks.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}
