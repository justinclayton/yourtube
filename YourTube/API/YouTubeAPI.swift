import Foundation

/// Thin client over the YouTube Data API v3.
///
/// Only reads. Everything the app writes (collections, watch-later, watched
/// state) lives on-device, which keeps the OAuth scope at `youtube.readonly`.
///
/// The access token is supplied by a closure rather than a reference to
/// `AuthController` so this type can be exercised in tests with a stub session
/// and no auth stack at all.
struct YouTubeAPI: Sendable {
    typealias TokenProvider = @Sendable () async throws -> String

    enum APIError: LocalizedError {
        case http(status: Int, message: String)
        case quotaExceeded
        case unauthorized
        case malformedResponse

        var errorDescription: String? {
            switch self {
            case .http(let status, let message):
                return "YouTube API error \(status): \(message)"
            case .quotaExceeded:
                return "Daily YouTube API quota exhausted. It resets at midnight US Pacific."
            case .unauthorized:
                return "YouTube rejected the session. Please sign in again."
            case .malformedResponse:
                return "Couldn't read YouTube's response."
            }
        }
    }

    static let baseURL = URL(string: "https://www.googleapis.com/youtube/v3/")!
    /// videos.list accepts at most 50 IDs per call.
    static let maxIdsPerBatch = 50

    private let session: URLSession
    private let tokenProvider: TokenProvider
    private let quota: QuotaTracker?

    init(
        session: URLSession = .shared,
        quota: QuotaTracker? = nil,
        tokenProvider: @escaping TokenProvider
    ) {
        self.session = session
        self.quota = quota
        self.tokenProvider = tokenProvider
    }

    // MARK: - Endpoints

    /// All channels the signed-in user subscribes to. 1 quota unit per page of 50.
    func subscriptions() async throws -> [YT.SubscriptionItem] {
        try await allPages(
            path: "subscriptions",
            query: [
                "part": "snippet",
                "mine": "true",
                "maxResults": "50",
                "order": "alphabetical",
            ],
            cost: 1
        )
    }

    /// Most recent uploads for one channel. 1 quota unit.
    ///
    /// Note we hit the channel's uploads playlist rather than `search.list`,
    /// which would cost 100 units per call and make a full refresh unaffordable.
    func recentUploads(
        playlistId: String,
        limit: Int = 10
    ) async throws -> [YT.PlaylistItem] {
        let page: YT.PageResponse<YT.PlaylistItem> = try await get(
            path: "playlistItems",
            query: [
                "part": "snippet,contentDetails",
                "playlistId": playlistId,
                "maxResults": String(min(limit, 50)),
            ],
            cost: 1
        )
        return page.items
    }

    /// Hydrates video IDs with duration and full snippet. 1 unit per 50 IDs.
    func videos(ids: [String]) async throws -> [YT.VideoItem] {
        var results: [YT.VideoItem] = []
        for batch in stride(from: 0, to: ids.count, by: Self.maxIdsPerBatch) {
            let slice = Array(ids[batch..<min(batch + Self.maxIdsPerBatch, ids.count)])
            guard !slice.isEmpty else { continue }
            let page: YT.PageResponse<YT.VideoItem> = try await get(
                path: "videos",
                query: [
                    "part": "snippet,contentDetails",
                    "id": slice.joined(separator: ","),
                    "maxResults": String(Self.maxIdsPerBatch),
                ],
                cost: 1
            )
            results.append(contentsOf: page.items)
        }
        return results
    }

    // MARK: - Transport

    private func allPages<Item: Decodable>(
        path: String,
        query: [String: String],
        cost: Int,
        pageLimit: Int = 20
    ) async throws -> [Item] {
        var items: [Item] = []
        var pageToken: String?
        var pagesFetched = 0

        repeat {
            var pageQuery = query
            if let pageToken { pageQuery["pageToken"] = pageToken }

            let page: YT.PageResponse<Item> = try await get(
                path: path, query: pageQuery, cost: cost
            )
            items.append(contentsOf: page.items)
            pageToken = page.nextPageToken
            pagesFetched += 1
            // Belt-and-braces against a pagination bug looping on quota.
        } while pageToken != nil && pagesFetched < pageLimit

        return items
    }

    private func get<T: Decodable>(
        path: String,
        query: [String: String],
        cost: Int
    ) async throws -> T {
        var components = URLComponents(
            url: Self.baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = query
            .sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        let token = try await tokenProvider()
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        await MainActor.run { quota?.record(units: cost) }

        guard let http = response as? HTTPURLResponse else {
            throw APIError.malformedResponse
        }

        guard (200..<300).contains(http.statusCode) else {
            throw Self.error(status: http.statusCode, body: data)
        }

        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            throw APIError.malformedResponse
        }
    }

    private static func error(status: Int, body: Data) -> APIError {
        struct Envelope: Decodable {
            struct Inner: Decodable {
                struct Detail: Decodable { let reason: String? }
                let message: String?
                let errors: [Detail]?
            }
            let error: Inner?
        }

        let envelope = try? JSONDecoder().decode(Envelope.self, from: body)
        let reason = envelope?.error?.errors?.first?.reason
        let message = envelope?.error?.message ?? "Unknown error"

        if status == 401 { return .unauthorized }
        if reason == "quotaExceeded" || reason == "dailyLimitExceeded" {
            return .quotaExceeded
        }
        return .http(status: status, message: message)
    }

    /// YouTube emits RFC 3339 timestamps, sometimes with fractional seconds and
    /// sometimes without, so we try both rather than trusting one formatter.
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]

        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = withFraction.date(from: string) { return date }
            if let date = plain.date(from: string) { return date }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unrecognised date format: \(string)"
            )
        }
        return decoder
    }()
}
