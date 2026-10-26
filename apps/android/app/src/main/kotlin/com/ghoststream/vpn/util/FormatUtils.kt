package com.ghoststream.vpn.util

import android.content.Context
import com.ghoststream.vpn.R
import com.ghoststream.vpn.data.VpnProfile

object FormatUtils {

    /**
     * Subscription label from the profile's cached /api/me answer, or null
     * while the server has never told us. Problem states carry "⚠" — callers
     * colour on it. Pass an Activity context so the in-app locale applies.
     */
    fun subscriptionText(ctx: Context, p: VpnProfile): String? {
        val enabled = p.cachedEnabled ?: return null
        if (!enabled) return ctx.getString(R.string.subscr_disabled)
        val exp = p.cachedExpiresAt ?: return ctx.getString(R.string.subscr_perpetual)
        val rem = exp - System.currentTimeMillis() / 1000
        val d = rem / 86400
        val h = (rem % 86400) / 3600
        return when {
            rem <= 0 -> ctx.getString(R.string.subscr_expired)
            d > 0    -> ctx.getString(R.string.subscr_days_hours, d, h)
            h > 0    -> ctx.getString(R.string.subscr_hours, h)
            else     -> ctx.getString(R.string.subscr_less_hour)
        }
    }

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
