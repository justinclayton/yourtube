import SwiftUI
import SwiftData
import YouTubePlayerKit

/// Video playback plus the actions we layer on top of it.
///
/// Playback goes through YouTube's IFrame player (which is what
/// `YouTubePlayerKit` wraps). That's the only sanctioned way to play YouTube
/// content in a third-party app — the Data API doesn't vend stream URLs, and
/// extracting them would break the API ToS.
///
/// Two consequences worth knowing: audio stops shortly after the screen locks
/// (YouTube enforces this server-side, nothing on the client can defeat it),
/// and Picture-in-Picture only engages from native fullscreen.
struct PlayerView: View {
    @Bindable var video: Video
    @Environment(\.modelContext) private var modelContext
    @Environment(AppServices.self) private var services

    @State private var player: YouTubePlayer

    init(video: Video) {
        self.video = video
        _player = State(
            initialValue: YouTubePlayer(
                source: .video(id: video.videoId),
                parameters: .init(
                    autoPlay: true,
                    showControls: true,
                    restrictRelatedVideosToSameChannel: true
                )
            )
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                YouTubePlayerView(player)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 6) {
                    Text(video.displayTitle)
                        .font(.headline)
                    // The player is where the app shows its working: whenever
                    // cleaning changed the title, YouTube's own is right
                    // underneath, so nothing is hidden.
                    if video.hasCleanedTitle {
                        Text(video.title)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 6) {
                        EpisodeBadge(video: video)
                        Text(video.channelTitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Text(video.publishedAt, format: .dateTime.month().day().year())
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                actions

                if !video.videoDescription.isEmpty {
                    Text(video.videoDescription)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .navigationBarTitleDisplayMode(.inline)
        // Opening the player no longer marks a video watched: watched
        // removes a video from Up Next, and peeking at an earmarked video
        // must not do that. Automatic marking returns as the 90% rule
        // with playback progress (#21).
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Button {
                try? services.upNext.toggle(video)
            } label: {
                Label(
                    video.isInUpNext ? "Earmarked" : "Earmark",
                    systemImage: video.isInUpNext ? "bookmark.fill" : "bookmark"
                )
            }
            .buttonStyle(.bordered)

            Button {
                toggleWatched()
            } label: {
                Label(
                    video.isWatched ? "Watched" : "Mark watched",
                    systemImage: video.isWatched ? "checkmark.circle.fill" : "checkmark.circle"
                )
            }
            .buttonStyle(.bordered)

            Spacer()
        }
    }

    /// Watched leaves Up Next; unwatching doesn't put it back.
    private func toggleWatched() {
        if video.isWatched {
            video.isWatched = false
            try? modelContext.save()
        } else {
            try? services.upNext.markWatched(video)
        }
    }
}
