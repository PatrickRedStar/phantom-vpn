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
}
