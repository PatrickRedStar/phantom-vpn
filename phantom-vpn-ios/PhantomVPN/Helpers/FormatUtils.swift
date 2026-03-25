import Foundation

enum FormatUtils {
    static func formatBytes(_ bytes: UInt64) -> String {
        switch bytes {
        case 0..<1_024:
            return "\(bytes) B"
        case 1_024..<1_048_576:
            return String(format: "%.1f KB", Double(bytes) / 1_024.0)
        case 1_048_576..<1_073_741_824:
            return String(format: "%.1f MB", Double(bytes) / 1_048_576.0)
        default:
            return String(format: "%.2f GB", Double(bytes) / 1_073_741_824.0)
        }
    }

    static func formatDuration(seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
}
