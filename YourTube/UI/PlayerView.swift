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

    @State private var player: YouTubePlayer

    init(video: Video) {
        self.video = video
        _player = State(
            initialValue: YouTubePlayer(
                source: .video(id: video.videoId),
                parameters: .init(
                    autoPlay: true,
                    showControls: true,
                    showRelatedVideos: false
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
                    Text(video.title)
                        .font(.headline)
                    Text(video.channelTitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
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
        .task {
            // Opening the player is a good enough signal that it's been seen.
            markWatched()
        }
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Button {
                toggleWatchLater()
            } label: {
                Label(
                    video.isSavedForLater ? "Saved" : "Watch Later",
                    systemImage: video.isSavedForLater ? "clock.fill" : "clock"
                )
            }
            .buttonStyle(.bordered)

            Button {
                video.isWatched.toggle()
                try? modelContext.save()
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

    private func toggleWatchLater() {
        video.savedForLaterAt = video.isSavedForLater ? nil : .now
        try? modelContext.save()
    }

    private func markWatched() {
        guard !video.isWatched else { return }
        video.isWatched = true
        try? modelContext.save()
    }
}
