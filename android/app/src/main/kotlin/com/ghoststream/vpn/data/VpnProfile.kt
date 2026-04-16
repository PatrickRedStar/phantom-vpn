package com.ghoststream.vpn.data

data class VpnProfile(
    val id: String = java.util.UUID.randomUUID().toString(),
    val name: String = "Подключение",
    val serverAddr: String = "",
    val serverName: String = "",
    val insecure: Boolean = false,
    val certPath: String = "",
    val keyPath: String = "",
    /** Inline PEM — survives app updates, reinstalls, cert file deletion. */
    val certPem: String? = null,
    val keyPem: String? = null,
    val tunAddr: String = "10.7.0.2/24",
    // Per-profile overrides (null = use global defaults)
    val dnsServers: List<String>? = null,
    val splitRouting: Boolean? = null,
    val directCountries: List<String>? = null,
    val perAppMode: String? = null,
    val perAppList: List<String>? = null,
    // Cached subscription data from last admin API fetch
    val cachedExpiresAt: Long? = null,
    val cachedEnabled: Boolean? = null,
    // Cached admin status from /api/me
    val cachedIsAdmin: Boolean? = null,
    // SHA-256 (hex) of the admin-server cert pinned after first mTLS handshake
    val cachedAdminServerCertFp: String? = null,
)
