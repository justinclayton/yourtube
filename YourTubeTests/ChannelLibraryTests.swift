import XCTest
import SwiftData
@testable import YourTube

/// Two channels stood up side by side: each gets its own store, defaults
/// suite and Keychain entry, the quota is shared, and a sign-in opens the
/// returned channel's data whichever was open before.
@MainActor
final class ChannelLibraryTests: XCTestCase {
    private let alpha = ChannelIdentity(id: "UC-alpha", title: "Alpha")
    private let beta = ChannelIdentity(id: "UC-beta", title: "Beta")
    private let config = AppConfig.Values(clientId: "tests", redirectScheme: "tests")

    private var root: URL!
    private var directoryDefaults: UserDefaults!
    private var directorySuite: String!
    private var keychain: InMemorySecretStore!
    private var quota: QuotaTracker!
    private var quotaSuite: String!
    /// What the stub identifier answers for the next token it is shown.
    private var identifies: ChannelIdentity!

    override func setUp() async throws {
        let unique = UUID().uuidString
        root = FileManager.default.temporaryDirectory.appending(path: "ChannelLibraryTests-\(unique)")
        directorySuite = "ChannelLibraryTests.directory.\(unique)"
        directoryDefaults = UserDefaults(suiteName: directorySuite)
        quotaSuite = "ChannelLibraryTests.quota.\(unique)"
        quota = QuotaTracker(defaults: UserDefaults(suiteName: quotaSuite)!)
        keychain = InMemorySecretStore()
        identifies = alpha
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        directoryDefaults.removePersistentDomain(forName: directorySuite)
        UserDefaults.standard.removePersistentDomain(forName: quotaSuite)
        for location in [LibraryLocation.legacy, .channel(alpha.id), .channel(beta.id)] {
            if let suite = location.defaultsSuiteName {
                UserDefaults.standard.removePersistentDomain(forName: suite)
            }
        }
    }

    private func makeAuth() -> AuthController {
        AuthController(
            config: config,
            directory: ChannelDirectory(defaults: directoryDefaults),
            keychain: keychain,
            // Answers nothing, so sign-out's revoke never reaches Google.
            session: StubURLProtocol.session(),
            identify: { [unowned self] _ in identifies }
        )
    }

    private func open(_ location: LibraryLocation, auth: AuthController) throws -> ChannelLibrary {
        try .open(location, root: root, auth: auth, quota: quota)
    }

    private func tokens(_ name: String) -> GoogleOAuth.Tokens {
        .init(accessToken: "access-\(name)", refreshToken: "refresh-\(name)", expiresAt: .now + 3600)
    }

    private func insertVideo(_ id: String, into library: ChannelLibrary) -> Video {
        let video = Video(
            videoId: id, channelId: "UC-shared", channelTitle: "Shared", title: id,
            videoDescription: "", publishedAt: .now, durationSeconds: 600
        )
        library.container.mainContext.insert(video)
        return video
    }

    private func videos(in library: ChannelLibrary) throws -> [Video] {
        try library.container.mainContext.fetch(FetchDescriptor<Video>())
    }

    // MARK: - Directory

    func testFirstChannelClaimsTheLegacyLocationAndLaterOnesGetTheirOwn() {
        let directory = ChannelDirectory(defaults: directoryDefaults)
        XCTAssertNil(directory.legacyOwnerId)

        directory.record(alpha)
        directory.record(beta)
        directory.record(ChannelIdentity(id: alpha.id, title: "Alpha renamed"))

        XCTAssertEqual(directory.location(of: alpha.id), .legacy)
        XCTAssertEqual(directory.location(of: beta.id), .channel(beta.id))
        XCTAssertEqual(directory.known.map(\.title), ["Alpha renamed", "Beta"])
    }

    func testLegacyLocationKeepsTheExistingKeychainKeyAndDefaults() {
        XCTAssertEqual(LibraryLocation.legacy.refreshTokenKey, "refresh_token")
        XCTAssertNil(LibraryLocation.legacy.defaultsSuiteName)
        XCTAssertNil(LibraryLocation.legacy.storeURL(in: root))

        let channel = LibraryLocation.channel(beta.id)
        XCTAssertNotEqual(channel.refreshTokenKey, LibraryLocation.legacy.refreshTokenKey)
        XCTAssertNotNil(channel.defaultsSuiteName)
        XCTAssertNotNil(channel.storeURL(in: root))
    }

    // MARK: - A store per channel

    func testANewChannelOpensEmptyWithDefaultPreferences() throws {
        let auth = makeAuth()
        let alphaLibrary = try open(.channel(alpha.id), auth: auth)
        _ = insertVideo("v1", into: alphaLibrary)
        try alphaLibrary.container.mainContext.save()
        alphaLibrary.defaults.set(5, forKey: SettingsKeys.channelDailyCap)

        let betaLibrary = try open(.channel(beta.id), auth: auth)

        XCTAssertEqual(try videos(in: betaLibrary).count, 0)
        XCTAssertNil(betaLibrary.defaults.object(forKey: SettingsKeys.channelDailyCap))
        XCTAssertEqual(try videos(in: alphaLibrary).count, 1)
    }

    func testReopeningAChannelShowsExactlyItsPreviousData() throws {
        let auth = makeAuth()
        do {
            let library = try open(.channel(alpha.id), auth: auth)
            let video = insertVideo("v1", into: library)
            try library.services.watchState.earmark(video)
            try library.container.mainContext.save()
            library.defaults.set(4, forKey: SettingsKeys.channelDailyCap)
        }
        do {
            let other = try open(.channel(beta.id), auth: auth)
            _ = insertVideo("v2", into: other)
            try other.container.mainContext.save()
        }

        let reopened = try open(.channel(alpha.id), auth: auth)
        let stored = try videos(in: reopened)
        XCTAssertEqual(stored.map(\.videoId), ["v1"])
        XCTAssertNotNil(stored.first?.upNextOrder)
        XCTAssertEqual(reopened.defaults.integer(forKey: SettingsKeys.channelDailyCap), 4)
    }

    func testASharedVideoHasIndependentWatchStateInEachChannel() throws {
        let auth = makeAuth()
        let alphaLibrary = try open(.channel(alpha.id), auth: auth)
        let betaLibrary = try open(.channel(beta.id), auth: auth)
        let inAlpha = insertVideo("shared", into: alphaLibrary)
        let inBeta = insertVideo("shared", into: betaLibrary)

        try alphaLibrary.services.watchState.markWatched(inAlpha)
        try betaLibrary.services.watchState.earmark(inBeta)
        betaLibrary.services.watchState.record(inBeta, position: 120)
        try alphaLibrary.container.mainContext.save()
        try betaLibrary.container.mainContext.save()

        let alphaVideo = try XCTUnwrap(try videos(in: alphaLibrary).first)
        let betaVideo = try XCTUnwrap(try videos(in: betaLibrary).first)
        XCTAssertTrue(alphaVideo.isWatched)
        XCTAssertNil(alphaVideo.upNextOrder)
        XCTAssertNil(alphaVideo.resumePositionSeconds)
        XCTAssertFalse(betaVideo.isWatched)
        XCTAssertNotNil(betaVideo.upNextOrder)
        XCTAssertEqual(betaVideo.resumePositionSeconds, 120)
    }

    // MARK: - Quota stays global

    func testQuotaIsSharedAndNeverWrittenToAChannelSuite() throws {
        let auth = makeAuth()
        let alphaLibrary = try open(.channel(alpha.id), auth: auth)
        let betaLibrary = try open(.channel(beta.id), auth: auth)
        XCTAssertTrue(alphaLibrary.services.quota === betaLibrary.services.quota)

        alphaLibrary.services.quota.record(units: 3)
        betaLibrary.services.quota.record(units: 2)

        XCTAssertEqual(quota.unitsUsedToday, 5)
        XCTAssertNil(alphaLibrary.defaults.object(forKey: "quota.unitsUsed"))
        XCTAssertNil(betaLibrary.defaults.object(forKey: "quota.unitsUsed"))
    }

    // MARK: - Sign-in opens the returned channel

    func testSignInOpensTheReturnedChannelAndSignOutClosesIt() async throws {
        let auth = makeAuth()
        XCTAssertEqual(auth.location, .legacy)
        var opened: [LibraryLocation?] = []
        auth.onLocationChange = { opened.append(auth.location) }

        identifies = alpha
        try await auth.adopt(tokens("alpha"))
        XCTAssertEqual(auth.channel, alpha)
        XCTAssertEqual(auth.location, .legacy)
        XCTAssertEqual(keychain.get(LibraryLocation.legacy.refreshTokenKey), "refresh-alpha")

        await auth.signOut()
        XCTAssertNil(auth.channel)
        XCTAssertNil(auth.location)
        XCTAssertEqual(auth.state, .signedOut)

        identifies = beta
        try await auth.adopt(tokens("beta"))
        XCTAssertEqual(auth.location, .channel(beta.id))
        XCTAssertEqual(keychain.get(LibraryLocation.channel(beta.id).refreshTokenKey), "refresh-beta")

        // Alpha claimed the legacy data already on screen, so only sign-out
        // and Beta swapped the library.
        XCTAssertEqual(opened, [nil, .channel(beta.id)])
    }

    /// The weekly re-sign-in coming back as another channel used to be
    /// refused; now it opens that channel, and the library that was open is
    /// never handed the new channel's token.
    func testReSignInAsAnotherChannelCannotFeedThePreviousLibrary() async throws {
        // Some other channel already owns the legacy store, so both of these
        // open stores under the test's root rather than the host app's.
        ChannelDirectory(defaults: directoryDefaults).record(ChannelIdentity(id: "UC-legacy", title: "Legacy"))
        let auth = makeAuth()
        identifies = alpha
        try await auth.adopt(tokens("alpha"))
        let alphaLocation = try XCTUnwrap(auth.location)
        XCTAssertEqual(alphaLocation, .channel(alpha.id))
        let alphaLibrary = try open(alphaLocation, auth: auth)

        identifies = beta
        try await auth.adopt(tokens("beta"))

        XCTAssertEqual(auth.channel, beta)
        do {
            _ = try await auth.validAccessToken(for: alphaLocation)
            XCTFail("The previous channel's library must not get a token")
        } catch is AuthController.ChannelClosed {}
        let betaToken = try await auth.validAccessToken(for: .channel(beta.id))
        XCTAssertEqual(betaToken, "access-beta")
        XCTAssertEqual(try videos(in: alphaLibrary).count, 0)
    }

    func testAKnownChannelSigningInAgainReopensItsOwnLocation() async throws {
        let auth = makeAuth()
        identifies = alpha
        try await auth.adopt(tokens("alpha"))
        identifies = beta
        try await auth.adopt(tokens("beta"))
        identifies = alpha
        try await auth.adopt(tokens("alpha-again"))

        XCTAssertEqual(auth.location, .legacy)
        // Relaunching reopens the same channel, behind the sign-in banner
        // until the token is tried.
        let relaunched = makeAuth()
        XCTAssertEqual(relaunched.channel, alpha)
        XCTAssertEqual(relaunched.location, .legacy)
        XCTAssertEqual(relaunched.state, .expired)
    }

    func testUnclaimedLegacyDataStaysOpenWithoutASession() {
        let auth = makeAuth()
        XCTAssertEqual(auth.location, .legacy)
        XCTAssertEqual(auth.state, .signedOut)
    }

    func testAnUnidentifiedLegacySessionOpensTheLegacyLocation() throws {
        try keychain.set("legacy-refresh", for: LibraryLocation.legacyRefreshTokenKey)
        let auth = makeAuth()
        XCTAssertEqual(auth.location, .legacy)
        XCTAssertNil(auth.channel)
        XCTAssertEqual(auth.state, .expired)
    }

    func testSessionSwapsLibraryWhenTheChannelChanges() async throws {
        ChannelDirectory(defaults: directoryDefaults).record(ChannelIdentity(id: "UC-legacy", title: "Legacy"))
        let auth = makeAuth()
        let session = AppSession(auth: auth, quota: quota) { [unowned self] location in
            try self.open(location ?? .channel("signed-out"), auth: auth)
        }
        let first = try session.library.get()
        identifies = beta
        try await auth.adopt(tokens("beta"))
        let second = try session.library.get()
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(second.location, .channel(beta.id))
    }

    // MARK: - Identifying the channel

    func testAuthorizeRequestOffersTheChannelPicker() {
        let items = GoogleOAuth.authorizeQueryItems(
            config: config, challenge: "c", challengeMethod: "S256", state: "s"
        )
        XCTAssertEqual(items.first { $0.name == "prompt" }?.value, "consent select_account")
        XCTAssertEqual(items.first { $0.name == "access_type" }?.value, "offline")
    }

    func testMyChannelDecodesTheChannelAndCountsQuota() async throws {
        StubURLProtocol.reset()
        defer { StubURLProtocol.reset() }
        StubURLProtocol.stub(matching: "channels", json: """
        { "items": [ { "id": "UC-alpha", "snippet": { "title": "Alpha" } } ] }
        """)
        let api = YouTubeAPI(session: StubURLProtocol.session(), quota: quota) { "token" }

        let channel = try await api.myChannel()

        XCTAssertEqual(channel, alpha)
        XCTAssertEqual(quota.unitsUsedToday, 1)
        let url = try XCTUnwrap(StubURLProtocol.recordedRequests.first?.url?.absoluteString)
        XCTAssertTrue(url.contains("mine=true"))
    }
}

/// Stands in for the Keychain, which an unsigned CI build can't reach.
final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private var values: [String: String] = [:]

    func set(_ value: String?, for key: String) throws { values[key] = value }
    func get(_ key: String) -> String? { values[key] }
    func remove(_ key: String) throws { values[key] = nil }
}
