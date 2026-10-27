import XCTest
@testable import GhostStream

@MainActor
final class SettingsValidationTests: XCTestCase {
    func testDnsServerMustBeAnIpLiteral() {
        for ok in ["1.1.1.1", "9.9.9.9", "0.0.0.0", "2606:4700::1111", "::1"] {
            XCTAssertTrue(SettingsViewModel.isValidDnsServer(ok), ok)
        }
        for bad in ["dns.google", "1", "1.1", "256.1.1.1", "010.1.1.1", "1.1.1.1:53", "fe80::1%en0", ""] {
            XCTAssertFalse(SettingsViewModel.isValidDnsServer(bad), bad)
        }
    }

    func testDnsEntriesSplitOnCommasSpacesAndLines() {
        XCTAssertEqual(SettingsViewModel.dnsEntries("1.1.1.1, 8.8.8.8\n9.9.9.9"), ["1.1.1.1", "8.8.8.8", "9.9.9.9"])
    }
}
