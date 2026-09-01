import XCTest
@testable import YourTube

final class PKCETests: XCTestCase {
    func testVerifierMeetsRFC7636LengthRequirement() {
        for _ in 0..<20 {
            let verifier = PKCE.randomVerifier()
            XCTAssertGreaterThanOrEqual(verifier.count, 43)
            XCTAssertLessThanOrEqual(verifier.count, 128)
        }
    }

    func testVerifierUsesOnlyUnreservedCharacters() {
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let verifier = PKCE.randomVerifier()
        XCTAssertNil(
            verifier.rangeOfCharacter(from: allowed.inverted),
            "verifier contained a reserved character: \(verifier)"
        )
    }

    func testVerifiersAreNotRepeated() {
        let verifiers = Set((0..<100).map { _ in PKCE.randomVerifier() })
        XCTAssertEqual(verifiers.count, 100)
    }

    /// Known-answer test from RFC 7636 Appendix B.
    func testChallengeMatchesRFCExample() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        XCTAssertEqual(
            PKCE.challenge(for: verifier),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        )
    }

    func testBase64URLEncodingHasNoPaddingOrReservedCharacters() {
        let encoded = PKCE.base64URLEncode(Data([0xFB, 0xFF, 0xFE, 0x00]))
        XCTAssertFalse(encoded.contains("="))
        XCTAssertFalse(encoded.contains("+"))
        XCTAssertFalse(encoded.contains("/"))
    }
}
