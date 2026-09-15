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
        XCTAssertTrue(instructions.contains("\(TitleRewritePrompt.maxLength) characters"))
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
        let stripped = String(repeating: "x", count: 140)
        let answer = String(repeating: "y", count: 120)
        XCTAssertEqual(TitleRewritePrompt.resolve(answer, strippedTitle: stripped), answer)
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

    // MARK: - Versioning

    /// Tier two's version is added to tier one's, so bumping either re-runs
    /// both. A rewrite judged against a stale stripping isn't worth keeping.
    @MainActor
    func testCleanerVersionIsBothTiersAdded() {
        XCTAssertEqual(TitleCleaner.version, TitleStripper.version + TitleRewritePrompt.version)
        XCTAssertGreaterThan(TitleCleaner.version, TitleStripper.version)
    }
}
