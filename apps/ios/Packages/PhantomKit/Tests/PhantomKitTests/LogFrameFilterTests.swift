import XCTest
@testable import PhantomKit

final class LogFrameFilterTests: XCTestCase {

    // MARK: - normalizedLevel

    func testLevelAliasesMapToCanonical() {
        XCTAssertEqual(LogFrameFilter.normalizedLevel("INF"), .info)
        XCTAssertEqual(LogFrameFilter.normalizedLevel("info"), .info)
        XCTAssertEqual(LogFrameFilter.normalizedLevel("WRN"), .warn)
        XCTAssertEqual(LogFrameFilter.normalizedLevel("warning"), .warn)
        XCTAssertEqual(LogFrameFilter.normalizedLevel("err"), .error)
        XCTAssertEqual(LogFrameFilter.normalizedLevel("DEBUG"), .debug)
        XCTAssertEqual(LogFrameFilter.normalizedLevel("trc"), .debug)
        XCTAssertEqual(LogFrameFilter.normalizedLevel("OK"), .ok)
        XCTAssertEqual(LogFrameFilter.normalizedLevel("success"), .ok)
    }

    func testUnknownLevelFallsBackToInfo() {
        XCTAssertEqual(LogFrameFilter.normalizedLevel("weird"), .info)
        XCTAssertEqual(LogFrameFilter.normalizedLevel(""), .info)
    }

    func testWhitespaceAndCaseAreIgnored() {
        XCTAssertEqual(LogFrameFilter.normalizedLevel("  Err "), .error)
    }

    // MARK: - matches

    private func match(
        _ search: String,
        level: String = "INF",
        msg: String = "handshake complete",
        category: String? = "tunnel",
        fields: [String: String]? = ["peer": "nl2"],
        useRegex: Bool = false
    ) -> Bool {
        let regex = (useRegex && !search.isEmpty)
            ? try? NSRegularExpression(pattern: search, options: [.caseInsensitive])
            : nil
        return LogFrameFilter.matches(
            level: level, msg: msg, category: category, fields: fields,
            search: search, regex: regex, useRegex: useRegex
        )
    }

    func testEmptySearchMatchesEverything() {
        XCTAssertTrue(match(""))
    }

    func testSubstringMatchesMsgCategoryAndFields() {
        XCTAssertTrue(match("handshake"))     // msg
        XCTAssertTrue(match("tunnel"))        // category
        XCTAssertTrue(match("nl2"))           // fields value
        XCTAssertTrue(match("peer"))          // fields key
        XCTAssertFalse(match("nonexistent"))
    }

    func testCaseInsensitiveSubstring() {
        XCTAssertTrue(match("HANDSHAKE"))
    }

    func testRegexMatch() {
        XCTAssertTrue(match("hand.*complete", useRegex: true))
        XCTAssertFalse(match("^complete", useRegex: true))
    }

    func testInvalidRegexNilYieldsNoMatch() {
        // useRegex=true, но паттерн не скомпилировался (regex=nil) → false
        XCTAssertFalse(match("[unclosed", useRegex: true))
    }
}
