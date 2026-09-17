# Is YouTube's own category good enough to replace the classifier?

Spike for issue #129. Run on 2026-09-17 against the signed-in store: 629
subscriptions, 620 of them filed by the on-device classifier at version 4.

## What this spike could not answer

Issue #129 asks whether the custom categorization work is pulling its weight.
**This does not answer that**, and no amount of the data below would.

`ChannelRule.isUserSet` is false for all 629 channels: nobody has ever
corrected a filing by hand, so there is no ground truth. Everything here
compares YouTube's filing against the *model's*, which means two guessers
being compared to each other. A disagreement says one of them is wrong
without saying which, and an agreement can be two identical mistakes.

So the question this spike does answer is the narrower one: **would YouTube's
own category be a usable substitute for, or pre-filter on, the classifier
pass?** That one turns out to be answerable without ground truth, because the
answer is no on structural grounds.

Answering the original question needs a different spike: file fifty channels
by hand in the Channels tab, then measure both sources against those.

## Answer

**Keep the classifier, and don't build a pre-filter.** YouTube's category is
silent about most of the subscription list, and where it does speak it is too
coarse to name a category in this taxonomy — 42% at the absolute best, and
that best is measured with hindsight.

A separate finding fell out of the run, and is worth more than the rest of it:
the second-category mechanism added in classifier v4 is effectively dead on
this store, firing on 2 channels out of 629. That is a defect, not a design
result — issue #130.

## Method

The numbers come from the SwiftData store on the signed-in simulator, copied
aside and queried read-only. Everything needed is also in the export from
Settings → Categories → "Export classifier evidence", which carries
`youtubeCategoryVotes` — each channel's stored `snippet.categoryId`s, counted
live — alongside its filing.

Three definitions, matching what the app itself does:

- **A channel's YouTube category** is the majority `categoryId` among its
  stored videos, needing more than half the votes, the way
  `YouTubeCategorySignal.suggestion(for:taxonomy:)` decides. Videos with no
  stored category don't vote.
- **Catch-alls** are People & Blogs, Entertainment and Education — what an
  uploader picks when nothing fits. `YouTubeCategorySignal` already maps them
  to nothing.
- **The ceiling** is, for each YouTube category, the share of its channels
  filed under that category's single most common filing. It is what a perfect
  hand-written mapping could reach, chosen after seeing the answers.

## 1. Coverage

| | channels | |
| --- | ---: | ---: |
| no video carries a `categoryId` | 324 | 52% |
| majority is a YouTube catch-all | 107 | 17% |
| no clear majority | 4 | 1% |
| **usable YouTube signal** | **194** | **31%** |

The 52% is largely an artifact and will shrink — see "Limits" below.

## 2. Agreement

296 channels have both a clear YouTube majority and a filing to compare it
against. Taken literally — YouTube's category name equals the category the
channel is filed under — they agree on 16, or 5%.

That number means almost nothing, because the two taxonomies don't share a
vocabulary. YouTube has "Comedy"; this device has Stand-up, Sketches and Panel
Shows. The ceiling is the fair measure:

| YouTube category | channels | ceiling | how the filings split |
| --- | ---: | ---: | --- |
| Comedy | 50 | 48% | Stand-up 24, News 7, Panel Shows 6, Sketches 5 |
| Music | 49 | 51% | Music Production 25, Music Commentary 9, Artists 6, Music Gear 3 |
| Entertainment | 46 | 22% | Stand-up 10, Film & TV 4, Panel Shows 4, Podcasts 4 |
| People & Blogs | 34 | 15% | 3D Printing 5, Stand-up 5, Music Production 3, Panel Shows 3 |
| Science & Technology | 26 | 46% | 3D Printing 12, Science 6, Software 4, Music Gear 2 |
| Education | 25 | 24% | Science 6, Explainers 5, Other 4, Education 2 |
| Gaming | 20 | 55% | Gaming 11, Other 3, Animation 1, Film & TV 1 |
| News & Politics | 18 | 83% | News 15, Explainers 2, Stand-up 1 |
| Film & Animation | 13 | 54% | Film & TV 7, Animation 3, Artists 1, Film Essays 1 |
| Howto & Style | 7 | 29% | Other 2, 3D Printing 1, Animation 1, Music Production 1 |
| Sports | 3 | 100% | Sports 3 |
| Autos & Vehicles | 2 | 100% | Cars 2 |
| Pets & Animals | 2 | 50% | Animation 1, Stand-up 1 |
| Nonprofits & Activism | 1 | 100% | Film & TV 1 |

**124 of 296 = 42%** of comparable channels, which is **20% of all 629
subscriptions**. Dropping the catch-alls lifts it to **54%, over 30% of
subscriptions**.

Read the ceiling as "not even in principle", not as a forecast: it is fitted
on this very data, so real performance on a new channel would be lower.

## 3. Is YouTube's taxonomy too coarse?

Yes, and the table is the argument. Only News & Politics (83%) predicts a
single category with any confidence; Sports, Autos & Vehicles and Nonprofits &
Activism are pure but have two or three channels between them.

Every category carrying real weight splits:

- **Comedy** (50) is four things here. Stand-up is the plurality at 24, but
  seven Comedy-filed channels are filed under News — political comedy, which
  YouTube has no way to express.
- **Music** (49) splits across Music Production, Music Commentary, Artists and
  Music Gear. YouTube's "Music" says the subject is music, not whether the
  channel makes it, reviews the gear, or talks about it.
- **Science & Technology** (26) is mostly 3D Printing, then Science, Software
  and Music Gear.

The catch-alls are worse than silence: Entertainment (46, 22%) and People &
Blogs (34, 15%) carry almost no information about the subject.

This is the part that was foreseeable from reading the two lists side by side.
YouTube's 44 IDs are one axis — broad subject — and this taxonomy's two dozen
names encode subject *and* format (Stand-up vs Sketches vs Panel Shows, Music
Production vs Music Commentary). No function from the first to the second
exists, and no amount of mapping effort creates one.

## 4. Would a pre-filter pay?

Skipping the LLM on exactly the 194 channels with a usable signal:

- saves **at most 31% of classifier calls**;
- files them at **54% at best**, the hindsight ceiling;
- costs a visible wrong chip on the feed for the rest.

The call it saves is ~1s, once per channel, cached forever as a rule, run in
the background off the main context. There is no user-visible cost to buy back
here, and precision over recall is the stated policy (`CategoryDecision`).
Not worth it.

## The signal is wired to the wrong names — issue #130

`YouTubeCategorySignal.taxonomyByYouTubeCategoryId` maps YouTube's IDs onto
`CategoryManager.defaultCategoryNames`, and only yields a suggestion when the
target name is in the live taxonomy. This device's taxonomy has none of
Comedy, Games, Makers & DIY, Music & Audio Gear, News & Politics or
Tech & Engineering — only Cars and Film & TV survive.

So the signal fires on 15 of 629 channels, and **2 rules in the whole store
carry a second category from YouTube**. The v4 mechanism is, in practice, off,
while looking alive in the code and green in the tests, which pass
`defaultCategoryNames` as the taxonomy.

## Limits

- **No ground truth.** See the top of this document. The 42% ceiling's
  direction is not in doubt; the exact figure is soft.
- **The coverage numbers are young.** `snippet.categoryId` is stored on
  hydration and has never been backfilled, so it is present on 1665 of 2303
  videos published this month and on essentially none published earlier. The
  52% of channels with no YouTube category is mostly "hasn't uploaded since
  the field shipped", and will shrink — which weakens §4 specifically, since
  the pre-filter's case rests on coverage. It will not reach zero: a dormant
  channel never gets one. The coarseness argument in §3 doesn't depend on it.
- **One device, one taxonomy.** The coarseness argument would soften on a
  device that kept the seeded `defaultCategoryNames`, which are closer to
  YouTube's own shape. It would not reverse: the catch-alls and the missing
  coverage are properties of YouTube's data, not of this taxonomy.
