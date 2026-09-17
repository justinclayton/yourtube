import Foundation

/// Whether a video's thumbnail is pillarboxed — a vertical frame sitting in a
/// landscape image with YouTube's blurred side fill — which is the signal that
/// catches most untagged Shorts.
///
/// The one part of the Shorts verdict that leaves the process. `VideoIntake`
/// accepts it rather than owning it, so the store-writing door can be driven
/// from a test or from `DebugFixtures` without a network, and without
/// `URLProtocol` standing in for one.
///
/// `nil` for a video means no evidence either way, not "no". A download that
/// failed and an image that decoded to nothing are the same answer: leave the
/// video un-flagged rather than guess.
protocol ThumbnailVerdict: Sendable {
    func pillarboxed(videoIds: [String]) async -> [String: Bool?]
}

/// The app's adapter: downloads `hqdefault.jpg` for each ID and runs
/// `ThumbnailAnalyzer` over it.
///
/// Failures (offline, 404, undecodable) map to nil, so a refresh is never
/// failed by a thumbnail.
struct DownloadedThumbnailVerdict: ThumbnailVerdict {
    /// How many thumbnails are fetched at once. Matches the refresh's own
    /// ceiling on simultaneous connections to Google.
    static let maxConcurrentDownloads = 6

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func pillarboxed(videoIds: [String]) async -> [String: Bool?] {
        var results: [String: Bool?] = [:]
        let session = session

        for batch in videoIds.chunked(into: Self.maxConcurrentDownloads) {
            await withTaskGroup(of: (String, Bool?).self) { group in
                for id in batch {
                    group.addTask {
                        let url = ThumbnailAnalyzer.thumbnailURL(forVideoId: id)
                        guard let (data, response) = try? await session.data(from: url),
                              (response as? HTTPURLResponse)?.statusCode == 200
                        else { return (id, nil) }
                        // The video's own thumbnail is often this same
                        // hqdefault URL (the API's "high" quality); seeding
                        // it here means the feed row shows it without a
                        // second download. See `ImageCache`.
                        ImageCache.shared.seed(data: data, for: url)
                        return (id, ThumbnailAnalyzer.looksPillarboxed(imageData: data))
                    }
                }
                for await (id, verdict) in group { results[id] = verdict }
            }
        }
        return results
    }
}

/// The offline adapter: an answer decided in advance, for every caller that
/// has no network and no wish for one.
///
/// One canned adapter rather than one for tests and another for fixtures:
/// both want exactly this — name the videos whose thumbnails are pillarboxed,
/// and every other video's thumbnail says nothing. `DebugFixtures` uses it to
/// make its declared Shorts come out Shorts through the real heuristic, and
/// `VideoIntakeTests` uses it to reach every branch of the verdict without a
/// `URLProtocol`.
struct CannedThumbnailVerdict: ThumbnailVerdict {
    /// Video IDs whose thumbnail is pillarboxed. Anything else asked about
    /// answers nil: no evidence.
    var pillarboxedIds: Set<String>

    init(pillarboxedIds: Set<String> = []) {
        self.pillarboxedIds = pillarboxedIds
    }

    func pillarboxed(videoIds: [String]) async -> [String: Bool?] {
        Dictionary(uniqueKeysWithValues: videoIds.map { id in
            (id, pillarboxedIds.contains(id) ? true : Bool?.none)
        })
    }
}
