import XCTest
import PhantomKit
@testable import GhostStream

final class ProfilePresentationTests: XCTestCase {
    func testBuyerProfileDoesNotExposeAdminAction() {
        let profile = VpnProfile(
            id: "user",
            name: "tls.nl2.bikini-bottom.com",
            serverAddr: "nl.example:443",
            cachedIsAdmin: false
        )

        let actions = ProfilePresentation.actions(for: profile, isActive: true)

        XCTAssertFalse(actions.contains(.serverControl))
        XCTAssertEqual(actions, [.identity, .subscription, .edit, .share, .delete])
    }

    func testAdminProfileExposesServerControlFirst() {
        let profile = VpnProfile(
            id: "admin",
            name: "stockholm-admin",
            serverAddr: "se.example:443",
            cachedIsAdmin: true
        )

        let actions = ProfilePresentation.actions(for: profile, isActive: false)

        XCTAssertEqual(actions.first, .serverControl)
        XCTAssertTrue(actions.contains(.createClientLink))
        XCTAssertTrue(actions.contains(.setActive))
    }

    @MainActor
    func testAdminGatewayIsDerivedFromProfileTunAddress() {
        let profile = VpnProfile(tunAddr: "10.42.9.77/24")

        XCTAssertEqual(
            ProfileEntitlementRefresher.adminBaseURL(for: profile)?.absoluteString,
            "https://10.42.9.1:8080"
        )
    }

    @MainActor
    func testTunMatchingIgnoresPrefixLength() {
        XCTAssertTrue(ProfileEntitlementRefresher.sameTunIP("10.7.0.2/24", "10.7.0.2"))
        XCTAssertFalse(ProfileEntitlementRefresher.sameTunIP("10.7.0.3/24", "10.7.0.2"))
    }
}
