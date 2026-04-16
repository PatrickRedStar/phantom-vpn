package com.ghoststream.vpn.data

import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * Singleton store for VPN connection profiles.
 * Backed by a JSON file; exposes reactive StateFlows for Compose.
 */
class ProfilesStore private constructor(private val context: Context) {

    companion object {
        @Volatile private var INSTANCE: ProfilesStore? = null

        fun getInstance(context: Context): ProfilesStore =
            INSTANCE ?: synchronized(this) {
                INSTANCE ?: ProfilesStore(context.applicationContext).also { INSTANCE = it }
            }
    }

    private val file = File(context.filesDir, "profiles.json")

    private val _profiles = MutableStateFlow<List<VpnProfile>>(emptyList())
    val profiles: StateFlow<List<VpnProfile>> = _profiles.asStateFlow()

    private val _activeId = MutableStateFlow<String?>(null)
    val activeId: StateFlow<String?> = _activeId.asStateFlow()

    init {
        load()
    }

    fun getActiveProfile(): VpnProfile? =
        _profiles.value.find { it.id == _activeId.value } ?: _profiles.value.firstOrNull()

    fun addProfile(profile: VpnProfile) {
        _profiles.value = _profiles.value + profile
        if (_activeId.value == null) _activeId.value = profile.id
        save()
    }

    fun updateProfile(profile: VpnProfile) {
        _profiles.value = _profiles.value.map { if (it.id == profile.id) profile else it }
        save()
    }

    fun deleteProfile(id: String) {
        _profiles.value.find { it.id == id }?.also { p ->
            runCatching { File(p.certPath).delete() }
            runCatching { File(p.keyPath).delete() }
            // Remove profile directory if empty
            runCatching { File(context.filesDir, "profiles/$id").deleteRecursively() }
        }
        _profiles.value = _profiles.value.filter { it.id != id }
        if (_activeId.value == id) _activeId.value = _profiles.value.firstOrNull()?.id
        save()
    }

    fun setActiveId(id: String) {
        _activeId.value = id
        save()
    }

    /** Migrate from legacy flat config. Call once if profiles.json doesn't exist. */
    fun migrateFromLegacy(
        serverAddr: String, serverName: String, insecure: Boolean,
        certPath: String, keyPath: String, tunAddr: String,
    ) {
        if (file.exists()) return // already migrated
        if (serverAddr.isBlank()) return
        addProfile(
            VpnProfile(
                name = "Подключение",
                serverAddr = serverAddr,
                serverName = serverName,
                insecure = insecure,
                certPath = certPath,
                keyPath = keyPath,
                tunAddr = tunAddr,
            ),
        )
    }

    private fun load() {
        if (!file.exists()) return
        runCatching {
            val obj = JSONObject(file.readText())
            val arr = obj.getJSONArray("profiles")
            _profiles.value = (0 until arr.length()).map { i ->
                val p = arr.getJSONObject(i)
                VpnProfile(
                    id         = p.getString("id"),
                    name       = p.optString("name", "Подключение"),
                    serverAddr = p.optString("serverAddr", ""),
                    serverName = p.optString("serverName", ""),
                    insecure   = p.optBoolean("insecure", false),
                    certPath   = p.optString("certPath", ""),
                    keyPath    = p.optString("keyPath", ""),
                    certPem    = p.optString("certPem").takeIf { it.isNotBlank() },
                    keyPem     = p.optString("keyPem").takeIf { it.isNotBlank() },
                    tunAddr     = p.optString("tunAddr", "10.7.0.2/24"),
                    dnsServers  = p.optString("dnsServers").takeIf { it.isNotBlank() }
                        ?.split(",")?.filter { it.isNotBlank() },
                    splitRouting    = if (p.has("splitRouting")) p.optBoolean("splitRouting") else null,
                    directCountries = p.optString("directCountries").takeIf { it.isNotBlank() }
                        ?.split(",")?.filter { it.isNotBlank() },
                    perAppMode  = p.optString("perAppMode").takeIf { it.isNotBlank() },
                    perAppList  = p.optString("perAppList").takeIf { it.isNotBlank() }
                        ?.split(",")?.filter { it.isNotBlank() },
                    cachedExpiresAt = p.optLong("cachedExpiresAt", 0).takeIf { it > 0 },
                    cachedEnabled   = if (p.has("cachedEnabled")) p.optBoolean("cachedEnabled") else null,
                    cachedIsAdmin   = if (p.has("cachedIsAdmin")) p.optBoolean("cachedIsAdmin") else null,
                    cachedAdminServerCertFp = p.optString("cachedAdminServerCertFp").takeIf { it.isNotBlank() },
                )
            }
            _activeId.value = obj.optString("activeId").takeIf { it.isNotBlank() }

            // Auto-migrate: read cert/key files into inline PEM if missing
            var migrated = false
            _profiles.value = _profiles.value.map { profile ->
                if (profile.certPem == null && profile.certPath.isNotBlank()) {
                    val certFile = File(profile.certPath)
                    val keyFile = File(profile.keyPath)
                    if (certFile.exists() && keyFile.exists()) {
                        migrated = true
                        profile.copy(
                            certPem = certFile.readText(),
                            keyPem = keyFile.readText(),
                        )
                    } else profile
                } else profile
            }
            if (migrated) save()
        }
    }

    /**
     * Ensure cert/key files exist on disk for the given profile.
     * If files are missing but inline PEM is available, recreate them.
     * Returns updated profile with correct certPath/keyPath, or null on failure.
     */
    fun ensureCertFiles(profile: VpnProfile): VpnProfile? {
        val certFile = File(profile.certPath)
        val keyFile = File(profile.keyPath)
        if (certFile.exists() && keyFile.exists()) return profile

        val certPem = profile.certPem ?: return null
        val keyPem = profile.keyPem ?: return null

        val profileDir = File(context.filesDir, "profiles/${profile.id}")
        profileDir.mkdirs()
        val newCert = File(profileDir, "client.crt")
        val newKey = File(profileDir, "client.key")
        newCert.writeText(certPem)
        newKey.writeText(keyPem)

        val updated = profile.copy(
            certPath = newCert.absolutePath,
            keyPath = newKey.absolutePath,
        )
        updateProfile(updated)
        return updated
    }

    private fun save() {
        runCatching {
            val arr = JSONArray()
            _profiles.value.forEach { p ->
                arr.put(JSONObject().apply {
                    put("id", p.id)
                    put("name", p.name)
                    put("serverAddr", p.serverAddr)
                    put("serverName", p.serverName)
                    put("insecure", p.insecure)
                    put("certPath", p.certPath)
                    put("keyPath", p.keyPath)
                    if (p.certPem != null) put("certPem", p.certPem)
                    if (p.keyPem != null) put("keyPem", p.keyPem)
                    put("tunAddr", p.tunAddr)
                    if (p.dnsServers != null) put("dnsServers", p.dnsServers.joinToString(","))
                    if (p.splitRouting != null) put("splitRouting", p.splitRouting)
                    if (p.directCountries != null) put("directCountries", p.directCountries.joinToString(","))
                    if (p.perAppMode != null) put("perAppMode", p.perAppMode)
                    if (p.perAppList != null) put("perAppList", p.perAppList.joinToString(","))
                    if (p.cachedExpiresAt != null) put("cachedExpiresAt", p.cachedExpiresAt)
                    if (p.cachedEnabled != null) put("cachedEnabled", p.cachedEnabled)
                    if (p.cachedIsAdmin != null) put("cachedIsAdmin", p.cachedIsAdmin)
                    if (p.cachedAdminServerCertFp != null) put("cachedAdminServerCertFp", p.cachedAdminServerCertFp)
                })
            }
            file.writeText(
                JSONObject().apply {
                    put("profiles", arr)
                    _activeId.value?.let { put("activeId", it) }
                }.toString(2),
            )
        }.onFailure { e ->
            android.util.Log.e("ProfilesStore", "Failed to save profiles: ${e.message}", e)
        }
    }
}
