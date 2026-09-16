import Foundation

/// Keeps the first title a feed row drew for as long as that row stays on
/// screen, so a title rewrite batch (#65) landing underneath an already
/// visible row doesn't change its text mid-scroll.
///
/// Pulled out of `FeedVideoRow` as a plain value type so the latch itself has
/// a fast, deterministic unit test independent of SwiftUI's view lifecycle —
/// see `TitleLatchTests`. The view stores one of these in `@State`, which is
/// what gives it the right lifetime: state tied to a row's identity survives
/// the feed's `sections` being recomputed, and resets only when the lazy
/// list actually discards and recreates the row (e.g. once it has scrolled
/// far enough off screen). See issue #68.
struct TitleLatch: Equatable {
    private(set) var value: String?

    /// Records `current` as the latched title, unless something is already
    /// latched. Call this every time the row appears; only the first call
    /// per row lifetime has any effect.
    mutating func capture(_ current: String) {
        guard value == nil else { return }
        value = current
    }

    /// What the row should show: the latched title once one has been
    /// captured, otherwise `current` — so the very first render (before
    /// `capture` has run) shows the right thing with no flash.
    func displayTitle(current: String) -> String {
        value ?? current
    }
}
