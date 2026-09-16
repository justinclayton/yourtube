import Foundation

/// A category suggestion drawn from YouTube's own per-video `categoryId`,
/// with a reason the user can read.
struct YouTubeCategorySuggestion: Sendable, Equatable {
    var categoryName: String
    var reason: String
}

/// Turns a channel's stored videos into a taxonomy category, purely from the
/// `categoryId` the uploader chose on each one — no model call, no store or
/// SwiftData dependency, in the shape of `ShowDetector`: evidence in,
/// optional verdict out.
///
/// YouTube's uploader-chosen category is a real signal for channels that sit
/// squarely in one of its topics (a car channel's uploads are almost all
/// filed under Autos & Vehicles), so this only maps the categories that mean
/// something: `showCategoryNames`-style catch-alls like People & Blogs,
/// Entertainment, and Education are what an uploader picks when nothing else
/// fits, so a channel voting for one of those says nothing about its actual
/// topic and gets no suggestion at all.
///
/// This is the signal alone. Wiring it into the on-device classifier
/// (`ChannelCategorizer`) is a separate change.
enum YouTubeCategorySignal {
    /// YouTube's numeric category id (`snippet.categoryId`) mapped onto the
    /// app's default taxonomy name. Only categories with an unambiguous home
    /// are listed; everything else — including the catch-alls uploaders use
    /// as defaults — maps to nothing.
    static let taxonomyByYouTubeCategoryId: [String: String] = [
        "1": "Film & TV",             // Film & Animation
        "2": "Cars",                  // Autos & Vehicles
        "10": "Music & Audio Gear",   // Music
        "20": "Games",                // Gaming
        "23": "Comedy",               // Comedy
        "25": "News & Politics",      // News & Politics
        "26": "Makers & DIY",         // Howto & Style
        "28": "Tech & Engineering",   // Science & Technology
    ]

    /// YouTube's own name for each id above, for the reason text.
    static let youtubeCategoryNames: [String: String] = [
        "1": "Film & Animation",
        "2": "Autos & Vehicles",
        "10": "Music",
        "20": "Gaming",
        "23": "Comedy",
        "25": "News & Politics",
        "26": "Howto & Style",
        "28": "Science & Technology",
    ]

    /// Share of voting videos the top category must clear. Simple majority,
    /// not a plurality: a channel split 40/35/25 across three categories
    /// isn't confidently anything.
    static let majorityShare = 0.5

    /// The suggested category, or nil when there's no clear majority, the
    /// majority category is a catch-all, no video has a stored category, or
    /// the target taxonomy name isn't in `taxonomy` (renamed or deleted).
    ///
    /// Videos with no stored `categoryId` (fetched before the field existed)
    /// don't vote; they're simply excluded rather than counting against the
    /// majority.
    static func suggestion(for videos: [EpisodeSignals], taxonomy: [String]) -> YouTubeCategorySuggestion? {
        let votes = videos.compactMap(\.categoryId)
        guard !votes.isEmpty else { return nil }

        let counts = votes.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        // Deterministic tie-break: highest count wins, ties broken by id so
        // the result never depends on dictionary iteration order.
        guard let top = counts.sorted(by: { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }).first
        else { return nil }

        guard Double(top.value) / Double(votes.count) > majorityShare else { return nil }
        guard let categoryName = taxonomyByYouTubeCategoryId[top.key], taxonomy.contains(categoryName) else { return nil }

        let youtubeName = youtubeCategoryNames[top.key] ?? categoryName
        return YouTubeCategorySuggestion(
            categoryName: categoryName,
            reason: "YouTube files most of its videos under \(youtubeName)"
        )
    }
}
