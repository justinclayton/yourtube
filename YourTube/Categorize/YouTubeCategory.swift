import Foundation

/// YouTube's own video category taxonomy (`Video.youtubeCategoryId`,
/// `snippet.categoryId` from the API) — a fixed, global list, not the
/// per-user one `CategoryManager` builds. Used only to show a channel's
/// dominant YouTube category alongside the classifier's guess, the way
/// `ShowDetector` reads it for its own two categories of interest.
enum YouTubeCategory {
    /// ID -> display name, from the `videoCategories.list` API (US locale;
    /// stable across regions for the IDs that actually show up in a feed).
    static let names: [String: String] = [
        "1": "Film & Animation",
        "2": "Autos & Vehicles",
        "10": "Music",
        "15": "Pets & Animals",
        "17": "Sports",
        "18": "Short Movies",
        "19": "Travel & Events",
        "20": "Gaming",
        "21": "Videoblogging",
        "22": "People & Blogs",
        "23": "Comedy",
        "24": "Entertainment",
        "25": "News & Politics",
        "26": "Howto & Style",
        "27": "Education",
        "28": "Science & Technology",
        "29": "Nonprofits & Activism",
        "30": "Movies",
        "31": "Anime/Animation",
        "32": "Action/Adventure",
        "33": "Classics",
        "34": "Comedy",
        "35": "Documentary",
        "36": "Drama",
        "37": "Family",
        "38": "Foreign",
        "39": "Horror",
        "40": "Sci-Fi/Fantasy",
        "41": "Thriller",
        "42": "Shorts",
        "43": "Shows",
        "44": "Trailers",
    ]

    /// The display name for a category ID, or the ID itself if unrecognised
    /// — YouTube adds categories occasionally, and some are region-specific.
    static func name(forId id: String) -> String {
        names[id] ?? "Category \(id)"
    }

    /// The most common ID among a channel's videos, ties broken by ID so the
    /// result is deterministic. Nil videos (stored before the field was
    /// fetched) don't vote. Nil result for no data at all.
    static func dominant(among categoryIds: [String?]) -> String? {
        let counts = categoryIds.compactMap { $0 }.reduce(into: [String: Int]()) {
            $0[$1, default: 0] += 1
        }
        let ranked = counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
        return ranked.first?.key
    }
}
