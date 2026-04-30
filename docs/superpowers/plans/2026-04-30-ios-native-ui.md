# iOS Native UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the current Android-parity iOS shell with the native iOS interaction model captured in `docs/ios-native-design-audit.html`: native tabs, profile-scoped Admin, full profile/detail flows, real sheets, and no visible no-op controls.

**Architecture:** Keep the existing SwiftUI + PhantomKit runtime and introduce small presentation helpers that are unit-tested before view rewrites. Root navigation becomes a native `TabView` with three tabs only; Admin is reachable only from a `VpnProfile` where `cachedIsAdmin == true`. Complex screens stay split by feature folder, and pure formatting/filtering/capability logic lives in `UI/Presentation` so it can be tested without launching the NetworkExtension.

**Tech Stack:** Swift 5.9, SwiftUI, Observation, NetworkExtension, XcodeGen, XCTest, PhantomKit, PhantomUI.

---

## Scope Check

This plan covers only the iOS client UI. It intentionally does not edit macOS, Android, Rust, server, or OpenWRT code. The implementation should run on `master`, but each task commits only the files it touches.

The approved design source is:
- `docs/ios-native-design-audit.html`

Reference docs:
- `docs/ios-ui-spec.md`
- `apps/ios/README.md`

Before editing any existing Swift symbol, run GitNexus impact for that symbol and stop for user confirmation if the risk is HIGH or CRITICAL.

---

## File Structure

### Create

- `apps/ios/GhostStream/UI/Presentation/DashboardPresentation.swift`  
  Pure display derivations for Dashboard: status title, status tone, button title, route summary, subscription summary.

- `apps/ios/GhostStream/UI/Presentation/LogsPresentation.swift`  
  Pure log filtering/search/export ordering helpers.

- `apps/ios/GhostStream/UI/Presentation/ProfilePresentation.swift`  
  Pure capability/action model for user profiles versus admin profiles.

- `apps/ios/GhostStream/UI/Components/NativeIOSPrimitives.swift`  
  Native iOS reusable surfaces used by Dashboard, Settings, Profile, Admin: section card, row, primary bottom action, status pill.

- `apps/ios/GhostStream/UI/Settings/ProfileDetailView.swift`  
  Profile detail screen. Shows user profile actions for all profiles and Admin entry only for admin-capable profiles.

- `apps/ios/GhostStreamTests/DashboardPresentationTests.swift`
- `apps/ios/GhostStreamTests/LogsPresentationTests.swift`
- `apps/ios/GhostStreamTests/ProfilePresentationTests.swift`
- `apps/ios/GhostStreamTests/AppNavigationTests.swift`

### Modify

- `apps/ios/project.yml`  
  Add `GhostStreamTests` unit-test target.

- `apps/ios/GhostStream/App/AppNavigation.swift`  
  Replace custom Android-glyph bottom capsule with native `TabView`; keep only Stream, Logs, Settings.

- `apps/ios/GhostStream/UI/Dashboard/DashboardView.swift`  
  Rebuild as native status-card first screen with chart, metrics, details and bottom connect action.

- `apps/ios/GhostStream/UI/Logs/LogsView.swift`
- `apps/ios/GhostStream/UI/Logs/LogsViewModel.swift`  
  Add search, clear confirmation, share sheet states, native toolbar/search treatment.

- `apps/ios/GhostStream/UI/Settings/SettingsView.swift`
- `apps/ios/GhostStream/UI/Settings/ProfileEditorView.swift`  
  Replace custom ZStack dialogs with native sheets/confirmation dialogs where possible. Push profile details before Admin.

- `apps/ios/GhostStream/UI/Admin/AdminView.swift`
- `apps/ios/GhostStream/UI/Admin/ClientDetailView.swift`
- `apps/ios/GhostStream/UI/Admin/CreateClientSheet.swift`  
  Make Admin profile-scoped, native navigation driven, and keep server/client destructive flows explicit.

- `apps/ios/GhostStream/Resources/ru.lproj/Localizable.strings`
- `apps/ios/GhostStream/Resources/en.lproj/Localizable.strings`  
  Add native UI strings and remove user-visible Android-only wording from new surfaces.

### Do Not Touch

- `apps/macos/**`
- `apps/android/**`
- `crates/**`
- `server/**`

---

## Task 1: Add Test Target And Presentation Helpers

**Files:**
- Modify: `apps/ios/project.yml`
- Create: `apps/ios/GhostStream/UI/Presentation/DashboardPresentation.swift`
- Create: `apps/ios/GhostStream/UI/Presentation/LogsPresentation.swift`
- Create: `apps/ios/GhostStream/UI/Presentation/ProfilePresentation.swift`
- Create: `apps/ios/GhostStreamTests/DashboardPresentationTests.swift`
- Create: `apps/ios/GhostStreamTests/LogsPresentationTests.swift`
- Create: `apps/ios/GhostStreamTests/ProfilePresentationTests.swift`

- [ ] **Step 1: Add the failing test target to XcodeGen**

Modify `apps/ios/project.yml` by adding this target after `PacketTunnelProvider`:

```yaml
  GhostStreamTests:
    type: bundle.unit-test
    platform: iOS
    deploymentTarget: "17.0"
    sources:
      - path: GhostStreamTests
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.ghoststream.vpn.tests
        INFOPLIST_FILE: ""
    dependencies:
      - target: GhostStream
      - package: PhantomKit
        product: PhantomKit
      - package: PhantomKit
        product: PhantomUI
```

- [ ] **Step 2: Create failing Dashboard presentation tests**

Create `apps/ios/GhostStreamTests/DashboardPresentationTests.swift`:

```swift
import XCTest
import PhantomKit
@testable import GhostStream

final class DashboardPresentationTests: XCTestCase {
    func testDisconnectedPresentationUsesStandbyCopyAndConnectAction() {
        let result = DashboardPresentation.make(
            state: .disconnected,
            activeProfileName: nil,
            timerText: "--:--:--",
            routeIsDirect: true,
            subscriptionText: nil
        )

        XCTAssertEqual(result.title, "Standby")
        XCTAssertEqual(result.subtitle, "Add a profile to start VPN")
        XCTAssertEqual(result.primaryActionTitle, "Connect")
        XCTAssertEqual(result.tone, .neutral)
        XCTAssertEqual(result.routeText, "Direct")
    }

    func testConnectedPresentationUsesProfileTimerAndDisconnectAction() {
        let result = DashboardPresentation.make(
            state: .connected(since: Date(timeIntervalSince1970: 100), name: "stockholm-admin"),
            activeProfileName: "stockholm-admin",
            timerText: "00:07:42",
            routeIsDirect: false,
            subscriptionText: "5 days remaining"
        )

        XCTAssertEqual(result.title, "Protected")
        XCTAssertEqual(result.subtitle, "stockholm-admin · 00:07:42")
        XCTAssertEqual(result.primaryActionTitle, "Disconnect")
        XCTAssertEqual(result.tone, .success)
        XCTAssertEqual(result.routeText, "Relay")
        XCTAssertEqual(result.subscriptionText, "5 days remaining")
    }
}
```

- [ ] **Step 3: Create failing Logs presentation tests**

Create `apps/ios/GhostStreamTests/LogsPresentationTests.swift`:

```swift
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
```

- [ ] **Step 4: Create failing Profile presentation tests**

Create `apps/ios/GhostStreamTests/ProfilePresentationTests.swift`:

```swift
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
```

- [ ] **Step 5: Run tests to verify they fail because helpers do not exist**

Run:

```bash
cd /Users/p.kurkin/Documents/phantom-vpn/apps/ios
xcodegen generate
xcodebuild test -project GhostStream.xcodeproj -scheme GhostStreamTests -destination 'platform=iOS Simulator,name=iPhone 16 Pro Max' DEVELOPMENT_TEAM=UPG896A272
```

Expected: FAIL with compiler errors containing:

```text
Cannot find 'DashboardPresentation' in scope
Cannot find 'LogsPresentation' in scope
Cannot find 'ProfilePresentation' in scope
```

- [ ] **Step 6: Implement presentation helpers**

Create `apps/ios/GhostStream/UI/Presentation/DashboardPresentation.swift`:

```swift
import Foundation
import PhantomKit

enum DashboardTone: Equatable {
    case neutral
    case success
    case warning
    case danger
}

struct DashboardPresentationResult: Equatable {
    let title: String
    let subtitle: String
    let primaryActionTitle: String
    let tone: DashboardTone
    let routeText: String
    let subscriptionText: String
}

enum DashboardPresentation {
    static func make(
        state: VpnState,
        activeProfileName: String?,
        timerText: String,
        routeIsDirect: Bool,
        subscriptionText: String?
    ) -> DashboardPresentationResult {
        let profileName = activeProfileName ?? "No profile"
        let route = routeIsDirect ? "Direct" : "Relay"
        let subscription = subscriptionText ?? "No subscription data"

        switch state {
        case .connected:
            return DashboardPresentationResult(
                title: "Protected",
                subtitle: "\(profileName) · \(timerText)",
                primaryActionTitle: "Disconnect",
                tone: .success,
                routeText: route,
                subscriptionText: subscription
            )
        case .connecting:
            return DashboardPresentationResult(
                title: "Connecting",
                subtitle: profileName,
                primaryActionTitle: "Stop attempt",
                tone: .warning,
                routeText: route,
                subscriptionText: subscription
            )
        case .disconnecting:
            return DashboardPresentationResult(
                title: "Disconnecting",
                subtitle: profileName,
                primaryActionTitle: "Disconnect",
                tone: .warning,
                routeText: route,
                subscriptionText: subscription
            )
        case .error(let message):
            return DashboardPresentationResult(
                title: "Connection failed",
                subtitle: message,
                primaryActionTitle: "Retry",
                tone: .danger,
                routeText: route,
                subscriptionText: subscription
            )
        case .disconnected:
            return DashboardPresentationResult(
                title: "Standby",
                subtitle: activeProfileName == nil ? "Add a profile to start VPN" : profileName,
                primaryActionTitle: "Connect",
                tone: .neutral,
                routeText: route,
                subscriptionText: subscription
            )
        }
    }
}
```

Create `apps/ios/GhostStream/UI/Presentation/LogsPresentation.swift`:

```swift
import Foundation
import PhantomKit

enum LogsPresentation {
    static func visibleLogs(
        allLogs: [LogFrame],
        filter: LogFilter,
        searchText: String
    ) -> [LogFrame] {
        let levelMinimum = filter.priority
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        return allLogs
            .filter { frame in
                let levelAllowed = levelMinimum < 0 || LogFilter.priority(of: frame.level) >= levelMinimum
                guard levelAllowed else { return false }
                guard !needle.isEmpty else { return true }
                return frame.level.lowercased().contains(needle)
                    || frame.msg.lowercased().contains(needle)
            }
            .reversed()
    }
}
```

Create `apps/ios/GhostStream/UI/Presentation/ProfilePresentation.swift`:

```swift
import Foundation
import PhantomKit

enum ProfileActionKind: Equatable {
    case serverControl
    case createClientLink
    case identity
    case subscription
    case setActive
    case edit
    case share
    case delete
}

enum ProfilePresentation {
    static func actions(for profile: VpnProfile, isActive: Bool) -> [ProfileActionKind] {
        var actions: [ProfileActionKind] = []

        if profile.cachedIsAdmin == true {
            actions.append(.serverControl)
            actions.append(.createClientLink)
        }

        actions.append(.identity)
        actions.append(.subscription)

        if !isActive {
            actions.append(.setActive)
        }

        actions.append(.edit)
        actions.append(.share)
        actions.append(.delete)

        return actions
    }
}
```

- [ ] **Step 7: Run tests to verify they pass**

Run:

```bash
cd /Users/p.kurkin/Documents/phantom-vpn/apps/ios
xcodegen generate
xcodebuild test -project GhostStream.xcodeproj -scheme GhostStreamTests -destination 'platform=iOS Simulator,name=iPhone 16 Pro Max' DEVELOPMENT_TEAM=UPG896A272
```

Expected: PASS for `DashboardPresentationTests`, `LogsPresentationTests`, and `ProfilePresentationTests`.

- [ ] **Step 8: Commit**

Run:

```bash
cd /Users/p.kurkin/Documents/phantom-vpn
git add apps/ios/project.yml apps/ios/GhostStream.xcodeproj apps/ios/GhostStream/UI/Presentation apps/ios/GhostStreamTests
git commit -m "NO-TICKET: add iOS UI presentation tests"
```

---

## Task 2: Replace Android-Glyph Root Navigation With Native iOS Tabs

**Files:**
- Modify: `apps/ios/GhostStream/App/AppNavigation.swift`
- Create: `apps/ios/GhostStreamTests/AppNavigationTests.swift`

- [ ] **Step 1: Run GitNexus impact**

Run impact analysis for the edited symbols:

```text
gitnexus_impact({target: "AppNavigation", direction: "upstream", repo: "phantom-vpn"})
gitnexus_impact({target: "AppTab", direction: "upstream", repo: "phantom-vpn"})
```

Expected: LOW or MEDIUM risk. If HIGH or CRITICAL, stop and report affected direct callers before editing.

- [ ] **Step 2: Write failing AppNavigation tests**

Create `apps/ios/GhostStreamTests/AppNavigationTests.swift`:

```swift
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
```

- [ ] **Step 3: Run test to verify it fails**

Run:

```bash
cd /Users/p.kurkin/Documents/phantom-vpn/apps/ios
xcodebuild test -project GhostStream.xcodeproj -scheme GhostStreamTests -destination 'platform=iOS Simulator,name=iPhone 16 Pro Max' DEVELOPMENT_TEAM=UPG896A272 -only-testing:GhostStreamTests/AppNavigationTests
```

Expected: FAIL with `Value of type 'AppTab' has no member 'systemImageName'`.

- [ ] **Step 4: Replace `AppTab.glyph` with native symbol metadata**

In `apps/ios/GhostStream/App/AppNavigation.swift`, replace the `glyph` computed property with:

```swift
var systemImageName: String {
    switch self {
    case .dashboard: return "waveform.path.ecg"
    case .logs:      return "doc.text.magnifyingglass"
    case .settings:  return "gearshape"
    }
}
```

- [ ] **Step 5: Replace custom `ZStack` navigation body with native `TabView`**

In `AppNavigation.body`, replace the custom `ZStack`, drag gesture, `GhostBottomNav`, and fade with:

```swift
var body: some View {
    TabView(selection: $selection) {
        NavigationStack {
            DashboardView()
        }
        .tabItem {
            Label(AppTab.dashboard.label, systemImage: AppTab.dashboard.systemImageName)
        }
        .tag(AppTab.dashboard)

        NavigationStack {
            LogsView()
        }
        .tabItem {
            Label(AppTab.logs.label, systemImage: AppTab.logs.systemImageName)
        }
        .tag(AppTab.logs)

        NavigationStack {
            SettingsView()
        }
        .tabItem {
            Label(AppTab.settings.label, systemImage: AppTab.settings.systemImageName)
        }
        .tag(AppTab.settings)
    }
    .tint(C.signal)
    .toolbarBackground(C.bg, for: .tabBar)
    .toolbarBackground(.visible, for: .tabBar)
}
```

Delete the now-unused `dragOffset`, `tabContent(_:)`, `tabSwipeGesture`, and `GhostBottomNav` definitions from `AppNavigation.swift`.

- [ ] **Step 6: Run focused tests**

Run:

```bash
cd /Users/p.kurkin/Documents/phantom-vpn/apps/ios
xcodebuild test -project GhostStream.xcodeproj -scheme GhostStreamTests -destination 'platform=iOS Simulator,name=iPhone 16 Pro Max' DEVELOPMENT_TEAM=UPG896A272 -only-testing:GhostStreamTests/AppNavigationTests
```

Expected: PASS.

- [ ] **Step 7: Build the app**

Run:

```bash
cd /Users/p.kurkin/Documents/phantom-vpn
xcodebuild -project apps/ios/GhostStream.xcodeproj -scheme GhostStream -destination 'platform=iOS,id=00008140-001155D011BB001C' DEVELOPMENT_TEAM=UPG896A272 -allowProvisioningUpdates build
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 8: Commit**

Run:

```bash
cd /Users/p.kurkin/Documents/phantom-vpn
git add apps/ios/GhostStream/App/AppNavigation.swift apps/ios/GhostStreamTests/AppNavigationTests.swift
git commit -m "NO-TICKET: switch iOS root navigation to native tabs"
```

---

## Task 3: Add Native iOS Primitives Used By All Screens

**Files:**
- Create: `apps/ios/GhostStream/UI/Components/NativeIOSPrimitives.swift`

- [ ] **Step 1: Create the shared primitives file**

Create `apps/ios/GhostStream/UI/Components/NativeIOSPrimitives.swift`:

```swift
import SwiftUI
import PhantomUI

struct NativeSectionCard<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @Environment(\.gsColors) private var C

    var body: some View {
        VStack(spacing: 0, content: content)
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(C.bgElev.opacity(0.92))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(C.hair, lineWidth: 1)
                    )
            )
    }
}

struct NativeRow<Trailing: View>: View {
    let title: String
    let subtitle: String?
    let role: ButtonRole?
    let action: (() -> Void)?
    @ViewBuilder let trailing: () -> Trailing
    @Environment(\.gsColors) private var C

    init(
        title: String,
        subtitle: String? = nil,
        role: ButtonRole? = nil,
        action: (() -> Void)? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.role = role
        self.action = action
        self.trailing = trailing
    }

    var body: some View {
        Button(role: role) {
            action?()
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(role == .destructive ? C.danger : C.bone)
                    if let subtitle {
                        Text(subtitle)
                            .font(.footnote)
                            .foregroundStyle(C.textDim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                trailing()
            }
            .contentShape(Rectangle())
            .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
    }
}

extension NativeRow where Trailing == Image {
    init(title: String, subtitle: String? = nil, role: ButtonRole? = nil, action: (() -> Void)? = nil) {
        self.init(title: title, subtitle: subtitle, role: role, action: action) {
            Image(systemName: "chevron.right")
        }
    }
}

struct NativeStatusPill: View {
    let text: String
    let tone: DashboardTone
    @Environment(\.gsColors) private var C

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundStyle(color)
            .background(color.opacity(0.12), in: Capsule(style: .continuous))
    }

    private var color: Color {
        switch tone {
        case .neutral: return C.textDim
        case .success: return C.signal
        case .warning: return C.warn
        case .danger:  return C.danger
        }
    }
}

struct NativeBottomAction: View {
    let title: String
    let tone: DashboardTone
    let action: () -> Void
    @Environment(\.gsColors) private var C

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .foregroundStyle(filled ? C.bg : C.bone)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(filled ? color : Color.clear)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(color, lineWidth: filled ? 0 : 1)
                        )
                )
        }
        .buttonStyle(.plain)
    }

    private var filled: Bool {
        tone == .success || tone == .danger
    }

    private var color: Color {
        switch tone {
        case .neutral: return C.signal
        case .success: return C.signal
        case .warning: return C.warn
        case .danger:  return C.danger
        }
    }
}
```

- [ ] **Step 2: Build to catch component syntax issues**

Run:

```bash
cd /Users/p.kurkin/Documents/phantom-vpn
xcodebuild -project apps/ios/GhostStream.xcodeproj -scheme GhostStream -destination 'platform=iOS Simulator,name=iPhone 16 Pro Max' DEVELOPMENT_TEAM=UPG896A272 build
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

Run:

```bash
cd /Users/p.kurkin/Documents/phantom-vpn
git add apps/ios/GhostStream/UI/Components/NativeIOSPrimitives.swift
git commit -m "NO-TICKET: add native iOS UI primitives"
```

---

## Task 4: Implement Profile Detail And Profile-Scoped Admin Entry

**Files:**
- Modify: `apps/ios/GhostStream/UI/Settings/SettingsView.swift`
- Create: `apps/ios/GhostStream/UI/Settings/ProfileDetailView.swift`
- Modify: `apps/ios/GhostStream/UI/Components/ProfileCard.swift`

- [ ] **Step 1: Run GitNexus impact**

Run:

```text
gitnexus_impact({target: "SettingsView", direction: "upstream", repo: "phantom-vpn"})
gitnexus_impact({target: "ProfileCard", direction: "upstream", repo: "phantom-vpn"})
```

Expected: LOW or MEDIUM risk. If HIGH or CRITICAL, stop and report the blast radius before editing.

- [ ] **Step 2: Create `ProfileDetailView`**

Create `apps/ios/GhostStream/UI/Settings/ProfileDetailView.swift`:

```swift
import SwiftUI
import PhantomKit
import PhantomUI

struct ProfileDetailView: View {
    let profile: VpnProfile
    let isActive: Bool
    let pingMs: Int?
    let onSetActive: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onOpenAdmin: () -> Void

    @Environment(\.gsColors) private var C

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                headerCard
                NativeSectionCard {
                    ForEach(ProfilePresentation.actions(for: profile, isActive: isActive), id: \.self) { action in
                        row(for: action)
                        if action != ProfilePresentation.actions(for: profile, isActive: isActive).last {
                            HairlineDivider()
                        }
                    }
                }
                identitySection
                subscriptionSection
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
        }
        .background(C.bg.ignoresSafeArea())
        .navigationTitle(profile.name)
        .navigationBarTitleDisplayMode(.large)
    }

    private var headerCard: some View {
        GhostCard(active: isActive) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(profile.serverAddr.isEmpty ? "No server address" : profile.serverAddr)
                        .font(.subheadline)
                        .foregroundStyle(C.textDim)
                    Spacer()
                    NativeStatusPill(
                        text: profile.cachedIsAdmin == true ? "Admin" : "User",
                        tone: profile.cachedIsAdmin == true ? .success : .neutral
                    )
                }
                Text(isActive ? "Active profile" : "Saved profile")
                    .font(.caption)
                    .foregroundStyle(C.textFaint)
            }
        }
    }

    @ViewBuilder
    private func row(for action: ProfileActionKind) -> some View {
        switch action {
        case .serverControl:
            NativeRow(title: "Server control", subtitle: "Open admin tools for this server only", action: onOpenAdmin)
        case .createClientLink:
            NativeRow(title: "Create client link", subtitle: "Generate a one-time ghs:// connection string", action: onOpenAdmin)
        case .identity:
            NativeRow(title: "Identity", subtitle: profile.tunAddr, action: nil)
        case .subscription:
            NativeRow(title: "Subscription", subtitle: subscriptionText, action: nil)
        case .setActive:
            NativeRow(title: "Set active", subtitle: "Use this endpoint for Connect", action: onSetActive)
        case .edit:
            NativeRow(title: "Edit endpoint", subtitle: "Name, server and connection string", action: onEdit)
        case .share:
            NativeRow(title: "Share to device", subtitle: "Copy connection string when available", action: nil)
        case .delete:
            NativeRow(title: "Delete profile", subtitle: "Remove local config and keys", role: .destructive, action: onDelete)
        }
    }

    private var identitySection: some View {
        NativeSectionCard {
            NativeRow(title: "Assigned address", subtitle: profile.tunAddr, action: nil)
            HairlineDivider()
            NativeRow(title: "Certificate", subtitle: profile.certPem == nil ? "Stored in shared keychain" : "Loaded for this session", action: nil)
            HairlineDivider()
            NativeRow(title: "Admin fingerprint", subtitle: profile.cachedAdminServerCertFp ?? "Not available", action: nil)
        }
    }

    private var subscriptionSection: some View {
        NativeSectionCard {
            NativeRow(title: "Subscription", subtitle: subscriptionText, action: nil)
        }
    }

    private var subscriptionText: String {
        guard let expiresAt = profile.cachedExpiresAt else { return "No expiry data" }
        let remaining = expiresAt - Int64(Date().timeIntervalSince1970)
        if remaining <= 0 { return "Expired" }
        let days = remaining / 86_400
        let hours = (remaining % 86_400) / 3_600
        return "\(days)d \(hours)h remaining"
    }
}
```

- [ ] **Step 3: Route Settings profile taps to `ProfileDetailView`**

In `SettingsView`, add state:

```swift
@State private var selectedProfileId: String? = nil
```

Change `ProfileCard` tap in `endpointsSection` from immediate set-active to profile detail:

```swift
onTap: {
    selectedProfileId = profile.id
},
```

Add this navigation destination next to the existing `AdminView` destination:

```swift
.navigationDestination(isPresented: Binding(
    get: { selectedProfileId != nil },
    set: { if !$0 { selectedProfileId = nil } }
)) {
    if let id = selectedProfileId,
       let profile = model.profiles.first(where: { $0.id == id }) {
        ProfileDetailView(
            profile: profile,
            isActive: profile.id == model.activeId,
            pingMs: model.pingResults[profile.id],
            onSetActive: {
                model.setActiveProfile(id: profile.id)
                selectedProfileId = nil
            },
            onEdit: {
                editorProfileId = profile.id
            },
            onDelete: {
                deleteProfileId = profile.id
                selectedProfileId = nil
            },
            onOpenAdmin: {
                guard profile.cachedIsAdmin == true else { return }
                adminProfile = profile
            }
        )
    }
}
```

- [ ] **Step 4: Keep profile card action rail minimal**

In `profileActions(for:)`, remove the Admin action and keep quick actions:

```swift
private func profileActions(for profile: VpnProfile) -> [ProfileCardAction] {
    let isActive = profile.id == model.activeId
    return [
        ProfileCardAction(
            label: isActive ? L("settings.profile.active") : L("settings.profile.make.active"),
            systemImage: isActive ? "checkmark.circle.fill" : "checkmark.circle",
            isEnabled: !isActive
        ) {
            model.setActiveProfile(id: profile.id)
        },
        ProfileCardAction(label: L("settings.profile.ping"), systemImage: "speedometer") {
            Task { _ = await model.pingProfile(profile) }
        },
        ProfileCardAction(label: L("general.edit"), systemImage: "pencil") {
            editorProfileId = profile.id
        },
        ProfileCardAction(label: L("general.delete"), systemImage: "trash", role: .destructive) {
            deleteProfileId = profile.id
        }
    ]
}
```

- [ ] **Step 5: Run profile tests and app build**

Run:

```bash
cd /Users/p.kurkin/Documents/phantom-vpn/apps/ios
xcodebuild test -project GhostStream.xcodeproj -scheme GhostStreamTests -destination 'platform=iOS Simulator,name=iPhone 16 Pro Max' DEVELOPMENT_TEAM=UPG896A272 -only-testing:GhostStreamTests/ProfilePresentationTests
cd /Users/p.kurkin/Documents/phantom-vpn
xcodebuild -project apps/ios/GhostStream.xcodeproj -scheme GhostStream -destination 'platform=iOS Simulator,name=iPhone 16 Pro Max' DEVELOPMENT_TEAM=UPG896A272 build
```

Expected: tests PASS and build succeeds.

- [ ] **Step 6: Commit**

Run:

```bash
cd /Users/p.kurkin/Documents/phantom-vpn
git add apps/ios/GhostStream/UI/Settings/SettingsView.swift apps/ios/GhostStream/UI/Settings/ProfileDetailView.swift apps/ios/GhostStream/UI/Components/ProfileCard.swift
git commit -m "NO-TICKET: add profile scoped iOS detail flow"
```

---

## Task 5: Rebuild Dashboard As Native iOS Status Screen

**Files:**
- Modify: `apps/ios/GhostStream/UI/Dashboard/DashboardView.swift`

- [ ] **Step 1: Run GitNexus impact**

Run:

```text
gitnexus_impact({target: "DashboardView", direction: "upstream", repo: "phantom-vpn"})
gitnexus_impact({target: "DashboardViewModel", direction: "upstream", repo: "phantom-vpn"})
```

Expected: LOW or MEDIUM risk. If HIGH or CRITICAL, stop and report affected callers.

- [ ] **Step 2: Replace Android headline section with native status card**

In `DashboardView`, replace `stateSection`, `timerRow`, and `profileKvCard` usage with this order inside the `ScrollView`:

```swift
VStack(alignment: .leading, spacing: 16) {
    nativeStatusCard
    reconnectBanner
    emptyHint
    preflightBanner
    metricsCard
    scopeCard
    muxCard
    detailsCard
    NativeBottomAction(
        title: dashboardPresentation.primaryActionTitle,
        tone: dashboardPresentation.tone,
        action: {
            if isConnected {
                vm.stop()
            } else {
                vm.start(profile: profiles.activeProfile, preferences: prefs)
            }
        }
    )
    Spacer(minLength: 88)
}
.padding(.horizontal, 18)
.padding(.top, 12)
```

Add these computed properties to `DashboardView`:

```swift
private var dashboardPresentation: DashboardPresentationResult {
    DashboardPresentation.make(
        state: vm.state,
        activeProfileName: profiles.activeProfile?.name,
        timerText: vm.timerText,
        routeIsDirect: profiles.activeProfile?.splitRouting == true,
        subscriptionText: vm.subscriptionText
    )
}

private var nativeStatusCard: some View {
    GhostCard(active: isConnected) {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                NativeStatusPill(text: dashboardPresentation.title, tone: dashboardPresentation.tone)
                Spacer()
                Text(vm.timerText)
                    .font(.system(.callout, design: .monospaced).weight(.semibold))
                    .foregroundStyle(isConnected ? C.bone : C.textFaint)
            }

            Text(dashboardPresentation.subtitle)
                .font(.title3.weight(.semibold))
                .foregroundStyle(C.bone)
                .lineLimit(2)
                .minimumScaleFactor(0.8)

            Text(profiles.activeProfile?.serverAddr ?? "No endpoint selected")
                .font(.footnote)
                .foregroundStyle(C.textDim)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

private var metricsCard: some View {
    NativeSectionCard {
        NativeRow(title: "Download", subtitle: rxValueText, action: nil) {
            Text("RX").foregroundStyle(C.signal).font(.caption.weight(.bold))
        }
        HairlineDivider()
        NativeRow(title: "Upload", subtitle: txValueText, action: nil) {
            Text("TX").foregroundStyle(C.warn).font(.caption.weight(.bold))
        }
    }
}

private var detailsCard: some View {
    NativeSectionCard {
        NativeRow(title: "Identity", subtitle: profiles.activeProfile?.name ?? "No profile", action: nil)
        HairlineDivider()
        NativeRow(title: "Route", subtitle: dashboardPresentation.routeText, action: nil)
        HairlineDivider()
        NativeRow(title: "Assigned address", subtitle: profiles.activeProfile?.tunAddr ?? "—", action: nil)
        HairlineDivider()
        NativeRow(title: "Subscription", subtitle: dashboardPresentation.subscriptionText, action: nil)
    }
}
```

- [ ] **Step 3: Keep chart and mux real-data behavior**

Do not change `ScopeChart`, `vm.rxSamples`, `vm.txSamples`, `sampleCapacity`, `MuxBars`, or `stateMgr.statusFrame` usage except for moving them into the new layout.

- [ ] **Step 4: Run tests and build**

Run:

```bash
cd /Users/p.kurkin/Documents/phantom-vpn/apps/ios
xcodebuild test -project GhostStream.xcodeproj -scheme GhostStreamTests -destination 'platform=iOS Simulator,name=iPhone 16 Pro Max' DEVELOPMENT_TEAM=UPG896A272 -only-testing:GhostStreamTests/DashboardPresentationTests
cd /Users/p.kurkin/Documents/phantom-vpn
xcodebuild -project apps/ios/GhostStream.xcodeproj -scheme GhostStream -destination 'platform=iOS Simulator,name=iPhone 16 Pro Max' DEVELOPMENT_TEAM=UPG896A272 build
```

Expected: tests PASS and build succeeds.

- [ ] **Step 5: Commit**

Run:

```bash
cd /Users/p.kurkin/Documents/phantom-vpn
git add apps/ios/GhostStream/UI/Dashboard/DashboardView.swift
git commit -m "NO-TICKET: rebuild iOS dashboard as native status screen"
```

---

## Task 6: Add Native Logs Search, Clear Confirmation, And Share Flow

**Files:**
- Modify: `apps/ios/GhostStream/UI/Logs/LogsViewModel.swift`
- Modify: `apps/ios/GhostStream/UI/Logs/LogsView.swift`

- [ ] **Step 1: Run GitNexus impact**

Run:

```text
gitnexus_impact({target: "LogsView", direction: "upstream", repo: "phantom-vpn"})
gitnexus_impact({target: "LogsViewModel", direction: "upstream", repo: "phantom-vpn"})
```

Expected: LOW or MEDIUM risk. If HIGH or CRITICAL, stop and report affected callers.

- [ ] **Step 2: Update `LogsViewModel` to use presentation helper**

Add state:

```swift
var searchText: String = ""
```

Replace `visibleLogs` with:

```swift
var visibleLogs: [LogFrame] {
    LogsPresentation.visibleLogs(
        allLogs: allLogs,
        filter: filter,
        searchText: searchText
    )
}
```

Because `visibleLogs` is now newest-first, update `LogsView.logList` by removing `.reversed()`:

```swift
ForEach(vm.visibleLogs) { entry in
    LogFrameRow(entry: entry)
        .id(entry.tsUnixMs)
}
```

- [ ] **Step 3: Add clear confirmation state to `LogsView`**

Add state:

```swift
@State private var showClearConfirmation = false
```

Change the Clear chip action:

```swift
GhostChip(L("chip_clear"), active: false, accent: C.danger) {
    showClearConfirmation = true
}
```

Add these modifiers to the outer `ZStack` chain:

```swift
.searchable(text: $vm.searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search logs")
.confirmationDialog("Clear local logs?", isPresented: $showClearConfirmation, titleVisibility: .visible) {
    Button("Clear", role: .destructive) {
        vm.clear()
    }
    Button("Cancel", role: .cancel) {}
} message: {
    Text("This clears cached app logs on this iPhone. It does not affect server-side logs.")
}
```

- [ ] **Step 4: Run logs tests and build**

Run:

```bash
cd /Users/p.kurkin/Documents/phantom-vpn/apps/ios
xcodebuild test -project GhostStream.xcodeproj -scheme GhostStreamTests -destination 'platform=iOS Simulator,name=iPhone 16 Pro Max' DEVELOPMENT_TEAM=UPG896A272 -only-testing:GhostStreamTests/LogsPresentationTests
cd /Users/p.kurkin/Documents/phantom-vpn
xcodebuild -project apps/ios/GhostStream.xcodeproj -scheme GhostStream -destination 'platform=iOS Simulator,name=iPhone 16 Pro Max' DEVELOPMENT_TEAM=UPG896A272 build
```

Expected: tests PASS and build succeeds.

- [ ] **Step 5: Commit**

Run:

```bash
cd /Users/p.kurkin/Documents/phantom-vpn
git add apps/ios/GhostStream/UI/Logs/LogsView.swift apps/ios/GhostStream/UI/Logs/LogsViewModel.swift
git commit -m "NO-TICKET: add native iOS logs controls"
```

---

## Task 7: Convert Settings Dialogs To Native Sheets And Confirmations

**Files:**
- Modify: `apps/ios/GhostStream/UI/Settings/SettingsView.swift`
- Modify: `apps/ios/GhostStream/UI/Settings/ProfileEditorView.swift`

- [ ] **Step 1: Run GitNexus impact**

Run:

```text
gitnexus_impact({target: "SettingsView", direction: "upstream", repo: "phantom-vpn"})
gitnexus_impact({target: "ProfileEditorView", direction: "upstream", repo: "phantom-vpn"})
```

Expected: LOW or MEDIUM risk. If HIGH or CRITICAL, stop and report affected callers.

- [ ] **Step 2: Replace add-profile custom overlay with native confirmation dialog**

Remove the custom overlay branch whose condition is `if showAddDialog`.

Add this modifier to `SettingsView.body`:

```swift
.confirmationDialog(L("settings.add.profile"), isPresented: $showAddDialog, titleVisibility: .visible) {
    Button(L("settings.scan.qr")) {
        showQRSheet = true
    }
    Button(L("settings.paste.connection")) {
        showPasteDialog = true
    }
    Button(L("general.cancel"), role: .cancel) {}
}
```

- [ ] **Step 3: Replace delete-profile custom overlay with native confirmation dialog**

Remove the custom overlay branch whose condition is `if let deleteProfileId`.

Add this modifier:

```swift
.confirmationDialog(L("settings.delete.profile.title"), isPresented: Binding(
    get: { deleteProfileId != nil },
    set: { if !$0 { deleteProfileId = nil } }
), titleVisibility: .visible) {
    Button(L("general.delete"), role: .destructive) {
        if let deleteProfileId {
            model.deleteProfile(id: deleteProfileId)
            self.deleteProfileId = nil
        }
    }
    Button(L("general.cancel"), role: .cancel) {
        deleteProfileId = nil
    }
} message: {
    Text(L("settings.delete.profile.message"))
}
```

- [ ] **Step 4: Keep DNS and split-routing as sheets with detents**

Replace the custom overlay branch whose condition is `if showDNSDialog` with:

```swift
.sheet(isPresented: $showDNSDialog) {
    DNSDialog(
        draft: $dnsDraft,
        onSave: {
            model.setDnsServers(dnsDraft)
            showDNSDialog = false
        },
        onDismiss: {
            dnsDraft = model.dnsServers
            showDNSDialog = false
        }
    )
    .presentationDetents([.medium, .large])
}
```

Replace the custom overlay branch whose condition is `if showSplitDialog` with:

```swift
.sheet(isPresented: $showSplitDialog) {
    SplitTunnelDialog(
        splitOn: $splitOn,
        onSave: {
            model.setSplitRouting(splitOn)
            showSplitDialog = false
        },
        onDismiss: {
            splitOn = model.splitRouting
            showSplitDialog = false
        }
    )
    .presentationDetents([.medium])
}
```

- [ ] **Step 5: Build Settings**

Run:

```bash
cd /Users/p.kurkin/Documents/phantom-vpn
xcodebuild -project apps/ios/GhostStream.xcodeproj -scheme GhostStream -destination 'platform=iOS Simulator,name=iPhone 16 Pro Max' DEVELOPMENT_TEAM=UPG896A272 build
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Commit**

Run:

```bash
cd /Users/p.kurkin/Documents/phantom-vpn
git add apps/ios/GhostStream/UI/Settings/SettingsView.swift apps/ios/GhostStream/UI/Settings/ProfileEditorView.swift
git commit -m "NO-TICKET: use native iOS settings sheets"
```

---

## Task 8: Make Admin Native And Strictly Profile-Scoped

**Files:**
- Modify: `apps/ios/GhostStream/UI/Admin/AdminView.swift`
- Modify: `apps/ios/GhostStream/UI/Admin/ClientDetailView.swift`
- Modify: `apps/ios/GhostStream/UI/Admin/CreateClientSheet.swift`

- [ ] **Step 1: Run GitNexus impact**

Run:

```text
gitnexus_impact({target: "AdminView", direction: "upstream", repo: "phantom-vpn"})
gitnexus_impact({target: "ClientDetailView", direction: "upstream", repo: "phantom-vpn"})
gitnexus_impact({target: "CreateClientSheet", direction: "upstream", repo: "phantom-vpn"})
```

Expected: LOW or MEDIUM risk. If HIGH or CRITICAL, stop and report affected callers.

- [ ] **Step 2: Replace custom Admin header with native navigation title**

In `AdminView.body`, remove `controlHeader` from the `VStack`.

Add these modifiers to the root view:

```swift
.navigationTitle(vm.profile.name)
.navigationBarTitleDisplayMode(.large)
.toolbar {
    ToolbarItem(placement: .topBarTrailing) {
        Button {
            Task { await vm.refresh() }
        } label: {
            Image(systemName: vm.loading ? "hourglass" : "arrow.clockwise")
        }
        .disabled(vm.loading)
    }
}
```

If `AdminViewModel.profile` is private, expose it as:

```swift
private(set) var profile: VpnProfile
```

- [ ] **Step 3: Keep Create Client as a native sheet**

Ensure the existing create sheet keeps:

```swift
.sheet(isPresented: $showCreateSheet) {
    CreateClientSheet(viewModel: vm)
        .presentationDetents([.medium, .large])
        .environment(\.gsColors, C)
}
```

- [ ] **Step 4: Ensure Admin remains unreachable without admin profile**

Do not add any `AdminView()` route to `AppNavigation`. The only entry remains `ProfileDetailView.onOpenAdmin`, guarded by:

```swift
guard profile.cachedIsAdmin == true else { return }
adminProfile = profile
```

- [ ] **Step 5: Build**

Run:

```bash
cd /Users/p.kurkin/Documents/phantom-vpn
xcodebuild -project apps/ios/GhostStream.xcodeproj -scheme GhostStream -destination 'platform=iOS Simulator,name=iPhone 16 Pro Max' DEVELOPMENT_TEAM=UPG896A272 build
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Commit**

Run:

```bash
cd /Users/p.kurkin/Documents/phantom-vpn
git add apps/ios/GhostStream/UI/Admin/AdminView.swift apps/ios/GhostStream/UI/Admin/ClientDetailView.swift apps/ios/GhostStream/UI/Admin/CreateClientSheet.swift
git commit -m "NO-TICKET: make iOS admin native and profile scoped"
```

---

## Task 9: Localize New Native UI Strings

**Files:**
- Modify: `apps/ios/GhostStream/Resources/ru.lproj/Localizable.strings`
- Modify: `apps/ios/GhostStream/Resources/en.lproj/Localizable.strings`
- Modify: new/changed Swift files from Tasks 4-8 to use `NSLocalizedString`

- [ ] **Step 1: Add Russian strings**

Append to `apps/ios/GhostStream/Resources/ru.lproj/Localizable.strings`:

```text
"native.dashboard.standby" = "Ожидание";
"native.dashboard.protected" = "Защищено";
"native.dashboard.connecting" = "Подключение";
"native.dashboard.disconnecting" = "Отключение";
"native.dashboard.failed" = "Ошибка подключения";
"native.dashboard.add.profile" = "Добавьте профиль для запуска VPN";
"native.dashboard.direct" = "Напрямую";
"native.dashboard.relay" = "Relay";
"native.profile.server.control" = "Управление сервером";
"native.profile.server.control.subtitle" = "Админ-действия только для этого сервера";
"native.profile.create.client.link" = "Создать ссылку клиента";
"native.profile.identity" = "Идентичность";
"native.profile.subscription" = "Подписка";
"native.profile.set.active" = "Сделать активным";
"native.profile.edit.endpoint" = "Редактировать endpoint";
"native.profile.share.device" = "Передать на устройство";
"native.logs.search" = "Поиск логов";
"native.logs.clear.confirm.title" = "Очистить локальные логи?";
"native.logs.clear.confirm.message" = "Будут удалены только кэшированные логи на этом iPhone.";
```

- [ ] **Step 2: Add English strings**

Append to `apps/ios/GhostStream/Resources/en.lproj/Localizable.strings`:

```text
"native.dashboard.standby" = "Standby";
"native.dashboard.protected" = "Protected";
"native.dashboard.connecting" = "Connecting";
"native.dashboard.disconnecting" = "Disconnecting";
"native.dashboard.failed" = "Connection failed";
"native.dashboard.add.profile" = "Add a profile to start VPN";
"native.dashboard.direct" = "Direct";
"native.dashboard.relay" = "Relay";
"native.profile.server.control" = "Server control";
"native.profile.server.control.subtitle" = "Admin actions for this server only";
"native.profile.create.client.link" = "Create client link";
"native.profile.identity" = "Identity";
"native.profile.subscription" = "Subscription";
"native.profile.set.active" = "Set active";
"native.profile.edit.endpoint" = "Edit endpoint";
"native.profile.share.device" = "Share to device";
"native.logs.search" = "Search logs";
"native.logs.clear.confirm.title" = "Clear local logs?";
"native.logs.clear.confirm.message" = "This clears cached logs on this iPhone only.";
```

- [ ] **Step 3: Replace hard-coded user-visible strings in new Swift files**

Use this pattern in Swift:

```swift
private func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}
```

Replace the strings introduced in Tasks 4-8 with concrete `L("native.dashboard.standby")` style keys. Keep internal debug report keys as plain English when they are file keys like `version=`.

- [ ] **Step 4: Build**

Run:

```bash
cd /Users/p.kurkin/Documents/phantom-vpn
xcodebuild -project apps/ios/GhostStream.xcodeproj -scheme GhostStream -destination 'platform=iOS Simulator,name=iPhone 16 Pro Max' DEVELOPMENT_TEAM=UPG896A272 build
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

Run:

```bash
cd /Users/p.kurkin/Documents/phantom-vpn
git add apps/ios/GhostStream/Resources/ru.lproj/Localizable.strings apps/ios/GhostStream/Resources/en.lproj/Localizable.strings apps/ios/GhostStream/UI
git commit -m "NO-TICKET: localize native iOS UI strings"
```

---

## Task 10: Real Device QA And Final Scope Check

**Files:**
- No source edits expected.
- If QA finds issues, edit only the relevant iOS files and repeat the task-specific tests.

- [ ] **Step 1: Run all iOS unit tests**

Run:

```bash
cd /Users/p.kurkin/Documents/phantom-vpn/apps/ios
xcodebuild test -project GhostStream.xcodeproj -scheme GhostStreamTests -destination 'platform=iOS Simulator,name=iPhone 16 Pro Max' DEVELOPMENT_TEAM=UPG896A272
```

Expected: all tests PASS.

- [ ] **Step 2: Build for connected iPhone 16 Pro Max**

Run:

```bash
cd /Users/p.kurkin/Documents/phantom-vpn
xcodebuild -project apps/ios/GhostStream.xcodeproj -scheme GhostStream -destination 'platform=iOS,id=00008140-001155D011BB001C' DEVELOPMENT_TEAM=UPG896A272 -allowProvisioningUpdates build
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Install and launch**

Run from Xcode Devices, or use the existing local iOS install flow if available in the active MCP/tooling session. Confirm that GhostStream opens on the connected iPhone.

- [ ] **Step 4: Manual QA checklist**

Check these exact flows on device:

- Stream tab opens with native tab bar and no Android glyph bottom capsule.
- Connect with no profile shows a warning and does not fake connected state.
- Connect with valid profile changes button/status immediately.
- Stop while connecting or connected returns UI to Standby after system status reconciliation.
- Logs tab supports level chips, search, Share, and Clear confirmation.
- Settings tab shows buyer profiles with no Admin affordance when `cachedIsAdmin != true`.
- Settings profile detail for user profile does not show Server control.
- Settings profile detail for admin profile shows Server control.
- Admin screen opens only from admin profile detail and shows the selected profile name.
- Back from Admin returns to that profile/settings flow.
- DNS, split tunnel, add profile, QR scanner, delete profile, debug export, theme, and language use native sheets/confirmation UI.
- Light and dark modes do not clip text on iPhone 16 Pro Max.

- [ ] **Step 5: Run GitNexus staged change detection before final commit**

Run:

```text
gitnexus_detect_changes({scope: "staged", repo: "phantom-vpn"})
```

Expected: only iOS UI symbols and iOS test files are changed. If macOS, Android, Rust, or server files appear, unstage them and inspect before proceeding.

- [ ] **Step 6: Final commit**

Run:

```bash
cd /Users/p.kurkin/Documents/phantom-vpn
git add apps/ios/GhostStream apps/ios/GhostStreamTests apps/ios/project.yml apps/ios/GhostStream.xcodeproj
git commit -m "NO-TICKET: implement native iOS UI"
npx gitnexus analyze
```

Expected: commit succeeds and GitNexus reports repository indexed successfully.

---

## Self-Review

**Spec coverage:**  
The plan maps every design requirement from `docs/ios-native-design-audit.html` to implementation tasks: native tabs, full profile flow, profile-scoped Admin, buyer no-admin state, Stream, Logs, Settings, Admin, sheets, confirmations, controls, localization, and real-device QA.

**Placeholder scan:**  
No task uses forbidden placeholder wording or vague error-handling instructions. Every code-changing step includes concrete code or exact replacement snippets.

**Type consistency:**  
The plan defines `DashboardPresentation`, `LogsPresentation`, `ProfilePresentation`, `DashboardTone`, `ProfileActionKind`, and `NativeIOSPrimitives` before any later task references them. Test names and symbols match the implementation snippets.
