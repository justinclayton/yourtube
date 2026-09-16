import SwiftUI
import SwiftData

@main
struct YourTubeApp: App {
    /// Config is loaded once at launch. If it's missing we show setup
    /// instructions rather than crashing, since a fresh clone won't have it.
    private let setup: Result<Setup, Error>

    /// Everything a launch resolves once: the store, the services over it,
    /// and the `UserDefaults` those services and `@AppStorage` write to.
    private struct Setup {
        let container: ModelContainer
        let services: AppServices
        let defaults: UserDefaults
    }

    init() {
        setup = MainActor.assumeIsolated {
            Result {
                #if DEBUG
                if DebugFixtures.isRequested {
                    // A fixture run gets its own defaults suite as well as its
                    // own store, so nothing it does reaches the real account.
                    let container = try DebugFixtures.makeContainer()
                    let defaults = DebugFixtures.defaults
                    let services = AppServices(
                        config: DebugFixtures.config,
                        modelContext: container.mainContext,
                        defaults: defaults
                    )
                    // Manual verification hook for issue #68; no-op unless
                    // launched with -mutateFixtureTitle. See `DebugFixtures`.
                    DebugFixtures.scheduleTitleMutation(in: container.mainContext)
                    return Setup(container: container, services: services, defaults: defaults)
                }
                #endif
                let config = try AppConfig.load()
                let container = try ModelContainer(
                    for: Video.self, Subscription.self,
                    VideoCollection.self, ChannelRule.self, Show.self
                )
                let services = AppServices(
                    config: config,
                    modelContext: container.mainContext
                )
                return Setup(container: container, services: services, defaults: .standard)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            switch setup {
            case .success(let setup):
                RootView()
                    .modelContainer(setup.container)
                    .environment(setup.services)
                    .defaultAppStorage(setup.defaults)
            case .failure(let error):
                SetupInstructionsView(error: error)
            }
        }
    }
}

/// Wires the app's long-lived objects together in one place so views can pull
/// what they need out of the environment instead of constructing collaborators.
@Observable
@MainActor
final class AppServices {
    let auth: AuthController
    let quota: QuotaTracker
    let api: YouTubeAPI
    let feed: FeedRefresher
    let categories: CategoryManager
    let upNext: UpNextQueue
    let titles: TitleCleaner
    let playback: PlaybackProgress
    let shows: ShowManager
    let showDetector: ShowDetectionRunner

    init(config: AppConfig.Values, modelContext: ModelContext, defaults: UserDefaults = .standard) {
        // One writer for every background pass, so the passes that overlap at
        // launch share a context instead of colliding over a row. See
        // `StoreWriter`.
        let writer = StoreWriter(modelContainer: modelContext.container)
        let auth = AuthController(config: config)
        let quota = QuotaTracker(defaults: defaults)
        let api = YouTubeAPI(quota: quota) { [auth] in
            try await auth.validAccessToken()
        }
        self.auth = auth
        self.quota = quota
        self.api = api
        self.feed = FeedRefresher(modelContext: modelContext, api: api, writer: writer)
        self.categories = CategoryManager(
            modelContext: modelContext,
            categorizer: ChannelCategorizerFactory.makeSystemCategorizer(),
            defaults: defaults,
            writer: writer
        )
        let upNext = UpNextQueue(modelContext: modelContext)
        self.upNext = upNext
        self.shows = ShowManager(modelContext: modelContext)
        self.titles = TitleCleaner(
            modelContext: modelContext,
            rewriter: TitleRewriterFactory.makeSystemRewriter(),
            defaults: defaults,
            writer: writer
        )
        self.playback = PlaybackProgress(modelContext: modelContext, upNext: upNext)
        self.showDetector = ShowDetectionRunner(
            modelContext: modelContext, defaults: defaults, writer: writer
        )
    }
}
