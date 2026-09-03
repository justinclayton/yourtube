import Foundation
import AuthenticationServices
import UIKit

/// Google OAuth 2.0 authorization-code + PKCE flow for a native iOS app.
///
/// Uses `ASWebAuthenticationSession` rather than an embedded `WKWebView` —
/// Google rejects webview-based consent with `disallowed_useragent`.
///
/// Note on token lifetime: while the Google Cloud consent screen is in
/// "Testing" mode, refresh tokens expire after 7 days. Moving to production
/// would require YouTube's annual sensitive-scope audit, which isn't realistic
/// for a personal app, so re-auth roughly weekly is expected behaviour here —
/// see `AuthController` for how that surfaces in the UI.
@MainActor
final class GoogleOAuth: NSObject {
    struct Tokens {
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date
    }

    enum OAuthError: LocalizedError {
        case cancelled
        case missingCode
        case tokenExchangeFailed(String)
        case refreshFailed(String)
        case noRefreshToken

        var errorDescription: String? {
            switch self {
            case .cancelled:
                return "Sign-in was cancelled."
            case .missingCode:
                return "Google didn't return an authorization code."
            case .tokenExchangeFailed(let detail):
                return "Couldn't exchange the authorization code: \(detail)"
            case .refreshFailed(let detail):
                return "Couldn't refresh the session: \(detail)"
            case .noRefreshToken:
                return "No stored session. Please sign in again."
            }
        }
    }

    static let authEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    static let revokeEndpoint = URL(string: "https://oauth2.googleapis.com/revoke")!

    /// Read-only is all we need: subscriptions and playlist reads. Collections
    /// and Watch Later are stored on-device, so we never write to YouTube.
    static let scopes = ["https://www.googleapis.com/auth/youtube.readonly"]

    private let config: AppConfig.Values
    private let session: URLSession

    init(config: AppConfig.Values, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    // MARK: - Interactive sign-in

    func signIn() async throws -> Tokens {
        let pkce = PKCE()
        let state = PKCE.randomVerifier()
        let callback = try await presentConsent(pkce: pkce, state: state)

        guard let components = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              let items = components.queryItems else {
            throw OAuthError.missingCode
        }
        guard items.first(where: { $0.name == "state" })?.value == state else {
            throw OAuthError.tokenExchangeFailed("State mismatch — possible interception.")
        }
        guard let code = items.first(where: { $0.name == "code" })?.value else {
            let reason = items.first(where: { $0.name == "error" })?.value ?? "unknown"
            throw OAuthError.tokenExchangeFailed(reason)
        }

        return try await exchange(code: code, verifier: pkce.verifier)
    }

    private func presentConsent(pkce: PKCE, state: String) async throws -> URL {
        var components = URLComponents(url: Self.authEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "client_id", value: config.clientId),
            .init(name: "redirect_uri", value: config.redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: Self.scopes.joined(separator: " ")),
            .init(name: "code_challenge", value: pkce.challenge),
            .init(name: "code_challenge_method", value: pkce.method),
            .init(name: "state", value: state),
            // Required to get a refresh token back at all.
            .init(name: "access_type", value: "offline"),
            // Without this, Google only returns a refresh token on the very
            // first consent — which makes re-auth after expiry silently useless.
            .init(name: "prompt", value: "consent"),
        ]

        let url = components.url!

        return try await withCheckedThrowingContinuation { continuation in
            let authSession = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: config.redirectScheme
            ) { callbackURL, error in
                if let error {
                    let nsError = error as NSError
                    if nsError.domain == ASWebAuthenticationSessionErrorDomain,
                       nsError.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                        continuation.resume(throwing: OAuthError.cancelled)
                    } else {
                        continuation.resume(throwing: error)
                    }
                    return
                }
                guard let callbackURL else {
                    continuation.resume(throwing: OAuthError.missingCode)
                    return
                }
                continuation.resume(returning: callbackURL)
            }
            authSession.presentationContextProvider = self
            // Release: don't reuse Safari's cookies, so the app's session stays
            // separate from whatever Google account is signed in on the web.
            // Debug: keep them, so re-auth in the simulator is a tap on the
            // remembered account instead of a full password + 2FA round trip.
            #if DEBUG
            authSession.prefersEphemeralWebBrowserSession = false
            #else
            authSession.prefersEphemeralWebBrowserSession = true
            #endif
            authSession.start()
        }
    }

    // MARK: - Token endpoints

    private func exchange(code: String, verifier: String) async throws -> Tokens {
        let body = [
            "client_id": config.clientId,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": config.redirectURI,
        ]
        do {
            return try await postForm(body)
        } catch let error as OAuthError {
            throw error
        } catch {
            throw OAuthError.tokenExchangeFailed(error.localizedDescription)
        }
    }

    func refresh(refreshToken: String) async throws -> Tokens {
        let body = [
            "client_id": config.clientId,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ]
        do {
            var tokens = try await postForm(body)
            // Google omits refresh_token on refresh responses; keep the old one.
            if tokens.refreshToken == nil { tokens.refreshToken = refreshToken }
            return tokens
        } catch {
            throw OAuthError.refreshFailed(error.localizedDescription)
        }
    }

    func revoke(token: String) async {
        var request = URLRequest(url: Self.revokeEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "token=\(token)".data(using: .utf8)
        // Best-effort: if this fails the local token is discarded anyway.
        _ = try? await session.data(for: request)
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Int

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
        }
    }

    private struct ErrorResponse: Decodable {
        let error: String?
        let errorDescription: String?

        enum CodingKeys: String, CodingKey {
            case error
            case errorDescription = "error_description"
        }
    }

    private func postForm(_ fields: [String: String]) async throws -> Tokens {
        var request = URLRequest(url: Self.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var components = URLComponents()
        components.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw OAuthError.tokenExchangeFailed("No HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let decoded = try? JSONDecoder().decode(ErrorResponse.self, from: data)
            let detail = decoded?.errorDescription ?? decoded?.error ?? "HTTP \(http.statusCode)"
            throw OAuthError.tokenExchangeFailed(detail)
        }

        let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        return Tokens(
            accessToken: decoded.accessToken,
            refreshToken: decoded.refreshToken,
            // Shave 60s off so we refresh slightly early rather than racing an
            // in-flight request against expiry.
            expiresAt: Date().addingTimeInterval(TimeInterval(decoded.expiresIn - 60))
        )
    }
}

extension GoogleOAuth: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        return scene?.keyWindow ?? ASPresentationAnchor()
    }
}
