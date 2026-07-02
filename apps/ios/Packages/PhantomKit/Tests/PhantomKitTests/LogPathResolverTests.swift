import XCTest
@testable import PhantomKit

final class LogPathResolverTests: XCTestCase {
    func testRuntimeLogUrlEndsWithCanonicalName() {
        XCTAssertEqual(LogPathResolver.defaultRuntimeLogURL().lastPathComponent, "runtime.log")
    }

    func testDisplayPathAbbreviatesHome() {
        let display = LogPathResolver.displayPath
        let home = NSString(string: "~/").expandingTildeInPath
        XCTAssertFalse(display.hasPrefix(home), "домашний каталог должен сжиматься в ~")
    }
}
