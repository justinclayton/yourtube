# YourTube domain glossary

Terms recorded here as they're settled, not written up front. See
`docs/agents/domain.md` for how agents should use this file.

## WatchState

The viewer's relationship to a video: watched, earmarked to Up Next, or
partway through. Backed by five fields on `Video` — `isWatched`,
`savedForLaterAt`, `upNextOrder`, `resumePositionSeconds`, `lastPlayedAt` —
and `WatchState` (`YourTube/WatchState/`) is their only writer and their only
reader, so "what does marking a video watched clear" and "what order is Up
Next in" each have exactly one answer in the app, not one per call site.

Settled during `/grilling` on issue #59 (2026-09-16):

- **Watched always clears position.** `markWatched` unconditionally clears
  `savedForLaterAt`, `upNextOrder`, and `resumePositionSeconds`, from every
  entry point (swipe, "Mark all watched", the 90% auto-rule, the manual
  button). A finished video restarts from the top if replayed. Previously
  three call sites each cleared a different subset, which is what let
  un-watching a swipe-watched video resurrect it in Continue Watching at its
  old position.
- **Unwatching is just `isWatched = false`.** It doesn't restore Up Next
  membership or a position — there's nothing to restore, since watched
  already cleared both.
- **`upNextOrder` is nil only pre-migration.** `earmark` assigns a position
  immediately; `migrateLegacySaves()` backfills any that predate Up Next, at
  launch. In steady state no entry is ever nil, so Up Next's canonical
  predicate/sort (`WatchState.upNextPredicate` / `upNextSortDescriptors`,
  reused by every `@Query` that lists it) never has to resolve a nil-first
  vs. nil-last disagreement.
- **`move` takes the caller's displayed array**, not a re-fetched one — the
  offsets SwiftUI's `onMove` hands in always index what was actually shown,
  so they can't drift from a separately-sorted internal fetch.

Not this module's job: `ShowManager.nextUp`/`isResumable` (which episode
"Play next" opens) stay on `ShowManager`, since they're about show-scoped
play order, not the fields themselves.
