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
| Hiding Shorts | Heuristic, ~95% accurate. There is no `isShort` flag in the API. |
| Watch Later, watched state | Works, stored **on-device**. YouTube's own Watch Later isn't API-accessible. |
| Search | Works, **local only**: filters cached titles and channel names on device. The API's search endpoint costs 100 quota units per call, so it isn't used. |
| Playback | Works, via YouTube's IFrame player. |
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

### 5. TestFlight

Archive and upload to App Store Connect, then add yourself as an **internal
tester**. Internal testing needs no App Review.

Builds expire **90 days** after upload, so this is a quarterly chore. Set a
calendar reminder.

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
simulator.

### Fixture data without a login

Debug builds accept a `-seedFixtures` launch argument. The app then opens an
in-memory store pre-filled with a few subscriptions, categories, and videos
(see `DebugFixtures.swift`) and skips `Config.plist`, so it runs signed out
with the re-auth banner showing. Use it to poke at local-only features such
as search, category chips, and the daily cap on a fresh simulator, or after
the weekly token expiry. Nothing touches disk; relaunch without the flag to
get the real store back.

Xcode: *Product > Scheme > Edit Scheme > Run > Arguments Passed On Launch*.
Command line: `xcrun simctl launch "YourTube Dev" net.claytons.yourtube -seedFixtures`.
The `yourtube-sim-fixtures` entry in `.claude/launch.json` carries it.

## Tests

Run with Cmd-U. Coverage is concentrated where the risk is:

- `ShortsHeuristicTests` — the only component that guesses.
- `YouTubeAPITests` — pagination, batching, and error classification, against
  stubbed responses. Pagination gets attention because a loop there would burn
  the daily quota.
- `CategoryManagerTests` — rule migration, multi-answer resolution, and the
  "contains" feed predicate, against a stub classifier.
- `ChannelDailyCapTests` — the per-channel daily cap that folds a prolific
  channel's extra uploads into a "+N more" row.
- `ISO8601DurationTests`, `PKCETests`, `SubscriptionTests`.

**The Shorts corpus is synthetic.** The cases in
`ShortsHeuristicTests.corpus` are hand-written to cover the decision boundary,
not captured from live API responses. Replace them with real `videos.list`
output before trusting the precision and recall figures.

## Roadmap

Built so far: sign-in, subscription feed with Shorts filtering, playback,
watch-later, watched state, browse by channel, on-device channel categories
with a category filter on the feed.

Next: per-video categorisation for channels that mix topics, probably via
`NLEmbedding` against the `VideoCollection` centroids that are already modelled.

## Non-goals

Downloading, ad blocking, App Store distribution, multi-user, comments.
