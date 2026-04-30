//
//  BundleExport.swift
//  PhantomUI
//
//  Re-exports the SwiftPM-generated `Bundle.module` so platform-specific
//  hosts (e.g. macOS app target) can register the bundled fonts via
//  CoreText. On iOS, fonts are loaded automatically via Info.plist
//  `UIAppFonts`; on macOS that key is ignored, so call
//  `PhantomUIResources.registerFonts()` once at app launch.
//

import CoreText
import Foundation
import os.log

public enum PhantomUIResources {

    /// SwiftPM-generated bundle that contains the font files in
    /// `Sources/PhantomUI/Resources/Fonts/`.
    public static var bundle: Bundle { .module }

    /// Register every bundled TTF/OTF with the CoreText font manager so
    /// `Font.custom("DepartureMono-Regular", size: 11)` resolves correctly
    /// on macOS hosts that don't read `UIAppFonts`.
    public static func registerFonts() {
        let log = Logger(subsystem: "com.ghoststream.vpn.PhantomUI", category: "fonts")
        let fontDirectory = bundle.url(forResource: "Fonts", withExtension: nil) ?? bundle.bundleURL
        let extensions = ["ttf", "otf"]

        var urls: [URL] = []
        for ext in extensions {
            if let list = bundle.urls(forResourcesWithExtension: ext, subdirectory: "Fonts") {
                urls.append(contentsOf: list)
            } else if let list = bundle.urls(forResourcesWithExtension: ext, subdirectory: nil) {
                urls.append(contentsOf: list)
            }
        }

        if urls.isEmpty {
            log.error("PhantomUIResources: no font files found in \(fontDirectory.path, privacy: .public)")
            return
        }

        for url in urls {
            var error: Unmanaged<CFError>?
            let ok = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
            if !ok {
                let cfErr = error?.takeRetainedValue()
                let desc = cfErr.map { CFErrorCopyDescription($0) as String } ?? "unknown"
                log.error("CTFontManagerRegisterFontsForURL failed for \(url.lastPathComponent, privacy: .public): \(desc, privacy: .public)")
            }
        }
    }
}
