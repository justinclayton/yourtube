import SwiftUI
import SwiftData

/// A show, presented as a show rather than as a channel: square art, where
/// the episodes come from, how often they arrive and how long they run, one
/// button that opens the right episode and one that clears the backlog, then
/// the episodes themselves.
///
/// Everything above the list is either stored on the show or computed by
/// `ShowManager` on the spot — cadence and typical duration are never stored,
/// so a show that changes its habits stops claiming the old ones as soon as
/// the new episodes land.
///
/// The page is driven by a live query of the channel's videos rather than a
/// one-shot fetch, so marking an episode watched, earmarking it, or switching
/// the play order redraws the header, the counts and the list together.
struct ShowPageView: View {
    @Environment(AppServices.self) private var services
    let show: Show

    @Query private var subscriptions: [Subscription]
    /// Every non-Short video from the show's channel, newest first. The
    /// retention window is applied by `ShowManager` on top of it, so the page
    /// lists exactly what the catalogue counts.
    @Query private var channelVideos: [Video]
    @State private var isShowingSettings = false
    /// Play next pushes the player itself rather than through a
    /// `NavigationLink`, which a `List` would dress up as a row complete with
    /// a disclosure chevron. The episode rows below are rows and use links.
    @State private var playing: Video?

    init(show: Show) {
        self.show = show
        let channelId = show.channelId
        _channelVideos = Query(
            filter: #Predicate<Video> { $0.channelId == channelId && !$0.isLikelyShort },
            sort: [SortDescriptor(\Video.publishedAt, order: .reverse)]
        )
    }

    /// What the page lists: air order, newest at the top, whatever the play
    /// order. Play next is the thing that respects the play order.
    private var episodes: [Video] {
        ShowManager.episodesNewestFirst(from: channelVideos, of: show)
    }

    /// The same episodes in the show's play order, which is what decides
    /// which one Play next opens.
    private var episodesInPlayOrder: [Video] {
        ShowManager.episodes(from: channelVideos, of: show)
    }

    private var subscription: Subscription? {
        subscriptions.first { $0.channelId == show.channelId }
    }

    var body: some View {
        let episodes = episodes
        let unwatched = episodes.filter { !$0.isWatched }.count
        List {
            Section {
                header(episodes: episodes, unwatched: unwatched)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
            }
            Section {
                ForEach(episodes) { episode in
                    row(episode)
                }
            } header: {
                Text(episodes.isEmpty
                     ? "No episodes yet"
                     : "\(unwatched) unwatched of \(episodes.count)")
            }
        }
        .listStyle(.plain)
        .navigationTitle(show.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isShowingSettings = true
                } label: {
                    Label("Show settings", systemImage: "slider.horizontal.3")
                }
            }
        }
        .navigationDestination(item: $playing) { episode in
            PlayerView(video: episode)
        }
        .sheet(isPresented: $isShowingSettings) {
            ShowSettingsSheet(show: show)
        }
    }

    // MARK: - Header

    /// Art, provenance, habit, and the two buttons. The lines are stacked in
    /// order of how sure the app is of them: the source is a fact, the
    /// cadence is computed from what's arrived so far, and the detector's
    /// reasons for calling this a show sit beneath them when it was a guess.
    private func header(episodes: [Video], unwatched: Int) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                ChannelArt(
                    url: subscription?.thumbnailURL,
                    title: show.title,
                    seed: show.channelId
                )
                .frame(width: 120, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                VStack(alignment: .leading, spacing: 6) {
                    // The navigation bar's inline title truncates; a show's
                    // name never should, so it's set again here in full.
                    Text(show.title)
                        .font(.title3.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(show.sourceDescription(channelTitle: subscription?.title ?? show.title))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let cadence = ShowManager.cadenceDescription(of: episodes) {
                        Text(cadence)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            DetectorReasons(show: show)
            buttons(unwatched: unwatched)
        }
    }

    @ViewBuilder
    private func buttons(unwatched: Int) -> some View {
        HStack(spacing: 12) {
            if let next = ShowManager.nextUp(in: episodesInPlayOrder) {
                Button {
                    playing = next
                } label: {
                    // Spelled out rather than a `Label`, which a button
                    // inside a `List` row renders title-only.
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill")
                        Text(ShowManager.isResumable(next) ? "Resume" : "Play next")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle")
                    Text("All caught up")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
            }
            Button("Mark all watched") {
                try? services.shows.markAllWatched(of: show)
            }
            .buttonStyle(.bordered)
            .disabled(unwatched == 0)
        }
        .font(.subheadline)
    }

    // MARK: - Episodes

    private func row(_ episode: Video) -> some View {
        NavigationLink(value: episode) {
            ShowEpisodeRow(episode: episode, show: show, avatarURL: subscription?.thumbnailURL)
        }
        .swipeActions(edge: .leading) {
            Button {
                try? services.upNext.toggle(episode)
            } label: {
                Label(
                    episode.isInUpNext ? "Remove" : "Up Next",
                    systemImage: episode.isInUpNext ? "bookmark.slash" : "bookmark"
                )
            }
            .tint(.indigo)
        }
        .swipeActions(edge: .trailing) {
            Button {
                if episode.isWatched {
                    episode.isWatched = false
                } else {
                    try? services.upNext.markWatched(episode)
                }
            } label: {
                Label(
                    episode.isWatched ? "Unwatched" : "Watched",
                    systemImage: episode.isWatched ? "arrow.uturn.backward" : "checkmark"
                )
            }
            .tint(episode.isWatched ? .orange : .green)
        }
    }
}

/// One episode: small art, the full title free to wrap, and the facts that
/// tell you whether it's worth your evening. Watched episodes are dimmed
/// rather than hidden — a backlog you've cleared should still be browsable.
private struct ShowEpisodeRow: View {
    let episode: Video
    let show: Show
    let avatarURL: String?

    /// The show's art preference decides the row's art too, so the page and
    /// the cards it feeds agree.
    private var usesThumbnail: Bool {
        show.artPreference == .thumbnails
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ChannelArt(
                url: usesThumbnail ? episode.thumbnailURL : avatarURL,
                title: usesThumbnail ? episode.title : show.title,
                seed: usesThumbnail ? episode.videoId : show.channelId
            )
            .frame(width: 84, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .opacity(episode.isWatched ? 0.5 : 1)

            VStack(alignment: .leading, spacing: 4) {
                Text(episode.episodeTitle)
                    .font(.subheadline.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(episode.isWatched ? .secondary : .primary)
                HStack(spacing: 6) {
                    Text(episode.formattedDuration)
                        .monospacedDigit()
                    Text(episode.publishedAt, format: .relative(presentation: .named))
                    if episode.isInUpNext {
                        Image(systemName: "bookmark.fill")
                    }
                    if episode.isWatched {
                        Image(systemName: "checkmark.circle.fill")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                if let progress = inProgressFraction {
                    ProgressView(value: progress)
                        .tint(.accentColor)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private var inProgressFraction: Double? {
        ShowManager.isResumable(episode) ? episode.playbackFraction : nil
    }
}

/// The per-show settings: the two choices that change how the show behaves
/// elsewhere in the app, reachable from the page they affect.
private struct ShowSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Bindable var show: Show

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Play next", selection: $show.playOrder) {
                        Text("Newest first").tag(PlayOrder.newestFirst)
                        Text("Oldest first").tag(PlayOrder.oldestFirst)
                    }
                } header: {
                    Text("Play order")
                } footer: {
                    Text("Newest first suits a daily news show. Oldest first walks a backlog forwards, which is how a podcast is meant to be heard. Either way, an episode you're partway through is offered first.")
                }
                Section {
                    Picker("Card art", selection: $show.artPreference) {
                        Text("Channel art").tag(ShowArtPreference.channelArt)
                        Text("Video thumbnails").tag(ShowArtPreference.thumbnails)
                    }
                } header: {
                    Text("Art")
                } footer: {
                    Text("Channel art keeps the show recognisable and leaves YouTube's thumbnails out of it. Switch to thumbnails for a channel whose avatar carries no information. This applies to the show's episodes here and its cards in Continue Watching and Up Next.")
                }
            }
            .navigationTitle(show.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        try? modelContext.save()
                        dismiss()
                    }
                }
            }
        }
    }
}

private extension Video {
    /// The title the show page lists an episode under: the cleaned one, which
    /// for a show's episodes has been through both the boilerplate stripper
    /// and the model rewrite. See `TitleCleaner`.
    var episodeTitle: String { displayTitle }
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
