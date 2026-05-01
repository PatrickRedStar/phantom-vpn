import XCTest
@testable import PhantomKit

final class ProfileNameDeriverTests: XCTestCase {
    func testUsesFirstServerNameLabelWhenCertificateNameIsUnavailable() {
        let parsed = ParsedConnConfig(
            serverAddr: "vpn.example.com:443",
            serverName: "spongebob2.vpn.example.com",
            tunAddr: "10.7.0.2/24",
            certPem: "not a certificate",
            keyPem: "key"
        )

        XCTAssertEqual(ProfileNameDeriver.defaultName(for: parsed), "spongebob2")
    }

    func testFallsBackToConnectionWhenNoNameCanBeDerived() {
        let parsed = ParsedConnConfig(
            serverAddr: "vpn.example.com:443",
            serverName: "",
            tunAddr: "10.7.0.2/24",
            certPem: "",
            keyPem: "key"
        )

        XCTAssertEqual(ProfileNameDeriver.defaultName(for: parsed), "Подключение")
    }
}
