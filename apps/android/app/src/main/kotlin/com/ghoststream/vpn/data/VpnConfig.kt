package com.ghoststream.vpn.data

data class VpnConfig(
    val serverAddr: String = "",
    val serverName: String = "",
    val insecure: Boolean = false,
    val certPath: String = "",
    val keyPath: String = "",
    val tunAddr: String = "10.7.0.2/24",
    val dnsServers: List<String> = listOf("8.8.8.8", "1.1.1.1"),
    val splitRouting: Boolean = false,
    val directCountries: List<String> = emptyList(),
    val perAppMode: String = "none",       // "none", "allowed", "disallowed"
    val perAppList: List<String> = emptyList(),
    /**
     * v0.27.0 (W10): experimental DPI shaping evasion. Periodically tear down
     * + re-handshake the tunnel before any individual TCP connection
     * accumulates the ~25 packets / ~16 KB of payload that triggers the
     * net4people #490 silent-freeze rule on Russian carrier DPI. Recommended
     * value when enabled is 15 seconds. `null` or `0` disables. Default off
     * — user opts in from Settings → Эксперимент: обход DPI шейпинга.
     */
    val dpiRecycleSecs: Int? = null,
)

data class VpnStats(
    val bytesRx: Long = 0,
    val bytesTx: Long = 0,
    val pktsRx: Long = 0,
    val pktsTx: Long = 0,
    val connected: Boolean = false,
    val elapsedSecs: Long = 0,
)
