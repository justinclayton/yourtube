import Foundation
import SwiftData

/// One channel's data, open: its store, its `UserDefaults` suite (which every
/// `@AppStorage` setting reads through `.defaultAppStorage`) and the services
/// over them.
///
/// Channels get separate stores rather than one store with a channel field on
/// every model: `Video.videoId` and `Subscription.channelId` are unique, a
/// compound uniqueness constraint needs iOS 18's `#Unique`, and tagging every
/// model would mean a channel filter on every `@Query`.
///
/// Only two things are shared across channels: the quota count, because
/// quota is per Google Cloud project, and the image cache, which is keyed by
/// URL. Both live outside this type.
@MainActor
final class ChannelLibrary: Identifiable {
    /// Distinct per opening, so the view tree is rebuilt whenever a library
    /// is swapped in, even for the same location.
    let id = UUID()
    /// `nil` for the empty library shown while no channel is open.
    let location: LibraryLocation?
    let container: ModelContainer
    let defaults: UserDefaults
    let services: AppServices

    init(
        location: LibraryLocation?,
        container: ModelContainer,
        defaults: UserDefaults,
        auth: AuthController,
        quota: QuotaTracker
    ) {
        self.location = location
        self.container = container
        self.defaults = defaults
        self.services = AppServices(
            modelContext: container.mainContext,
            defaults: defaults,
            auth: auth,
            quota: quota,
            tokenProvider: { [auth] in
                guard let location else { throw GoogleOAuth.OAuthError.noRefreshToken }
                return try await auth.validAccessToken(for: location)
            }
        )
    }

    /// Where `.channel` stores live: one directory per channel ID.
    nonisolated static var channelsRoot: URL {
        URL.applicationSupportDirectory.appending(path: "Channels", directoryHint: .isDirectory)
    }

    /// Opens the store and defaults at `location`, creating them empty for a
    /// channel the app hasn't seen.
    static func open(
        _ location: LibraryLocation,
        root: URL = channelsRoot,
        auth: AuthController,
        quota: QuotaTracker
    ) throws -> ChannelLibrary {
        let container: ModelContainer
        if let url = location.storeURL(in: root) {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            container = try ModelContainer(
                for: Video.self, Subscription.self,
                VideoCollection.self, ChannelRule.self, Show.self, ShowSuggestion.self,
                migrationPlan: VideoMigrationPlan.self,
                configurations: ModelConfiguration(url: url)
            )
        } else {
            // The legacy store, opened exactly as it was before channels.
            container = try ModelContainer(
                for: Video.self, Subscription.self,
                VideoCollection.self, ChannelRule.self, Show.self, ShowSuggestion.self,
                migrationPlan: VideoMigrationPlan.self
            )
        }
        let defaults = location.defaultsSuiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        return ChannelLibrary(
            location: location, container: container, defaults: defaults, auth: auth, quota: quota
        )
    }

    static let signedOutSuite = "net.claytons.yourtube.signedOut"

    /// An empty, in-memory library for when no channel is open, so the tabs
    /// show nothing behind the sign-in banner rather than any channel's data.
    static func signedOut(auth: AuthController, quota: QuotaTracker) throws -> ChannelLibrary {
        UserDefaults.standard.removePersistentDomain(forName: signedOutSuite)
        let container = try ModelContainer(
            for: Video.self, Subscription.self, VideoCollection.self, ChannelRule.self, Show.self, ShowSuggestion.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ChannelLibrary(
            location: nil,
            container: container,
            defaults: UserDefaults(suiteName: signedOutSuite)!,
            auth: auth,
            quota: quota
        )
    }
}

/// The app's long-lived state above any one channel: the sign-in, the shared
/// quota, and whichever channel's library is open.
@Observable
@MainActor
final class AppSession {
    let auth: AuthController
    let quota: QuotaTracker
    private(set) var library: Result<ChannelLibrary, Error>

    private let openLibrary: (LibraryLocation?) throws -> ChannelLibrary

    /// - Parameter openLibrary: opens the library for a location, or the
    ///   signed-out one for `nil`.
    init(
        auth: AuthController,
        quota: QuotaTracker,
        openLibrary: @escaping (LibraryLocation?) throws -> ChannelLibrary
    ) {
        self.auth = auth
        self.quota = quota
        self.openLibrary = openLibrary
        self.library = Result { try openLibrary(auth.location) }
        auth.onLocationChange = { [weak self] in self?.reopen() }
    }

    /// Swaps in the library for the auth's current location. The old
    /// library's container is released with it.
    private func reopen() {
        library = Result { try openLibrary(auth.location) }
    }

    /// The real app: channel stores under Application Support, quota on the
    /// standard defaults whichever channel is open.
    static func live(config: AppConfig.Values) -> AppSession {
        let quota = QuotaTracker(defaults: .standard)
        let auth = AuthController(
            config: config,
            directory: ChannelDirectory(defaults: .standard),
            identify: { token in
                try await YouTubeAPI(quota: quota) { token }.myChannel()
            }
        )
        return AppSession(auth: auth, quota: quota) { location in
            guard let location else { return try .signedOut(auth: auth, quota: quota) }
            return try .open(location, auth: auth, quota: quota)
        }
    }
}
