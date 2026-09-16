import Foundation
import NaturalLanguage
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Decides the capitalisation of a rewritten title, from the evidence in the
/// title it was rewritten from.
///
/// The on-device model cannot be trusted with case. Asked the same title three
/// times it returned it shouted back verbatim, half-calmed
/// (`lebron James, syndney sweeney DISGUSTING…`) and flattened to nothing but
/// lower case (`lebron james, sydney sweeney gambling shilling`) — and the
/// phone leans hard on that last one, which is what #27 reported. No wording
/// of the instructions fixes a coin flip, so the app takes the decision back:
/// the model is asked for the *words*, and this decides their case.
///
/// The house style is ordinary sentence case — capital at the front, names and
/// acronyms capitalised, everything else lower — because that is what an
/// episode title of a calm programme looks like, and because it is the one
/// style that can be derived rather than guessed.
///
/// Each word of the answer is looked up in the title it came from, which is
/// the only place any evidence lives:
///
/// - **Letters and digits together** (`WW3`, `F-15`, `MST3K`, `DS9`) — a code
///   or a name, never a word being shouted, so the source's spelling is
///   copied exactly.
/// - **Written with an inner capital** (`LeBron`, `iPhone`, `McCarthy`) — that
///   spelling is deliberate and is copied exactly. A capital after a hyphen
///   isn't inner: `Mail-In` is two words in Title Case, decided one at a time.
/// - **Hyphenated** (`Mail-In`, `Ben-Gvir`, `US-Israel`) — each part decided
///   on its own, and one name makes the whole a name.
/// - **Capitalised** (`Trump`, `Cameras`) — ambiguous, because YouTube
///   capitalises every word of a title as a matter of style. `NLTagger`'s
///   *person* recognition decides, run over the original title where the
///   model's casing isn't in play, with "not a word `NLEmbedding` has ever
///   seen" as a second opinion for the names it misses (`Syndney`, `Sandi`).
/// - **SHOUTED** — the emphasis the rewrite exists to remove, so it is taken
///   off unless the word is a name (`TRUMP` → `Trump`), an initialism
///   (`DOGE`, `NASA`, `U.S.` — short or dotted, all-capital, and not an
///   ordinary English word) or a roman numeral (`Vol VIII`).
/// - **lower case**, or not in the source at all — left lower case unless it
///   opens the title or follows a full stop, question mark, exclamation mark
///   or colon.
///
/// That last rule is the one the first attempt at this got wrong: it copied
/// the source's case onto every word it recognised, which capitalised
/// mid-sentence function words (`what The polls miss`). Case is copied here
/// only for a name or a deliberate inner capital; a function word is never a
/// name, so it always comes back lower case.
///
/// Given the stripped title as both answer and source, this is a
/// deterministic calming of the title on its own — what the app shows when
/// the model refuses a title or its answer can't be trusted.
enum TitleCasing {
    /// Initialisms that are also ordinary English words, so the vocabulary
    /// check can't tell them apart from shouting. Kept deliberately tiny — one
    /// entry earns its place only when getting it wrong is worse than the
    /// occasional shout that survives, and "us" in a news feed is that.
    static let ambiguousInitialisms: Set<String> = ["us"]

    /// Initialisms too long for the shape rule, which stops at four letters
    /// so a five-letter shouted surname (`PRIYA`) isn't taken for one. The
    /// ones a news feed meets often enough to list by hand.
    static let knownInitialisms: Set<String> = [
        "scotus", "potus", "flotus", "usaid", "nasdaq", "covid", "unesco", "unicef", "nafta", "nascar",
    ]

    /// Abbreviations whose full stop doesn't end a sentence, so the word
    /// after `Dr.` or `No.` isn't capitalised for sitting there.
    static let abbreviations: Set<String> = [
        "dr", "mr", "mrs", "ms", "jr", "sr", "st", "mt", "ft", "feat", "no", "ep", "pt", "vol",
    ]

    /// The answer in sentence case, decided word by word against `source`.
    static func restore(_ answer: String, from source: String) -> String {
        let evidence = Evidence(source: source)
        var pieces: [String] = []
        var opensSentence = true

        for piece in answer.split(separator: " ").map(String.init) {
            let token = Token(piece)
            guard !token.stem.isEmpty else {
                pieces.append(piece)
                continue
            }
            pieces.append(token.rebuilt(
                with: evidence.case(token.stem, openingSentence: opensSentence)
            ))
            opensSentence = token.closesSentence
        }
        return pieces.joined(separator: " ")
    }

    /// The words of a title as this file sees them: lower-cased stems with
    /// the punctuation, possessives and hyphens taken off, so `Durk’s`,
    /// `Durk's` and `DURK` are all one word. What the rewrite's validation
    /// compares an answer against.
    static func words(in title: String) -> [String] {
        title.split(whereSeparator: \.isWhitespace).flatMap { piece -> [String] in
            let stem = Token(String(piece)).stem
            guard !stem.isEmpty else { return [] }
            return stem.split(separator: "-").map {
                var word = $0.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
                if word.hasSuffix("."), word.count > 1 { word.removeLast() }
                return word
            }
        }
    }

    // MARK: - Words

    /// One whitespace-delimited piece of a title, split into the part whose
    /// case is in question and the punctuation around it, so the answer's own
    /// commas, quotes and possessives come back untouched.
    private struct Token {
        /// Punctuation before the word: an opening quote or bracket.
        var lead: String = ""
        /// The word itself, without any possessive.
        var stem: String = ""
        /// `'s` or `’s`, kept off the stem so `NASA's` is looked up as `NASA`.
        var possessive: String = ""
        /// Punctuation after the word, which is also where a sentence ends.
        var trail: String = ""

        init(_ piece: String) {
            let characters = Array(piece)
            guard let first = characters.firstIndex(where: { $0.isLetter || $0.isNumber }),
                  let last = characters.lastIndex(where: { $0.isLetter || $0.isNumber }) else {
                trail = piece
                return
            }
            lead = String(characters[..<first])
            trail = String(characters[(last + 1)...])
            var core = String(characters[first...last])
            if core.count > 2, let mark = core.dropLast().last,
               mark == "'" || mark == "\u{2019}", core.last?.lowercased() == "s" {
                possessive = String(core.suffix(2))
                core = String(core.dropLast(2))
            }
            // The last full stop of `U.S.` or `A.I.` belongs to the word, not
            // to the sentence: kept on the stem so the initialism is looked
            // up whole and the word after it isn't taken for a new sentence.
            if core.contains("."), trail.first == "." {
                core.append(".")
                trail.removeFirst()
            }
            stem = core
        }

        /// Whether the next word starts a new sentence.
        var closesSentence: Bool {
            guard let mark = trail.first(where: { ".!?:\u{2026}".contains($0) }) else { return false }
            return mark != "." || !TitleCasing.abbreviations.contains(stem.lowercased())
        }

        func rebuilt(with stem: String) -> String {
            lead + stem + possessive + trail
        }
    }

    // MARK: - The source title

    /// What the title the model was given says about each of its words.
    private struct Evidence {
        /// Lower-cased word -> how the source spells it. A word the source
        /// both shouts and writes normally keeps the normal spelling: that is
        /// the one carrying information. The parts of a hyphenated word are
        /// listed too, so `US-Israel` answers for `US` and for `Israel`.
        private var spelling: [String: String] = [:]
        /// Lower-cased words `NLTagger` recognised as part of a person's
        /// name. People only: see `TitleCasing.people(in:)`.
        private var people: Set<String> = []

        init(source: String) {
            for piece in source.split(whereSeparator: \.isWhitespace).map(String.init) {
                let stem = Token(piece).stem
                guard !stem.isEmpty else { continue }
                record(stem)
                if stem.contains("-") {
                    for part in stem.split(separator: "-") { record(String(part)) }
                }
            }
            people = TitleCasing.people(in: source)
            // Name recognition is trained on ordinary prose and gives up on a
            // shouted title, so it gets a second look at one with the shouting
            // taken off. A pass that finds nothing costs nothing.
            let calmed = TitleCasing.calmed(source)
            if calmed != source { people.formUnion(TitleCasing.people(in: calmed)) }
        }

        private mutating func record(_ stem: String) {
            let key = stem.lowercased()
            if let existing = spelling[key], !TitleCasing.isShouted(existing) { return }
            spelling[key] = stem
            // `A.I.` answers for `A.I` too, however the model punctuates it.
            if key.hasSuffix("."), key.count > 1 { spelling[String(key.dropLast())] = stem }
        }

        /// How this word should be written, given what the source did with it.
        func `case`(_ stem: String, openingSentence: Bool) -> String {
            let key = stem.lowercased()
            // The pronoun, which is the one word whose capital owes nothing to
            // where it sits.
            if key == "i" { return "I" }
            let text = decided(stem, key: key)
            guard openingSentence, let first = text.first else { return text }
            return first.uppercased() + text.dropFirst()
        }

        /// The word's case on its own merits, before any sentence-opening
        /// capital.
        private func decided(_ stem: String, key: String) -> String {
            let source = spelling[key]

            // Letters and digits together are a code or a name, never a word
            // being shouted: whoever wrote `WW3` or `F-15` chose that case.
            if TitleCasing.mixesLettersAndDigits(stem) { return source ?? stem }
            // A capital somewhere other than the front is always deliberate,
            // whether the source wrote it or the model did.
            if TitleCasing.hasInnerCapital(source ?? stem) { return source ?? stem }
            // A shouted numeral is a numeral, even when the recogniser has
            // read `Vol XVI` as somebody's name.
            if let source, TitleCasing.isShouted(source), TitleCasing.isRomanNumeral(source),
               !TitleCasing.isInUse(key) {
                return source
            }
            // A person comes next: a surname of four or five letters looks
            // exactly like an initialism, and `PRIYA` is a name being
            // shouted where `NASA` never was.
            if people.contains(key) { return TitleCasing.sentenceCased(source ?? stem) }
            // Each part of a hyphenated word on its own, and one name makes
            // the whole a name: `mail-in`, but `Ben-Gvir` and `US-Israel`.
            if let parts = TitleCasing.hyphenParts(stem) {
                let decided = parts.map { self.decided($0, key: $0.lowercased()) }
                guard decided.contains(where: { $0.first?.isUppercase == true }) else {
                    return decided.joined(separator: "-")
                }
                return decided.map(TitleCasing.sentenceCased).joined(separator: "-")
            }

            guard let source else {
                // Not in the source at all: the model's own word.
                return key.count > 1 && isName(key) ? TitleCasing.sentenceCased(stem) : key
            }
            if TitleCasing.isShouted(source) {
                if TitleCasing.isInitialism(source, key) { return source }
                return isName(key) ? TitleCasing.sentenceCased(source) : key
            }
            if source.first?.isUppercase == true { return isName(key) ? source : key }
            return source
        }

        /// Whether this word is a name: recognised as a person, or absent
        /// from the vocabulary of ordinary English, which is what a surname,
        /// a brand and a misspelling all look like.
        private func isName(_ key: String) -> Bool {
            people.contains(key) || !TitleCasing.isOrdinaryWord(key)
        }
    }

    // MARK: - Shapes

    /// Two or more letters, none of them lower case: emphasis, an initialism,
    /// or a name being shouted.
    static func isShouted(_ word: String) -> Bool {
        let letters = word.filter(\.isLetter)
        return letters.count >= 2 && letters.allSatisfy(\.isUppercase)
    }

    /// A capital somewhere other than the front, which is always deliberate:
    /// `LeBron`, `McCarthy`, `iPhone`. A capital right after a hyphen doesn't
    /// count — `Mail-In` is Title Case, not a spelling.
    static func hasInnerCapital(_ word: String) -> Bool {
        guard !isShouted(word) else { return false }
        return zip(word.dropFirst(), word).contains { character, previous in
            character.isUppercase && previous != "-"
        }
    }

    /// `WW3`, `F-15`, `MST3K`: a code or a name, whose case is whoever wrote
    /// it's to choose.
    static func mixesLettersAndDigits(_ word: String) -> Bool {
        word.contains(where: \.isLetter) && word.contains(where: \.isNumber)
    }

    /// The parts of a hyphenated word, or nil for a word that isn't one.
    static func hyphenParts(_ word: String) -> [String]? {
        let parts = word.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count > 1, parts.allSatisfy({ !$0.isEmpty }) else { return nil }
        return parts
    }

    /// A short all-capital run of letters that isn't in ordinary use, or a
    /// dotted one of any length: nobody shouts with full stops between the
    /// letters. Long enough to be shouting is long enough not to be an
    /// initialism, and an initialism the vocabulary happens to know (`US`)
    /// is listed by hand.
    ///
    /// Four letters, not five, because a five-letter one is rare (`USAID`)
    /// and a five-letter shouted surname is not (`PRIYA`, `RAMAN`) — and the
    /// two are indistinguishable by shape. The person recogniser catches the
    /// surname when it can, but it doesn't everywhere: on CI's simulator it
    /// found neither of those, which is exactly the device this has to be
    /// right on without it. The longer ones a news feed keeps meeting
    /// (`SCOTUS`) are listed by hand instead.
    ///
    /// This asks `isInUse` rather than `isOrdinaryWord` deliberately: the
    /// spell checker accepts `nasa` and `doge`, so bringing it in here would
    /// lower-case the two initialisms the reported titles turned on.
    static func isInitialism(_ word: String, _ key: String) -> Bool {
        guard isShouted(word), word.allSatisfy({ $0.isLetter || $0 == "." }) else { return false }
        if word.contains(".") || knownInitialisms.contains(key) { return true }
        guard (2...4).contains(word.count) else { return false }
        return !isInUse(key) || ambiguousInitialisms.contains(key)
    }

    /// `VIII`, `XVI`: a well-formed roman numeral. `MIX` and `DIM` are
    /// numerals too, or words; the caller checks the vocabulary.
    static func isRomanNumeral(_ word: String) -> Bool {
        !word.isEmpty && word.range(
            of: #"^M{0,3}(CM|CD|D?C{0,3})(XC|XL|L?X{0,3})(IX|IV|V?I{0,3})$"#,
            options: .regularExpression
        ) != nil
    }

    /// A word English uses, as opposed to a name, a brand or a misspelling.
    ///
    /// Two dictionaries, because neither alone draws the line in the right
    /// place. `NLEmbedding`'s vocabulary is a vocabulary of *usage*, so it
    /// has never seen `doge` or `lebron` — but it has also never seen
    /// `favourite`, and capitalising British spellings is its own kind of
    /// wrong. The spell checker knows those, so a word either of them
    /// recognises is ordinary and gets lower-cased.
    static func isOrdinaryWord(_ key: String) -> Bool {
        isInUse(key) || spellsAsAWord(key)
    }

    /// In `NLEmbedding`'s vocabulary of ordinary usage.
    private static func isInUse(_ key: String) -> Bool {
        embedding?.contains(key) ?? false
    }

    /// Accepted by the spell checker, in either spelling of English: `colour`
    /// and `color` are both words, and a show's titles may use either.
    private static func spellsAsAWord(_ key: String) -> Bool {
        let range = NSRange(location: 0, length: (key as NSString).length)
        #if canImport(UIKit)
        let checker = UITextChecker()
        return spellingLanguages.contains { language in
            checker.rangeOfMisspelledWord(
                in: key, range: range, startingAt: 0, wrap: false, language: language
            ).location == NSNotFound
        }
        #else
        // The Mac, for `scripts/rewrite-harness.sh` alone; the app never runs here.
        let checker = NSSpellChecker.shared
        return spellingLanguages.contains { language in
            checker.checkSpelling(
                of: key, startingAt: 0, language: language, wrap: false,
                inSpellDocumentWithTag: 0, wordCount: nil
            ).location == NSNotFound
        }
        #endif
    }

    private static let spellingLanguages = ["en_US", "en_GB"]

    /// A capital at the front and nothing shouted behind it, on each part of
    /// a hyphenated word: `BEN-GVIR` → `Ben-Gvir`.
    static func sentenceCased(_ word: String) -> String {
        word.split(separator: "-", omittingEmptySubsequences: false).map { part -> String in
            guard let first = part.first else { return String(part) }
            let rest = isShouted(String(part)) ? part.dropFirst().lowercased() : String(part.dropFirst())
            return first.uppercased() + rest
        }.joined(separator: "-")
    }

    /// The title with its shouting taken off, for the benefit of the name
    /// recogniser alone — never shown to anyone.
    private static func calmed(_ title: String) -> String {
        title.split(separator: " ", omittingEmptySubsequences: false)
            .map { isShouted(String($0)) ? sentenceCased(String($0)) : String($0) }
            .joined(separator: " ")
    }

    /// The words `NLTagger` places inside a person's name.
    ///
    /// People only, and this is the load-bearing decision in the file. The
    /// recogniser leans on capitalisation, so over a title in YouTube's Title
    /// Case it tags any run of capitalised words as a place or an
    /// organisation — `How To Ruin University Challenge` comes back with
    /// `University Challenge` as a place, and `Sandi's Favourite Malicious
    /// Compliance` with `Favourite Malicious Compliance` as an organisation.
    /// Trusting those would keep the capitals on ordinary words, which is the
    /// whole thing this is meant to take off. `.personalName` doesn't drift
    /// that way: over the same titles it found Trump, Lebron James, Sweeney
    /// and Priya Raman and nothing else. An organisation whose name is an
    /// ordinary word (`Flock`) is the price, and it is the cheaper mistake.
    private static func people(in title: String) -> Set<String> {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = title
        var found: Set<String> = []
        tagger.enumerateTags(
            in: title.startIndex..<title.endIndex,
            unit: .word,
            scheme: .nameType,
            options: [.omitWhitespace, .omitPunctuation, .joinNames]
        ) { tag, range in
            guard tag == .personalName else { return true }
            for piece in title[range].split(whereSeparator: \.isWhitespace) {
                let stem = Token(String(piece)).stem
                if !stem.isEmpty { found.insert(stem.lowercased()) }
            }
            return true
        }
        return found
    }

    /// Loaded once: it is a word list, and building it per title would cost
    /// more than the model call it follows.
    private static let embedding = NLEmbedding.wordEmbedding(for: .english)
}
