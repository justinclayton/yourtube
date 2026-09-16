import SwiftUI
import SwiftData

/// Keeps a derived number — a badge, a library total — in step with the store
/// without holding a live query over the rows it is derived from.
///
/// `@Query` is the obvious way to keep a count honest, but a query lives as
/// long as its view does, and `TabView` keeps every tab alive: a counting
/// query on the Shows tab re-ran on every store change while the Channels tab
/// was the one on screen, fetching thousands of rows to produce a handful of
/// numbers. See issue #66.
///
/// This runs the caller's fetch instead: once when the view appears, again
/// after each save while it is on screen, and never once it has gone away —
/// `task(id:)` is cancelled on disappear, so a hidden tab counts nothing.
///
/// Saves arrive in bursts (a feed refresh saves a page at a time), so a
/// recomputation is scheduled a moment after a save and rescheduled if
/// another lands, which collapses a burst into one pass.
extension View {
    /// - Parameters:
    ///   - id: Recomputes from scratch whenever this changes, the way
    ///     `task(id:)` does. Pass whatever the count depends on besides the
    ///     store itself — the Shorts toggle, the shows on screen.
    ///   - settle: How long to wait for a burst of saves to finish.
    ///   - recompute: Reads the store and updates the view's state.
    func recomputingFromStore<ID: Equatable>(
        id: ID,
        settle: Duration = .milliseconds(200),
        _ recompute: @escaping @MainActor () -> Void
    ) -> some View {
        task(id: id) {
            recompute()
            var scheduled: Task<Void, Never>?
            defer { scheduled?.cancel() }
            for await _ in NotificationCenter.default.notifications(named: ModelContext.didSave) {
                scheduled?.cancel()
                scheduled = Task { @MainActor in
                    try? await Task.sleep(for: settle)
                    guard !Task.isCancelled else { return }
                    recompute()
                }
            }
        }
    }
}
