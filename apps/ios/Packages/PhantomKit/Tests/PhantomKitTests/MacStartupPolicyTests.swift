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

// Добивка покрытия (июль 2026): ветка «нет менеджера и нет профиля» —
// extension НЕ активируем (нечего запускать), онбординг открываем
// в зависимости от startInMenuBar.
extension MacStartupPolicyTests {
    func testNoManagerNoProfileShowsWelcomeAndSkipsActivation() {
        let decision = MacStartupPolicy.decide(
            managerConfigured: false,
            hasActiveProfile: false,
            startInMenuBar: false
        )
        XCTAssertFalse(decision.shouldActivateSystemExtension)
        XCTAssertEqual(decision.foregroundWindow, .welcome)
    }

    func testNoManagerNoProfileMenuBarStartStaysHidden() {
        let decision = MacStartupPolicy.decide(
            managerConfigured: false,
            hasActiveProfile: false,
            startInMenuBar: true
        )
        XCTAssertFalse(decision.shouldActivateSystemExtension)
        XCTAssertNil(decision.foregroundWindow)
    }
}
