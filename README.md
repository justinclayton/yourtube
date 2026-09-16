# YourTube

A personal iOS YouTube client: subscription feed only, no Shorts, no
recommendations. Built for one user, distributed through internal TestFlight.

Not intended for the App Store.

## Why this exists

The YouTube app optimises for engagement. This one optimises for "show me what
the channels I chose have posted, newest first, and nothing else."

## What works, and what can't

Some limits here are Google's, not implementation gaps. They're worth knowing
before you build this.

| | Status |
|---|---|
| Subscription feed | Works. Fans out across subscribed channels' uploads playlists. |
| Playlists as shows | Works. Listing a channel's playlists and paging one costs 1 unit per call, spent only on demand. |
| Hiding Shorts | Heuristic, ~95% accurate. There is no `isShort` flag in the API. |
| Up Next (earmarks), watched state | Works, stored **on-device**. YouTube's own Watch Later isn't API-accessible, and this app doesn't try to mirror it. |
| Search | Works, **local only**: filters cached titles and channel names on device. The API's search endpoint costs 100 quota units per call, so it isn't used. |
| Playback | Works, via YouTube's IFrame player. |
| Resume position | Works, stored **on-device**. The player reports where it got to; past 90% counts as watched. |
| Background audio | **Not possible.** YouTube kills embedded playback server-side after screen lock. |
| Picture-in-Picture | Only from native fullscreen. |
| Watch history | **Not possible.** Removed from the API years ago. |
| Staying signed in | ~7 days. See "The weekly sign-in" below. |

### The weekly sign-in

While the Google Cloud consent screen is in *Testing* mode, refresh tokens
expire after 7 days. The only way out is publishing the consent screen, which
for YouTube's sensitive scopes triggers a verification process and an annual
audit — not realistic for a personal app.

So: expect to tap "Sign in" about once a week. The app is built around this
rather than fighting it — expiry shows as a banner above the feed, and cached
videos stay readable while signed out.

### Why Shorts detection is a guess

The API has never exposed a Shorts flag. The most accurate signal available is
probing `youtube.com/shorts/{id}` and watching for a redirect (~99% accurate),
but that's an undocumented endpoint, it rate-limits aggressively, and it
arguably breaches the API Terms of Service. This app doesn't use it.

Instead: a video is treated as a Short if it's **3 minutes or under** (YouTube's
cap since late 2024) *and* one of these corroborates it:

- tagged `#shorts` in the title or description;
- a portrait thumbnail (rare — the API reports 16:9 for nearly everything);
- a **pillarboxed thumbnail**: YouTube renders vertical video into a 16:9
  thumbnail with a blurred fill either side. `ThumbnailAnalyzer` downloads the
  small `hqdefault.jpg` (no API quota) and compares edge detail in the side
  strips against the centre. Shorts score well under half; regular videos are
  roughly even. This catches the untagged majority.

Duration alone isn't enough — trailers, clips, and pre-2020 uploads are often
short.

Because it's a guess, Shorts are **hidden, never deleted**. If something you
wanted gets filtered, flip *Show Shorts* in Settings.

## Setup

### 1. Prerequisites

- Xcode 15+ (iOS 17 deployment target)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- An Apple Developer Program membership ($99/yr) — required for TestFlight

### 2. Google Cloud

1. Create a project at [console.cloud.google.com](https://console.cloud.google.com).
2. Enable **YouTube Data API v3** under *APIs & Services > Library*.
3. Configure the **OAuth consent screen**:
   - User type: External, left in **Testing** mode
   - Add scope `https://www.googleapis.com/auth/youtube.readonly`
   - Add your own Google account under **Test users** — without this, sign-in fails
4. Create credentials → **OAuth client ID** → type **iOS**, bundle ID
   `net.claytons.yourtube` (or whatever you set in `project.yml`).
5. Note the **Client ID** and its reversed form.

### 3. Configure the app

```sh
cp YourTube/Resources/Config.example.plist YourTube/Resources/Config.plist
```

Fill in `GoogleClientID` and `GoogleRedirectScheme`. Then put the same reversed
client ID into `YourTube/Resources/Info.plist` under `CFBundleURLSchemes`,
replacing `com.googleusercontent.apps.REPLACE_WITH_YOUR_CLIENT_ID_PREFIX`.

`Config.plist` is gitignored. (The client ID isn't secret — native OAuth clients
use PKCE and have no client secret — but it's per-install.)

### 4. Build

```sh
xcodegen generate
open YourTube.xcodeproj
```

Set your Development Team in *Signing & Capabilities*, then run.

The `.xcodeproj` is gitignored, so pulling commits that add or remove Swift
files leaves it stale ("Cannot find 'X' in scope"). Either rerun
`xcodegen generate`, or install the repo's git hooks once to do it for you
after pulls, checkouts, and rebases:

```sh
git config core.hooksPath scripts/git-hooks
```

### 5. TestFlight

Archive and upload to App Store Connect, then add yourself as an **internal
tester**. Internal testing needs no App Review.

Builds expire **90 days** after upload, so this is a quarterly chore. Set a
calendar reminder.

## Shows and Up Next

The tab bar is Shows, Feed, Channels, Settings. Feed is an **inbox**: videos
appear newest first until you triage them, and once a video is watched or
earmarked it leaves the feed, so the feed trends toward empty instead of
scrolling forever. A fully triaged feed (for the current category/Shorts
filter) shows an "All caught up" state rather than a blank list. Every row
has swipe actions — leading to earmark to Up Next, trailing to mark
watched — so triage is a gesture, not a trip into the player. Category
chips, the Priority chip, the Shorts toggle, the per-channel daily cap, and
local search all keep working over whatever's left in the inbox.

Shows is the calmer library view of that same content, and holds **Up
Next**: the list of videos you've earmarked by hand, from the feed, the
player, or a show page. The app never adds to it and never treats its order
as a play order; Edit lets you group things however you like, and finishing
a video (marking it watched) takes it off the list. Videos saved under the
old Watch Later tab were moved into Up Next in the order they were saved.

Above Up Next sits **Continue Watching**: videos you started and haven't
finished, most recently played first, with a progress bar over the art and
the time left. It fills itself from playback and empties itself, and it's
hidden when there's nothing in progress.

**Your Shows** sits beneath Up Next: a three-column grid of the channels
you've flagged as shows, each a square of channel art with the show's full
name set beneath it and a count of the episodes you haven't watched (no badge
when you're caught up). Posters carry nothing but art and a name, so a show
never looks like a single video. The chips above the grid are the feed's
chips, and a show appears under every category its channel carries; Priority
shows are pinned first.

### The show page

Tapping a poster opens the show: square channel art, where the episodes come
from, and a line of habit — "Posts Tue, Fri · about 1 hr 15 min". Both halves
of that line are computed from the episodes on hand and never stored: the
weekdays are the ones the show has posted on at least twice, and the length is
the median episode rounded to five minutes, so a show that changes its habits
stops claiming the old ones as soon as the new episodes land.

**Play next** opens the right episode in one tap: the newest unwatched for a
daily news show, the oldest for a backlog watched forwards, and — whatever the
play order — an episode you're partway through, where the button reads
*Resume*. **Mark all watched** clears the backlog, badge included; episodes it
marks leave Continue Watching and Up Next like any other finished video, and
ones the retention window hides are left alone.

Below that, the episodes in air order, newest first whatever the play order,
watched ones dimmed and no title truncated. Swipe an episode right to earmark
it to Up Next, left to mark it watched.

**Segments are hidden.** A news hour posts its full episode and then cuts a
handful of clips out of it, and on a channel like that three uploads in four
are cut-downs. A video shorter than half a typical episode is taken to be one
of those clips: left off the page, left out of the unwatched count, and
offered behind a *Show N segments* button beside the count that explains it.
Play next and the player's Next episode land on full episodes only — following
a clip with another clip is the app repeating itself.

The rule is by length rather than by title, because titles are the one thing a
channel changes without warning. "Typical" can't be the plain median (on a
mostly-clips channel the median *is* a clip) nor the longest episode (one
three-hour election special would demote every ordinary episode), so it's read
from the top down: set aside the longest tenth of the show — never fewer
than the two longest — and take the median of everything at least half as long
as what's left. On a show that cuts nothing up, nothing is set aside and the
answer is the ordinary median, so nothing is classified.

**Retention** is the other way the page keeps quiet: *keep the last N
episodes*, and the older ones drop off the page and out of the counts with a
footer saying how many went and why. Neither kind of hiding deletes anything
or touches the store — hidden episodes and segments are still in the feed,
still searchable, still there when the setting is cleared. It's the same
policy as Shorts hiding.

Four per-show settings live behind the button in the top corner. **Play order**
is the newest-first/oldest-first choice above. **Segments** is a slider from a
tenth to nine tenths of a typical episode, captioned with the length it draws
the line at and how many of the show's videos fall below it, so the effect is
visible while it's being set rather than after. **Retention** is the keep-the-
last-N choice. **Card art** decides whether the show's episodes use the
channel's art or the videos' own thumbnails — for a channel whose avatar
carries no information — and applies to the show's cards in Continue Watching
and Up Next as well as to the page. Other shows are unaffected; a show's
poster in the grid is always channel art, because that's what makes it a show
and not a video.

Flag a channel as a show from the Channels tab: swipe it, long-press it, or
use its Categories sheet. Both answers are recorded — "Not a show" is stored
as a standing decision, so the automatic detector below can't overrule either
one. Channels marks its shows with a small screen icon and lists them first
inside each category, above a rule that reads "Other channels", so the split
the app has made is visible at a glance; a category that is all shows or no
shows has no rule to draw. A show's episodes are every non-Short video from
its channel, resolved live, so a new upload is an episode the moment it
lands.

A channel-backed show can also be un-flagged from its own page: the toolbar
menu next to Show settings offers "Not a show" too, for when a detector guess
turns out wrong and Channels isn't where you're looking. It records the same
standing decision and leaves the page, since the show is no longer in the
catalogue.

### Shows that are playlists, not channels

A channel isn't always the unit you think in. A podcast hosted on a network
channel is its own show, and a series-based show has a playlist per series.
So a playlist can be a show: long-press a channel in the Channels tab and pick
**Add playlist as show**, or use the button on the channel's own page.

The sheet lists the channel's playlists with their video counts. Pick one and
that playlist is the show. Pick several and they become one show with a season
each, in the order you tap them — the show page then offers a season picker
that narrows the episode list, and Play next follows whatever season you're
looking at. The source line reads "Playlist on Team Coco" rather than
"Channel".

A playlist-backed show inherits its channel's categories and Priority tag, so
there is nothing to file twice and no second rule to keep in step. It sits in
Your Shows under the same chips as its channel, and the grid, the page,
Play next, Next episode, Mark all watched, segment hiding and the retention
window all behave as they do for a channel-backed show. Picking a season
narrows all of it: the segments and the retention window are measured over
the season you're looking at, so an older series still lists its episodes on
a show told to keep only its last few.

The one difference is where its episodes come from. A channel's episodes
arrive with the routine refresh; a playlist's membership is a list only
YouTube knows, so it is asked for when the show is created and again when its
page is opened — one quota unit per 50 items, never during the routine
refresh. New videos a playlist turns up are stored through the same door the
feed uses, Shorts verdict first, so they show up in the feed too. Signed out,
nothing is asked and the page lists what the store already holds.

### Guessing which channels are shows

Most shows file themselves. After a refresh (and at launch) a detector reads
each channel's stored videos and guesses, so Your Shows fills up without your
doing anything. It's guesswork of the same kind as the Shorts heuristic: a
channel has to have a few full-length uploads to be considered at all, and
then several weak signals are summed against a threshold — a median duration
over twenty minutes, a regular posting slot, numbered episode titles,
YouTube's own News & Politics or Entertainment category, and "podcast" or
"episode" in the descriptions. No single signal is enough, because long
videos alone are a maker channel and a reliable schedule alone is a vlog.

Every guess says why. The show page and the channel's Categories sheet list
the reasons the detector found, so a wrong one can be recognised and
corrected rather than just overturned. Corrections are permanent: a channel
you have flagged either way is skipped entirely by every later pass, and a
show you created by hand is never taken back. Adding a playlist-backed show
is not a decision about its channel, though — a channel that only hosts a
playlist show still gets its own verdict from the detector. Channels are
examined once and then only again when their uploads actually move.

The player offers a Next episode button whenever the video it's playing
belongs to a show and a later episode exists — it swaps the player to that
episode in place, never leaving the show. It's absent on a non-show video and
on a show's newest episode. There's no autoplay of any kind.

Channels itself has two presentations, toggled from the toolbar: the
grouped list, and an avatar grid of square channel art with the full name
wrapped beneath (never truncated). Both read the same category grouping and
draw the same show/not-show split — shows first, then the rule, then the
rest; the toggle is remembered across launches.
Tapping a tile opens the channel page, and long-press offers the same menu
as the list row — categories, Priority, and the show flag.

### Resume and the 90% rule

The player remembers where you stopped and opens there next time. Two
thresholds decide what that means: under thirty seconds in counts as never
started (so a glance at a video doesn't clutter Continue Watching), and past
90% of the duration counts as watched — no tap needed, and the video leaves
both Continue Watching and Up Next. Opening the player on its own no longer
marks anything watched, and the manual "Mark watched" button still works.
All of this is on-device; YouTube's own watch history isn't API-accessible.

The player polls its position every two seconds but only writes to the store
when it's moved fifteen seconds or more, on pause, and on leaving the
player — a store write reruns every live query in the app, so writing on
every poll made the whole UI redo work for as long as a video played. Resume
still lands within about fifteen seconds of where you stopped.

## Titles

YouTube titles carry two things at once: what the video is, and which channel
it came from. The second is already on screen beside the title, so the app
strips it. "Mamdani & Staten Island | The Weekly Show with Jon Stewart" reads
as "Mamdani & Staten Island"; "Joe Rogan Experience #2549 - Jared Diamond"
reads as "Jared Diamond" with **Ep. 2549** set beside the date.

Only a channel's titles together can say which part is the repeat, so
`TitleStripper` works on them as a set: it splits each title on the delimiters
channels use for this (pipe, spaced dash, colon, bullet), lifts out an episode
number ("#142", "Ep. 31", "S20 Ep.4", "Series 19 Episode 11"), drops segments
that are nothing but a marker like "FULL EPISODE", and then removes the first
or last segment when most of the channel's titles carry the same one.

It errs towards leaving titles alone:

- A channel with no repeated affix comes through byte-for-byte. A title
  nothing is taken out of is never tidied either, so YouTube's own double
  space or trailing ellipsis survives and the player doesn't set a duplicate
  original beneath a line that reads the same.
- A delimiter is not on its own evidence — Knowing Better pipes a different
  series name onto every upload, and keeps all of them.
- When every part of a title is boilerplate, nothing is stripped: Trolden's
  "Funny And Lucky Moments - Hearthstone - Ep. 680" keeps its name and just
  loses the number, because the alternative is a title that says nothing.
- A phrasing that varies is beyond this pass. Off Menu names itself in every
  title and words it differently each time, so tier one leaves it; that's what
  the rewrite below is for.

### Tier two: the on-device rewrite

What the stripper leaves can still shout. **Episodes of your shows** go one
step further: Apple's on-device language model rewrites the stripped title
into a calm, factual one, so "TOP Election Analyst: 'NIGHTMARE SCENARIO' For
Republicans" stops yelling. `TitleRewriter` opens a fresh `LanguageModelSession`
per title with constrained generation — the model fills a `@Generable` answer
holding one title, so there's no free text to parse — and the instructions
forbid adding anything the original didn't say, forbid capitals for emphasis,
and cap the length.

The app doesn't trust the answer. `TitleRewritePrompt.resolve` collapses
whitespace, drops surrounding quotes, and falls back to the stripped title
whenever the answer is empty or longer than what it was given. A title the
model refuses keeps its stripped version and isn't retried until a version
bump.

It trusts the answer's *capitals* least of all. Asked the same title three
times the model shouted it back verbatim, half-calmed it, and flattened it to
nothing but lower case — and the phone favours that last one, which made
"Lebron James, Syndney Sweeney DISGUSTING Gambling SHILLING" come back as
"lebron james, sydney sweeney gambling shilling". So the model is asked for
the words and `TitleCasing` decides the case, from the title the model was
given: a word written with an inner capital is copied exactly, a word the
source shouted loses the shouting unless it's an initialism, and everything
else is lower case unless it opens a sentence or is a name. Names are found
by `NLTagger`'s person recognition plus "no dictionary has this word", which
is what keeps `Syndney` and `Sweeney` capitalised while `Gambling` and
`Favourite` go down. The result is ordinary sentence case, which is the one
house style that can be derived rather than guessed.

Only show episodes are rewritten: it's one model call per title, and
clickbait is most in the way where the app is pretending to be television.
Episodes are resolved by the same membership rule `ShowManager` uses — every
non-Short upload of a channel-backed show, only the playlist's members for a
playlist-backed one — so the host channel of a podcast playlist keeps tier one
on everything that isn't the podcast. Everything else gets tier one alone, and
so does every device without Apple Intelligence — the feature degrades rather
than disappears, and Settings says why the toggle is off.

**Settings → Titles → Rewrite show titles** turns tier two off. Tier one's
output is kept alongside the rewrite (`strippedTitle`), so turning it off puts
the stripped titles back without re-running the stripper, and turning it on
rewrites the show episodes again without a second stripping pass.

### Caching

Cleaning runs in the background after launch and after each refresh, never in
front of the feed: results are cached on `Video` (`cleanedTitle`,
`strippedTitle`, `episodeNumber`, `seasonNumber`) and a video with none yet
shows its raw title. Each video records the `TitleCleaner.version` that
produced its result, exactly as the Shorts heuristic does. That version is the
two tiers' versions added together, so bumping either one re-cleans the whole
store on the next launch with no migration — a rewrite judged against a
stripping that has since changed isn't worth keeping.

The player shows YouTube's original title under the cleaned one whenever the
two differ, so nothing the app changed is hidden.

## Categories

Subscribed channels are sorted into categories (Comedy, Music & Audio Gear,
Tech & Engineering, ...) by Apple's on-device language model via the
Foundation Models framework. Input is the channel name, its "about" text and
its ten most recent video titles; output is constrained to one to three names
from the current category list, most relevant first. Nothing leaves the device
and there's no API cost.

A channel can carry several categories at once: a comedian's interview show
is filed under both Comedy and Podcasts & Interviews, and shows up under every
feed chip it carries. The chips themselves stay single-select. The taxonomy is
fixed and editable in Settings rather than free-form tags, because a small
model invents a long tail of near-duplicate tags and that's the opposite of
calm.

- Runs once per channel in the background after launch and after each refresh;
  ~1.5 channels/second on an M4, so a 600-channel library takes about 7 minutes
  the first time, then only new subscriptions are classified.
- Each answer is matched against the list with a tolerant word-overlap
  matcher. Off-list answers are dropped individually; a channel with nothing
  left, or one the model refuses (its safety guardrail trips on some names),
  stays **Uncategorized** rather than being filed wrongly.
- Filing a channel by hand (swipe or long-press in Channels) opens a
  multi-select of categories and is permanent: the classifier never
  overwrites a user-set assignment.
- Deleting a category drops it from every channel without touching the
  channel's other categories. Adding one and pressing "Re-sort all" lets the
  model consider it.
- Bumping `CategoryManager.classifierVersion` makes the next launch re-run the
  classifier over every non-user-set channel once, which is how channels filed
  under a single category before multi-tagging pick up their extra tags.

### Priority

One tag is built in and hand-assigned only: **Priority**, for the handful of
channels you never want to miss. It's pinned first in the chip row and can't
be renamed or deleted. The classifier never sees it, so it's never assigned
automatically and "Re-sort all" never removes it; it rides alongside a
channel's topic categories, so a channel can be both Priority and Comedy and
shows under both chips. Mark or unmark a channel from the swipe or long-press
menu in Channels. Marking a channel Priority doesn't count as filing it by
hand, so the model still sorts its topics. The chip shows no count or unread
badge on purpose.

Requires iOS 26 and a device that supports Apple Intelligence (iPhone 15 Pro or
later). Elsewhere the feature degrades to manual filing only. The classifier's
self-reported confidence turned out to be noise — it hedged on more than half
of clear-cut channels — so the app trusts the category answers alone.

## API quota

The default allowance is 10,000 units/day, resetting at midnight US Pacific.

A full refresh costs roughly `number_of_subscriptions + 4` units — about 104 for
100 channels, so ~95 refreshes/day. Settings shows current usage.

This is affordable only because the app avoids `search.list` (100 units/call)
and derives each channel's uploads playlist ID by rewriting the `UC` prefix to
`UU` instead of calling `channels.list`.

`activities.list` — the endpoint that looks like it should return a subscription
feed — has been functionally broken since around 2020 and isn't used.

## Layout

```
YourTube/
  App/        Entry point, DI wiring, config loading
  Auth/       Google OAuth (PKCE), Keychain, token lifecycle
  API/        YouTube Data API client, DTOs, quota tracking
  Feed/       Refresh algorithm, Shorts heuristic, thumbnail analysis
  UpNext/     The earmark list behind the Shows tab
  Shows/      The show catalogue behind Your Shows, and the show detector
  Categorize/ On-device channel classification, category management
  Model/      SwiftData models
  UI/         SwiftUI views
YourTubeTests/
```

## Development loop

Run and test on **one** simulator, named `YourTube Dev`, and never erase it.
The refresh token lives in that device's Keychain and the Google web login in
its cookie jar, so signing in is a weekly one-tap affair rather than a
password-and-2FA trip on every fresh device. Debug builds keep the Google
cookies for this reason (`prefersEphemeralWebBrowserSession` is false only
under `DEBUG`); release builds still isolate the session.

If the device doesn't exist yet:

```sh
xcrun simctl create "YourTube Dev" "iPhone 17 Pro"
```

`.claude/launch.json` targets it by UDID because `xcodebuild` doesn't
reliably resolve the name; update the `id=` there after creating the device
(`xcrun simctl list devices | grep "YourTube Dev"`).

Agents: pass `device: "YourTube Dev"` when building or launching in the
simulator. The simulator tool's tap and swipe coordinates are device points
(402×874 on an iPhone 17 Pro, as `attach` reports), not the pixels of the
screenshot it returns (1206×2622): divide by three, or taps silently miss.

### Parallel work: the simulator pool

`YourTube Dev` is the only simulator that holds the signed-in store, and the
only reason to keep to one device is that store. Unit tests and
`-seedFixtures` drives never open it, so they can run on throwaway
simulators in parallel. Create a pool of three matching devices once:

```sh
for i in 1 2 3; do
  xcrun simctl boot "$(xcrun simctl create "YourTube Test $i" \
    com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro \
    com.apple.CoreSimulator.SimRuntime.iOS-26-2)"
done
```

`scripts/simpool.sh acquire <name>` prints the UDID of a free booted
`YourTube Test N` (waiting if all are busy), `release <name>` hands it back,
and `status` lists the pool. Run tests and fixture drives on the UDID it
gives you; screenshots come out identical to the Dev device. Keep
`YourTube Dev` for drives that need the real data, and never uninstall or
erase it.

### What keeps the data, and what wipes it

The signed-in store (`Library/Application Support/default.store` inside the
app's data container) survives everything that *replaces* the app and dies
with anything that *removes* it. iOS keeps a data container for as long as
the bundle id stays installed, whichever build is in it:

| Keeps the store | Wipes the store |
| --- | --- |
| Xcode Run (Cmd-R) | `xcrun simctl uninstall "YourTube Dev" net.claytons.yourtube` |
| `xcrun simctl install "YourTube Dev" <path>.app` over an existing install | `xcrun simctl erase` |
| `xcodebuild test` (installs the test host the same way) | Deleting the app from the home screen |
| `xcrun simctl launch ... -seedFixtures` (in-memory store, own defaults) | Deleting the simulator |

Never uninstall to "get a clean state". `-seedFixtures` is the clean state,
and it costs nothing; an uninstall costs the 6,000-video store and a
re-login. Installing a different branch's build is fine: SwiftData migrates
the store forward for additive schema changes, and a build that can't open
the store fails loudly with its setup screen rather than touching it.

Before anything you're unsure of, copy the store out:

```sh
C=$(xcrun simctl get_app_container "YourTube Dev" net.claytons.yourtube data)
cp "$C/Library/Application Support/"default.store* ~/Desktop/yourtube-store-backup/
```

To put it back, terminate the app, copy `default.store` over the one in the
container, delete the `-wal` and `-shm` files beside it, and launch. The
container path changes after every reinstall, so always re-run
`get_app_container` rather than reusing a saved path.

### Fixture data without a login

Debug builds accept a `-seedFixtures` launch argument. The app then opens an
in-memory store pre-filled with a few subscriptions, categories, videos, and
five show-shaped channels — a twice-weekly long-form interview show, a
numbered weekly podcast, a weekday news hour with cut-down segments, one left
unflagged for the detector to find at launch, and one marked "Not a show" that
it must never pick up — plus two playlist-backed shows: a podcast hosted on a
network channel, and a three-series programme whose page offers a season
picker (see `DebugFixtures.swift`). It skips `Config.plist`,
so it runs signed out
with the re-auth banner showing. Use it to poke at local-only features such
as search, category chips, and the daily cap on a fresh simulator, or after
the weekly token expiry. The store is in memory and `UserDefaults` (quota,
classifier and detector bookkeeping, settings) go to a separate suite that is
reset on each fixture launch, so the real store and the real defaults are
never opened; relaunch without the flag to get them back. It is a launch
argument, not a reinstall: don't pair it with `simctl uninstall`, which
deletes the real store (see above).

Xcode: *Product > Scheme > Edit Scheme > Run > Arguments Passed On Launch*.
Command line: `xcrun simctl launch "YourTube Dev" net.claytons.yourtube -seedFixtures`.
The `yourtube-sim-fixtures` entry in `.claude/launch.json` carries it.

## Tests

Run with Cmd-U. Coverage is concentrated where the risk is:

- `ShortsHeuristicTests` and `ShowDetectorTests` — the two components that
  guess. The show detector is run against a corpus of the six shapes that sit
  on its boundary: a twice-weekly news show, a numbered podcast, a daily news
  show buried in its own segments, a maker channel, a vlog, and a clips
  channel.
- `FeedRefresherTests` — a refresh against stubbed API and thumbnail
  responses. Pins that a new video never reaches the store before its Shorts
  verdict, since the feed observes the store live.
- `YouTubeAPITests` — pagination, batching, and error classification, against
  stubbed responses. Pagination gets attention because a loop there would burn
  the daily quota.
- `CategoryManagerTests` — rule migration, multi-answer resolution, and the
  "contains" feed predicate, against a stub classifier.
- `ShowManagerTests` — the show catalogue: membership for both kinds of show
  (a channel's non-Short videos, a playlist's items — Shorts are never
  episodes either way), seasons and the picker's filter,
  episode-versus-segment classification at the threshold and when the
  threshold moves, unwatched counts under a retention window, what Play next
  opens under each play order (an episode in progress always winning), the
  cadence weekdays and typical duration behind the show page's habit line,
  and the thing most worth pinning — a hand-made show flag, in either
  direction, surviving an automatic detector pass.
- `ShowDetectionRunnerTests` — the pass that joins the detector to the
  catalogue: what it flags, what it is forbidden to touch, and the fingerprint
  that stops it re-judging a channel whose uploads haven't moved.
- `ChannelDailyCapTests` — the per-channel daily cap that folds a prolific
  channel's extra uploads into a "+N more" row.
- `TitleStripperTests` — the title cleaner, driven against **real** per-channel
  title lists captured from the signed-in store (the file says which lists are
  captured and which are hand-written): shared prefix and suffix found and
  removed, episode numbers extracted, unpatterned channels untouched.
- `TitleCleanerTests` — the bookkeeping around both tiers, with the model
  stubbed the way `CategoryManagerTests` stubs the categorizer: channels judged
  against their own titles, show episodes rewritten and everything else left
  with tier one (a playlist-backed show's host channel included), the Settings
  toggle restoring and re-running the rewrite, and a version bump re-running
  both tiers.
- `TitleRewriterTests` — what the model is told and what the app believes of
  the answer: the constraints present in the instructions, and the fallback to
  the stripped title on an empty or over-long answer.
- `ISO8601DurationTests`, `PKCETests`, `SubscriptionTests`.

**The Shorts corpus is synthetic**, and so is the show detector's. The cases
in `ShortsHeuristicTests.corpus` and `ShowDetectorTests` are hand-written to
cover the decision boundary, not captured from live API responses. Replace
them with real `videos.list` output before trusting the precision and recall
figures.

## Roadmap

Built so far: sign-in, subscription feed with Shorts filtering, playback,
Up Next, watched state, browse by channel, on-device channel categories with a
category filter on the feed, shows in the Your Shows grid — flagged by
hand or guessed, with reasons, by the show detector — and title cleaning in
both tiers: the deterministic stripper everywhere, the on-device rewrite on
show episodes.

Next: per-video categorisation for channels that mix topics, probably via
`NLEmbedding` against the `VideoCollection` centroids that are already modelled.

## Non-goals

Downloading, ad blocking, App Store distribution, multi-user, comments.
