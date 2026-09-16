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
        XCTAssertTrue(instructions.contains("keep every clause"))
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
                "The polls are missing something",
                strippedTitle: "TOP ANALYST: The polls are MISSING something"
            ),
            "The polls are missing something"
        )
    }

    /// The fallback that keeps the feature safe: an answer the app can't use
    /// costs the viewer the rewrite, never the title. What it gets instead
    /// is the stripped title with its shouting taken off, which needs no
    /// model — the calm title is unchanged by it.
    func testAnEmptyAnswerFallsBackToTheCalmedStrippedTitle() {
        XCTAssertEqual(TitleRewritePrompt.resolve("", strippedTitle: "The deficit, explained"),
                       "The deficit, explained")
        XCTAssertEqual(TitleRewritePrompt.resolve("   \n  ", strippedTitle: "The deficit, explained"),
                       "The deficit, explained")
        XCTAssertEqual(
            TitleRewritePrompt.resolve("", strippedTitle: "Iran STRIKES U.S. Bases As Trump Threatens To WIPE THEM OUT"),
            "Iran strikes U.S. bases as Trump threatens to wipe them out"
        )
    }

    /// The model's guardrail refuses a third of a political show's titles,
    /// and those used to stay shouting. The fallback is what the store
    /// writes for a refusal, so it has to be calm on its own.
    func testTheFallbackCalmsAShoutedTitleWithoutAModel() {
        XCTAssertEqual(
            TitleRewritePrompt.fallback(for: "TOP Election Analyst: 'NIGHTMARE SCENARIO' For Republicans "),
            "Top election analyst: 'Nightmare scenario' for republicans"
        )
        XCTAssertEqual(
            TitleRewritePrompt.fallback(for: "Kash Patel SQUIRMS Over Epstein Questions"),
            "Kash Patel squirms over Epstein questions"
        )
    }

    // MARK: - Keeping to the source

    /// "Never add information" made checkable: a word the title didn't use
    /// is one the app can't vouch for, whether it's a respelt name, a
    /// corrected one, or a new claim. The answer is dropped for the calmed
    /// title, which says exactly what the original did.
    func testAnAnswerWithWordsTheTitleDidntUseIsRejected() {
        XCTAssertEqual(
            TitleRewritePrompt.resolve(
                "Dana Ruiz discusses the housing market crash",
                strippedTitle: "Dana Ruiz on why the housing market broke"
            ),
            "Dana Ruiz on why the housing market broke"
        )
        XCTAssertEqual(
            TitleRewritePrompt.resolve(
                "massie moves to impeach pete hegsseth over iran war",
                strippedTitle: "Massie Moves To IMPEACH Pete Hegseth Over Iran War"
            ),
            "Massie moves to impeach Pete Hegseth over Iran war"
        )
        XCTAssertEqual(
            TitleRewritePrompt.resolve(
                "andrew daly feels _____ about being conan's friend.",
                strippedTitle: "Andy Daly feels _____ about being Conan's friend."
            ),
            "Andy Daly feels _____ about being Conan's friend."
        )
    }

    /// Taking the hype out of a sentence sometimes needs a joining word to
    /// hold the rest together, and a joining word carries no information.
    func testJoiningWordsMayBeAdded() {
        XCTAssertEqual(
            TitleRewritePrompt.resolve(
                "pablo torre reacts to doj criminal investigation into steve ballmer",
                strippedTitle: "Pablo Torre REACTS: DOJ CRIMINAL INVESTIGATION Into Steve Ballmer"
            ),
            "Pablo Torre reacts to DOJ criminal investigation into Steve Ballmer"
        )
        XCTAssertTrue(TitleRewritePrompt.keepsToTheSource("the deficit, explained", source: "Deficit: EXPLAINED!"))
    }

    /// Case, punctuation, possessives and hyphens aren't changes of wording:
    /// `Durk’s`, `Durk's` and `DURK` are the same word, and so are `mail-in`
    /// and `Mail-In`.
    func testWordsAreComparedWithoutCasePunctuationOrPossessives() {
        XCTAssertTrue(TitleRewritePrompt.keepsToTheSource(
            "feds reveal durk's delete thread message after murder",
            source: "Feds Reveal Durk\u{2019}s \u{201C}DELETE THREAD\u{201D} Message After Murder"
        ))
        XCTAssertTrue(TitleRewritePrompt.keepsToTheSource(
            "trump rages at scotus over mail in ballot smackdown",
            source: "Trump RAGES At SCOTUS Over Mail-In Ballot Smackdown"
        ))
        XCTAssertTrue(TitleRewritePrompt.keepsToTheSource(
            "iran strikes u.s. bases", source: "Iran STRIKES U.S. Bases"
        ))
    }

    /// The answer that kept a name and dropped the sentence around it (#87):
    /// fewer than half the title's words is a different title, not a calmer
    /// one.
    func testAnAnswerThatDropsMostOfTheTitleIsRejected() {
        XCTAssertEqual(
            TitleRewritePrompt.resolve(
                "Mike Binder: Academy politics",
                strippedTitle: "Mike Binder: The Academy Kept Me Out Because of Politics"
            ),
            "Mike Binder: The academy kept me out because of politics"
        )
        // Dropping the hype alone is what the rewrite is for.
        XCTAssertEqual(
            TitleRewritePrompt.resolve(
                "global bond market chaos as bessent flails",
                strippedTitle: "Global Bond Market IN CHAOS As Bessent DESPERATELY FLAILS"
            ),
            "Global bond market chaos as Bessent flails"
        )
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
        XCTAssertEqual(TitleRewritePrompt.resolve("\"The deficit, explained\"", strippedTitle: "THE DEFICIT, EXPLAINED"),
                       "The deficit, explained")
        XCTAssertEqual(TitleRewritePrompt.resolve("\u{201C}The deficit, explained\u{201D}", strippedTitle: "THE DEFICIT, EXPLAINED"),
                       "The deficit, explained")
    }

    /// An answer that arrives on three lines must not become a three-line
    /// feed row.
    func testWhitespaceIsCollapsedToSingleSpaces() {
        XCTAssertEqual(
            TitleRewritePrompt.resolve("The deficit,\n  explained\n", strippedTitle: "THE DEFICIT, EXPLAINED"),
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

    /// Two names, one of them spelled a way no dictionary knows. The model
    /// silently corrected the spelling, which is a word the title didn't
    /// use, so the answer is dropped for the calmed title — which keeps the
    /// typo and the hype word, keeps both names capitalised, and loses the
    /// shouting all the same.
    func testARespeltNameFallsBackToTheCalmedTitle() {
        XCTAssertEqual(
            TitleRewritePrompt.resolve(
                "lebron james, sydney sweeney gambling shilling",
                strippedTitle: "Lebron James, Syndney Sweeney DISGUSTING Gambling SHILLING"
            ),
            "Lebron James, Syndney Sweeney disgusting gambling shilling"
        )
    }

    /// The failure the first attempt at this made: copying the source's case
    /// onto every word it recognised capitalised `The` in the middle of a
    /// sentence. A function word is never a name, so it is always lower case
    /// unless it opens the title.
    func testMidSentenceFunctionWordsStayLowerCase() {
        XCTAssertEqual(
            TitleRewritePrompt.resolve(
                "analyst: the polls are missing something",
                strippedTitle: "TOP ANALYST: The polls are MISSING something"
            ),
            "Analyst: The polls are missing something"
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

    /// `U.S.` and `A.I.` are initialisms however long they are — nobody
    /// shouts with full stops between the letters — and their last full stop
    /// doesn't start a new sentence (#87).
    func testDottedInitialismsKeepTheirCapitals() {
        XCTAssertEqual(
            TitleRewritePrompt.resolve(
                "iran strikes u.s. bases as trump threatens to wipe them out",
                strippedTitle: "Iran STRIKES U.S. Bases As Trump Threatens To WIPE THEM OUT"
            ),
            "Iran strikes U.S. bases as Trump threatens to wipe them out"
        )
        XCTAssertEqual(
            TitleRewritePrompt.resolve(
                "dr. dre is using a.i. and i hate it",
                strippedTitle: "Dr. Dre Is Using A.I. and I Hate It"
            ),
            "Dr. Dre is using A.I. and I hate it"
        )
    }

    /// Letters and digits together are a code or a name, never shouting, so
    /// the source's spelling is copied exactly.
    func testWordsMixingLettersAndDigitsAreCopiedExactly() {
        XCTAssertEqual(
            TitleRewritePrompt.resolve(
                "ww3?: german power plant sabotage as zelensky shuts down russian skies",
                strippedTitle: "WW3?: German POWER PLANT SABOTAGE As Zelensky SHUTS Down Russian Skies"
            ),
            "WW3?: German power plant sabotage as Zelensky shuts down Russian skies"
        )
        XCTAssertEqual(
            TitleRewritePrompt.resolve(
                "houthis shoot down saudi arabia f-15 jet",
                strippedTitle: "SHOCK: Houthis Shoot Down Saudi Arabia F-15 Jet"
            ),
            "Houthis shoot down Saudi Arabia F-15 jet"
        )
        XCTAssertEqual(
            TitleRewritePrompt.resolve(
                "mst3k presents: the joel mixtapes | vol xvi",
                strippedTitle: "MST3K Presents: The Joel Mixtapes | Vol XVI"
            ),
            "MST3K presents: The Joel mixtapes | vol XVI"
        )
    }

    /// A hyphenated word is decided one part at a time — `Mail-In` is Title
    /// Case, not a spelling — and one name makes the whole a name.
    func testHyphenatedWordsAreDecidedPartByPart() {
        XCTAssertEqual(
            TitleRewritePrompt.resolve(
                "trump rages at scotus over mail-in ballot smackdown",
                strippedTitle: "Trump RAGES At SCOTUS Over Mail-In Ballot Smackdown"
            ),
            "Trump rages at SCOTUS over mail-in ballot smackdown"
        )
        XCTAssertEqual(
            TitleRewritePrompt.resolve(
                "pentagon official: us-israel merger would be catastrophic",
                strippedTitle: "Pentagon Official: US-Israel Merger Would Be CATASTROPHIC"
            ),
            "Pentagon official: US-Israel merger would be catastrophic"
        )
        XCTAssertEqual(
            TitleRewritePrompt.resolve(
                "itamar ben-gvir posts psycho ai video",
                strippedTitle: "Itamar Ben-Gvir Posts PSYCHO AI Video"
            ),
            "Itamar Ben-Gvir posts psycho AI video"
        )
        XCTAssertEqual(
            TitleRewritePrompt.resolve(
                "thomas massie exposes epstein alleged co-conspirators on house floor",
                strippedTitle: "Thomas Massie EXPOSES Epstein Alleged Co-Conspirators ON HOUSE FLOOR"
            ),
            "Thomas Massie exposes Epstein alleged co-conspirators on house floor"
        )
    }

    // MARK: - Versioning

    /// Tier two's version is added to tier one's, so bumping either re-runs
    /// both. A rewrite judged against a stale stripping isn't worth keeping.
    /// #27's fix changes what a rewrite looks like, so every title already
    /// rewritten under the old prompt has to be done again. The bump is what
    /// makes that happen at the next launch;
    /// `TitleCleanerTests.testAVersionBumpReRunsBothTiers` covers the re-run.
    /// The calmed fallback and the source check bumped it again, so every
    /// refused title that was left shouting gets its calming.
    func testTheCasingFixBumpedThePromptVersion() {
        XCTAssertGreaterThanOrEqual(TitleRewritePrompt.version, 3)
    }

    @MainActor
    func testCleanerVersionIsBothTiersAdded() {
        XCTAssertEqual(TitleCleaner.version, TitleStripper.version + TitleRewritePrompt.version)
        XCTAssertGreaterThan(TitleCleaner.version, TitleStripper.version)
    }
}
