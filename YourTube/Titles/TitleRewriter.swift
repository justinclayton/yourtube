import Foundation

/// Everything the rewriter gets to see about one title.
///
/// The input is deliberately the *stripped* title, not YouTube's: tier one has
/// already taken the channel's boilerplate off, so the model is asked to calm
/// down a sentence rather than to work out which half of it is a show name.
struct TitleRewriteRequest: Sendable, Equatable {
    /// Tier one's output — what the viewer would see without the rewrite, and
    /// what the app falls back to whenever the answer is unusable.
    var strippedTitle: String
    /// The show this episode belongs to, so the model knows what's already on
    /// screen beside the title and needn't repeat it.
    var showTitle: String
}

/// Rewrites one already-stripped title into a calm, factual one.
///
/// A protocol for the same reason `ChannelCategorizer` is one: the on-device
/// model isn't there on the simulator without Apple Intelligence, nor on older
/// hardware, and the app's bookkeeping has to be testable without it.
///
/// The answer comes back unvalidated, exactly as the model produced it.
/// `TitleRewritePrompt.resolve` is what decides whether it may be shown, and
/// it lives on the calling side so no backend — real, stubbed, or future —
/// can put an empty or rambling title into the store.
protocol TitleRewriter: Sendable {
    func rewrite(_ request: TitleRewriteRequest) async throws -> String
}

/// Prompt construction and answer validation, kept out of the model call so
/// both are testable and so any backend sees the same input.
enum TitleRewritePrompt {
    /// Bump when the instructions or the validation change in a way that
    /// should give already-rewritten titles another go. Added to the
    /// stripper's version to make `TitleCleaner.version`, so a bump here
    /// re-runs both tiers — tier one's output is tier two's input, and a
    /// rewrite judged against a stale stripping is not worth keeping.
    static let version = 2

    /// The longest rewrite worth showing. A title that comes back longer than
    /// this hasn't been calmed, it's been elaborated, which is the one thing
    /// the rewrite must never do.
    static let maxLength = 80

    static let instructions = """
    You rewrite YouTube video titles so they read like the episode title of a \
    calm, factual programme.

    Rules, in order of importance:
    - Never add information the title doesn't already contain. No new names, \
    numbers, claims, outcomes or conclusions, and no guessing at what the \
    episode is about. Reuse the title's own words: take a word out rather \
    than swap it for a different one.
    - Write in normal sentence case, the way a newspaper writes a headline: \
    a capital letter at the start, names of people, places, programmes and \
    organisations capitalised, acronyms in capitals, and every other word in \
    lower case. Never use capital letters for emphasis.
    - Keep it under \(maxLength) characters, and never longer than the title \
    you were given.
    - Drop hype, teases and shouting; keep the subject and the people named.
    - Don't repeat the show's name. It is already on screen beside the title.
    - If the title is already calm and factual, give it back word for word.

    Answer with the rewritten title and nothing else: no quotation marks, no \
    explanation.
    """

    static func prompt(for request: TitleRewriteRequest) -> String {
        var lines: [String] = []
        let show = request.showTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !show.isEmpty { lines.append("Show: \(show)") }
        lines.append("Title: \(request.strippedTitle)")
        return lines.joined(separator: "\n")
    }

    /// The title to store for an answer, which is the stripped title whenever
    /// the answer can't be trusted.
    ///
    /// Two things disqualify an answer, and both are things a small model
    /// does often enough to plan for: nothing at all, and a paragraph where a
    /// title was asked for. The *wording* of everything else is taken as
    /// given — second-guessing it is what the instructions are for — but the
    /// *casing* is not: asked the same title three times the model shouted it
    /// back, half-calmed it and flattened it to lower case, so `TitleCasing`
    /// decides that from the title the model was given rather than from the
    /// answer (#27).
    static func resolve(_ answer: String, strippedTitle: String) -> String {
        let fallback = strippedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = unquoted(collapsed(answer))
        guard !text.isEmpty else { return fallback }
        // A rewrite may be longer than the cap only if the original was
        // longer still, and even then only if it shortened it: some show
        // titles are genuinely long sentences.
        guard text.count <= max(maxLength, fallback.count) else { return fallback }
        return TitleCasing.restore(text, from: fallback)
    }

    /// Whitespace and line breaks squeezed to single spaces, so an answer that
    /// arrives on three lines doesn't become a three-line feed row.
    private static func collapsed(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Models wrap titles in quotes about as often as they don't, and a quoted
    /// title beside unquoted ones reads as the app shouting in a new way.
    private static func unquoted(_ text: String) -> String {
        let pairs: [(Character, Character)] = [("\"", "\""), ("'", "'"), ("“", "”"), ("‘", "’")]
        guard let first = text.first, let last = text.last, text.count >= 2,
              pairs.contains(where: { $0.0 == first && $0.1 == last }) else { return text }
        return String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
    }
}

/// Picks the best available backend for this device.
enum TitleRewriterFactory {
    /// Apple's on-device model when the OS and hardware support it and Apple
    /// Intelligence is enabled; nil otherwise, which leaves tier-one stripping
    /// alone — the degradation the feature is designed around.
    static func makeSystemRewriter() -> (any TitleRewriter)? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return FoundationModelTitleRewriter.ifAvailable()
        }
        #endif
        return nil
    }

    /// Human-readable reason the rewrite can't run, for Settings.
    static func systemModelUnavailableReason() -> String? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return FoundationModelTitleRewriter.unavailableReason()
        }
        #endif
        return "Requires iOS 26 and a device that supports Apple Intelligence."
    }
}

#if canImport(FoundationModels)
import FoundationModels
import os

@available(iOS 26.0, *)
struct FoundationModelTitleRewriter: TitleRewriter {
    /// Constrained output: the model fills this shape, so there's no free text
    /// to parse and no way for an explanation to arrive where a title should.
    @Generable
    struct Answer {
        @Guide(
            description: "The rewritten title alone, under 80 characters, in normal sentence case with names capitalised, saying nothing the original didn't."
        )
        var title: String
    }

    private static let log = Logger(subsystem: "net.claytons.yourtube", category: "titles")

    static func ifAvailable() -> FoundationModelTitleRewriter? {
        if case .available = SystemLanguageModel.default.availability {
            return FoundationModelTitleRewriter()
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
                return "This device doesn't support Apple Intelligence, so titles are only tidied by pattern."
            case .appleIntelligenceNotEnabled:
                return "Turn on Apple Intelligence in Settings to let the model rewrite show titles."
            case .modelNotReady:
                return "The on-device model is still downloading. Try again later."
            @unknown default:
                return "The on-device model isn't available."
            }
        }
    }

    func rewrite(_ request: TitleRewriteRequest) async throws -> String {
        // A fresh session per title, like the categorizer's per channel: the
        // context stays one sentence long, and no title can anchor the tone of
        // the next one.
        let session = LanguageModelSession(instructions: TitleRewritePrompt.instructions)
        let response = try await session.respond(
            to: TitleRewritePrompt.prompt(for: request),
            generating: Answer.self
        )
        Self.log.notice("\(request.strippedTitle, privacy: .public) -> \(response.content.title, privacy: .public)")
        return response.content.title
    }
}
#endif
