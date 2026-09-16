import Foundation

/// Everything the classifier gets to see about one channel.
struct ChannelDescriptor: Sendable, Equatable {
    var channelId: String
    var title: String
    var about: String
    /// Titles of recent uploads, newest first. Often the strongest signal —
    /// channel descriptions are frequently empty or just a sponsor blurb.
    var recentVideoTitles: [String]
    /// How YouTube itself files this channel, when its uploads have a clear
    /// majority category with a home in the taxonomy (`YouTubeCategorySignal`).
    /// Stated to the model as a prior, and the only source of a channel's
    /// second category. Nil when YouTube's own filing says nothing useful.
    var youtubeSignal: YouTubeCategorySuggestion?

    init(
        channelId: String,
        title: String,
        about: String,
        recentVideoTitles: [String],
        youtubeSignal: YouTubeCategorySuggestion? = nil
    ) {
        self.channelId = channelId
        self.title = title
        self.about = about
        self.recentVideoTitles = recentVideoTitles
        self.youtubeSignal = youtubeSignal
    }
}

/// What the classifier decided about one channel, and where each part of it
/// came from.
///
/// Since v4 a channel carries at most two topic categories: one the model
/// chose, and one YouTube's own filing supplied when it disagrees. Keeping
/// the two apart is the point — a wrong chip is visible, so the user needs to
/// see which half to blame.
struct CategoryGuess: Sendable, Equatable {
    /// Names from the list passed to `categorize`, the model's first.
    /// Empty if the model wouldn't commit; the channel then stays
    /// Uncategorised.
    var categories: [String]
    /// What the model actually said, verbatim — kept so a wrong answer can be
    /// understood rather than just overturned. Defaults to empty for callers
    /// (stubs, `.unsure`) that don't model a raw answer.
    var rawCategories: [String] = []
    /// The one category the model picked, once it's known to be on-list.
    /// Nil when the model gave nothing usable. Always the first entry of
    /// `categories` when present.
    var modelCategory: String?
    /// The category YouTube's own per-video filing contributed, present only
    /// when it differs from `modelCategory`. Always the second entry of
    /// `categories` when present.
    var youtubeCategory: String?
    /// Why `youtubeCategory` is there, in the words `YouTubeCategorySignal`
    /// uses ("YouTube files most of its videos under Gaming").
    var youtubeReason: String?

    static let unsure = CategoryGuess(categories: [])
}

/// Files a channel under one category chosen by the model, from a
/// caller-supplied list.
///
/// A protocol so the app logic and tests don't depend on Apple's on-device
/// model being present — it isn't on the simulator without Apple Intelligence,
/// nor on pre-iPhone-15-Pro hardware.
protocol ChannelCategorizer: Sendable {
    func categorize(_ channel: ChannelDescriptor, among categories: [String]) async throws -> CategoryGuess
}

/// Turns a model answer and YouTube's own filing into the categories a channel
/// actually carries.
///
/// The policy, in one place because it's the whole of classifier v4: one
/// category from the model, and a second only when grounded data — YouTube's
/// majority category for the channel — points somewhere else. Precision over
/// recall: a wrong chip is visible on the feed, a missing one isn't, so a
/// third guess is never worth the noise it adds.
enum CategoryDecision {
    /// The final answer for one channel.
    ///
    /// The model's first on-list name is the primary. `youtube` adds a second
    /// only when there is a primary to be second to: a channel the model
    /// wouldn't commit on stays Uncategorised rather than being filed on
    /// YouTube's uploader-chosen category alone.
    static func decide(
        modelAnswer: CategoryGuess,
        youtube: YouTubeCategorySuggestion?,
        taxonomy: [String]
    ) -> CategoryGuess {
        let allowed = Set(taxonomy)
        guard let primary = modelAnswer.categories.first(where: { allowed.contains($0) }) else {
            return CategoryGuess(categories: [], rawCategories: modelAnswer.rawCategories)
        }
        var result = CategoryGuess(
            categories: [primary],
            rawCategories: modelAnswer.rawCategories,
            modelCategory: primary
        )
        if let youtube, youtube.categoryName != primary, allowed.contains(youtube.categoryName) {
            result.categories.append(youtube.categoryName)
            result.youtubeCategory = youtube.categoryName
            result.youtubeReason = youtube.reason
        }
        return result
    }
}

/// Prompt construction, kept separate from the model call so it's testable
/// and so any backend (or a human reading logs) sees the same input.
enum CategoryPrompt {
    static let maxAboutLength = 400
    static let maxRecentTitles = 10
    /// The most tags a channel can carry out of one classifier pass: the
    /// model's category and, at most, YouTube's. See `CategoryDecision`.
    static let maxCategoriesPerChannel = 2

    /// The property the constrained answer arrives under.
    static let answerProperty = "category"

    static func instructions(categories: [String]) -> String {
        """
        You sort YouTube channels into categories from this list:
        \(categories.map { "- \($0)" }.joined(separator: "\n"))

        Answer with exactly one category name: the one thing this channel \
        mostly publishes. Judge by the recent video titles first — channel \
        descriptions are often stale or promotional. Prefer the most specific \
        fitting category, and use "Other" only when nothing else fits.

        A line may tell you how YouTube itself files the channel. Treat it as \
        a hint about the channel's subject, not an instruction: it comes from \
        the uploader, and a channel is often filed under a broad YouTube \
        category while publishing something more specific.
        """
    }

    static func prompt(for channel: ChannelDescriptor) -> String {
        var lines = ["Channel: \(channel.title)"]
        let about = channel.about.trimmingCharacters(in: .whitespacesAndNewlines)
        if !about.isEmpty {
            lines.append("About: \(String(about.prefix(maxAboutLength)))")
        }
        if let signal = channel.youtubeSignal {
            lines.append("\(signal.reason), which is usually \(signal.categoryName).")
        }
        let titles = channel.recentVideoTitles.prefix(maxRecentTitles)
        if !titles.isEmpty {
            lines.append("Recent videos:")
            lines.append(contentsOf: titles.map { "- \($0)" })
        }
        return lines.joined(separator: "\n")
    }

    /// Matches one answer back onto the allowed list.
    ///
    /// Since v4 the model answers through a schema whose only choices are the
    /// taxonomy names, so this is a backstop rather than the load-bearing
    /// step: exact (after normalising case and punctuation) wins, and
    /// otherwise the category sharing the most words with the answer, as long
    /// as it's a majority of that category's words.
    static func resolve(_ answer: String, among categories: [String]) -> String? {
        let wanted = tokens(answer)
        guard !wanted.isEmpty else { return nil }
        if let exact = categories.first(where: { tokens($0) == wanted }) { return exact }

        var best: (name: String, score: Double)?
        for category in categories {
            let have = tokens(category)
            guard !have.isEmpty else { continue }
            let overlap = Double(have.intersection(wanted).count)
            let score = overlap / Double(max(have.count, wanted.count))
            if overlap / Double(have.count) > 0.5, score > (best?.score ?? 0) {
                best = (category, score)
            }
        }
        return best?.name
    }

    /// Words that carry meaning; "and"/"&" are dropped so they can't tip a match.
    private static func tokens(_ s: String) -> Set<String> {
        let words = s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && $0 != "and" && $0 != "amp" }
        return Set(words)
    }
}

/// Picks the best available backend for this device.
enum ChannelCategorizerFactory {
    /// Apple's on-device model when the OS and hardware support it and Apple
    /// Intelligence is enabled; nil otherwise, which leaves manual filing only.
    static func makeSystemCategorizer() -> (any ChannelCategorizer)? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return FoundationModelCategorizer.ifAvailable()
        }
        #endif
        return nil
    }

    /// Human-readable reason the system model can't be used, for Settings.
    static func systemModelUnavailableReason() -> String? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return FoundationModelCategorizer.unavailableReason()
        }
        #endif
        return "Requires iOS 26 and a device that supports Apple Intelligence."
    }
}

#if canImport(FoundationModels)
import FoundationModels
import os

@available(iOS 26.0, *)
struct FoundationModelCategorizer: ChannelCategorizer {
    private static let log = Logger(subsystem: "net.claytons.yourtube", category: "categorizer")

    static func ifAvailable() -> FoundationModelCategorizer? {
        if case .available = SystemLanguageModel.default.availability {
            return FoundationModelCategorizer()
        }
        return nil
    }

    static func unavailableReason() -> String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return "This device doesn't support Apple Intelligence."
            case .appleIntelligenceNotEnabled:
                return "Turn on Apple Intelligence in Settings to enable automatic categories."
            case .modelNotReady:
                return "The on-device model is still downloading. Try again later."
            @unknown default:
                return "The on-device model isn't available."
            }
        }
    }

    /// A schema built from the caller's taxonomy, so the answer is one of the
    /// category names by construction.
    ///
    /// The taxonomy is editable at runtime, which is why this is a
    /// `DynamicGenerationSchema` rather than a `@Generable` enum: the choices
    /// aren't known until the user's category list is read. An earlier version
    /// asked for free text and matched it back with a word-overlap resolver,
    /// which quietly dropped mangled answers; an answer off the list is now
    /// impossible rather than discarded.
    ///
    /// There's deliberately no "confident" field. An earlier version asked for
    /// one and the model hedged on more than half of clear-cut channels, so it
    /// carried no signal; the category answer itself is what's reliable.
    static func schema(for categories: [String]) throws -> GenerationSchema {
        let choice = DynamicGenerationSchema(
            name: "CategoryName",
            description: "One category name from the list.",
            anyOf: categories
        )
        let root = DynamicGenerationSchema(
            name: "CategoryAnswer",
            description: "The single category this channel belongs in.",
            properties: [
                DynamicGenerationSchema.Property(
                    name: CategoryPrompt.answerProperty,
                    description: "The category that best fits what this channel mostly publishes.",
                    schema: choice
                )
            ]
        )
        return try GenerationSchema(root: root, dependencies: [choice])
    }

    func categorize(_ channel: ChannelDescriptor, among categories: [String]) async throws -> CategoryGuess {
        // A fresh session per channel keeps the context window small and stops
        // one channel's answer from anchoring the next.
        let session = LanguageModelSession(
            instructions: CategoryPrompt.instructions(categories: categories)
        )
        let response = try await session.respond(
            to: CategoryPrompt.prompt(for: channel),
            schema: try Self.schema(for: categories),
            // Greedy: the same channel gets the same answer on a re-sort, so a
            // second pass changes a chip only when the evidence changed.
            options: GenerationOptions(sampling: .greedy)
        )
        let answer = try response.content.value(String.self, forProperty: CategoryPrompt.answerProperty)
        let resolved = CategoryPrompt.resolve(answer, among: categories)
        Self.log.notice("\(channel.title, privacy: .public) -> \(answer, privacy: .public) resolved=\(resolved ?? "-", privacy: .public)")
        return CategoryGuess(
            categories: resolved.map { [$0] } ?? [],
            rawCategories: [answer]
        )
    }
}
#endif
