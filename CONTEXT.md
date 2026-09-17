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

Not this module's job: which episode "Play next" opens, and whether the
button reads "Resume", are `ShowListing`'s — they're about show-scoped play
order, not the fields themselves.

## ShowListing

What a show shows: one value type over a show's settings (segment threshold,
retention window, play order, seasons), the season being looked at, and a
pile of videos. It answers everything the show page, the Your Shows badge and
the player ask about a show — episodes in air order and in play order,
segments, how many episodes the retention window hides, the unwatched count,
which episode "Play next" opens, the cadence line, the typical length, the
footer — and it never touches the store. `ShowManager.listing(of:)` fetches
the videos; a view with a live `@Query` hands in its own; both get the same
answers because there is only one derivation.

Settled during issue #60 (2026-09-16):

- **One door, not nine stages.** The listing pipeline used to be nine public
  `ShowManager` functions in mirrored instance/static pairs, each carrying a
  comment that it "mirrors *x* exactly", which callers composed themselves.
  The grid's badge and the page's header each hand-rolled
  `filter { !isWatched }.count` over a separately composed chain. Now both
  read `unwatchedCount` off a listing, so they are equal by construction
  rather than by agreement.
- **The season is applied before classification.** Picking a series narrows
  the whole listing — segments, retention window and footer included — so the
  page describes the season in front of you. Filtering afterwards would leave
  an older series empty on a show told to keep only its last few episodes.
- **The page is air order; the play order is only "Play next".** `episodes`
  is newest first whatever the show's play order; `episodesInPlayOrder` and
  `nextUp` are where `oldestFirst` means anything. An episode in progress
  beats the play order either way.
- **One median, one tie-break.** Durations are measured by
  `ShowListing.median`, which takes the shorter of the two middles on an even
  count, so a typical length never overstates and the line the segment rule
  draws at a fraction of it never creeps up into real episodes. This replaced
  two medians that disagreed on even counts. `ShowDetector` keeps a median of
  its own (the mean of the two middles, over day gaps rather than durations);
  sharing this one would move its verdicts.
- **Not this type's job:** the catalogue. Which channels are shows, the
  tombstones, the detector's verdicts and the playlist membership writes stay
  on `ShowManager`, which owns the store.

## Intake

The door videos enter the store by. Everything between "the API handed back
some JSON" and "there is a `Video` row" happens in `VideoIntake`
(`YourTube/Feed/VideoIntake.swift`) and nowhere else: the DTO is mapped to a
`VideoDraft`, the Shorts verdict is reached, and only then is the row
inserted. Three callers use it — the feed refresh, a playlist-backed show's
membership refresh, and `DebugFixtures` — and no other code in the app
constructs a `Video`.

Settled while doing issue #62 (2026-09-16):

- **Classify before inserting.** The feed's `@Query` watches the store, so a
  video inserted before its verdict would appear and then vanish. The insert
  is what's deferred, not the save; a Short is hidden from its first
  appearance.
- **The thumbnail verdict is accepted, not owned.** `ThumbnailVerdict` has two
  adapters: `DownloadedThumbnailVerdict` in the app and
  `CannedThumbnailVerdict` everywhere else. It is the only part of the
  decision that leaves the process, so it is the only seam intake needs — and
  with it, "held until the verdict is known" is a test with no `URLProtocol`
  in it.
- **Fixtures go through the door.** `DebugFixtures` describes videos the way
  the API describes them and hands them to intake with a canned verdict, so
  `isLikelyShort` and `classifierVersion` are reached rather than stamped.
  There is no second way in that can drift.
- **`VideoSignals` has one home.** Both derivations — from a hydrated DTO and
  from a stored row being re-judged — live on `VideoSignals` itself, so the
  two halves of one decision can't read different fields.

Not this module's job: finding out which videos there are. The subscription
list, the channel fan-out, the refresh's phases and the quota they cost stay
on `FeedRefresher`; `ShowManager` still owns the show catalogue, and
`WatchState` still owns watched / Up Next / partway-through.
