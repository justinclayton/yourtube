#if DEBUG
import Foundation
import SwiftData

/// A signed-out, populated store for exercising the UI on a simulator without
/// a Google login. Debug builds only.
///
/// Launch the app with the `-seedFixtures` argument (see `.claude/launch.json`
/// and README "Development loop") and it opens an in-memory container holding
/// a handful of subscriptions, categories, and videos instead of the real
/// store, with `UserDefaults` redirected to its own suite. The real store and
/// the real defaults are never opened, and no token is involved, so the
/// sign-in banner shows and refresh is disabled: exactly the "offline, signed
/// out" state local features like search have to work in.
///
/// The data is chosen to be awkward on purpose: diacritics, mixed case, a
/// channel name that also appears in another channel's titles, a prolific
/// channel to trip the daily cap, two earmarked videos so Up Next shows its
/// two-column grid, and one left partway through so Continue Watching has a
/// card.
///
/// **Nothing here is hand-stamped.** The fixtures describe videos the way the
/// API describes them and hand them to `VideoIntake`, the same door a refresh
/// uses. `Show` rows are made by `ShowManager`, and watched / Up Next /
/// partway-through are set by `WatchState`. A fixture run therefore exercises
/// the real paths rather than a parallel one that can drift away from them,
/// and `DebugFixturesTests` asserts on what came through the door.
enum DebugFixtures {
    static let launchArgument = "-seedFixtures"

    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

    /// Manual verification hook for issue #68's Done-when: a visible feed
    /// row's title doesn't change while it stays on screen during a rewrite
    /// batch. `TitleRewriter` needs the on-device model, which the shared
    /// simulator pool may not have, so this stands in for a real batch by
    /// mutating one video's `cleanedTitle` a few seconds after launch —
    /// enough time to have the feed on screen and latched, but short enough
    /// to drive by hand. Combine with `-seedFixtures`.
    static let mutateTitleLaunchArgument = "-mutateFixtureTitle"

    static var shouldMutateTitle: Bool {
        ProcessInfo.processInfo.arguments.contains(mutateTitleLaunchArgument)
    }

    /// Rewrites the newest fixture video's title after a short delay, as if
    /// a `TitleRewriter` batch (#65) had just landed underneath it. Whatever
    /// feed row is showing that video should keep displaying the title it
    /// first drew — see `FeedVideoRow`'s `TitleLatch` — until it scrolls off
    /// screen and back, at which point the lazy list recreates the row and
    /// the new title appears.
    @MainActor
    static func scheduleTitleMutation(in context: ModelContext) {
        guard shouldMutateTitle else { return }
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            let newestFirst = FetchDescriptor<Video>(
                sortBy: [SortDescriptor(\Video.publishedAt, order: .reverse)]
            )
            guard let video = try? context.fetch(newestFirst).first else { return }
            video.cleanedTitle = "MUTATED TITLE — latch should hide this"
            try? context.save()
        }
    }

    /// Placeholder OAuth values so a fixture run doesn't need `Config.plist`.
    static let config = AppConfig.Values(clientId: "fixtures", redirectScheme: "fixtures")

    /// The `UserDefaults` suite a fixture run reads and writes instead of
    /// `.standard`: quota, classifier and detector bookkeeping, and every
    /// `@AppStorage` setting. Keeping it separate means a fixture run can't
    /// leave fixture channel fingerprints or a toggled setting behind for the
    /// real account to trip over.
    static let defaultsSuite = "net.claytons.yourtube.fixtures"
    static var defaults: UserDefaults { UserDefaults(suiteName: defaultsSuite)! }

    @MainActor
    static func makeContainer() throws -> ModelContainer {
        // The fixture store is new every launch, so its defaults are too:
        // otherwise the show detector would believe it had already examined
        // these channels and leave the grid short of its heuristic show.
        defaults.removePersistentDomain(forName: defaultsSuite)
        let container = try ModelContainer(
            for: Video.self, Subscription.self, VideoCollection.self, ChannelRule.self, Show.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )

        // Built once and used twice: the videos go in through intake, and
        // what the store should then say about them — watched, earmarked,
        // partway through — is read off the same list. Published dates are
        // relative to now, so generating them twice would not give the same
        // answer.
        let videos = allVideos()
        let intake = VideoIntake(writer: StoreWriter(modelContainer: container))
        try runBlocking { try await intake.admit(videos.map(\.item)) }

        try seed(container.mainContext, videos: videos)
        return container
    }

    /// Runs the async half of seeding to completion from the synchronous
    /// launch path. `YourTubeApp.init` can't await, and the fixture store has
    /// to be fully populated before the first view reads it — a feed that
    /// fills in a moment after launch is not the thing being exercised.
    ///
    /// Safe to block the main thread on: everything awaited inside runs on
    /// `StoreWriter`'s own executor or the cooperative pool and never hops
    /// back to the main actor, so the wait can't be waiting on the thread it
    /// is holding. Debug fixture seeding only; nothing in the real app does
    /// this.
    private static func runBlocking(
        _ body: @escaping @Sendable () async throws -> Void
    ) throws {
        let finished = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var thrown: Error?
        Task.detached {
            do { try await body() } catch { thrown = error }
            finished.signal()
        }
        finished.wait()
        if let thrown { throw thrown }
    }

    // MARK: - One fixture video

    /// A video the fixtures want in the store, described the way the API
    /// describes one so that intake can store it like any other.
    ///
    /// `isWatched` is what the fixture *intends*, not a field written to the
    /// row: it's applied by `WatchState` once the row exists.
    struct FixtureVideo {
        var id: String
        var channelId: String
        var channelTitle: String
        var title: String
        var summary: String = ""
        var publishedAt: Date
        var seconds: Int
        var youtubeCategoryId: String?
        var isWatched = false

        var item: YT.VideoItem {
            YT.VideoItem(
                id: id,
                snippet: YT.VideoItem.Snippet(
                    title: title,
                    description: summary,
                    channelId: channelId,
                    channelTitle: channelTitle,
                    publishedAt: publishedAt,
                    thumbnails: nil,
                    categoryId: youtubeCategoryId
                ),
                contentDetails: YT.VideoItem.ContentDetails(duration: "PT\(seconds)S")
            )
        }
    }

    private static func allVideos() -> [FixtureVideo] {
        feedVideos() + showChannelVideos() + playlistShowVideos()
    }

    // MARK: - Awkward-data channels

    private struct Channel {
        var id: String
        var title: String
        var categories: [String]
        /// Present when the fixture channel stands for one the classifier
        /// filed rather than one filed by hand: the rule is then not
        /// user-set, and carries the evidence a v4 pass records — which
        /// category the model chose and which YouTube's own filing added.
        /// That's what the Categories sheet's "Why" section reads.
        var classifier: ClassifierEvidence?
        /// YouTube's own `snippet.categoryId` on every one of this channel's
        /// videos, so `YouTubeCategorySignal` has a majority to find. Nil
        /// leaves the videos uncategorised on YouTube's side, which is what
        /// most fixture channels want.
        var youtubeCategoryId: String?
        var videos: [(title: String, hoursAgo: Double, seconds: Int)]
    }

    /// See `Channel.classifier`.
    private struct ClassifierEvidence {
        var modelCategory: String
        var youtubeCategory: String?
        var youtubeReason: String?
        var dominantCategoryId: String
    }

    private static let channels: [Channel] = [
        Channel(id: "UC-teamcoco", title: "Team Coco", categories: ["Comedy", "Podcasts & Interviews"], videos: [
            ("Conan Visits Cuba", 3, 1260),
            ("Conan O'Brien Needs A Friend: Full Episode", 26, 3900),
            ("Conan tries the world's hottest wing #shorts", 27, 45),
        ]),
        Channel(id: "UC-beyonce", title: "Beyoncé", categories: ["Music & Audio Gear"], videos: [
            ("Café Sessions, Part 4", 5, 620),
            ("Rehearsal Diaries: São Paulo", 30, 780),
        ]),
        Channel(id: "UC-lmnc", title: "Look Mum No Computer", categories: ["Music & Audio Gear", "Makers & DIY"], videos: [
            ("Building a Synth From a Furby", 8, 1420),
            ("Modular jam in the bunker", 50, 900),
        ]),
        Channel(id: "UC-berlin", title: "Berlin Vlogs", categories: [], videos: [
            ("Straße walk in Kreuzberg", 12, 2400),
            ("Späti tour", 13, 60),
        ]),
        // The automatically-filed fixture, and the one that shows a channel's
        // two chips coming from two sources: the model reads the uploads as
        // explainers while YouTube's own filing is Science & Technology,
        // which the taxonomy calls Tech & Engineering.
        Channel(
            id: "UC-nasa",
            title: "NASA",
            categories: ["Priority", "Science & Explainers", "Tech & Engineering"],
            classifier: ClassifierEvidence(
                modelCategory: "Science & Explainers",
                youtubeCategory: "Tech & Engineering",
                youtubeReason: "YouTube files most of its videos under Science & Technology",
                dominantCategoryId: "28"
            ),
            youtubeCategoryId: "28",
            videos: [
            ("Artemis III launch briefing", 1, 5400),
            ("Mars weather this week", 2, 300),
            ("Space station timelapse", 4, 240),
            ("Live Q&A with the crew", 6, 4200),
            ("Rocket engine test #shorts", 7, 20),
            ]
        ),
        Channel(id: "UC-conanfans", title: "Conan Clips Archive", categories: ["Comedy"], videos: [
            ("Late Night 1997: Triumph at Westminster", 100, 500),
        ]),
        // Every title carries the show name after a pipe and an episode
        // number, so the title cleaner has something to bite on signed out.
        Channel(id: "UC-blocks", title: "Blocks Podcast", categories: ["Podcasts & Interviews"], youtubeCategoryId: "23", videos: [
            ("Ali Macofsky | Blocks Podcast w/ Neal Brennan | Ep. 214", 9, 4500),
            ("Mark Normand | Blocks Podcast w/ Neal Brennan | Ep. 213", 33, 4200),
            ("Bill Burr | Blocks Podcast w/ Neal Brennan | FULL EPISODE | Ep. 212", 58, 5100),
            ("Tig Notaro | Blocks Podcast w/ Neal Brennan | Ep. 211", 80, 3900),
        ]),
    ]

    /// Earmarked to Up Next, in this order. Neither is a channel's last
    /// video, which the seed marks watched.
    private static let upNext = ["UC-teamcoco-1", "UC-nasa-3"]

    /// Partway through, in seconds, so Continue Watching has something to
    /// show. Neither earmarked nor watched, so it's the section's own.
    private static let inProgress = ["UC-lmnc-0": 620.0]

    private static func feedVideos() -> [FixtureVideo] {
        channels.flatMap { channel in
            channel.videos.enumerated().map { index, video in
                FixtureVideo(
                    id: "\(channel.id)-\(index)",
                    channelId: channel.id,
                    channelTitle: channel.title,
                    title: video.title,
                    publishedAt: Date(timeIntervalSinceNow: -video.hoursAgo * 3600),
                    seconds: video.seconds,
                    youtubeCategoryId: channel.youtubeCategoryId,
                    isWatched: index == channel.videos.count - 1
                )
            }
        }
    }

    // MARK: - Seeding the rest of the store

    @MainActor
    private static func seed(_ context: ModelContext, videos: [FixtureVideo]) throws {
        let collections = Dictionary(
            uniqueKeysWithValues: CategoryManager.defaultCategoryNames.enumerated().map { index, name in
                (name, VideoCollection(name: name, isUserCreated: false, sortOrder: index))
            }
        )
        collections.values.forEach(context.insert)
        let priority = VideoCollection(
            name: CategoryManager.priorityName,
            isUserCreated: false,
            sortOrder: CategoryManager.prioritySortOrder,
            isPriority: true
        )
        context.insert(priority)

        for channel in channels {
            context.insert(Subscription(
                channelId: channel.id,
                title: channel.title,
                channelDescription: "Fixture channel for \(channel.title)."
            ))
            let filed = channel.categories.compactMap { name in
                name == CategoryManager.priorityName ? priority : collections[name]
            }
            if !filed.isEmpty {
                let rule = ChannelRule(
                    channelId: channel.id,
                    channelTitle: channel.title,
                    collections: filed,
                    isUserSet: channel.classifier == nil,
                    classifiedAt: channel.classifier == nil ? nil : .now
                )
                if let evidence = channel.classifier {
                    rule.classifierRawAnswer = [evidence.modelCategory]
                    rule.classifierResolvedCategories = filed.map(\.name)
                    rule.classifierModelCategory = evidence.modelCategory
                    rule.classifierYouTubeCategory = evidence.youtubeCategory
                    rule.classifierYouTubeReason = evidence.youtubeReason
                    rule.classifierDominantCategoryId = evidence.dominantCategoryId
                }
                context.insert(rule)
            }
        }
        try context.save()

        let watchState = WatchState(modelContext: context)
        let shows = ShowManager(modelContext: context, watchState: watchState)
        try seedShows(context, collections: collections, priority: priority, shows: shows)
        try seedPlaylistShows(context, collections: collections, shows: shows)
        try context.save()

        try applyWatchState(context, videos: videos, watchState: watchState)
    }

    /// Watched, earmarked and partway-through, applied to rows that are
    /// already in the store — through `WatchState`, which is their only
    /// writer everywhere else in the app (see CONTEXT.md). Watched first:
    /// marking a video watched clears any Up Next place and any position, and
    /// no fixture video is meant to be both.
    @MainActor
    private static func applyWatchState(
        _ context: ModelContext,
        videos: [FixtureVideo],
        watchState: WatchState
    ) throws {
        let stored = Dictionary(
            uniqueKeysWithValues: try context.fetch(FetchDescriptor<Video>())
                .map { ($0.videoId, $0) }
        )
        try watchState.markWatched(videos.filter(\.isWatched).compactMap { stored[$0.id] })
        // In this order, so Up Next's own order is the one declared above.
        for id in upNext {
            guard let video = stored[id] else { continue }
            try watchState.earmark(video)
        }
        for (id, position) in inProgress {
            guard let video = stored[id] else { continue }
            watchState.record(video, position: position)
        }
    }
}

// MARK: - Show-shaped channels

/// Three channels that behave like television, kept apart from the awkward-data
/// fixtures above because later slices lean on their shape rather than on their
/// names: the show page, the cadence detector, and title cleaning all want
/// something realistic to chew on.
///
/// - **The Bellwether** — twice-weekly long-form interviews, an hour or more,
///   every title carrying the channel's ` | The Bellwether` suffix, and the
///   Priority tag, so the grid has something to pin first.
/// - **Second Take** — a weekly numbered podcast, `#147 — Guest — Second Take`,
///   with an oldest-first play order because a backlog is watched forwards.
/// - **Newsline Nightly** — a weekday news hour, each full episode trailed by
///   three cut-down segments. Segments are ordinary videos, not Shorts, which
///   is exactly why a show has to tell them apart.
///
/// Two more exist for the detector rather than the grid:
///
/// - **The Rundown** — show-shaped and unflagged, so a fixture run shows the
///   detector finding a show by itself, reasons and all.
/// - **Off the Record** — just as show-shaped, and marked "Not a show" by
///   hand. It's the one the detector must never pick up.
extension DebugFixtures {
    /// What the fixture store has already decided about a show-shaped channel,
    /// so a run exercises all three states the detector has to respect.
    private enum ShowFlag {
        /// Flagged by hand: the detector must leave it alone.
        case user
        /// "Not a show" by hand: a tombstone the detector must not overturn,
        /// on a channel it would otherwise flag.
        case notAShow
        /// No row at all — the detector's to find at launch.
        case undecided
    }

    private struct ShowChannel {
        var id: String
        var title: String
        var categories: [String]
        var flag: ShowFlag = .user
        /// YouTube's own category ID, a signal the detector reads.
        var youtubeCategoryId: String?
        var playOrder: PlayOrder = .newestFirst
        /// Weekdays it posts on, `Calendar` numbering (1 = Sunday).
        var weekdays: Set<Int>
        var hour: Int
        /// Full episodes, newest first, paired with their durations.
        var episodes: [(title: String, seconds: Int)]
        /// Segment titles cut from each episode, and their durations. Empty
        /// for a show that doesn't cut its episodes up.
        var segments: [(title: String, seconds: Int)] = []
        /// How many of the newest episodes are left unwatched.
        var unwatched: Int
    }

    private static let showChannels: [ShowChannel] = [
        ShowChannel(
            id: "UC-bellwether",
            title: "The Bellwether",
            categories: ["Priority", "News & Politics", "Podcasts & Interviews"],
            weekdays: [3, 6],
            hour: 6,
            episodes: [
                ("Dana Ruiz on why the housing market broke | The Bellwether", 4_860),
                ("Is the deficit actually a problem? | The Bellwether", 4_140),
                ("Marcus Bell on the new labour movement | The Bellwether", 5_220),
                ("What the polls keep missing | The Bellwether", 3_900),
                ("Priya Raman on rebuilding the grid | The Bellwether", 4_500),
                ("The case against the primary system | The Bellwether", 3_780),
                ("Tom Ingram on the end of cheap money | The Bellwether", 5_040),
                ("A conversation about attention | The Bellwether", 4_320),
            ],
            unwatched: 3
        ),
        ShowChannel(
            id: "UC-secondtake",
            title: "Second Take",
            categories: ["Podcasts & Interviews", "Comedy"],
            playOrder: .oldestFirst,
            weekdays: [4],
            hour: 9,
            episodes: [
                ("#147 — Wendy Cho — Second Take", 5_700),
                ("#146 — Ray Ortiz — Second Take", 6_240),
                ("#145 — Nina Haddad — Second Take", 5_100),
                ("#144 — Desmond Pike — Second Take", 6_600),
                ("#143 — Alice Fenn — Second Take", 5_460),
                ("#142 — Gus Mbeki — Second Take", 5_880),
            ],
            unwatched: 2
        ),
        ShowChannel(
            id: "UC-newsline",
            title: "Newsline Nightly",
            categories: ["News & Politics"],
            weekdays: [2, 3, 4, 5, 6],
            hour: 19,
            episodes: Array(repeating: (title: "Newsline Nightly — FULL EPISODE", seconds: 3_180), count: 10),
            segments: [
                ("Newsline Nightly: the budget fight, explained", 620),
                ("Newsline Nightly: what the court ruling means", 480),
                ("Newsline Nightly: the jobs numbers in context", 405),
            ],
            unwatched: 2
        ),
        // Nothing decided about this one, so the detector finds it at launch
        // and the grid gains a poster nobody flagged by hand.
        ShowChannel(
            id: "UC-rundown",
            title: "The Rundown",
            categories: ["News & Politics"],
            flag: .undecided,
            youtubeCategoryId: "25",
            weekdays: [2, 5],
            hour: 7,
            episodes: [
                ("The Rundown: Ep. 88 — the week in one hour", 3_720),
                ("The Rundown: Ep. 87 — what the vote changed", 3_960),
                ("The Rundown: Ep. 86 — the case for patience", 3_480),
                ("The Rundown: Ep. 85 — borders and budgets", 4_080),
                ("The Rundown: Ep. 84 — the long recount", 3_600),
                ("The Rundown: Ep. 83 — a quiet fortnight", 3_840),
                ("The Rundown: Ep. 82 — the committee hearings", 3_540),
            ],
            unwatched: 4
        ),
        // Show-shaped in every way the detector can see, and the user has
        // said no. It must stay out of Your Shows however many passes run.
        ShowChannel(
            id: "UC-offtherecord",
            title: "Off the Record",
            categories: ["Podcasts & Interviews"],
            flag: .notAShow,
            youtubeCategoryId: "24",
            weekdays: [4],
            hour: 11,
            episodes: [
                ("Off the Record #61 — the touring years", 4_500),
                ("Off the Record #60 — leaving the label", 5_100),
                ("Off the Record #59 — writing in hotel rooms", 4_260),
                ("Off the Record #58 — the first record", 4_920),
                ("Off the Record #57 — session players", 4_380),
                ("Off the Record #56 — a life in studios", 5_040),
            ],
            unwatched: 3
        ),
    ]

    /// The show-shaped channels' episodes and segments, newest first, with
    /// the dates a real cadence would have put them on.
    private static func showChannelVideos() -> [FixtureVideo] {
        let calendar = Calendar.current
        var result: [FixtureVideo] = []
        for channel in showChannels {
            let dates = recentDates(
                onWeekdays: channel.weekdays,
                count: channel.episodes.count,
                hour: channel.hour,
                calendar: calendar
            )
            for (index, episode) in channel.episodes.enumerated() {
                let date = dates[index]
                let watched = index >= channel.unwatched
                result.append(FixtureVideo(
                    id: "\(channel.id)-e\(index)",
                    channelId: channel.id,
                    channelTitle: channel.title,
                    title: dateStamped(episode.title, date: date, calendar: calendar),
                    summary: "Fixture episode of \(channel.title).",
                    publishedAt: date,
                    seconds: episode.seconds,
                    youtubeCategoryId: channel.youtubeCategoryId,
                    isWatched: watched
                ))
                // Segments land through the evening after the full episode.
                for (offset, segment) in channel.segments.enumerated() {
                    result.append(FixtureVideo(
                        id: "\(channel.id)-e\(index)s\(offset)",
                        channelId: channel.id,
                        channelTitle: channel.title,
                        title: segment.title,
                        summary: "Fixture episode of \(channel.title).",
                        publishedAt: date.addingTimeInterval(Double(offset + 1) * 2_700),
                        seconds: segment.seconds,
                        youtubeCategoryId: channel.youtubeCategoryId,
                        isWatched: watched
                    ))
                }
            }
        }
        return result
    }

    /// Seeds the show-shaped channels and the `Show` rows that put them in
    /// Your Shows. Three are flagged the way the user would flag them by hand
    /// — through `ShowManager`, the same call the Channels list makes — so the
    /// grid is populated without anything automatic having to run; the other
    /// two are left for the detector to get right and wrong.
    @MainActor
    private static func seedShows(
        _ context: ModelContext,
        collections: [String: VideoCollection],
        priority: VideoCollection,
        shows: ShowManager
    ) throws {
        for channel in showChannels {
            context.insert(Subscription(
                channelId: channel.id,
                title: channel.title,
                channelDescription: "Fixture show channel for \(channel.title)."
            ))
            let filed = channel.categories.compactMap { name in
                name == CategoryManager.priorityName ? priority : collections[name]
            }
            if !filed.isEmpty {
                context.insert(ChannelRule(
                    channelId: channel.id,
                    channelTitle: channel.title,
                    collections: filed,
                    isUserSet: true
                ))
            }
            switch channel.flag {
            case .user:
                let show = try shows.markAsShow(
                    channelId: channel.id, channelTitle: channel.title
                )
                // Play order is a setting on the show, set the same way the
                // show page's picker sets it.
                show.playOrder = channel.playOrder
            case .notAShow:
                try shows.markAsNotAShow(channelId: channel.id, channelTitle: channel.title)
            case .undecided:
                break
            }
        }
        try context.save()
    }

    /// A daily show's episodes are named for their day, so the fixture titles
    /// are stamped at seed time rather than frozen into the table.
    private static func dateStamped(_ title: String, date: Date, calendar: Calendar) -> String {
        guard title.hasSuffix("FULL EPISODE") else { return title }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.setLocalizedDateFormatFromTemplate("EEEMMMd")
        return "\(title) — \(formatter.string(from: date))"
    }

    /// The most recent `count` dates falling on `weekdays`, newest first, at
    /// `hour` local time. Cadence is a signal the show detector reads, so the
    /// fixtures have to post on real weekdays rather than at round intervals.
    static func recentDates(
        onWeekdays weekdays: Set<Int>,
        count: Int,
        hour: Int,
        calendar: Calendar = .current,
        from reference: Date = .now
    ) -> [Date] {
        var dates: [Date] = []
        var day = calendar.startOfDay(for: reference)
        // Two years of days is far more than any fixture needs; the bound is
        // there so a nonsense weekday set can't spin forever.
        var remainingDays = 730
        while dates.count < count, remainingDays > 0 {
            remainingDays -= 1
            if weekdays.contains(calendar.component(.weekday, from: day)),
               let stamped = calendar.date(byAdding: .hour, value: hour, to: day),
               stamped < reference {
                dates.append(stamped)
            }
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return dates
    }
}

// MARK: - Playlist-backed shows

/// Two shows that are playlists rather than channels, because a channel is not
/// always the unit a viewer thinks in.
///
/// - **Conan O'Brien Needs a Friend** — a podcast hosted on Team Coco, a
///   network channel that also puts out clips, tour footage and everything
///   else. The show is the playlist. It has no rule of its own: it appears in
///   Your Shows under Team Coco's Comedy and Podcasts & Interviews chips
///   because it inherits them, which is the whole point.
/// - **Quizmaster** — a series-based show with a playlist per series, so its
///   page offers a season picker. Its channel is deliberately not a show:
///   Quizmaster Extra's uploads are outtakes and trailers, and only the three
///   series playlists are the programme.
///
/// Membership is recorded the way a refresh records it — `addPlaylistShow`
/// then `setPlaylistItems`, the same two calls `FeedRefresher
/// .refreshMembership` makes — so a fixture run exercises the stored path
/// without a network call.
extension DebugFixtures {
    private struct PlaylistSeason {
        var playlistId: String
        var name: String
        /// Episodes newest first, with their durations.
        var episodes: [(title: String, seconds: Int)]
        /// Weekdays the series aired on, `Calendar` numbering (1 = Sunday).
        var weekdays: Set<Int>
        /// Weeks back the series finished, so season 1 is older than season 3.
        var weeksAgo: Int
        /// How many of the newest episodes are left unwatched.
        var unwatched: Int

        /// The IDs given to this season's episodes, newest first — the same
        /// derivation `playlistShowVideos()` uses, so membership and rows
        /// can't disagree.
        var videoIds: [String] {
            episodes.indices.map { "\(playlistId)-\($0)" }
        }
    }

    private struct PlaylistShow {
        var channelId: String
        var channelTitle: String
        /// Set when the channel isn't already a fixture subscription.
        var channelCategories: [String]?
        /// Records "not a show" against the channel itself, for a channel
        /// whose uploads are outtakes and trailers and whose programme is
        /// only in the playlists. Without it the detector would flag the
        /// channel too and the grid would carry the same thing twice.
        var channelIsNotAShow = false
        var title: String
        var seasons: [PlaylistSeason]
    }

    private static let playlistShows: [PlaylistShow] = [
        PlaylistShow(
            channelId: "UC-teamcoco",
            channelTitle: "Team Coco",
            title: "Conan O'Brien Needs a Friend",
            seasons: [
                PlaylistSeason(
                    playlistId: "PL-conanfriend",
                    name: "Conan O'Brien Needs a Friend",
                    episodes: [
                        ("Michelle Obama", 4_320),
                        ("Bob Odenkirk", 3_960),
                        ("Nicole Byer Returns", 4_140),
                        ("Paul Rudd", 3_720),
                        ("Sona's Wedding, One Year On", 4_500),
                        ("Timothy Olyphant", 3_840),
                    ],
                    weekdays: [2],
                    weeksAgo: 0,
                    unwatched: 3
                ),
            ]
        ),
        PlaylistShow(
            channelId: "UC-quizmaster",
            channelTitle: "Quizmaster Extra",
            channelCategories: ["Comedy"],
            channelIsNotAShow: true,
            title: "Quizmaster",
            seasons: [
                PlaylistSeason(
                    playlistId: "PL-quizmaster-s14",
                    name: "Series 14",
                    episodes: [
                        ("Series 14, Episode 5: A Very Small Hat", 3_000),
                        ("Series 14, Episode 4: Blow the Whistle", 2_880),
                        ("Series 14, Episode 3: An Egg of Sorts", 3_060),
                        ("Series 14, Episode 2: The Long Way Round", 2_940),
                        ("Series 14, Episode 1: Welcome Back", 3_120),
                    ],
                    weekdays: [5],
                    weeksAgo: 0,
                    unwatched: 4
                ),
                PlaylistSeason(
                    playlistId: "PL-quizmaster-s13",
                    name: "Series 13",
                    episodes: [
                        ("Series 13, Episode 5: The Final Reckoning", 2_820),
                        ("Series 13, Episode 4: Potato Diplomacy", 3_180),
                        ("Series 13, Episode 3: Sing It Backwards", 2_760),
                        ("Series 13, Episode 2: A Bucket of Water", 3_240),
                        ("Series 13, Episode 1: First Impressions", 2_880),
                    ],
                    weekdays: [5],
                    weeksAgo: 8,
                    unwatched: 0
                ),
                PlaylistSeason(
                    playlistId: "PL-quizmaster-s12",
                    name: "Series 12",
                    episodes: [
                        ("Series 12, Episode 5: Champion of Champions", 3_060),
                        ("Series 12, Episode 4: The Balloon Incident", 2_940),
                        ("Series 12, Episode 3: Tallest Tower", 3_000),
                        ("Series 12, Episode 2: Hidden Talents", 2_820),
                        ("Series 12, Episode 1: Meet the Five", 3_180),
                    ],
                    weekdays: [5],
                    weeksAgo: 16,
                    unwatched: 0
                ),
            ]
        ),
    ]

    /// Every playlist-backed show's episodes, season by season.
    private static func playlistShowVideos() -> [FixtureVideo] {
        let calendar = Calendar.current
        var result: [FixtureVideo] = []
        for entry in playlistShows {
            for season in entry.seasons {
                let dates = recentDates(
                    onWeekdays: season.weekdays,
                    count: season.episodes.count,
                    hour: 20,
                    calendar: calendar,
                    from: Date(timeIntervalSinceNow: -Double(season.weeksAgo) * 7 * 86_400)
                )
                for (index, episode) in season.episodes.enumerated() {
                    result.append(FixtureVideo(
                        id: "\(season.playlistId)-\(index)",
                        channelId: entry.channelId,
                        channelTitle: entry.channelTitle,
                        title: episode.title,
                        summary: "Fixture episode of \(entry.title).",
                        publishedAt: dates[index],
                        seconds: episode.seconds,
                        isWatched: index >= season.unwatched
                    ))
                }
            }
        }
        return result
    }

    /// Seeds the playlist-backed shows and the membership a refresh would
    /// have recorded. No `ChannelRule` is created for a show whose channel
    /// already has one: inheriting it is the behaviour on show.
    @MainActor
    private static func seedPlaylistShows(
        _ context: ModelContext,
        collections: [String: VideoCollection],
        shows: ShowManager
    ) throws {
        for entry in playlistShows {
            if let categories = entry.channelCategories {
                context.insert(Subscription(
                    channelId: entry.channelId,
                    title: entry.channelTitle,
                    channelDescription: "Fixture channel for \(entry.channelTitle)."
                ))
                let filed = categories.compactMap { collections[$0] }
                if !filed.isEmpty {
                    context.insert(ChannelRule(
                        channelId: entry.channelId,
                        channelTitle: entry.channelTitle,
                        collections: filed,
                        isUserSet: true
                    ))
                }
            }
            if entry.channelIsNotAShow {
                try shows.markAsNotAShow(
                    channelId: entry.channelId, channelTitle: entry.channelTitle
                )
            }

            let show = try shows.addPlaylistShow(
                entry.seasons.map { PlaylistChoice(playlistId: $0.playlistId, title: $0.name) },
                channelId: entry.channelId,
                title: entry.title
            )
            for season in entry.seasons {
                // Playlist order, which for a series is the order it aired:
                // oldest episode first, however the page lists them.
                try shows.setPlaylistItems(
                    season.videoIds.reversed(), playlistId: season.playlistId, of: show
                )
            }
        }
    }
}
#endif
