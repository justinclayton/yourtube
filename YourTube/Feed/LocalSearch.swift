import Foundation

/// Filters what is already cached on device by video title and channel name.
///
/// Deliberately local-only: the Data API's `search.list` costs 100 quota
/// units per call against a 10,000 unit daily budget, so remote search, if it
/// is ever added, has to be an explicit action. This never touches the network,
/// which is also what lets it work offline and while signed out.
///
/// Matching is case- and diacritic-insensitive ("beyonce" finds "Beyoncé"),
/// and every whitespace-separated word in the query has to appear somewhere in
/// the haystack, in any order. Results keep the caller's order, so a
/// newest-first feed stays newest-first.
enum LocalSearch {
    /// Folds case and diacritics so two strings can be compared byte-for-byte.
    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .lowercased()
    }

    /// The query split into normalised words. Empty when there is nothing to
    /// search for, in which case everything matches.
    static func terms(in query: String) -> [String] {
        normalize(query).split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// True when every term appears in at least one of the fields.
    static func matches(terms: [String], fields: [String]) -> Bool {
        guard !terms.isEmpty else { return true }
        let haystack = fields.map(normalize).joined(separator: "\n")
        return terms.allSatisfy { haystack.contains($0) }
    }

    /// Filters `items` to those whose fields match `query`, keeping order.
    static func filter<T>(_ items: [T], query: String, fields: (T) -> [String]) -> [T] {
        let terms = terms(in: query)
        guard !terms.isEmpty else { return items }
        return items.filter { matches(terms: terms, fields: fields($0)) }
    }
}
