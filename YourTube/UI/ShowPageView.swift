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
    @Environment(\.dismiss) private var dismiss
    let show: Show

    @Query private var subscriptions: [Subscription]
    /// The videos the show's episodes are drawn from, newest first: its
    /// channel's for a channel-backed show, and every stored video for a
    /// playlist-backed one, since a playlist may hold a guest channel's video
    /// and `ShowManager` is the thing that knows which are members. The
    /// retention window is applied by `ShowManager` on top of it, so the page
    /// lists exactly what the catalogue counts.
    @Query private var channelVideos: [Video]
    @State private var isShowingSettings = false
    /// Segments start hidden every time the page opens: the full episodes are
    /// what a show is, and the cut-downs are there when they're asked for.
    /// Not stored on the show — it's a way of looking at the page, not a
    /// property of the show.
    @State private var isShowingSegments = false
    /// Which season the list is narrowed to, by index into `seasonNames`, or
    /// nil for all of them. Only a show with seasons offers the picker.
    @State private var season: Int?
    /// Set once the playlist behind the show has been walked this visit, so
    /// opening the page costs one unit and reopening it in the same session
    /// costs nothing.
    @State private var didRefreshMembership = false
    /// Play next pushes the player itself rather than through a
    /// `NavigationLink`, which a `List` would dress up as a row complete with
    /// a disclosure chevron. The episode rows below are rows and use links.
    @State private var playing: Video?

    init(show: Show) {
        self.show = show
        let channelId = show.channelId
        _channelVideos = Query(
            filter: show.isPlaylistBacked
                ? #Predicate<Video> { !$0.isLikelyShort }
                : #Predicate<Video> { $0.channelId == channelId && !$0.isLikelyShort },
            sort: [SortDescriptor(\Video.publishedAt, order: .reverse)]
        )
    }

    /// The raw material the page classifies: the show's members — its
    /// channel's uploads or its playlist's items — narrowed to the chosen
    /// season.
    ///
    /// The season is applied *before* classification rather than after, so
    /// the whole listing is about one thing: the segments behind the toggle,
    /// the retention window and the footer all describe the season in front
    /// of you. Filtering afterwards would leave an older series empty on a
    /// show told to keep only its last few episodes, which is not what
    /// picking that series means.
    private var seasonVideos: [Video] {
        ShowManager.episodes(
            ShowManager.members(from: channelVideos, of: show),
            inSeason: season,
            of: show
        )
    }

    /// What the page has to work with: the episodes it lists, the segments
    /// behind the toggle, and what the retention window is holding back. In
    /// air order, newest at the top, whatever the play order.
    private var listing: ShowListing {
        ShowManager.listing(from: seasonVideos, of: show)
    }

    /// The same episodes in the show's play order, which is what decides
    /// which one Play next opens. It follows the season picker too: the
    /// button should open what the list in front of you says is next.
    private var episodesInPlayOrder: [Video] {
        ShowManager.order(listing.episodes, by: show.playOrder)
    }

    private var subscription: Subscription? {
        subscriptions.first { $0.channelId == show.channelId }
    }

    var body: some View {
        let listing = listing
        let episodes = listing.episodes
        let unwatched = episodes.filter { !$0.isWatched }.count
        // Segments sit among the episodes in air order rather than in a list
        // of their own: a clip means something next to the episode it came
        // from, and nowhere else.
        let listed = isShowingSegments ? listing.everything : episodes
        let segmentIds = Set(listing.segments.map(\.videoId))
        List {
            Section {
                header(episodes: episodes, unwatched: unwatched)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
            }
            Section {
                ForEach(listed) { episode in
                    row(episode, isSegment: segmentIds.contains(episode.videoId))
                }
            } header: {
                // The plain style pins this header while the rows scroll but
                // paints nothing behind it, so rows would show through. The
                // bar material matches the navigation bar it sits under.
                episodesHeader(listing: listing, unwatched: unwatched)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.bar)
                    .listRowInsets(EdgeInsets())
            } footer: {
                if let summary = listing.hiddenSummary(revealingSegments: isShowingSegments) {
                    Text(summary)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(show.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // A playlist-backed show has no channel-level "not a show"
                // decision to record — that flag lives on the channel, and
                // this page is one playlist within it — so it keeps the
                // plain settings button. A channel-backed show gets the menu.
                if show.isPlaylistBacked {
                    settingsButton
                } else {
                    Menu {
                        settingsButton
                        Button {
                            markAsNotAShow()
                        } label: {
                            Label("Not a show", systemImage: "tv.slash")
                        }
                    } label: {
                        Label("Show settings", systemImage: "slider.horizontal.3")
                    }
                }
            }
        }
        .navigationDestination(item: $playing) { episode in
            PlayerView(video: episode)
        }
        .sheet(isPresented: $isShowingSettings) {
            ShowSettingsSheet(show: show, videos: channelVideos)
        }
        .task { await refreshMembershipIfNeeded() }
    }

    /// A playlist-backed show's membership is only as fresh as the last time
    /// someone asked YouTube what's in the playlist, and opening the page is
    /// when it's worth asking: one unit, on demand, for the show you're
    /// looking at. A channel-backed show needs none of this — its episodes
    /// arrive with the routine refresh — and signed out nothing is asked at
    /// all, so a fixture run shows what the store already holds.
    private func refreshMembershipIfNeeded() async {
        guard show.isPlaylistBacked, !didRefreshMembership, !services.auth.needsReauth else {
            return
        }
        didRefreshMembership = true
        _ = try? await services.feed.refreshMembership(of: show, using: services.shows)
    }

    private var settingsButton: some View {
        Button {
            isShowingSettings = true
        } label: {
            Label("Show settings", systemImage: "slider.horizontal.3")
        }
    }

    /// Records "not a show" the same way Channels does — the standing
    /// decision the detector can never overrule — then leaves the page,
    /// since the show it was showing is no longer in the catalogue.
    private func markAsNotAShow() {
        try? services.shows.setIsShow(
            false,
            channelId: show.channelId,
            channelTitle: subscription?.title ?? show.title
        )
        dismiss()
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
            seasonPicker
            buttons(unwatched: unwatched)
        }
    }

    /// The season picker, for a show built from several playlists: one
    /// playlist per series, browsed one series at a time. A show with one
    /// playlist has nothing to pick between and gets no picker.
    @ViewBuilder
    private var seasonPicker: some View {
        if show.hasSeasons {
            Picker("Season", selection: $season) {
                Text("All seasons").tag(Int?.none)
                ForEach(Array(show.seasonNames.enumerated()), id: \.offset) { index, name in
                    Text(name).tag(Int?.some(index))
                }
            }
            .pickerStyle(.menu)
            .font(.subheadline)
            .frame(maxWidth: .infinity, alignment: .leading)
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

    /// The list's header counts episodes, not rows: the count means the same
    /// thing as the badge on the poster whether or not the segments are
    /// showing. The toggle sits beside it because that's the count it
    /// explains.
    @ViewBuilder
    private func episodesHeader(listing: ShowListing, unwatched: Int) -> some View {
        HStack {
            Text(listing.episodes.isEmpty
                 ? "No episodes yet"
                 : "\(unwatched) unwatched of \(listing.episodes.count)")
            Spacer(minLength: 8)
            if !listing.segments.isEmpty {
                Button(isShowingSegments
                       ? "Hide segments"
                       : "Show \(listing.segments.count) segments") {
                    withAnimation { isShowingSegments.toggle() }
                }
                .font(.caption.weight(.medium))
                .textCase(nil)
                .buttonStyle(.borderless)
            }
        }
    }

    private func row(_ episode: Video, isSegment: Bool) -> some View {
        NavigationLink(value: episode) {
            ShowEpisodeRow(
                episode: episode,
                show: show,
                avatarURL: subscription?.thumbnailURL,
                isSegment: isSegment
            )
        }
        .swipeActions(edge: .leading) {
            Button {
                try? services.upNext.toggle(episode)
            } label: {
                Label(
                    episode.isInUpNext ? "Un-earmark" : "Earmark",
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
    /// A revealed cut-down, which is labelled so that a list showing both
    /// never leaves you wondering which is the real episode.
    var isSegment = false

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
                    if isSegment {
                        Text("Segment")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 4))
                            .foregroundStyle(.secondary)
                    }
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

/// The per-show settings: the choices that change how this show behaves
/// elsewhere in the app, reachable from the page they affect. Two of them —
/// the segment threshold and the retention window — decide what the page
/// lists at all, so they report what they're doing to the show's videos while
/// they're being set.
private struct ShowSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Bindable var show: Show
    /// The show's videos, so the sheet can say what a setting is doing to
    /// them while it's being moved rather than only after it's dismissed.
    let videos: [Video]

    private var listing: ShowListing {
        ShowManager.listing(from: videos, of: show)
    }

    /// "Keep everything" is a retention count of nil, which a `Picker` can't
    /// tag; zero stands in for it here and nowhere else.
    private var retention: Binding<Int> {
        Binding(
            get: { show.retentionCount ?? 0 },
            set: { show.retentionCount = $0 == 0 ? nil : $0 }
        )
    }

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
                segmentsSection
                retentionSection
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

    /// The segment rule, with its consequence shown as it's moved: the number
    /// under the slider is the length the show is about to draw the line at
    /// and how many of its videos fall below it. A setting whose effect you
    /// can only see after dismissing the sheet is a setting you have to guess
    /// at.
    @ViewBuilder
    private var segmentsSection: some View {
        Section {
            Slider(
                value: $show.segmentThreshold,
                in: Show.segmentThresholdRange,
                step: 0.05
            ) {
                Text("Segment threshold")
            } minimumValueLabel: {
                Text("10%")
                    .font(.caption2)
            } maximumValueLabel: {
                Text("90%")
                    .font(.caption2)
            }
            LabeledContent("Segments are shorter than", value: thresholdDescription)
                .font(.subheadline)
        } header: {
            Text("Segments")
        } footer: {
            Text("A news hour posts its full episode and then cuts clips out of it. A video shorter than this much of a typical episode is taken to be one of those clips: hidden on this page unless you ask for it, and left out of the show's unwatched count. It stays in the feed either way.")
        }
    }

    /// The length the slider currently draws the line at, and what that does
    /// to the videos the show already has.
    private var thresholdDescription: String {
        let percent = Int((show.segmentThreshold * 100).rounded())
        guard let typical = listing.typicalEpisodeDuration,
              let length = ShowManager.approximateLength(typical * show.segmentThreshold) else {
            return "\(percent)% of an episode"
        }
        return "\(length) · \(listing.segmentCount) of \(listing.sourceCount)"
    }

    @ViewBuilder
    private var retentionSection: some View {
        Section {
            Picker("Keep", selection: retention) {
                Text("All episodes").tag(0)
                ForEach(Show.retentionOptions, id: \.self) { count in
                    Text("Last \(count) episodes").tag(count)
                }
            }
        } header: {
            Text("Retention")
        } footer: {
            Text("Keeping the last few episodes stops a daily show piling up a backlog you feel obliged to clear. The older ones are hidden from this page and its counts, never deleted, and they stay in the feed.")
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
                Text("Mark it \u{201C}Not a show\u{201D} above, or in Channels, if this is wrong; that decision sticks.")
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
