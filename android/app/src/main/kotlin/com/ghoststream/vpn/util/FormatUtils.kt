package com.ghoststream.vpn.util

object FormatUtils {

    fun formatBytes(bytes: Long): String = when {
        bytes < 1_024L              -> "$bytes B"
        bytes < 1_048_576L          -> "%.1f KB".format(bytes / 1_024.0)
        bytes < 1_073_741_824L      -> "%.1f MB".format(bytes / 1_048_576.0)
        else                        -> "%.2f GB".format(bytes / 1_073_741_824.0)
    }

    fun formatSpeed(bytes: Long, elapsedSecs: Long): String {
        if (elapsedSecs <= 0) return "0 B/s"
        return "${formatBytes(bytes / elapsedSecs)}/s"
    }

    fun formatDuration(seconds: Long): String {
        val h = seconds / 3600
        val m = (seconds % 3600) / 60
        val s = seconds % 60
        return "%02d:%02d:%02d".format(h, m, s)
    }
}
