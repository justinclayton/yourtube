import Foundation
import Observation

/// Owns the app's authentication state, knows which YouTube channel it is
/// signed in as, and hands out valid access tokens.
///
/// The weekly re-auth constraint (Testing-mode refresh tokens expire after
/// 7 days) is deliberately surfaced as `needsReauth` rather than thrown at the
/// call site, so the feed can show a one-tap banner and keep displaying cached
/// videos instead of blocking behind a modal.
///
/// Each channel keeps its own data (see `ChannelLibrary`) and its own refresh
/// token, at the `LibraryLocation` the `ChannelDirectory` gives it. A sign-in
/// identifies the channel before anything is written, and opens that
/// channel's location whichever channel was open before. Tokens are handed
/// out per location, so a library can never be given another channel's token.
@Observable
@MainActor
final class AuthController {
    enum State: Equatable {
        case signedOut
        case signedIn
        /// We have a stored session but it's no longer usable.
        case expired
    }

    /// A library asked for a token for a channel that is no longer open.
    struct ChannelClosed: LocalizedError {
        var errorDescription: String? { "That channel is no longer open." }
    }

    /// Looks up the channel an access token belongs to.
    typealias Identifier = @MainActor (_ accessToken: String) async throws -> ChannelIdentity

    private(set) var state: State = .signedOut
    private(set) var lastError: String?
    private(set) var isWorking = false
    /// The open channel. `nil` when signed out, and also while a session from
    /// before channels were recorded is waiting to be identified.
    private(set) var channel: ChannelIdentity?
    /// Where the open channel's data lives, or `nil` when no channel is open.
    /// `.legacy` before any channel has been identified.
    private(set) var location: LibraryLocation?

    var needsReauth: Bool { state != .signedIn }

    /// Called whenever `location` changes, before anything observes the new
    /// state, so the app can open the matching library. See `AppSession`.
    var onLocationChange: (() -> Void)?

    private let keychain: KeychainStore
    private let oauth: GoogleOAuth
    private let directory: ChannelDirectory
    private let identify: Identifier

    private var accessToken: String?
    private var accessTokenExpiry: Date?
    /// Coalesces concurrent refreshes so a burst of feed requests triggers one
    /// token call, not one per request.
    private var refreshTask: Task<String, Error>?

    init(
        config: AppConfig.Values,
        directory: ChannelDirectory,
        keychain: KeychainStore = KeychainStore(),
        session: URLSession = .shared,
        identify: @escaping Identifier
    ) {
        self.keychain = keychain
        self.oauth = GoogleOAuth(config: config, session: session)
        self.directory = directory
        self.identify = identify

        if let active = directory.activeChannel {
            // Whether a stored token is still valid is only known once we try
            // to use it, so start at .expired either way. The channel's data
            // stays open behind the sign-in banner.
            channel = active
            location = directory.location(of: active.id)
            state = .expired
        } else if directory.legacyOwnerId == nil {
            // Data from before the app recorded channels, signed in or not.
            // It stays on screen as it always was. With a stored session, the
            // first token refresh identifies whose it is before anything else
            // gets a token; without one, the next sign-in claims it.
            location = .legacy
            state = keychain.get(LibraryLocation.legacyRefreshTokenKey) == nil ? .signedOut : .expired
        }
    }

    // MARK: - Sign in / out

    func signIn() async {
        isWorking = true
        lastError = nil
        defer { isWorking = false }

        do {
            let tokens = try await oauth.signIn()
            try await adopt(tokens)
        } catch GoogleOAuth.OAuthError.cancelled {
            // Not an error worth showing — the user chose to back out.
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Identifies the channel a fresh sign-in returned and opens it.
    ///
    /// Nothing is written until the channel is known: the refresh token goes
    /// under that channel's key, and the location switches to that channel's
    /// whichever was open before. The previously open library is never handed
    /// a token for the new channel; see `validAccessToken(for:)`.
    func adopt(_ tokens: GoogleOAuth.Tokens) async throws {
        let identity = try await identify(tokens.accessToken)
        directory.record(identity)
        let newLocation = directory.location(of: identity.id)
        if let refreshToken = tokens.refreshToken {
            try keychain.set(refreshToken, for: newLocation.refreshTokenKey)
        }
        refreshTask = nil
        accessToken = tokens.accessToken
        accessTokenExpiry = tokens.expiresAt
        directory.activeChannelId = identity.id
        channel = identity
        state = .signedIn
        open(newLocation)
    }

    /// Closes the open channel. Its data and other channels' data stay where
    /// they are; the next sign-in opens whichever channel is picked.
    func signOut() async {
        if let key = location?.refreshTokenKey {
            if let refreshToken = keychain.get(key) {
                await oauth.revoke(token: refreshToken)
            }
            try? keychain.remove(key)
        }
        accessToken = nil
        accessTokenExpiry = nil
        refreshTask = nil
        lastError = nil
        directory.activeChannelId = nil
        channel = nil
        state = .signedOut
        open(nil)
    }

    private func open(_ newLocation: LibraryLocation?) {
        guard newLocation != location else { return }
        location = newLocation
        onLocationChange?()
    }

    // MARK: - Token vending

    /// Returns a valid access token for the library at `requested`, refreshing
    /// if needed.
    ///
    /// Throws `ChannelClosed` if that library's channel isn't the open one,
    /// including when the channel changed while the token was being fetched,
    /// so a library left over from before a switch can't write another
    /// channel's data into its store.
    func validAccessToken(for requested: LibraryLocation) async throws -> String {
        guard requested == location else { throw ChannelClosed() }
        let token = try await validAccessToken()
        guard requested == location else { throw ChannelClosed() }
        return token
    }

    /// Returns a valid access token for the open channel, refreshing if needed.
    ///
    /// Throws `OAuthError.noRefreshToken` when interactive sign-in is required;
    /// callers should let that propagate and let the UI show the banner.
    func validAccessToken() async throws -> String {
        if let token = accessToken, let expiry = accessTokenExpiry, expiry > .now {
            return token
        }
        if let existing = refreshTask {
            return try await existing.value
        }
        guard let refreshing = location else { throw GoogleOAuth.OAuthError.noRefreshToken }

        let task = Task<String, Error> { [weak self] in
            guard let self else { throw GoogleOAuth.OAuthError.noRefreshToken }
            return try await self.performRefresh(for: refreshing)
        }
        refreshTask = task
        defer { if refreshTask == task { refreshTask = nil } }

        do {
            let token = try await task.value
            state = .signedIn
            return token
        } catch is ChannelClosed {
            throw ChannelClosed()
        } catch {
            // A failed refresh in Testing mode almost always means the 7-day
            // window lapsed. Drop the dead token so the UI stops retrying it.
            guard refreshing == location else { throw error }
            try? keychain.remove(refreshing.refreshTokenKey)
            accessToken = nil
            accessTokenExpiry = nil
            state = .expired
            throw error
        }
    }

    private func performRefresh(for refreshing: LibraryLocation) async throws -> String {
        guard let refreshToken = keychain.get(refreshing.refreshTokenKey) else {
            throw GoogleOAuth.OAuthError.noRefreshToken
        }
        let tokens = try await oauth.refresh(refreshToken: refreshToken)
        if channel == nil {
            // A session from before channels were recorded: find out whose
            // data the legacy location holds before any refresh can write.
            let identity = try await identify(tokens.accessToken)
            guard refreshing == location else { throw ChannelClosed() }
            directory.record(identity)
            directory.activeChannelId = identity.id
            channel = identity
        }
        // A sign-in as another channel landed while this was in flight.
        guard refreshing == location else { throw ChannelClosed() }
        accessToken = tokens.accessToken
        accessTokenExpiry = tokens.expiresAt
        return tokens.accessToken
    }
}
