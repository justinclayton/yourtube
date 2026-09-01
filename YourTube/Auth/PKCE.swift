import Foundation
import CryptoKit

/// PKCE (RFC 7636) parameters for the OAuth authorization code flow.
///
/// Native apps can't keep a client secret, so PKCE is what stops an attacker
/// who intercepts the redirect from redeeming the authorization code.
struct PKCE {
    let verifier: String
    let challenge: String
    let method = "S256"

    init() {
        verifier = Self.randomVerifier()
        challenge = Self.challenge(for: verifier)
    }

    /// RFC 7636 requires 43–128 chars from the unreserved set. 32 random bytes
    /// base64url-encoded lands at 43.
    static func randomVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URLEncode(Data(bytes))
    }

    static func challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URLEncode(Data(digest))
    }

    static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
