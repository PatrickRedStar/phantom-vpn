package com.ghoststream.vpn.data

data class VpnConfig(
    val serverAddr: String = "",
    val serverName: String = "",
    val certPath: String = "",
    val keyPath: String = "",
    val tunAddr: String = "10.7.0.2/24",
    val dnsServers: List<String> = listOf("8.8.8.8", "1.1.1.1"),
    val splitRouting: Boolean = false,
    val directCountries: List<String> = emptyList(),
    val perAppMode: String = "none",       // "none", "allowed", "disallowed"
    val perAppList: List<String> = emptyList(),
    /**
     * v0.27.0 (W11): experimental DPI shaping evasion. Tear down +
     * re-handshake the tunnel once the cumulative `bytes_rx + bytes_tx`
     * crosses this byte cap. Recommended ~100_000 (100 KB). `null` or
     * `0` disables. Default off — user opts in via Settings →
     * "Эксперимент: обход DPI шейпинга". Byte-based instead of time-based
     * so an idle tunnel doesn't get pointlessly recycled.
     */
    val dpiRecycleBytes: Long? = null,
)

data class VpnStats(
    val bytesRx: Long = 0,
    val bytesTx: Long = 0,
    val pktsRx: Long = 0,
    val pktsTx: Long = 0,
    val connected: Boolean = false,
    val elapsedSecs: Long = 0,
)
