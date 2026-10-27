import XCTest
import PhantomKit
@testable import GhostStream

final class LogsPresentationTests: XCTestCase {
    func testFilterKeepsNewestFirstAndAppliesMinimumLevel() {
        let logs = [
            LogFrame(tsUnixMs: 1, level: "INFO", msg: "connected"),
            LogFrame(tsUnixMs: 2, level: "WARN", msg: "route changed"),
            LogFrame(tsUnixMs: 3, level: "ERROR", msg: "snapshot stale")
        ]

        let visible = LogsPresentation.visibleLogs(
            allLogs: logs,
            filter: .warn,
            searchText: ""
        )

        XCTAssertEqual(visible.map(\.msg), ["snapshot stale", "route changed"])
    }

    func testSearchMatchesLevelAndMessageCaseInsensitively() {
        let logs = [
            LogFrame(tsUnixMs: 1, level: "INFO", msg: "status frame received"),
            LogFrame(tsUnixMs: 2, level: "ERROR", msg: "stale snapshot ignored")
        ]

        let visible = LogsPresentation.visibleLogs(
            allLogs: logs,
            filter: .all,
            searchText: "SNAP"
        )

        XCTAssertEqual(visible.map(\.msg), ["stale snapshot ignored"])
    }

    func testConsecutiveRepeatsCollapseIntoOneLineWithCount() {
        let newestFirst = [
            LogFrame(tsUnixMs: 5, level: "INFO", msg: "stream reopened"),
            LogFrame(tsUnixMs: 4, level: "WARN", msg: "stream closed"),
            LogFrame(tsUnixMs: 3, level: "WARN", msg: "stream closed"),
            LogFrame(tsUnixMs: 2, level: "WARN", msg: "stream closed"),
            LogFrame(tsUnixMs: 1, level: "INFO", msg: "stream reopened")
        ]

        let lines = LogsPresentation.collapsed(newestFirst)

        XCTAssertEqual(lines.map(\.frame.msg), ["stream reopened", "stream closed", "stream reopened"])
        XCTAssertEqual(lines.map(\.count), [1, 3, 1])
        XCTAssertEqual(lines[1].frame.tsUnixMs, 4)
    }

    func testThreeCharLevelCodesFromCoreFilterLikeLongNames() {
        let logs = [
            LogFrame(tsUnixMs: 1, level: "DBG", msg: "frame"),
            LogFrame(tsUnixMs: 2, level: "WRN", msg: "stream closed")
        ]

        let visible = LogsPresentation.visibleLogs(allLogs: logs, filter: .warn, searchText: "")

        XCTAssertEqual(visible.map(\.msg), ["stream closed"])
    }
}
