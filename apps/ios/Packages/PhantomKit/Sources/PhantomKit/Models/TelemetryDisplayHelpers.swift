import Foundation

/// Pure helpers used by macOS / iOS dashboards to project a `StatusFrame`
/// onto display widgets. Extracted so they can be unit-tested without
/// pulling in SwiftUI.
public enum TelemetryDisplayHelpers {

    /// Number of stream-activity bars to render given `nStreams` reported by
    /// the runtime. Clamps to the [1, 16] range expected by the UI:
    /// the runtime always emits a `streamActivity` array of length 16, and
    /// at least one bar is shown so the widget never collapses to nothing.
    public static func barCountFromStreams(_ nStreams: UInt8) -> Int {
        let raw = Int(nStreams)
        if raw < 1 { return 1 }
        if raw > 16 { return 16 }
        return raw
    }

    /// Convert a bits-per-second rate (the wire contract of
    /// `StatusFrame.rate_rx_bps` / `rate_tx_bps`) into bytes/sec for UI
    /// stores that work in bytes (graph stores, KB/MB labels).
    /// Returns 0 for non-finite or negative inputs.
    public static func bytesPerSecondFromBitsPerSecond(_ bps: Double) -> Double {
        guard bps.isFinite, bps > 0 else { return 0 }
        return bps / 8.0
    }
}

/// Display-formatted app version pulled from the host bundle's `Info.plist`.
/// Falls back to "?" if the key is missing — never returns a hardcoded
/// constant, so the UI always tracks the actual installed build.
public enum AppVersion {

    /// e.g. `"v0.23.3"`. Reads `CFBundleShortVersionString` from `Bundle.main`.
    public static var short: String {
        "v" + (rawShort ?? "?")
    }

    /// e.g. `"v0.23.3 (13)"`. Combines `CFBundleShortVersionString` and
    /// `CFBundleVersion`.
    public static var shortWithBuild: String {
        let s = rawShort ?? "?"
        let b = rawBuild ?? "?"
        return "v\(s) (\(b))"
    }

    private static var rawShort: String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    private static var rawBuild: String? {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String
    }
}
