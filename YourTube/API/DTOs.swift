import Foundation

/// Wire types for the YouTube Data API v3 responses we consume.
/// Deliberately partial — we decode only the fields the app uses.
enum YT {
    struct Thumbnail: Decodable {
        let url: String
        let width: Int?
        let height: Int?
    }

    struct Thumbnails: Decodable {
        let `default`: Thumbnail?
        let medium: Thumbnail?
        let high: Thumbnail?
        let standard: Thumbnail?
        let maxres: Thumbnail?

        /// Prefer the largest available, falling back down the ladder.
        var best: Thumbnail? { maxres ?? standard ?? high ?? medium ?? `default` }
    }

    struct PageResponse<Item: Decodable>: Decodable {
        let items: [Item]
        let nextPageToken: String?
    }

    // MARK: subscriptions.list

    struct SubscriptionItem: Decodable {
        let snippet: Snippet

        struct Snippet: Decodable {
            let title: String
            let resourceId: ResourceId
            let thumbnails: Thumbnails?
        }

        struct ResourceId: Decodable {
            let channelId: String?
        }
    }

    // MARK: playlistItems.list

    struct PlaylistItem: Decodable {
        let snippet: Snippet?
        let contentDetails: ContentDetails?

        struct Snippet: Decodable {
            let title: String?
            let description: String?
            let channelId: String?
            let videoOwnerChannelId: String?
            let videoOwnerChannelTitle: String?
            let thumbnails: Thumbnails?
            let resourceId: ResourceId?
        }

        struct ResourceId: Decodable {
            let videoId: String?
        }

        struct ContentDetails: Decodable {
            let videoId: String?
            let videoPublishedAt: Date?
        }

        var videoId: String? { contentDetails?.videoId ?? snippet?.resourceId?.videoId }
    }

    // MARK: videos.list

    struct VideoItem: Decodable {
        let id: String
        let snippet: Snippet?
        let contentDetails: ContentDetails?

        struct Snippet: Decodable {
            let title: String?
            let description: String?
            let channelId: String?
            let channelTitle: String?
            let publishedAt: Date?
            let thumbnails: Thumbnails?
        }

        struct ContentDetails: Decodable {
            /// ISO 8601, e.g. "PT4M13S". Absent for live streams.
            let duration: String?
        }
    }
}
