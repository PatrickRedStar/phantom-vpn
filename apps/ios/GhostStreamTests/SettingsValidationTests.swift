import PhantomKit
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

    func testDuplicateImportMatchesByCertOrTunnelAddressOnServer() {
        var a = VpnProfile()
        a.certPem = "CERT-A"; a.tunAddr = "10.7.0.5/24"; a.serverAddr = "nl:8443"
        var b = VpnProfile()
        b.certPem = "CERT-B"; b.tunAddr = "10.7.0.6/24"; b.serverAddr = "nl:8443"
        let profiles = [a, b]
        XCTAssertEqual(SettingsViewModel.matchingProfile(in: profiles, certPem: "CERT-B", tunAddr: "x", serverAddr: "y")?.id, b.id)
        // Re-issued client: new cert, same address on the same server.
        XCTAssertEqual(SettingsViewModel.matchingProfile(in: profiles, certPem: "NEW", tunAddr: "10.7.0.5/24", serverAddr: "nl:8443")?.id, a.id)
        XCTAssertNil(SettingsViewModel.matchingProfile(in: profiles, certPem: "NEW", tunAddr: "10.7.0.5/24", serverAddr: "other:8443"))
    }

    func testDnsEntriesSplitOnCommasSpacesAndLines() {
        XCTAssertEqual(SettingsViewModel.dnsEntries("1.1.1.1, 8.8.8.8\n9.9.9.9"), ["1.1.1.1", "8.8.8.8", "9.9.9.9"])
    }
}
