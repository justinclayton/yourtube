import SwiftUI
import SwiftData

@main
struct YourTubeApp: App {
    /// Config is loaded once at launch. If it's missing we show setup
    /// instructions rather than crashing, since a fresh clone won't have it.
    private let session: Result<AppSession, Error>

    init() {
        session = MainActor.assumeIsolated {
            Result {
                #if DEBUG
                if DebugFixtures.isRequested {
                    return try DebugFixtures.makeSession()
                }
                #endif
                return AppSession.live(config: try AppConfig.load())
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            switch session {
            case .success(let session):
                ChannelLibraryView(session: session)
            case .failure(let error):
                SetupInstructionsView(error: error)
            }
        }
    }
}

/// Shows whichever channel's library is open, rebuilding the whole view tree
/// when a sign-in or sign-out swaps it, so nothing keeps reading the
/// previous channel's store or settings.
private struct ChannelLibraryView: View {
    let session: AppSession

    var body: some View {
        switch session.library {
        case .success(let library):
            RootView()
                .modelContainer(library.container)
                .environment(library.services)
                .defaultAppStorage(library.defaults)
                .id(library.id)
        case .failure(let error):
            SetupInstructionsView(error: error)
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
    let watchState: WatchState
    let titles: TitleCleaner
    let shows: ShowManager
    let showDetector: ShowDetectionRunner

    /// - Parameters:
    ///   - defaults: the open channel's suite. `quota` is shared across
    ///     channels and never reads it.
    ///   - tokenProvider: hands out tokens for this library's channel only;
    ///     see `AuthController.validAccessToken(for:)`.
    init(
        modelContext: ModelContext,
        defaults: UserDefaults,
        auth: AuthController,
        quota: QuotaTracker,
        tokenProvider: @escaping YouTubeAPI.TokenProvider
    ) {
        // One writer for every background pass, so the passes that overlap at
        // launch share a context instead of colliding over a row. See
        // `StoreWriter`.
        let writer = StoreWriter(modelContainer: modelContext.container)
        let api = YouTubeAPI(quota: quota, tokenProvider: tokenProvider)
        self.auth = auth
        self.quota = quota
        self.api = api
        let feed = FeedRefresher(modelContext: modelContext, api: api, writer: writer)
        self.feed = feed
        self.categories = CategoryManager(
            modelContext: modelContext,
            categorizer: ChannelCategorizerFactory.makeSystemCategorizer(),
            defaults: defaults,
            writer: writer
        )
        let watchState = WatchState(modelContext: modelContext)
        self.watchState = watchState
        self.shows = ShowManager(modelContext: modelContext, watchState: watchState)
        self.titles = TitleCleaner(
            modelContext: modelContext,
            rewriter: TitleRewriterFactory.makeSystemRewriter(),
            defaults: defaults,
            writer: writer,
            isRefreshingProvider: { [weak feed] in feed?.isRefreshing ?? false }
        )
        self.showDetector = ShowDetectionRunner(
            modelContext: modelContext, defaults: defaults, writer: writer
        )
    }
}
