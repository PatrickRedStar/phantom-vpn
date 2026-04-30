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
}
