#if DEBUG
import Foundation
import SwiftData

/// A signed-out, populated store for exercising the UI on a simulator without
/// a Google login. Debug builds only.
///
/// Launch the app with the `-seedFixtures` argument (see `.claude/launch.json`
/// and README "Development loop") and it opens an in-memory container holding
/// a handful of subscriptions, categories, and videos instead of the real
/// store. Nothing is written to disk and no token is involved, so the
/// sign-in banner shows and refresh is disabled: exactly the "offline, signed
/// out" state local features like search have to work in.
///
/// The data is chosen to be awkward on purpose: diacritics, mixed case, a
/// channel name that also appears in another channel's titles, a prolific
/// channel to trip the daily cap, a few Shorts, two earmarked videos so
/// Up Next shows its two-column grid, and one left partway through so
/// Continue Watching has a card.
enum DebugFixtures {
    static let launchArgument = "-seedFixtures"

    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

    /// Placeholder OAuth values so a fixture run doesn't need `Config.plist`.
    static let config = AppConfig.Values(clientId: "fixtures", redirectScheme: "fixtures")

    @MainActor
    static func makeContainer() throws -> ModelContainer {
        let container = try ModelContainer(
            for: Video.self, Subscription.self, VideoCollection.self, ChannelRule.self, Show.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        try seed(container.mainContext)
        return container
    }

    private struct Channel {
        var id: String
        var title: String
        var categories: [String]
        var videos: [(title: String, hoursAgo: Double, seconds: Int, short: Bool)]
    }

    private static let channels: [Channel] = [
        Channel(id: "UC-teamcoco", title: "Team Coco", categories: ["Comedy", "Podcasts & Interviews"], videos: [
            ("Conan Visits Cuba", 3, 1260, false),
            ("Conan O'Brien Needs A Friend: Full Episode", 26, 3900, false),
            ("Conan tries the world's hottest wing #shorts", 27, 45, true),
        ]),
        Channel(id: "UC-beyonce", title: "Beyoncé", categories: ["Music & Audio Gear"], videos: [
            ("Café Sessions, Part 4", 5, 620, false),
            ("Rehearsal Diaries: São Paulo", 30, 780, false),
        ]),
        Channel(id: "UC-lmnc", title: "Look Mum No Computer", categories: ["Music & Audio Gear", "Makers & DIY"], videos: [
            ("Building a Synth From a Furby", 8, 1420, false),
            ("Modular jam in the bunker", 50, 900, false),
        ]),
        Channel(id: "UC-berlin", title: "Berlin Vlogs", categories: [], videos: [
            ("Straße walk in Kreuzberg", 12, 2400, false),
            ("Späti tour", 13, 60, true),
        ]),
        Channel(id: "UC-nasa", title: "NASA", categories: ["Priority", "Science & Explainers"], videos: [
            ("Artemis III launch briefing", 1, 5400, false),
            ("Mars weather this week", 2, 300, false),
            ("Space station timelapse", 4, 240, false),
            ("Live Q&A with the crew", 6, 4200, false),
            ("Rocket engine test #shorts", 7, 20, true),
        ]),
        Channel(id: "UC-conanfans", title: "Conan Clips Archive", categories: ["Comedy"], videos: [
            ("Late Night 1997: Triumph at Westminster", 100, 500, false),
        ]),
        // Every title carries the show name after a pipe and an episode
        // number, so the title cleaner has something to bite on signed out.
        Channel(id: "UC-blocks", title: "Blocks Podcast", categories: ["Podcasts & Interviews"], videos: [
            ("Ali Macofsky | Blocks Podcast w/ Neal Brennan | Ep. 214", 9, 4500, false),
            ("Mark Normand | Blocks Podcast w/ Neal Brennan | Ep. 213", 33, 4200, false),
            ("Bill Burr | Blocks Podcast w/ Neal Brennan | FULL EPISODE | Ep. 212", 58, 5100, false),
            ("Tig Notaro | Blocks Podcast w/ Neal Brennan | Ep. 211", 80, 3900, false),
        ]),
    ]

    /// Earmarked to Up Next, in this order. Neither is a channel's last
    /// video, which the seed marks watched.
    private static let upNext = ["UC-teamcoco-1", "UC-nasa-3"]

    /// Partway through, in seconds, so Continue Watching has something to
    /// show. Neither earmarked nor watched, so it's the section's own.
    private static let inProgress = ["UC-lmnc-0": 620.0]

    private static func seed(_ context: ModelContext) throws {
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
                context.insert(ChannelRule(
                    channelId: channel.id,
                    channelTitle: channel.title,
                    collections: filed,
                    isUserSet: true
                ))
            }
            for (index, video) in channel.videos.enumerated() {
                let videoId = "\(channel.id)-\(index)"
                let position = upNext.firstIndex(of: videoId)
                context.insert(Video(
                    videoId: videoId,
                    channelId: channel.id,
                    channelTitle: channel.title,
                    title: video.title,
                    videoDescription: "",
                    publishedAt: Date(timeIntervalSinceNow: -video.hoursAgo * 3600),
                    durationSeconds: video.seconds,
                    isLikelyShort: video.short,
                    isWatched: index == channel.videos.count - 1,
                    savedForLaterAt: position.map { Date(timeIntervalSinceNow: -Double($0 + 1) * 86_400) },
                    upNextOrder: position.map { $0 + 1 },
                    resumePositionSeconds: inProgress[videoId],
                    lastPlayedAt: inProgress[videoId].map { _ in Date(timeIntervalSinceNow: -7200) },
                    classifierVersion: ShortsHeuristic.version
                ))
            }
        }
        try seedShows(context, collections: collections, priority: priority)
        try context.save()
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
extension DebugFixtures {
    private struct ShowChannel {
        var id: String
        var title: String
        var categories: [String]
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
    ]

    /// Seeds the show-shaped channels, their videos, and the `Show` rows that
    /// put them in Your Shows. Flagged as the user would flag them by hand, so
    /// a fixture run shows the grid populated without anything automatic
    /// having to run.
    static func seedShows(
        _ context: ModelContext,
        collections: [String: VideoCollection],
        priority: VideoCollection
    ) throws {
        let calendar = Calendar.current
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
            context.insert(Show(
                source: .channel(id: channel.id),
                title: channel.title,
                flagOrigin: .user,
                override: .forceShow,
                playOrder: channel.playOrder
            ))

            let dates = recentDates(
                onWeekdays: channel.weekdays,
                count: channel.episodes.count,
                hour: channel.hour,
                calendar: calendar
            )
            for (index, episode) in channel.episodes.enumerated() {
                let date = dates[index]
                let watched = index >= channel.unwatched
                context.insert(fixtureVideo(
                    id: "\(channel.id)-e\(index)",
                    channel: channel,
                    title: dateStamped(episode.title, date: date, calendar: calendar),
                    publishedAt: date,
                    seconds: episode.seconds,
                    isWatched: watched
                ))
                // Segments land through the evening after the full episode.
                for (offset, segment) in channel.segments.enumerated() {
                    context.insert(fixtureVideo(
                        id: "\(channel.id)-e\(index)s\(offset)",
                        channel: channel,
                        title: segment.title,
                        publishedAt: date.addingTimeInterval(Double(offset + 1) * 2_700),
                        seconds: segment.seconds,
                        isWatched: watched
                    ))
                }
            }
        }
    }

    private static func fixtureVideo(
        id: String,
        channel: ShowChannel,
        title: String,
        publishedAt: Date,
        seconds: Int,
        isWatched: Bool
    ) -> Video {
        Video(
            videoId: id,
            channelId: channel.id,
            channelTitle: channel.title,
            title: title,
            videoDescription: "Fixture episode of \(channel.title).",
            publishedAt: publishedAt,
            durationSeconds: seconds,
            isLikelyShort: false,
            isWatched: isWatched,
            classifierVersion: ShortsHeuristic.version
        )
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
#endif

