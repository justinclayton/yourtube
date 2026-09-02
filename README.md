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
its ten most recent video titles; output is constrained to one name from the
current category list. Nothing leaves the device and there's no API cost.

- Runs once per channel in the background after launch and after each refresh;
  ~1.5 channels/second on an M4, so a 600-channel library takes about 7 minutes
  the first time, then only new subscriptions are classified.
- Channels the model refuses (its safety guardrail trips on some names) or
  answers off-list for stay **Uncategorized** rather than being filed wrongly.
- Filing a channel by hand (swipe or long-press in Channels) is permanent: the
  classifier never overwrites a user-set assignment.
- Categories are editable in Settings. Adding one and pressing "Re-sort all"
  lets the model consider it.

Requires iOS 26 and a device that supports Apple Intelligence (iPhone 15 Pro or
later). Elsewhere the feature degrades to manual filing only. The classifier's
self-reported confidence turned out to be noise — it hedged on more than half
of clear-cut channels — so the app trusts the category answer alone.

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

## Tests

Run with Cmd-U. Coverage is concentrated where the risk is:

- `ShortsHeuristicTests` — the only component that guesses.
- `YouTubeAPITests` — pagination, batching, and error classification, against
  stubbed responses. Pagination gets attention because a loop there would burn
  the daily quota.
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
