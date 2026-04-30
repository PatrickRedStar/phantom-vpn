//
//  main.swift
//  GhostStream PacketTunnelExtension (macOS system extension)
//
//  System extensions on macOS are executable bundles, so they need an
//  explicit `_main`. NetworkExtension's PacketTunnelProvider takeover
//  is dispatched via NEProvider.startSystemExtensionMode(), which the
//  framework hands off to our PacketTunnelProvider subclass declared in
//  Info.plist (NetworkExtension > NEProviderClasses).
//

import Foundation
import NetworkExtension

NEProvider.startSystemExtensionMode()

// Block forever — startSystemExtensionMode never returns.
dispatchMain()
