//
//  VpnPulseColor.swift
//  GhostStream (iOS)
//
//  Maps `VpnState` (iOS-app-only enum) to the canonical pulse colour used
//  across screens. Lives in the app target — `VpnState` has associated values
//  (since:Date, serverName:) that are not part of PhantomKit's `ConnState`.
//

import PhantomUI
import SwiftUI

@MainActor
func pulseColor(for state: VpnState, colors C: GsColorSet) -> Color {
    switch state {
    case .connected:     return C.signal
    case .connecting,
         .disconnecting: return C.warn
    case .error:         return C.danger
    case .disconnected:  return C.textFaint
    }
}
