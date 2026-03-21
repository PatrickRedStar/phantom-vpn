package com.ghoststream.vpn.data

data class VpnProfile(
    val id: String = java.util.UUID.randomUUID().toString(),
    val name: String = "Подключение",
    val serverAddr: String = "",
    val serverName: String = "",
    val insecure: Boolean = false,
    val certPath: String = "",
    val keyPath: String = "",
    val caCertPath: String? = null,
    val tunAddr: String = "10.7.0.2/24",
)
