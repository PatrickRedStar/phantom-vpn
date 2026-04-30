//
//  FontRegistration.swift
//  GhostStream (macOS)
//
//  On macOS the iOS-only `UIAppFonts` Info.plist key is ignored, so we
//  must register the bundled TTF/OTF files programmatically. PhantomUI
//  ships an internal helper `PhantomUIResources.registerFonts()` that
//  iterates over the SwiftPM-generated bundle and calls
//  `CTFontManagerRegisterFontsForURL` for each file.
//

import Foundation
import PhantomUI

enum FontRegistration {

    /// Registers all PhantomUI-bundled fonts with the process-scoped
    /// CoreText font manager. Call once at launch (e.g. from
    /// `AppDelegate.applicationDidFinishLaunching`).
    @MainActor
    static func register() {
        PhantomUIResources.registerFonts()
    }
}
