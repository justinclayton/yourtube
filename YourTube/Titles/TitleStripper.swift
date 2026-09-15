import Foundation

/// A title after tier-one cleaning: the text to display, plus any episode
/// numbering lifted out of it so the UI can show it as a label instead of
/// clutter in the title.
struct CleanedTitle: Equatable {
    var title: String
    var seasonNumber: Int?
    var episodeNumber: Int?

    init(title: String, seasonNumber: Int? = nil, episodeNumber: Int? = nil) {
        self.title = title
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
    }

    /// "Ep. 142", or "S20 Ep. 4" when a season was found. Nil when the title
    /// carried no episode numbering.
    var episodeLabel: String? {
        TitleStripper.episodeLabel(season: seasonNumber, episode: episodeNumber)
    }
}

/// The prefix and/or suffix a channel repeats across most of its uploads,
/// held in normalised form (see `TitleStripper.normalize`) so comparison
/// ignores case, emoji and stray punctuation.
struct ChannelBoilerplate: Equatable {
    var prefix: String?
    var suffix: String?

    static let none = ChannelBoilerplate(prefix: nil, suffix: nil)

    var isEmpty: Bool { prefix == nil && suffix == nil }
}

/// Tier one of title cleaning: a deterministic pass that strips the
/// boilerplate a channel repeats on every upload and pulls episode numbers
/// out into metadata. No model is involved, so it works on every device and
/// costs nothing to run over the whole store.
///
/// The shape of the problem is that YouTube titles carry two things at once:
/// what this video is, and which channel it came from. The second is already
/// on screen next to the title, so repeating it is pure noise — but only the
/// channel as a whole tells you which part is the repeat. So the stripper
/// works on a channel's titles together, not one title at a time.
///
/// How it decides, in order:
///
/// 1. Split each title on the delimiters channels actually use for this —
///    pipe, spaced dash, colon, bullet.
/// 2. Pull an episode number out of the first segment that has one, and drop
///    segments that are nothing but a generic marker ("FULL EPISODE"). Doing
///    this before affix detection is what lets "Joe Rogan Experience #2549"
///    and "Joe Rogan Experience #2548" be recognised as the same prefix.
/// 3. Count the first and last segments across the channel. A value carried
///    by most titles (and at least a few of them) is boilerplate.
/// 4. Strip it — unless that would leave nothing, which means the boilerplate
///    *is* the title (Trolden's "Funny And Lucky Moments - Hearthstone") and
///    removing it would say less than leaving it.
///
/// Everything here errs towards leaving a title alone: a channel with no
/// repeated affix comes through untouched, and so does every title whose
/// remainder would be empty. The model rewrite that handles the titles this
/// pass can't (#27) reuses the same cache fields and the same version.
enum TitleStripper {
    /// Bump when the stripping logic changes so stored videos get re-cleaned
    /// on the next launch (see `Video.titleCleanerVersion`). Mirrors
    /// `ShortsHeuristic.version`.
    static let version = 1

    /// Below this many titles a "shared" affix is just a coincidence.
    static let minimumSampleSize = 4
    /// However small the sample, boilerplate has to have been seen a few times.
    static let minimumAffixCount = 3
    /// "Most of them", as a fraction of the titles that have an affix to share.
    static let sharedAffixThreshold = 0.6

    /// Markers that say nothing about what a video is. Stripped when they
    /// make up a whole segment ("... | FULL EPISODE | ...") or sit in
    /// brackets ("(Official Video)"), never when they're part of a phrase —
    /// "Full Video on our Channel!" is that channel's boilerplate, and the
    /// shared-suffix rule is what removes it.
    static let genericMarkers = [
        "full episode",
        "full episodes",
        "full show",
        "full interview",
        "full podcast",
        "full set",
        "full video",
        "official video",
        "official music video",
        "official audio",
        "official lyric video",
        "official trailer",
    ]

    // MARK: - Public

    /// Cleans a channel's titles together, which is the only way the shared
    /// affix can be found. Order is preserved, so the result lines up with
    /// the input.
    static func clean(titles: [String]) -> [CleanedTitle] {
        let boilerplate = boilerplate(in: titles)
        return titles.map { clean($0, boilerplate: boilerplate) }
    }

    /// The prefix and suffix most of a channel's titles share, or `.none`
    /// when there isn't one.
    static func boilerplate(in titles: [String]) -> ChannelBoilerplate {
        guard titles.count >= minimumSampleSize else { return .none }
        let candidates = titles
            .map { prepared($0).segments }
            .filter { $0.count >= 2 }
        guard candidates.count >= minimumAffixCount else { return .none }

        return ChannelBoilerplate(
            prefix: dominant(candidates.map { normalize($0[0].text) }, outOf: candidates.count),
            suffix: dominant(candidates.map { normalize($0[$0.count - 1].text) }, outOf: candidates.count)
        )
    }

    /// Cleans one title against a channel's boilerplate. Pass `.none` to get
    /// episode-number extraction and generic-marker removal alone.
    static func clean(_ rawTitle: String, boilerplate: ChannelBoilerplate) -> CleanedTitle {
        let (segments, season, episode) = prepared(rawTitle)
        var kept = segments

        if kept.count >= 2 {
            var trimmed = kept
            if let prefix = boilerplate.prefix, normalize(trimmed[0].text) == prefix {
                trimmed.removeFirst()
            }
            if let suffix = boilerplate.suffix, let last = trimmed.last,
               normalize(last.text) == suffix {
                trimmed.removeLast()
            }
            // Nothing survived: every part of this title is boilerplate, so
            // the boilerplate is all the title has. Leave it whole.
            if !trimmed.isEmpty { kept = trimmed }
        }

        let text = tidy(join(kept))
        let fallback = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return CleanedTitle(
            title: text.isEmpty ? fallback : text,
            seasonNumber: season,
            episodeNumber: episode
        )
    }

    /// "Ep. 142", or "S20 Ep. 4" when a season was found.
    static func episodeLabel(season: Int?, episode: Int?) -> String? {
        guard let episode else { return nil }
        if let season { return "S\(season) Ep. \(episode)" }
        return "Ep. \(episode)"
    }

    // MARK: - Segments

    /// One delimited part of a title, carrying the delimiter that preceded it
    /// so a title can be put back together in its own punctuation.
    struct Segment: Equatable {
        var text: String
        var separatorBefore: String
    }

    /// Splits a title, removes the first episode number it finds and any
    /// segment that is nothing but a generic marker. This is the shape both
    /// affix detection and cleaning work on, so they always agree.
    private static func prepared(_ title: String) -> (segments: [Segment], season: Int?, episode: Int?) {
        var segments = split(title)
        var season: Int?
        var episode: Int?

        for index in segments.indices where episode == nil {
            let found = removeEpisodeNumber(from: segments[index].text)
            guard found.episode != nil else { continue }
            segments[index].text = found.text
            season = found.season
            episode = found.episode
        }

        segments = segments.map {
            Segment(text: removeBracketedMarkers(from: $0.text), separatorBefore: $0.separatorBefore)
        }
        segments = segments.filter { !normalize($0.text).isEmpty && !isGenericMarker($0.text) }
        return (segments, season, episode)
    }

    private static func split(_ title: String) -> [Segment] {
        let text = title as NSString
        let whole = NSRange(location: 0, length: text.length)
        var segments: [Segment] = []
        var start = 0
        var separator = ""

        for match in separatorRegex.matches(in: title, range: whole) {
            guard match.range.location >= start else { continue }
            let piece = text.substring(with: NSRange(
                location: start, length: match.range.location - start
            ))
            segments.append(Segment(text: piece, separatorBefore: separator))
            separator = text.substring(with: match.range)
            start = match.range.location + match.range.length
        }
        segments.append(Segment(text: text.substring(from: start), separatorBefore: separator))
        return segments
    }

    private static func join(_ segments: [Segment]) -> String {
        guard let first = segments.first else { return "" }
        return segments.dropFirst().reduce(first.text) { $0 + $1.separatorBefore + $1.text }
    }

    // MARK: - Episode numbers

    private static func removeEpisodeNumber(
        from text: String
    ) -> (text: String, season: Int?, episode: Int?) {
        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)

        if let match = seasonEpisodeRegex.firstMatch(in: text, range: whole),
           let season = number(match, 1, in: ns), let episode = number(match, 2, in: ns) {
            return (ns.replacingCharacters(in: match.range, with: " "), season, episode)
        }
        for regex in [hashNumberRegex, episodeNumberRegex] {
            if let match = regex.firstMatch(in: text, range: whole),
               let episode = number(match, 1, in: ns) {
                return (ns.replacingCharacters(in: match.range, with: " "), nil, episode)
            }
        }
        return (text, nil, nil)
    }

    private static func number(
        _ match: NSTextCheckingResult, _ group: Int, in text: NSString
    ) -> Int? {
        let range = match.range(at: group)
        guard range.location != NSNotFound else { return nil }
        return Int(text.substring(with: range))
    }

    // MARK: - Generic markers

    private static func isGenericMarker(_ text: String) -> Bool {
        normalizedMarkers.contains(normalize(text))
    }

    private static func removeBracketedMarkers(from text: String) -> String {
        let ns = text as NSString
        return bracketedMarkerRegex.stringByReplacingMatches(
            in: text,
            range: NSRange(location: 0, length: ns.length),
            withTemplate: " "
        )
    }

    // MARK: - Comparison and tidying

    /// Case-, accent- and punctuation-insensitive form used to decide whether
    /// two segments are "the same" boilerplate. Emoji and stray punctuation
    /// are noise here: Off Menu's "Off Menu Podcast 🍽️" and "Off Menu
    /// Podcast" are one suffix, not two.
    static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        let stripped = String(folded.map { $0.isLetter || $0.isNumber ? $0 : " " })
        return stripped.split(separator: " ").joined(separator: " ")
    }

    private static func dominant(_ values: [String], outOf total: Int) -> String? {
        var counts: [String: Int] = [:]
        for value in values where !value.isEmpty { counts[value, default: 0] += 1 }
        // Sorted rather than `max(by:)` so a tie resolves the same way every
        // run; dictionary order isn't stable across launches.
        guard let best = counts.sorted(by: {
            $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
        }).first else { return nil }
        // The epsilon keeps a share that is exactly the threshold (six titles
        // in ten) on the inside of it, whichever way the division rounds.
        guard best.value >= minimumAffixCount,
              Double(best.value) / Double(total) + 1e-9 >= sharedAffixThreshold else { return nil }
        return best.key
    }

    private static func tidy(_ text: String) -> String {
        let ns = text as NSString
        let collapsed = whitespaceRunRegex.stringByReplacingMatches(
            in: text,
            range: NSRange(location: 0, length: ns.length),
            withTemplate: " "
        )
        return collapsed.trimmingCharacters(in: trimmable)
    }

    // MARK: - Patterns

    /// The delimiters channels use to bolt a show name onto a title. A bare
    /// hyphen only counts when it's spaced, so "222-0." and "Seventh-day"
    /// stay in one piece; a colon only when a space follows, so "8:30" does.
    private static let separatorRegex = regex(#"\s*[|•·]\s*|\s+[-–—]\s+|:\s+"#)

    /// "S29E03", "S20 Ep.4", "Season 29 Episode 3", "Series 19 Episode 11".
    private static let seasonEpisodeRegex =
        regex(#"\bS(?:eason|eries)?\s*(\d{1,3})\s*[,\-–—]?\s*(?:Episode|Ep|E)\.?\s*(\d{1,4})\b"#)
    /// "#142". Digits are required, so hashtags like "#shorts" don't match.
    private static let hashNumberRegex = regex(#"#(\d{1,5})\b"#)
    /// "Ep. 31", "Ep 31", "EP31", "Episode 41".
    private static let episodeNumberRegex = regex(#"\b(?:Episode|Ep)\.?\s*(\d{1,5})\b"#)

    private static let whitespaceRunRegex = regex(#"\s{2,}"#)

    private static let bracketedMarkerRegex = regex(
        "[\\(\\[]\\s*(?:" + genericMarkers.joined(separator: "|") + ")\\s*[\\)\\]]"
    )

    private static let normalizedMarkers = Set(genericMarkers.map(normalize))

    private static let trimmable = CharacterSet(charactersIn: " \t\n|-–—:•·,.")

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // Patterns are literals in this file; a failure here is a programmer
        // error, not something a title can cause.
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }
}
