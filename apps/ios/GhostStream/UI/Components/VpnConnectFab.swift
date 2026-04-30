//
//  VpnConnectFab.swift
//  GhostStream (iOS)
//
//  Convenience wrapper around `GhostFab` that maps a `VpnState` enum to
//  label / colour / action. iOS-specific because `VpnState` lives in the
//  app target (with associated values like `since:Date`, `serverName:`).
//

import PhantomUI
import SwiftUI

/// Convenience: builds a `GhostFab` from a `VpnState` that performs the
/// correct action (start when disconnected, stop otherwise).
struct VpnConnectFab: View {

    let state: VpnState
    let onStart: () -> Void
    let onStop:  () -> Void

    @Environment(\.gsColors) private var C

    var body: some View {
        let (label, outline, tint) = decoration(for: state, C: C)
        GhostFab(text: label, outline: outline, tint: tint) {
            switch state {
            case .disconnected, .error:
                onStart()
            case .connecting, .connected, .disconnecting:
                onStop()
            }
        }
    }

    private func decoration(
        for state: VpnState,
        C: GsColorSet
    ) -> (String, Bool, Color) {
        switch state {
        case .disconnected:  return ("CONNECT",        true,  C.signal)
        case .connecting:    return ("CONNECTING…",    false, C.warn)
        case .connected:     return ("DISCONNECT",     false, C.signal)
        case .disconnecting: return ("DISCONNECTING…", false, C.warn)
        case .error:         return ("RETRY",          true,  C.danger)
        }
    }
}
