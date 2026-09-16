import Foundation

/// How much of the feed's inbox the list is asking the store for.
///
/// The inbox query used to be unbounded. On a real account that is close to
/// four thousand unwatched videos going back to 2007 — fetched, grouped by
/// day, and run past the per-channel daily cap on every store change, for a
/// list nobody scrolls past the first screen of (issue #66). The feed asks
/// for a page at a time instead, and offers a "Show older" row for as long as
/// the page it asked for came back full.
///
/// A row count rather than a date window on purpose: "the last 30 days" reads
/// as "all caught up" on an account whose entire backlog is older than that,
/// which is a lie the empty state would tell with a straight face. A count
/// can only ever be short of rows that exist, which is what the row at the
/// bottom is for.
struct FeedWindow: Equatable {
    /// Rows per page. Big enough that scrolling to the bottom is a decision
    /// rather than an accident, small enough that grouping and the daily cap
    /// stay cheap.
    static let pageSize = 300

    private(set) var limit = FeedWindow.pageSize

    mutating func showOlder() {
        limit += Self.pageSize
    }

    /// Whether there may be older rows behind the window. A full page is the
    /// only evidence there is: the store was asked for `limit` and gave all
    /// of it, so there is no telling without asking for more.
    func hasOlder(loaded: Int) -> Bool {
        loaded >= limit
    }
}
