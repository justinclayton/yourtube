import SwiftUI
import SwiftData

@main
struct YourTubeApp: App {
    /// Config is loaded once at launch. If it's missing we show setup
    /// instructions rather than crashing, since a fresh clone won't have it.
    private let setup: Result<(container: ModelContainer, services: AppServices), Error>

    init() {
        setup = MainActor.assumeIsolated {
            Result {
                let config = try AppConfig.load()
                let container = try ModelContainer(
                    for: Video.self, Subscription.self,
                    VideoCollection.self, ChannelRule.self
                )
                let services = AppServices(
                    config: config,
                    modelContext: container.mainContext
                )
                return (container, services)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            switch setup {
            case .success(let (container, services)):
                RootView()
                    .modelContainer(container)
                    .environment(services)
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

    init(config: AppConfig.Values, modelContext: ModelContext) {
        let auth = AuthController(config: config)
        let quota = QuotaTracker()
        let api = YouTubeAPI(quota: quota) { [auth] in
            try await auth.validAccessToken()
        }
        self.auth = auth
        self.quota = quota
        self.api = api
        self.feed = FeedRefresher(modelContext: modelContext, api: api)
        self.categories = CategoryManager(
            modelContext: modelContext,
            categorizer: ChannelCategorizerFactory.makeSystemCategorizer()
        )
    }
}
