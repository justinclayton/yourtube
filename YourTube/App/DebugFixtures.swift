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
/// channel to trip the daily cap, and a few Shorts.
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
            for: Video.self, Subscription.self, VideoCollection.self, ChannelRule.self,
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
    ]

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
                context.insert(Video(
                    videoId: "\(channel.id)-\(index)",
                    channelId: channel.id,
                    channelTitle: channel.title,
                    title: video.title,
                    videoDescription: "",
                    publishedAt: Date(timeIntervalSinceNow: -video.hoursAgo * 3600),
                    durationSeconds: video.seconds,
                    isLikelyShort: video.short,
                    isWatched: index == channel.videos.count - 1,
                    classifierVersion: ShortsHeuristic.version
                ))
            }
        }
        try context.save()
    }
}
#endif
