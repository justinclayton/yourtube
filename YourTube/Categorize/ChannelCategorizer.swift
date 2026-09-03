import Foundation

/// Everything the classifier gets to see about one channel.
struct ChannelDescriptor: Sendable, Equatable {
    var channelId: String
    var title: String
    var about: String
    /// Titles of recent uploads, newest first. Often the strongest signal —
    /// channel descriptions are frequently empty or just a sponsor blurb.
    var recentVideoTitles: [String]
}

struct CategoryGuess: Sendable, Equatable {
    /// Names from the list passed to `categorize`, most relevant first.
    /// Empty if the model wouldn't commit or answered entirely off-list;
    /// the channel then stays Uncategorised.
    var categories: [String]

    static let unsure = CategoryGuess(categories: [])
}

/// Files a channel under one to three of a caller-supplied list of categories.
///
/// A protocol so the app logic and tests don't depend on Apple's on-device
/// model being present — it isn't on the simulator without Apple Intelligence,
/// nor on pre-iPhone-15-Pro hardware.
protocol ChannelCategorizer: Sendable {
    func categorize(_ channel: ChannelDescriptor, among categories: [String]) async throws -> CategoryGuess
}

/// Prompt construction, kept separate from the model call so it's testable
/// and so any backend (or a human reading logs) sees the same input.
enum CategoryPrompt {
    static let maxAboutLength = 400
    static let maxRecentTitles = 10
    /// The most tags a channel can carry from one classifier answer. Three is
    /// enough for "comedian with a podcast and a car show"; more and every
    /// channel ends up everywhere.
    static let maxCategoriesPerChannel = 3

    static func instructions(categories: [String]) -> String {
        """
        You sort YouTube channels into categories from this list:
        \(categories.map { "- \($0)" }.joined(separator: "\n"))

        Answer with one to \(maxCategoriesPerChannel) category names, most \
        relevant first. Judge by what the channel mostly publishes. Prefer the \
        most specific fitting categories, and add a second or third only when \
        the channel genuinely publishes both kinds of thing. Use "Other" only \
        when nothing else fits, and never alongside another category.
        """
    }

    static func prompt(for channel: ChannelDescriptor) -> String {
        var lines = ["Channel: \(channel.title)"]
        let about = channel.about.trimmingCharacters(in: .whitespacesAndNewlines)
        if !about.isEmpty {
            lines.append("About: \(String(about.prefix(maxAboutLength)))")
        }
        let titles = channel.recentVideoTitles.prefix(maxRecentTitles)
        if !titles.isEmpty {
            lines.append("Recent videos:")
            lines.append(contentsOf: titles.map { "- \($0)" })
        }
        return lines.joined(separator: "\n")
    }

    /// Matches a list of answers back onto the allowed list, keeping order.
    ///
    /// Each answer goes through `resolve`; off-list answers are dropped rather
    /// than failing the whole channel, duplicates collapse, and the result is
    /// capped at `maxCategoriesPerChannel`.
    static func resolve(_ answers: [String], among categories: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for answer in answers {
            guard let name = resolve(answer, among: categories), seen.insert(name).inserted else { continue }
            result.append(name)
            if result.count == maxCategoriesPerChannel { break }
        }
        return result
    }

    /// Matches one answer back onto the allowed list.
    ///
    /// Exact (after normalising case and punctuation) wins. Otherwise the
    /// category sharing the most words with the answer, as long as it's a
    /// majority of that category's words — the 3B model occasionally drops
    /// or mangles a token ("Music' Audio Gear"), and rejecting those would
    /// leave obviously-right answers uncategorised.
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
    /// Constrained output: the model must fill this shape, so we never have to
    /// parse free text. Each name is validated against the list afterwards.
    ///
    /// There's deliberately no "confident" field. An earlier version asked for
    /// one and the model hedged on more than half of clear-cut channels, so it
    /// carried no signal; the category answers themselves are what's reliable.
    @Generable
    struct Answer {
        @Guide(
            description: "One to three category names copied exactly from the list, most relevant first.",
            .minimumCount(1), .maximumCount(3)
        )
        var categories: [String]
    }

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

    func categorize(_ channel: ChannelDescriptor, among categories: [String]) async throws -> CategoryGuess {
        // A fresh session per channel keeps the context window small and stops
        // one channel's answer from anchoring the next.
        let session = LanguageModelSession(
            instructions: CategoryPrompt.instructions(categories: categories)
        )
        let response = try await session.respond(
            to: CategoryPrompt.prompt(for: channel),
            generating: Answer.self
        )
        let resolved = CategoryPrompt.resolve(response.content.categories, among: categories)
        Self.log.notice("\(channel.title, privacy: .public) -> \(response.content.categories.joined(separator: " | "), privacy: .public) resolved=\(resolved.joined(separator: " | "), privacy: .public)")
        return CategoryGuess(categories: resolved)
    }
}
#endif
