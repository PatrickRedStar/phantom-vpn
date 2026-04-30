import XCTest
@testable import GhostStream

final class AppNavigationTests: XCTestCase {
    func testRootTabsAreStreamLogsSettingsOnly() {
        XCTAssertEqual(AppTab.allCases, [.dashboard, .logs, .settings])
    }

    func testTabsUseNativeSFSymbolNames() {
        XCTAssertEqual(AppTab.dashboard.systemImageName, "waveform.path.ecg")
        XCTAssertEqual(AppTab.logs.systemImageName, "doc.text.magnifyingglass")
        XCTAssertEqual(AppTab.settings.systemImageName, "gearshape")
    }
}
