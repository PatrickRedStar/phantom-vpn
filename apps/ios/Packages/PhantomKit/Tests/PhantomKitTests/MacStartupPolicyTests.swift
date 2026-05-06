import XCTest
@testable import PhantomKit

final class MacStartupPolicyTests: XCTestCase {
    func testConfiguredManagerDoesNotOpenSetup() {
        let decision = MacStartupPolicy.decide(
            managerConfigured: true,
            hasActiveProfile: true,
            startInMenuBar: false
        )

        XCTAssertTrue(decision.shouldActivateSystemExtension)
        XCTAssertNil(decision.foregroundWindow)
    }

    func testProfileWithoutManagerOpensWelcomeByDefault() {
        let decision = MacStartupPolicy.decide(
            managerConfigured: false,
            hasActiveProfile: true,
            startInMenuBar: false
        )

        XCTAssertTrue(decision.shouldActivateSystemExtension)
        XCTAssertEqual(decision.foregroundWindow, .welcome)
    }

    func testStartInMenuBarSuppressesWelcomeWindow() {
        let decision = MacStartupPolicy.decide(
            managerConfigured: false,
            hasActiveProfile: true,
            startInMenuBar: true
        )

        XCTAssertTrue(decision.shouldActivateSystemExtension)
        XCTAssertNil(decision.foregroundWindow)
    }
}
