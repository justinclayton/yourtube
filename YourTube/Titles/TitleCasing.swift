import Foundation
import NaturalLanguage
import UIKit

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
/// - **Written with an inner capital** (`LeBron`, `iPhone`, `McCarthy`) — that
///   spelling is deliberate and is copied exactly.
/// - **Capitalised** (`Trump`, `Cameras`) — ambiguous, because YouTube
///   capitalises every word of a title as a matter of style. `NLTagger`'s
///   *person* recognition decides, run over the original title where the
///   model's casing isn't in play, with "not a word `NLEmbedding` has ever
///   seen" as a second opinion for the names it misses (`Syndney`, `Sandi`).
/// - **SHOUTED** — the emphasis the rewrite exists to remove, so it is taken
///   off unless the word is a name (`TRUMP` → `Trump`) or an initialism
///   (`DOGE`, `NASA`, `FBI` — short, all-capital, and not an ordinary English
///   word).
/// - **lower case**, or not in the source at all — left lower case unless it
///   opens the title or follows a full stop, question mark, exclamation mark
///   or colon.
///
/// That last rule is the one the first attempt at this got wrong: it copied
/// the source's case onto every word it recognised, which capitalised
/// mid-sentence function words (`what The polls miss`). Case is copied here
/// only for a name or a deliberate inner capital; a function word is never a
/// name, so it always comes back lower case.
enum TitleCasing {
    /// Initialisms that are also ordinary English words, so the vocabulary
    /// check can't tell them apart from shouting. Kept deliberately tiny — one
    /// entry earns its place only when getting it wrong is worse than the
    /// occasional shout that survives, and "us" in a news feed is that.
    static let ambiguousInitialisms: Set<String> = ["us"]

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
            stem = core
        }

        /// Whether the next word starts a new sentence.
        var closesSentence: Bool {
            trail.contains { ".!?:\u{2026}".contains($0) }
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
        /// the one carrying information.
        private var spelling: [String: String] = [:]
        /// Lower-cased words `NLTagger` recognised as part of a person's
        /// name. People only: see `TitleCasing.people(in:)`.
        private var people: Set<String> = []

        init(source: String) {
            for piece in source.split(whereSeparator: \.isWhitespace).map(String.init) {
                let stem = Token(piece).stem
                guard !stem.isEmpty else { continue }
                let key = stem.lowercased()
                if let existing = spelling[key], !TitleCasing.isShouted(existing) { continue }
                spelling[key] = stem
            }
            people = TitleCasing.people(in: source)
            // Name recognition is trained on ordinary prose and gives up on a
            // shouted title, so it gets a second look at one with the shouting
            // taken off. A pass that finds nothing costs nothing.
            let calmed = TitleCasing.calmed(source)
            if calmed != source { people.formUnion(TitleCasing.people(in: calmed)) }
        }

        /// How this word should be written, given what the source did with it.
        func `case`(_ stem: String, openingSentence: Bool) -> String {
            let key = stem.lowercased()
            var text: String

            if let source = spelling[key] {
                if TitleCasing.isShouted(source) {
                    // A person comes first: a surname of four or five letters
                    // looks exactly like an initialism, and `PRIYA` is a name
                    // being shouted where `NASA` never was.
                    if people.contains(key) {
                        text = TitleCasing.sentenceCased(source)
                    } else if TitleCasing.isInitialism(source, key) {
                        text = source
                    } else if isName(key) {
                        text = TitleCasing.sentenceCased(source)
                    } else {
                        text = key
                    }
                } else if TitleCasing.hasInnerCapital(source) {
                    text = source
                } else if source.first?.isUppercase == true {
                    text = isName(key) ? source : key
                } else {
                    text = source
                }
            } else if TitleCasing.hasInnerCapital(stem) {
                // The model wrote it with a deliberate inner capital of its
                // own; nothing in the source contradicts that.
                text = stem
            } else if key.count > 1, isName(key) {
                text = TitleCasing.sentenceCased(stem)
            } else {
                text = key
            }

            // The pronoun, which is the one word whose capital owes nothing to
            // where it sits.
            if key == "i" { return "I" }
            guard openingSentence, let first = text.first else { return text }
            return first.uppercased() + text.dropFirst()
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
    /// `LeBron`, `McCarthy`, `iPhone`.
    static func hasInnerCapital(_ word: String) -> Bool {
        !isShouted(word) && word.dropFirst().contains(where: \.isUppercase)
    }

    /// A short all-capital run of letters that isn't in ordinary use. Long
    /// enough to be shouting is long enough not to be an initialism, and an
    /// initialism the vocabulary happens to know (`US`) is listed by hand.
    ///
    /// This asks `isInUse` rather than `isOrdinaryWord` deliberately: the
    /// spell checker accepts `nasa` and `doge`, so bringing it in here would
    /// lower-case the two initialisms the reported titles turned on.
    static func isInitialism(_ word: String, _ key: String) -> Bool {
        guard isShouted(word), word.allSatisfy(\.isLetter), (2...5).contains(word.count) else {
            return false
        }
        return !isInUse(key) || ambiguousInitialisms.contains(key)
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
        let checker = UITextChecker()
        let range = NSRange(location: 0, length: (key as NSString).length)
        return spellingLanguages.contains { language in
            checker.rangeOfMisspelledWord(
                in: key, range: range, startingAt: 0, wrap: false, language: language
            ).location == NSNotFound
        }
    }

    private static let spellingLanguages = ["en_US", "en_GB"]

    /// A capital at the front and nothing shouted behind it.
    static func sentenceCased(_ word: String) -> String {
        guard let first = word.first else { return word }
        let rest = isShouted(word) ? word.dropFirst().lowercased() : String(word.dropFirst())
        return first.uppercased() + rest
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
