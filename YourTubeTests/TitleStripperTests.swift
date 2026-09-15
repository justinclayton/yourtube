import XCTest
@testable import YourTube

/// The title cleaner guesses what part of a title is the channel repeating
/// itself, so it gets real data rather than invented data.
///
/// **Every title list marked REAL below was captured from the signed-in
/// store on the development simulator** (the `ZVIDEO` table of the app's
/// SwiftData store), ten uploads per channel, in the order the feed holds
/// them. They're verbatim, emoji, curly quotes, typos and all — the
/// "Big Fat Qui" at the end of one Big Fat Quiz title is YouTube's, not a
/// transcription slip, and it's worth keeping because it's exactly the kind
/// of near-miss the affix matcher has to not over-reach on.
///
/// The few lists marked SYNTHETIC are hand-written to pin an edge case that
/// the captured channels don't happen to contain.
final class TitleStripperTests: XCTestCase {

    // MARK: - Helpers

    private func cleaned(_ titles: [String]) -> [String] {
        TitleStripper.clean(titles: titles).map(\.title)
    }

    private func labels(_ titles: [String]) -> [String?] {
        TitleStripper.clean(titles: titles).map(\.episodeLabel)
    }

    // MARK: - Shared suffix

    /// REAL: The Weekly Show with Jon Stewart. The plainest case there is —
    /// every upload is "<topic> | <show name>".
    private let weeklyShow = [
        "Mamdani & Staten Island | The Weekly Show with Jon Stewart",
        "Democrats' Leverage | The Weekly Show with Jon Stewart",
        "Reverse Centaur Theory | The Weekly Show with Jon Stewart",
        "The Fed's Independence | The Weekly Show with Jon Stewart",
        "Tucker's Party | The Weekly Show with Jon Stewart",
        "Action vs. Corruption | The Weekly Show with Jon Stewart",
        "Dems 2028 Plan? | The Weekly Show with Jon Stewart",
        "Cost Of Living | The Weekly Show with Jon Stewart",
        "McD's Fries vs. BK Onion Rings | The Weekly Show with Jon Stewart",
        "Cynicism & Free Speech | The Weekly Show with Jon Stewart",
    ]

    func testSharedSuffixIsFoundAndRemoved() {
        XCTAssertEqual(cleaned(weeklyShow).first, "Mamdani & Staten Island")
        XCTAssertEqual(cleaned(weeklyShow).last, "Cynicism & Free Speech")
        XCTAssertFalse(cleaned(weeklyShow).contains { $0.contains("Weekly Show") })
    }

    func testBoilerplateReportsTheSuffixItFound() {
        let boilerplate = TitleStripper.boilerplate(in: weeklyShow)
        XCTAssertEqual(boilerplate.suffix, "the weekly show with jon stewart")
        XCTAssertNil(boilerplate.prefix)
    }

    /// REAL: The Ezra Klein Show. Curly quotes and trailing punctuation have
    /// to survive the trim that tidies up after a strip.
    func testSuffixStripKeepsTheRestOfThePunctuationIntact() {
        let ezraKlein = [
            "Robin Wigglesworth's Book Recommendations | The Ezra Klein Show",
            "How Bad Is America’s $40 Trillion Debt? | The Ezra Klein Show",
            "The Trump Administration's 'Kitchen Sink Approach’ to Lowering Bond Yields | The Ezra Klein Show",
            "What the Heck Is Going On in the Bond Market? | The Ezra Klein Show",
            "Annie Lowrey's Book Recommendations | The Ezra Klein Show",
            "Need Help? Prepare for the ‘Time Tax.’ | The Ezra Klein Show",
            "This Is Why People Hate the Government | The Ezra Klein Show",
            "Brad Setser's Book Recommendations | The Ezra Klein Show",
            "Has Trump’s Trade Policy Achieved Any of Its Goals? | The Ezra Klein Show",
            "Helen Toner's Book Recommendations | The Ezra Klein Show",
        ]
        XCTAssertEqual(cleaned(ezraKlein)[1], "How Bad Is America’s $40 Trillion Debt?")
        XCTAssertEqual(cleaned(ezraKlein)[5], "Need Help? Prepare for the ‘Time Tax.’")
    }

    /// REAL: Don't Tell Comedy. Seven of ten uploads end in the same call to
    /// action and the rest don't, which is what "most of them" has to mean:
    /// the seven lose it, the other three keep what they have.
    func testSuffixCarriedByMostTitlesIsStrippedFromThoseTitlesOnly() {
        let dontTellComedy = [
            "\"Politicians are Too Old\" 🎤: Subhah Agarwal | Full Video on our Channel!",
            "\"Catching a D*ck in the Wild\" | Subhah Agarwal | Stand Up Comedy",
            "\"Dad Got Out of Prison\" 🎤: Nick Murphy | @NickMurphyComedy | Full Video on our Channel!",
            "\"Milking My Wife\" 🎤: Hunter Hill | @HunterHillComedy | Full Video on our Channel!",
            "Parenting Trends are Insane | Hunter Hill | Stand Up Comedy",
            "\"Jury Duty\" 🎤: Chad Goes Deep | @Chadandjtgodeep | Full Video on our Channel!",
            "\"Live Photo D*ck Pic\" 🎤: Sam Biru | @SamBiruComedy | Full Video on our Channel!",
            "\"Arab Friends\" 🎤: Josh Ocean Thomas | @joshoceanthomas | Full Video on our Channel!",
            "Don’t Tell Comedy is helping keep Portland weird!",
            "\"Books Make You Gay\" 🎤: Sarah Tiana | @sarahtiana | Full Video on our Channel!",
        ]
        let result = cleaned(dontTellComedy)
        XCTAssertEqual(result[0], "\"Politicians are Too Old\" 🎤: Subhah Agarwal")
        XCTAssertEqual(result[2], "\"Dad Got Out of Prison\" 🎤: Nick Murphy | @NickMurphyComedy")
        // Not part of the shared suffix, so it stays.
        XCTAssertEqual(result[1], "\"Catching a D*ck in the Wild\" | Subhah Agarwal | Stand Up Comedy")
        // No delimiters at all: nothing to take off.
        XCTAssertEqual(result[8], "Don’t Tell Comedy is helping keep Portland weird!")
    }

    // MARK: - Shared prefix

    /// REAL: PowerfulJRE. The prefix only becomes visible once the episode
    /// number is out of the way — "Joe Rogan Experience #2549" and
    /// "Joe Rogan Experience #2548" share nothing as strings.
    private let powerfulJRE = [
        "Joe Rogan Experience #2549 - Jared Diamond",
        "JRE MMA Show #185 with Ethyn Ewing",
        "Joe Rogan Experience #2548 - Brian Simpson",
        "Joe Rogan Experience #2547 - Daniel Everett",
        "Joe Rogan Experience #2546 - Michael Button",
        "Joe Rogan Experience #2545 - Jesse Michels",
        "Joe Rogan Experience #2544 - Chris Williamson",
        "Joe Rogan Experience #2543 - MrBallen",
        "Joe Rogan Experience #2542 - Steve Hilton",
        "Joe Rogan Experience #2541 - Thomas Campbell",
    ]

    func testSharedPrefixIsFoundAfterEpisodeNumbersAreLifted() {
        let result = TitleStripper.clean(titles: powerfulJRE)
        XCTAssertEqual(result[0].title, "Jared Diamond")
        XCTAssertEqual(result[0].episodeNumber, 2549)
        XCTAssertEqual(result[0].episodeLabel, "Ep. 2549")
        XCTAssertEqual(result[9].title, "Thomas Campbell")
    }

    /// The one upload from the channel's other strand has no delimiter, so
    /// there's nothing to strip — but its number still comes out.
    func testTitleWithoutDelimitersKeepsItsTextAndLosesOnlyTheNumber() {
        let result = TitleStripper.clean(titles: powerfulJRE)[1]
        XCTAssertEqual(result.title, "JRE MMA Show with Ethyn Ewing")
        XCTAssertEqual(result.episodeNumber, 185)
    }

    /// REAL: What's News With You? Josh Johnson & Ashley Gavin. Prefix,
    /// suffix and episode number in one title, and the prefix is only on the
    /// episodes the regular hosts front.
    func testPrefixAndSuffixAreBothStrippedFromTheSameTitle() {
        let wnwy = [
            "JOSH JOHNSON / ASHLEY GAVIN — The Origins of Evil Explained & Strippers Need a Raise | WNWY #77",
            "JOSH JOHNSON / ASHLEY GAVIN — A Serial Arsonist Brags About Their Crimes on Our Hotline | WNWY #76",
            "JOSH JOHNSON / ASHLEY GAVIN — U.S. Munitions EXPLODING in Michigan & Mustard is Medicine | WNWY #75",
            "BAILEY POPE — The Cyclospora Outbreak is Getting Scary & Cops are Deadlier Than Malaria | WNWY #74",
            "SAM MORRISON — Ashley Gets Hurt for Her “Jokes,” REAL Infinite Money Glitch, & Lunch Pail | WNWY #73",
            "JOSH JOHNSON / ASHLEY GAVIN — Gov’t Passport Fraud EXPOSED & Beholding the Burning Bush | WNWY #72",
            "JEN DAVIS — Manosphere Streamers Take Big L’s, Cheerleaders Unionize, & Gym At Nite | WNWY #71",
            "ALI SIDDIQ, HANNAH GADSBY, & MORE — Vigilantes on the Loose, Hell Hotels, & Other Bonus! | WNWY #70",
            "JOSH JOHNSON / ASHLEY GAVIN — Frolf BEATS The World Cup & Dung Showers | WNWY #69",
            "JOSH JOHNSON / ASHLEY GAVIN — You’ll Never Vacation Again & Women Be Stabbin’ | WNWY #68",
        ]
        let result = TitleStripper.clean(titles: wnwy)
        XCTAssertEqual(result[0].title, "The Origins of Evil Explained & Strippers Need a Raise")
        XCTAssertEqual(result[0].episodeLabel, "Ep. 77")
        // A guest-fronted episode: the show name goes, the guest's name is
        // not boilerplate and stays.
        XCTAssertEqual(
            result[3].title,
            "BAILEY POPE — The Cyclospora Outbreak is Getting Scary & Cops are Deadlier Than Malaria"
        )
        XCTAssertEqual(result[3].episodeNumber, 74)
    }

    // MARK: - Episode numbers

    /// REAL: Trolden. Every title is identical apart from the number, so
    /// there's nothing left once both affixes go — which is the case where
    /// stripping has to stand down and leave the title whole.
    func testTitleThatIsEntirelyBoilerplateIsLeftWhole() {
        let trolden = (671...680).reversed().map {
            "Funny And Lucky Moments - Hearthstone - Ep. \($0)"
        }
        let result = TitleStripper.clean(titles: trolden)
        XCTAssertEqual(result[0].title, "Funny And Lucky Moments - Hearthstone")
        XCTAssertEqual(result[0].episodeLabel, "Ep. 680")
        XCTAssertEqual(Set(result.map(\.title)).count, 1)
    }

    /// REAL: HIGNFY, which posts two shows. "Series 19 Episode 11" is the
    /// whole of its segment, so removing it leaves one segment and nothing
    /// to strip; "S29E03" sits inside a segment that then reads as the show
    /// name three uploads share.
    func testSeasonAndEpisodePatternsAreBothRecognised() {
        let hignfy = [
            "Would I Lie To You? - Series 19 Episode 11",
            "Would I Lie To You? - Series 19 Episode 10",
            "Would I Lie To You? - Series 19 Episode 9",
            "Would I Lie To You? - Series 19 Episode 6",
            "8 Out of 10 Cats Does Countdown S29E03 | Surprise Guest Shakes Up the Game",
            "Would I Lie To You? - Series 19 Episode 5",
            "Would I Lie To You? - Series 19 Episode 4",
            "8 Out of 10 Cats Does Countdown S29E02 | Jimmy Carr Hosts Another Hilarious Showdown",
            "8 Out of 10 Cats Does Countdown S29E01 | Season 29 Premiere with Jon Richardson & Rob Beckett",
            "Would I Lie To You? - Series 19 Episode 3",
        ]
        let result = TitleStripper.clean(titles: hignfy)
        XCTAssertEqual(result[0].title, "Would I Lie To You?")
        XCTAssertEqual(result[0].seasonNumber, 19)
        XCTAssertEqual(result[0].episodeNumber, 11)
        XCTAssertEqual(result[0].episodeLabel, "S19 Ep. 11")

        XCTAssertEqual(result[4].title, "Surprise Guest Shakes Up the Game")
        XCTAssertEqual(result[4].episodeLabel, "S29 Ep. 3")
    }

    /// SYNTHETIC: the numbering spellings the captured channels don't cover.
    func testEpisodeNumberSpellings() {
        let none = ChannelBoilerplate.none
        XCTAssertEqual(TitleStripper.clean("S20 Ep.4 The Reunion", boilerplate: none),
                       CleanedTitle(title: "The Reunion", seasonNumber: 20, episodeNumber: 4))
        XCTAssertEqual(TitleStripper.clean("Season 3 Episode 12: Landfall", boilerplate: none),
                       CleanedTitle(title: "Landfall", seasonNumber: 3, episodeNumber: 12))
        XCTAssertEqual(TitleStripper.clean("Ep 31 - Tide Pools", boilerplate: none),
                       CleanedTitle(title: "Tide Pools", episodeNumber: 31))
        XCTAssertEqual(TitleStripper.clean("EP31 Tide Pools", boilerplate: none),
                       CleanedTitle(title: "Tide Pools", episodeNumber: 31))
        XCTAssertEqual(TitleStripper.clean("Tide Pools #142", boilerplate: none),
                       CleanedTitle(title: "Tide Pools", episodeNumber: 142))
    }

    /// SYNTHETIC: a hashtag isn't an episode number, and neither is a number
    /// that just happens to be in the title.
    func testNumbersThatArentEpisodeNumbersAreLeftAlone() {
        let none = ChannelBoilerplate.none
        XCTAssertEqual(TitleStripper.clean("Quick tip #shorts", boilerplate: none),
                       CleanedTitle(title: "Quick tip #shorts"))
        XCTAssertEqual(TitleStripper.clean("Top 10 Synths of 2026", boilerplate: none),
                       CleanedTitle(title: "Top 10 Synths of 2026"))
        XCTAssertEqual(TitleStripper.clean("The iPhone 17 Pro, one year on", boilerplate: none),
                       CleanedTitle(title: "The iPhone 17 Pro, one year on"))
    }

    // MARK: - Generic markers

    /// REAL: The Big Fat Quiz Channel. "FULL EPISODE" is its own segment on
    /// some uploads and absent on others, and the show name is the suffix on
    /// all but the one upload YouTube has a typo in.
    func testGenericMarkerSegmentIsRemovedAlongsideTheSharedSuffix() {
        let bigFatQuiz = [
            "Brexit, Boaty McBoatface & Mannequin Challenge | FULL EPISODE | Big Fat Quiz",
            "Claudia Winkleman Bluffs Her Way Through Big Fat Quiz | Big Fat Quiz",
            "Copacabana, Alcatraz & Top Gun Trivia | FULL EPISODE | Big Fat Quiz",
            "00s Nostalgia, Reality TV & Shaggy Hits | Big Fat Quiz",
            "Jack Whitehall & Rob Beckett Turn The Quiz Into Break Time | Big Fat Quiz",
            "Fake News, Brexit & 2017’s Viral Moments | FULL EPISODE | Big Fat Quiz",
            "Jimmy Carr Gets Roasted By The Panel | Big Fat Qui",
            "History, Science & Pop Culture Trivia | FULL EPISODE | Big Fat Quiz",
            "Greg Davies Turns One Point Into A Power Struggle | Big Fat Quiz",
            "Taskmaster Favourites Take On The Big Fat Quiz | Big Fat Quiz",
        ]
        let result = cleaned(bigFatQuiz)
        XCTAssertEqual(result[0], "Brexit, Boaty McBoatface & Mannequin Challenge")
        XCTAssertEqual(result[5], "Fake News, Brexit & 2017’s Viral Moments")
        // The truncated suffix isn't the shared one, so it isn't touched.
        XCTAssertEqual(result[6], "Jimmy Carr Gets Roasted By The Panel | Big Fat Qui")
    }

    /// SYNTHETIC: markers in brackets, and the rule that a marker inside a
    /// longer phrase is left alone — "Full Video on our Channel!" above is
    /// boilerplate the suffix rule removes, not a marker.
    func testBracketedMarkersAreRemovedButPhrasesContainingThemArent() {
        let none = ChannelBoilerplate.none
        XCTAssertEqual(TitleStripper.clean("Nightcall (Official Video)", boilerplate: none).title,
                       "Nightcall")
        XCTAssertEqual(TitleStripper.clean("Nightcall [Official Audio]", boilerplate: none).title,
                       "Nightcall")
        XCTAssertEqual(TitleStripper.clean("Nightcall | FULL EPISODE", boilerplate: none).title,
                       "Nightcall")
        XCTAssertEqual(TitleStripper.clean("How we shot the official video", boilerplate: none).title,
                       "How we shot the official video")
    }

    // MARK: - Channels with no pattern

    /// REAL: vlogbrothers. No repeated affix anywhere, so every title has to
    /// come through byte-for-byte.
    func testChannelWithNoRepeatedAffixIsLeftUntouched() {
        let vlogbrothers = [
            "You Can't Go Home Again, but I Tried",
            "Why the Deadliest Virus Was the Easiest to Kill",
            "Jad Abumrad on Dolly Parton: \"The Unicorn of Unicorns\"",
            "The Great Thing about Infectious Disease",
            "Not (Just) Dunking on Jeff Bezos",
            "My Nemeses",
            "Pain in the _____",
            "Hollywood, Ending",
            "Just Trying to Figure Out My Job",
            "Esther Day 2026: Some Thoughts on Loss",
        ]
        XCTAssertEqual(cleaned(vlogbrothers), vlogbrothers)
        XCTAssertEqual(labels(vlogbrothers), Array(repeating: nil, count: vlogbrothers.count))
        XCTAssertTrue(TitleStripper.boilerplate(in: vlogbrothers).isEmpty)
    }

    /// REAL: Knowing Better. Every upload has a pipe and a suffix, but the
    /// suffix is the series it belongs to and changes — a delimiter is not
    /// on its own evidence of boilerplate.
    func testChannelWhoseSuffixVariesIsLeftUntouched() {
        let knowingBetter = [
            "We Intend to Eat Pork | Hawaii: Rise",
            "So now you have no Hawaii video? | Announcement",
            "Paranoid Protestants | Seventh-day Adventists",
            "Steampunk KB Mission Archive | SDA Lore Recap",
            "Four Times a Day | John Harvey Kellogg",
            "The Cure for Literally Everything | Vegetarianism",
            "God's Alternative Medicine | Christian Science",
            "Geronimo: The Quintessential American Indian | Indian Removal Bonus",
            "The Story We Tell Ourselves | Pilgrims and Thanksgiving",
            "The War to Save the Buffalo | Indian Removal Bonus",
        ]
        XCTAssertEqual(cleaned(knowingBetter), knowingBetter)
    }

    /// REAL: Off Menu. A known limit of tier one, recorded rather than
    /// papered over: the channel names itself in every title but phrases it
    /// differently every time, so no exact segment repeats often enough.
    /// This is the case the model rewrite (#27) exists for.
    func testSuffixPhrasedDifferentlyEveryTimeIsBeyondTierOne() {
        let offMenu = [
            "James Acaster can't stand restaurant buzzers 🚨| Tessa Coates, Ed Gamble & James Acaster on Off Menu",
            "Tessa Coates wants double potato | Off Menu with Ed Gamble and James Acaster Podcast 🍽️",
            "Kaya Scodelario had a prawn cocktail with Kim Kardashian | Off Menu Podcast 🍽️",
            "Kaya Scodelario likes to crush actors' dreams 🧚‍♀️ | James Acaster & Ed Gamble on Off Menu podcast",
            "Kaya Scodelario hates soup 🥫 | James Acaster, Ed Gamble and Kaya Scodelario on the Off Menu podcast",
            "Kaya Scodelario is unimpressed with British food | James Acaster & Ed Gamble host Off Menu podcast",
            "Kaya Scodelario loves a Rodízio | Off Menu with Ed Gamble and James Acaster Podcast 🍽️",
            "Tom Cruise pranked Mark Gatiss and he fell for it | Off Menu Podcast w/ Ed Gamble and James Acaster",
            "James Acaster's chip shop horror story 🤐 | Mark Gatiss & Ed Gamble host the Off Menu podcast",
            "James Acaster can't believe Sherlock survived 🕵️| Mark Gatiss & Ed Gamble react on Off Menu podcast",
        ]
        XCTAssertEqual(cleaned(offMenu), offMenu)
    }

    // MARK: - Evidence thresholds

    /// SYNTHETIC: two uploads that happen to end the same way aren't a
    /// pattern. The channel has to have posted enough for the repeat to mean
    /// something.
    func testTooFewTitlesToJudgeLeavesThemAlone() {
        let pair = [
            "Bench planes | Woodwork Weekly",
            "Sharpening jigs | Woodwork Weekly",
        ]
        XCTAssertEqual(cleaned(pair), pair)
        XCTAssertTrue(TitleStripper.boilerplate(in: pair).isEmpty)
    }

    /// SYNTHETIC: "most of them" counts against the titles that could carry
    /// an affix at all, not against everything the channel posts — a channel
    /// that brands its series and posts one-offs besides still gets its
    /// series titles cleaned.
    func testMajorityIsMeasuredAgainstTitlesThatCouldCarryAnAffix() {
        let titles = [
            "Bench planes | Woodwork Weekly",
            "Sharpening jigs | Woodwork Weekly",
            "Dovetails by hand | Woodwork Weekly",
            "Shop tour 2026",
            "A drawer that doesn't stick",
            "Finishing oak",
            "Why I sold my table saw",
            "Chisels, ranked",
        ]
        XCTAssertEqual(cleaned(titles)[0], "Bench planes")
        XCTAssertEqual(cleaned(titles)[3], "Shop tour 2026")
    }

    /// SYNTHETIC: episode extraction doesn't need a channel behind it, so a
    /// single title still gets its number lifted.
    func testEpisodeNumberIsExtractedWithoutAChannelSample() {
        let result = TitleStripper.clean(titles: ["The Reunion | Ep. 12"])
        XCTAssertEqual(result[0].title, "The Reunion")
        XCTAssertEqual(result[0].episodeNumber, 12)
    }

    /// SYNTHETIC: cleaning must never hand back nothing.
    func testTitleThatWouldCleanToNothingFallsBackToTheOriginal() {
        let titles = Array(repeating: "Ep. 1", count: 5)
        XCTAssertEqual(TitleStripper.clean(titles: titles)[0].title, "Ep. 1")
    }
}
