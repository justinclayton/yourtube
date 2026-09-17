# Is YouTube's own category good enough to replace the classifier?

Spike for issue #129. Run on 2026-09-17 against the signed-in store: 629
subscriptions, 620 of them filed by the on-device classifier at version 4.

Reproduce with Settings → Categories → "Export classifier evidence", then:

```
scripts/category-agreement.sh yourtube-categories-<n>.json
```

The run this document is written from is checked in beside it, as
[`129-category-agreement-report.txt`](129-category-agreement-report.txt). The
export itself is not: it carries every channel title, description and recent
video title in the subscription list.

## Answer

**Keep the classifier, and don't build a pre-filter.** YouTube's category is
silent about half the subscription list, and where it does speak it is too
coarse to name a category in this taxonomy — 42% at the absolute best, and
that best is measured with hindsight.

A separate finding fell out of the run: the second-category mechanism added in
classifier v4 is effectively dead on this store, firing on 2 channels out of
629. That is a defect, not a design result — see "The signal is wired to the
wrong names" below.

## 1. Agreement rate

296 channels have both a clear YouTube majority category and a filing to
compare it against. Taken literally — YouTube's category name equals the
category the channel is filed under — they agree on 16, or 5%.

That number means almost nothing, because the two taxonomies don't share a
vocabulary. YouTube has "Comedy"; this device has Stand-up, Sketches and Panel
Shows. So the fair measure is the generous one: for each YouTube category, how
often is the channel's filing that category's *most common* filing? That is
the ceiling a perfect hand-written mapping could reach.

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
subscriptions**. Dropping YouTube's three catch-alls (People & Blogs,
Entertainment, Education) lifts it to **54%, over 30% of subscriptions**.

That ceiling is fitted on this very data — it picks each YouTube category's
winning filing after seeing the answers — so real performance on a new channel
would be lower. Read it as "not even in principle", not as a forecast.

## 2. Is YouTube's taxonomy too coarse?

Yes, and the table above is the argument. Only News & Politics (83%) predicts
a single category with any confidence; Sports, Autos & Vehicles and Nonprofits
& Activism are pure but have two or three channels between them.

Every category that carries real weight here splits:

- **Comedy** (50 channels) is four different things on this device. Stand-up
  is the plurality at 24, but seven Comedy-filed channels are filed under
  News — political comedy, which YouTube has no way to express.
- **Music** (49) splits across Music Production, Music Commentary, Artists and
  Music Gear. YouTube's "Music" says the subject is music, not whether the
  channel makes it, reviews the gear, or talks about it.
- **Science & Technology** (26) is mostly 3D Printing here, then Science,
  Software and Music Gear.

And the catch-alls are worse than silence: Entertainment (46 channels, 22%)
and People & Blogs (34, 15%) are what an uploader picks when nothing fits, so
they carry almost no information about the subject.
`YouTubeCategorySignal` is already right to map them to nothing.

The gap isn't fixable by mapping harder. YouTube's 44 IDs are one axis —
broad subject — and this taxonomy's two dozen names encode subject *and* format
(Stand-up vs Sketches vs Panel Shows, Music Production vs Music Commentary).
No function from the first to the second exists.

## 3. Would a pre-filter pay?

Only 194 of 629 channels (31%) have a YouTube signal that is both a clear
majority and not a catch-all. Skipping the LLM on exactly those:

- saves **at most 31% of classifier calls**;
- files them at **54% at best** — the hindsight ceiling — against a classifier
  that a spot-check of the table's leading filings says is broadly right;
- costs a visible wrong chip on the feed for the rest.

The call it saves is ~1s, once per channel, cached forever as a rule, run in
the background off the main context. There is no user-visible cost to buy back
here, and precision over recall is the stated policy (`CategoryDecision`).
Not worth it.

## The signal is wired to the wrong names

`YouTubeCategorySignal.taxonomyByYouTubeCategoryId` maps YouTube's IDs onto
`CategoryManager.defaultCategoryNames`, and only yields a suggestion when the
target name is in the live taxonomy. This device's taxonomy has none of
Comedy, Games, Makers & DIY, Music & Audio Gear, News & Politics or
Tech & Engineering — only Cars and Film & TV survive.

So the signal fires on 15 of 629 channels, and **2 rules in the whole store
carry a second category from YouTube**. The v4 mechanism is, in practice, off.

This is worth its own issue: either re-point the mapping at something that
survives an edited taxonomy, or drop the second-category path and let the
model's single answer stand. Since the numbers above say a YouTube-derived
second category would be right less than half the time, dropping it is the
cheaper answer — but that is a design call, not this spike's.

## Limits of this data

- **No labelled data.** `isUserSet` is false for all 629 channels: nobody has
  corrected a filing by hand, so "agreement with the user's final category",
  as issue #129 asks for it, cannot be measured. Everything above compares
  YouTube against the *model*, which means a channel both get wrong counts as
  disagreement, and one they both get wrong in the same way counts as
  agreement. The direction of the conclusion is not in doubt at 42% — the
  exact figure is soft.
- **The coverage numbers are young.** `snippet.categoryId` is stored on
  hydration and has never been backfilled, so it is present on 1665 of 2303
  videos published this month and on essentially none published before.
  The 52% of channels with no YouTube category at all is mostly "hasn't
  uploaded since the field shipped", and will shrink. It will not reach zero:
  a dormant channel never gets one.
- **One device, one taxonomy.** The coarseness argument would soften on a
  device that kept the seeded `defaultCategoryNames`, which are closer to
  YouTube's own shape. It would not reverse: the catch-alls and the missing
  coverage are properties of YouTube's data, not of this taxonomy.
