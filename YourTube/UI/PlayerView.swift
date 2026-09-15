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
    /// `@State`, not `@Bindable`: "Next episode" replaces this with a
    /// different `Video` outright rather than editing the one we opened
    /// with, and only `@State`'s storage survives that reassignment across
    /// view updates. Nothing here hands out a `Binding` into it, so losing
    /// `@Bindable` costs nothing.
    @State private var video: Video
    @Environment(\.modelContext) private var modelContext
    @Environment(AppServices.self) private var services

    @State private var player: YouTubePlayer
    /// The last position the player reported, kept so leaving the view can
    /// store one without waiting on the web view we're tearing down.
    @State private var lastReportedPosition: Double?
    /// The episode after this one in its show, if any. Nil hides the Next
    /// episode button: either this video isn't part of a show, or it's
    /// already the newest episode. Recomputed whenever `video` changes.
    @State private var nextEpisode: Video?

    /// How often playback reports where it's got to. Two seconds keeps the
    /// resume point close to where you actually stopped without polling the
    /// web view hard.
    private static let reportInterval: Duration = .seconds(2)

    init(video: Video) {
        _video = State(initialValue: video)
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
        .task(id: video.videoId) { refreshNextEpisode() }
        .onDisappear {
            if let position = lastReportedPosition {
                services.playback.record(video, position: position)
            }
        }
    }

    /// Looks up whether the show this video belongs to has a next episode.
    /// Cheap enough to run on every video change without debouncing: it's an
    /// in-memory SwiftData fetch, not a network call.
    private func refreshNextEpisode() {
        nextEpisode = try? services.shows.nextEpisode(after: video)
    }

    /// Swaps the player to the next episode in place: same view, same
    /// actions, new source. Never crosses to another show — `nextEpisode`
    /// only ever names an episode of `video`'s own show.
    private func advanceToNextEpisode() {
        guard let next = nextEpisode else { return }
        // The episode we're leaving won't hit `onDisappear`, so bank its
        // progress here the same way leaving the player would.
        if let position = lastReportedPosition {
            services.playback.record(video, position: position)
        }
        lastReportedPosition = nil
        let startTime = PlaybackProgress.resumePosition(for: next)
            .map { Measurement(value: $0, unit: UnitDuration.seconds) }
        video = next
        Task {
            try? await player.load(source: .video(id: next.videoId), startTime: startTime)
        }
    }

    /// Poll the player while it's playing and hand each position to
    /// `PlaybackProgress`. Polling rather than the kit's `currentTimePublisher`
    /// because that one rides an undocumented progress event, and because a
    /// position must only be recorded while the video is actually playing: a
    /// buffering or cued player reports zero, which would read as "not
    /// started" and throw away the resume point we just opened at.
    @MainActor
    private func reportProgress() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.reportInterval)
            guard !Task.isCancelled else { return }
            if player.isEnded {
                // Some videos never report a time close to the end; the
                // ended state is the honest signal that they finished.
                services.playback.record(video, position: Double(video.durationSeconds))
                continue
            }
            guard player.isPlaying,
                  let time = try? await player.getCurrentTime() else { continue }
            let seconds = time.converted(to: .seconds).value
            guard seconds > 0 else { continue }
            lastReportedPosition = seconds
            services.playback.record(video, position: seconds)
        }
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

            if nextEpisode != nil {
                Button {
                    advanceToNextEpisode()
                } label: {
                    Label("Next episode", systemImage: "forward.end.fill")
                }
                .buttonStyle(.bordered)
            }

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
