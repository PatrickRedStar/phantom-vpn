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
)

data class VpnStats(
    val bytesRx: Long = 0,
    val bytesTx: Long = 0,
    val pktsRx: Long = 0,
    val pktsTx: Long = 0,
    val connected: Boolean = false,
    val elapsedSecs: Long = 0,
)
