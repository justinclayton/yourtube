import XCTest
@testable import YourTube

final class ISO8601DurationTests: XCTestCase {
    func testMinutesAndSeconds() {
        XCTAssertEqual(ISO8601Duration.seconds(from: "PT4M13S"), 253)
    }

    func testSecondsOnly() {
        XCTAssertEqual(ISO8601Duration.seconds(from: "PT45S"), 45)
    }

    func testHoursMinutesSeconds() {
        XCTAssertEqual(ISO8601Duration.seconds(from: "PT1H2M3S"), 3723)
    }

    func testDaysAreSupported() {
        XCTAssertEqual(ISO8601Duration.seconds(from: "P1DT2H3M4S"), 93_784)
    }

    /// Live streams report PT0S. The parser returns 0 rather than nil; callers
    /// are responsible for treating 0 as "no duration known".
    func testZeroDuration() {
        XCTAssertEqual(ISO8601Duration.seconds(from: "PT0S"), 0)
    }

    func testMonthsAreRejectedAsAmbiguous() {
        XCTAssertNil(ISO8601Duration.seconds(from: "P1M"))
        XCTAssertNil(ISO8601Duration.seconds(from: "P1Y"))
    }

    func testMinutesInsideTimeSectionAreMinutesNotMonths() {
        XCTAssertEqual(ISO8601Duration.seconds(from: "PT1M"), 60)
    }

    func testMalformedInputReturnsNil() {
        XCTAssertNil(ISO8601Duration.seconds(from: ""))
        XCTAssertNil(ISO8601Duration.seconds(from: "P"))
        XCTAssertNil(ISO8601Duration.seconds(from: "4M13S"))
        XCTAssertNil(ISO8601Duration.seconds(from: "PT4M13"), "trailing digits with no unit")
        XCTAssertNil(ISO8601Duration.seconds(from: "PTXS"))
    }
}
