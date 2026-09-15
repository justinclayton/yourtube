import XCTest
@testable import YourTube

/// Tier two's two halves that don't need a model: what the model is told, and
/// what the app is willing to believe of what comes back. The model itself is
/// not under test — `TitleCleanerTests` stubs it, and the wording is tuned by
/// hand on the phone.
final class TitleRewriterTests: XCTestCase {
    private func request(
        _ stripped: String,
        show: String = "The Bellwether"
    ) -> TitleRewriteRequest {
        TitleRewriteRequest(strippedTitle: stripped, showTitle: show)
    }

    // MARK: - Prompt assembly

    /// The three constraints the PRD names, in the instructions the model
    /// actually sees. They're asserted on because a rewrite without them is
    /// the failure mode the feature has to avoid: a title that says something
    /// the video didn't.
    func testInstructionsCarryTheConstraints() {
        let instructions = TitleRewritePrompt.instructions.lowercased()
        XCTAssertTrue(instructions.contains("never add information"))
        XCTAssertTrue(instructions.contains("never use capital letters for emphasis"))
        XCTAssertTrue(instructions.contains("normal sentence case"))
        XCTAssertTrue(instructions.contains("\(TitleRewritePrompt.maxLength) characters"))
        // The wording that told the model a word in capitals "becomes
        // ordinary lower case", which it read as licence to lower-case the
        // whole title, names included (#27).
        XCTAssertFalse(instructions.contains("becomes ordinary lower case"))
    }

    /// The model is given tier one's output, not YouTube's title: the channel
    /// boilerplate is already gone, so the model is asked to calm a sentence
    /// rather than work out which half of it is a show name.
    func testPromptCarriesTheStrippedTitleAndTheShow() {
        let prompt = TitleRewritePrompt.prompt(for: request("WHY THE POLLS KEEP MISSING"))
        XCTAssertTrue(prompt.contains("Title: WHY THE POLLS KEEP MISSING"))
        XCTAssertTrue(prompt.contains("Show: The Bellwether"))
    }

    /// A video whose show has no name yet still gets asked about; the line is
    /// left out rather than sent empty, which reads to the model as a show
    /// actually called "".
    func testPromptOmitsAnEmptyShowLine() {
        let prompt = TitleRewritePrompt.prompt(for: request("What the polls keep missing", show: "  "))
        XCTAssertFalse(prompt.contains("Show:"))
        XCTAssertEqual(prompt, "Title: What the polls keep missing")
    }

    // MARK: - Answer resolution

    func testAPlainAnswerIsTakenAsGiven() {
        XCTAssertEqual(
            TitleRewritePrompt.resolve(
                "An election analyst on what the polls miss",
                strippedTitle: "TOP ANALYST: The polls are MISSING something"
            ),
            "An election analyst on what the polls miss"
        )
    }

    /// The fallback that keeps the feature safe: an answer the app can't use
    /// costs the viewer the rewrite, never the title.
    func testAnEmptyAnswerFallsBackToTheStrippedTitle() {
        XCTAssertEqual(TitleRewritePrompt.resolve("", strippedTitle: "The deficit, explained"),
                       "The deficit, explained")
        XCTAssertEqual(TitleRewritePrompt.resolve("   \n  ", strippedTitle: "The deficit, explained"),
                       "The deficit, explained")
    }

    /// A model that answers with a paragraph has elaborated, which is the one
    /// thing the rewrite must never do.
    func testAnOverLongAnswerFallsBackToTheStrippedTitle() {
        let rambling = String(repeating: "a very long explanation ", count: 10)
        XCTAssertEqual(TitleRewritePrompt.resolve(rambling, strippedTitle: "The deficit, explained"),
                       "The deficit, explained")
    }

    /// A title that was already long may be rewritten to something still over
    /// the cap, as long as the rewrite is the shorter of the two.
    func testALongTitleMayBeRewrittenToSomethingStillOverTheCap() {
        let stripped = String(repeating: "the long and winding sentence that ", count: 4)
        let answer = String(repeating: "the long and winding sentence that ", count: 3)
            .trimmingCharacters(in: .whitespaces)
        XCTAssertGreaterThan(answer.count, TitleRewritePrompt.maxLength)
        XCTAssertEqual(
            TitleRewritePrompt.resolve(answer, strippedTitle: stripped),
            answer.prefix(1).uppercased() + answer.dropFirst()
        )
    }

    /// Models quote titles about as often as they don't, and a quoted title
    /// beside unquoted ones is the app shouting in a new way.
    func testSurroundingQuotesAreDropped() {
        XCTAssertEqual(TitleRewritePrompt.resolve("\"The deficit, explained\"", strippedTitle: "raw"),
                       "The deficit, explained")
        XCTAssertEqual(TitleRewritePrompt.resolve("\u{201C}The deficit, explained\u{201D}", strippedTitle: "raw"),
                       "The deficit, explained")
    }

    /// An answer that arrives on three lines must not become a three-line
    /// feed row.
    func testWhitespaceIsCollapsedToSingleSpaces() {
        XCTAssertEqual(
            TitleRewritePrompt.resolve("The deficit,\n  explained\n", strippedTitle: "raw"),
            "The deficit, explained"
        )
    }

    // MARK: - Casing

    /// The three titles #27 reported, with the answers the on-device model
    /// actually gave for them on the phone: every word flattened to lower
    /// case. The words are the model's; the capitals are the app's.

    func testAFlattenedAnswerComesBackInSentenceCase() {
        XCTAssertEqual(
            TitleRewritePrompt.resolve(
                "glass, metal, salmonella food investigations",
                strippedTitle: "GLASS, METAL, SALMONELLA Food Investigations Hit RECORD After DOGE Cuts"
            ),
            "Glass, metal, salmonella food investigations"
        )
    }

    func testANameSurvivesAFlattenedAnswer() {
        XCTAssertEqual(
            TitleRewritePrompt.resolve(
                "trump on flock cameras: i like them",
                strippedTitle: "Trump On Flock Cameras: 'I LIKE THEM!'"
            ),
            "Trump on flock cameras: I like them"
        )
    }

    /// Two names, one of them spelled a way no dictionary knows, and one the
    /// model silently corrected so it isn't in the source at all. Both come
    /// back capitalised; the shouting between them doesn't.
    func testNamesSurviveEvenWhenTheModelRespellsThem() {
        XCTAssertEqual(
            TitleRewritePrompt.resolve(
                "lebron james, sydney sweeney gambling shilling",
                strippedTitle: "Lebron James, Syndney Sweeney DISGUSTING Gambling SHILLING"
            ),
            "Lebron James, Sydney Sweeney gambling shilling"
        )
    }

    /// The failure the first attempt at this made: copying the source's case
    /// onto every word it recognised capitalised `The` in the middle of a
    /// sentence. A function word is never a name, so it is always lower case
    /// unless it opens the title.
    func testMidSentenceFunctionWordsStayLowerCase() {
        XCTAssertEqual(
            TitleRewritePrompt.resolve(
                "an election analyst on what the polls miss",
                strippedTitle: "TOP ANALYST: The polls are MISSING something"
            ),
            "An election analyst on what the polls miss"
        )
        XCTAssertEqual(
            TitleRewritePrompt.resolve(
                "the case against the primary system",
                strippedTitle: "The Case Against The Primary System"
            ),
            "The case against the primary system"
        )
    }

    /// An initialism is the one kind of capitals the rewrite must not take
    /// off, and a spell checker can't tell one from a shouted word — `doge`
    /// and `nasa` are both in its dictionary. Absence from the vocabulary of
    /// ordinary English is what separates them.
    func testInitialismsKeepTheirCapitals() {
        XCTAssertEqual(
            TitleRewritePrompt.resolve(
                "food investigations hit record after doge cuts",
                strippedTitle: "GLASS, METAL, SALMONELLA Food Investigations Hit RECORD After DOGE Cuts"
            ),
            "Food investigations hit record after DOGE cuts"
        )
        XCTAssertEqual(
            TitleRewritePrompt.resolve(
                "nasa's telescope finds something weird",
                strippedTitle: "SHOCKING: NASA's new telescope finds something WEIRD"
            ),
            "NASA's telescope finds something weird"
        )
    }

    /// A name that was itself being shouted comes back as a name, not as an
    /// initialism and not in lower case — on every device, including the one
    /// whose person recogniser doesn't find it. `PRIYA` and `RAMAN` are five
    /// letters, which is why an initialism stops at four.
    func testAShoutedNameIsCalmedRatherThanFlattened() {
        XCTAssertEqual(
            TitleRewritePrompt.resolve(
                "priya raman on rebuilding the grid",
                strippedTitle: "PRIYA RAMAN On Rebuilding The GRID"
            ),
            "Priya Raman on rebuilding the grid"
        )
    }

    /// A capital the source put somewhere other than the front is always
    /// deliberate, so it is copied exactly however the model wrote it.
    func testInnerCapitalsAreCopiedExactly() {
        XCTAssertEqual(
            TitleRewritePrompt.resolve(
                "lebron james on the iphone deal",
                strippedTitle: "LeBron James On The iPhone Deal"
            ),
            "LeBron James on the iPhone deal"
        )
    }

    /// A full stop, question mark or colon starts a new sentence, and a new
    /// sentence starts with a capital.
    func testSentencePunctuationStartsACapital() {
        XCTAssertEqual(
            TitleRewritePrompt.resolve(
                "who really pays? the answer is complicated",
                strippedTitle: "WHO Really Pays? THE ANSWER Is COMPLICATED"
            ),
            "Who really pays? The answer is complicated"
        )
    }

    /// A word `NLEmbedding` has never seen is taken for a name, which is what
    /// rescues `Syndney` — but British spellings are outside that vocabulary
    /// too, and `Favourite` is not a name. The spell checker is the second
    /// opinion that keeps them lower case.
    func testBritishSpellingsAreNotMistakenForNames() {
        XCTAssertEqual(
            TitleRewritePrompt.resolve(
                "sandi's favourite malicious compliance",
                strippedTitle: "Sandi's Favourite Malicious Compliance"
            ),
            "Sandi's favourite malicious compliance"
        )
    }

    /// A title that was already calm is unchanged by the casing pass, which
    /// is what makes "give it back word for word" a safe instruction.
    func testAnAlreadyCalmTitleIsUntouched() {
        let calm = "Dana Ruiz on why the housing market broke"
        XCTAssertEqual(TitleRewritePrompt.resolve(calm, strippedTitle: calm), calm)
    }

    // MARK: - Versioning

    /// Tier two's version is added to tier one's, so bumping either re-runs
    /// both. A rewrite judged against a stale stripping isn't worth keeping.
    /// #27's fix changes what a rewrite looks like, so every title already
    /// rewritten under the old prompt has to be done again. The bump is what
    /// makes that happen at the next launch;
    /// `TitleCleanerTests.testAVersionBumpReRunsBothTiers` covers the re-run.
    func testTheCasingFixBumpedThePromptVersion() {
        XCTAssertGreaterThanOrEqual(TitleRewritePrompt.version, 2)
    }

    @MainActor
    func testCleanerVersionIsBothTiersAdded() {
        XCTAssertEqual(TitleCleaner.version, TitleStripper.version + TitleRewritePrompt.version)
        XCTAssertGreaterThan(TitleCleaner.version, TitleStripper.version)
    }
}
