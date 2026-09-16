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
    /// The one video this player plays. It never changes hands: the player
    /// has no next-episode action, so a `let` is enough, and the model's
    /// observation keeps the title and buttons live.
    let video: Video
    @Environment(\.modelContext) private var modelContext
    @Environment(AppServices.self) private var services

    @State private var player: YouTubePlayer
    /// The last position the player reported, kept so leaving the view can
    /// store one without waiting on the web view we're tearing down.
    @State private var lastReportedPosition: Double?
    /// The last position actually written to the store for the current
    /// video, so `reportProgress` can throttle: see `PlaybackProgress.shouldWrite`.
    @State private var lastWrittenPosition: Double?
    /// Whether the previous poll saw the player paused, so a pause writes
    /// once on the play->pause edge rather than on every poll spent paused.
    @State private var wasPaused = false
    /// The episode after this one in its show, if any. Nil hides the Next
    /// episode button: either this video isn't part of a show, or it's
    /// already the newest episode. Recomputed whenever `video` changes.

    /// How often playback reports where it's got to. Two seconds keeps the
    /// resume point close to where you actually stopped without polling the
    /// web view hard.
    private static let reportInterval: Duration = .seconds(2)

    init(video: Video) {
        self.video = video
        _player = State(
            initialValue: YouTubePlayer(
                source: .video(id: video.videoId),
                parameters: .init(
                    autoPlay: true,
                    // Resume: the IFrame player's own start parameter, so
                    // playback opens at the stored position rather than
                    // seeking there after the fact.
                    startTime: PlaybackProgress.resumePosition(for: video)
                        .map { Measurement(value: $0, unit: UnitDuration.seconds) },
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
        // Opening the player doesn't mark a video watched: watched removes a
        // video from Up Next, and peeking at an earmarked video must not do
        // that. Watched is set automatically once playback passes 90% of the
        // duration instead — see `PlaybackProgress`.
        .task { await reportProgress() }
        .onDisappear {
            if let position = lastReportedPosition {
                services.playback.record(video, position: position)
            }
        }
    }

    /// Poll the player while it's playing and hand positions worth keeping to
    /// `PlaybackProgress`. Polling rather than the kit's `currentTimePublisher`
    /// because that one rides an undocumented progress event, and because a
    /// position must only be recorded while the video is actually playing: a
    /// buffering or cued player reports zero, which would read as "not
    /// started" and throw away the resume point we just opened at.
    ///
    /// The poll itself stays at two seconds, but most polls don't write:
    /// every write is a store change that reruns every live query in the app
    /// for as long as playback lasts (#71). `PlaybackProgress.shouldWrite`
    /// throttles to roughly every 15 s of movement; pausing and leaving the
    /// player (`onDisappear`) always write so the
    /// resume point reflects where playback actually stopped.
    @MainActor
    private func reportProgress() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.reportInterval)
            guard !Task.isCancelled else { return }
            if player.isEnded {
                // Some videos never report a time close to the end; the
                // ended state is the honest signal that they finished.
                let position = Double(video.durationSeconds)
                if PlaybackProgress.shouldWrite(lastWritten: lastWrittenPosition, position: position) {
                    services.playback.record(video, position: position)
                    lastWrittenPosition = position
                }
                continue
            }
            if player.isPaused {
                // Write once on the play->pause edge, not on every poll
                // spent paused.
                if !wasPaused, let position = lastReportedPosition {
                    services.playback.record(video, position: position)
                    lastWrittenPosition = position
                }
                wasPaused = true
                continue
            }
            wasPaused = false
            guard player.isPlaying,
                  let time = try? await player.getCurrentTime() else { continue }
            let seconds = time.converted(to: .seconds).value
            guard seconds > 0 else { continue }
            lastReportedPosition = seconds
            if PlaybackProgress.shouldWrite(lastWritten: lastWrittenPosition, position: seconds) {
                services.playback.record(video, position: seconds)
                lastWrittenPosition = seconds
            }
        }
    }

    /// Apple TV-style "normal" action button: white pill, black content.
    /// `lineLimit(1)` keeps a label on one line so two buttons never wrap
    /// their text into tall pills that collide with the row above.
    private struct PlayerActionButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .foregroundStyle(.black)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.white, in: Capsule())
                .opacity(configuration.isPressed ? 0.7 : 1)
        }
    }

    /// Two actions, and only two: earmarking and watched. There is no
    /// "next episode" here on purpose — the app doesn't binge, and the show
    /// page one level back is where the rest of the show lives. The Up Next
    /// button is the bookmark alone so both pills fit a phone's width
    /// without scrolling; its label lives in accessibility.
    private var actions: some View {
        HStack(spacing: 12) {
            Button {
                try? services.upNext.toggle(video)
            } label: {
                Image(systemName: video.isInUpNext ? "bookmark.fill" : "bookmark")
            }
            .buttonStyle(PlayerActionButtonStyle())
            .accessibilityLabel(video.isInUpNext ? "Remove from Up Next" : "Add to Up Next")

            Button {
                toggleWatched()
            } label: {
                Label(
                    video.isWatched ? "Watched" : "Mark watched",
                    systemImage: video.isWatched ? "checkmark.circle.fill" : "checkmark.circle"
                )
            }
            .buttonStyle(PlayerActionButtonStyle())

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
