import Foundation
import Observation

/// Owns the app's authentication state and hands out valid access tokens.
///
/// The weekly re-auth constraint (Testing-mode refresh tokens expire after
/// 7 days) is deliberately surfaced as `needsReauth` rather than thrown at the
/// call site, so the feed can show a one-tap banner and keep displaying cached
/// videos instead of blocking behind a modal.
@Observable
@MainActor
final class AuthController {
    enum State: Equatable {
        case signedOut
        case signedIn
        /// We have a stored session but it's no longer usable.
        case expired
    }

    private(set) var state: State = .signedOut
    private(set) var lastError: String?
    private(set) var isWorking = false

    var needsReauth: Bool { state != .signedIn }

    private let keychain: KeychainStore
    private let oauth: GoogleOAuth
    private let refreshTokenKey = "refresh_token"

    private var accessToken: String?
    private var accessTokenExpiry: Date?
    /// Coalesces concurrent refreshes so a burst of feed requests triggers one
    /// token call, not one per request.
    private var refreshTask: Task<String, Error>?

    init(config: AppConfig.Values, keychain: KeychainStore = KeychainStore()) {
        self.keychain = keychain
        self.oauth = GoogleOAuth(config: config)
        // A stored refresh token means we had a session; whether it is still
        // valid is only known once we try to use it, so start at .expired.
        self.state = keychain.get("refresh_token") == nil ? .signedOut : .expired
    }

    // MARK: - Sign in / out

    func signIn() async {
        isWorking = true
        lastError = nil
        defer { isWorking = false }

        do {
            let tokens = try await oauth.signIn()
            try apply(tokens)
            state = .signedIn
        } catch GoogleOAuth.OAuthError.cancelled {
            // Not an error worth showing — the user chose to back out.
        } catch {
            lastError = error.localizedDescription
        }
    }

    func signOut() async {
        if let refreshToken = keychain.get(refreshTokenKey) {
            await oauth.revoke(token: refreshToken)
        }
        try? keychain.remove(refreshTokenKey)
        accessToken = nil
        accessTokenExpiry = nil
        refreshTask = nil
        lastError = nil
        state = .signedOut
    }

    // MARK: - Token vending

    /// Returns a valid access token, refreshing if needed.
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

        let task = Task<String, Error> { [weak self] in
            guard let self else { throw GoogleOAuth.OAuthError.noRefreshToken }
            return try await self.performRefresh()
        }
        refreshTask = task
        defer { refreshTask = nil }

        do {
            let token = try await task.value
            state = .signedIn
            return token
        } catch {
            // A failed refresh in Testing mode almost always means the 7-day
            // window lapsed. Drop the dead token so the UI stops retrying it.
            try? keychain.remove(refreshTokenKey)
            accessToken = nil
            accessTokenExpiry = nil
            state = .expired
            throw error
        }
    }

    private func performRefresh() async throws -> String {
        guard let refreshToken = keychain.get(refreshTokenKey) else {
            throw GoogleOAuth.OAuthError.noRefreshToken
        }
        let tokens = try await oauth.refresh(refreshToken: refreshToken)
        try apply(tokens)
        return tokens.accessToken
    }

    private func apply(_ tokens: GoogleOAuth.Tokens) throws {
        accessToken = tokens.accessToken
        accessTokenExpiry = tokens.expiresAt
        if let refreshToken = tokens.refreshToken {
            try keychain.set(refreshToken, for: refreshTokenKey)
        }
    }
}
