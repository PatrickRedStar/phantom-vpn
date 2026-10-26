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
        maybeImportDebugProfiles()
        load()
    }

    /**
     * TEST SCAFFOLDING (debug builds only): if no profile exists yet, seed
     * profiles.json from /data/local/tmp/gs_profiles.json. That dir is
     * shell-writable AND app-readable and survives reinstalls, so a clean
     * `ship-android` install auto-provisions the test profile without needing
     * run-as write access (blocked by Samsung Knox). No-op in release.
     */
    private fun maybeImportDebugProfiles() {
        if (!com.ghoststream.vpn.BuildConfig.DEBUG) return
        if (file.exists()) return
        runCatching {
            val src = File("/data/local/tmp/gs_profiles.json")
            if (src.exists()) {
                file.writeText(src.readText())
                android.util.Log.i("ProfilesStore", "debug: seeded profiles from ${src.path}")
            }
        }
    }

    fun getActiveProfile(): VpnProfile? =
        _profiles.value.find { it.id == _activeId.value } ?: _profiles.value.firstOrNull()

    fun addProfile(profile: VpnProfile) {
        val p = withoutInlineKey(profile)
        _profiles.value = _profiles.value + p
        if (_activeId.value == null) _activeId.value = p.id
        save()
    }

    fun updateProfile(profile: VpnProfile) {
        val p = withoutInlineKey(profile)
        _profiles.value = _profiles.value.map { if (it.id == p.id) p else it }
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
        serverAddr: String, serverName: String,
        certPath: String, keyPath: String, tunAddr: String,
    ) {
        if (file.exists()) return // already migrated
        if (serverAddr.isBlank()) return
        addProfile(
            VpnProfile(
                name = "Подключение",
                serverAddr = serverAddr,
                serverName = serverName,
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
                    // Legacy "insecure" key (if present in an old profiles.json)
                    // is intentionally ignored — server TLS is now always
                    // verified via webpki on the Rust side.
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
                    relayEnabled = p.optBoolean("relayEnabled", false),
                    relayAddr = p.optString("relayAddr").takeIf { it.isNotBlank() },
                )
            }
            _activeId.value = obj.optString("activeId").takeIf { it.isNotBlank() }

            // Auto-migrate: the (public) cert is kept inline as well; the private
            // key the other way round — older versions kept it inline too, now
            // it lives in its file only.
            var migrated = false
            _profiles.value = _profiles.value.map { profile ->
                var p = profile
                if (p.certPem == null && p.certPath.isNotBlank()) {
                    val certFile = File(p.certPath)
                    if (certFile.exists()) p = p.copy(certPem = certFile.readText())
                }
                p = withoutInlineKey(p)
                if (p != profile) migrated = true
                p
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

        val updated = writeCertFiles(profile) ?: return null
        updateProfile(updated)
        return updated.copy(keyPem = null)
    }

    /** Writes inline PEM to profiles/<id>/; null when there is nothing to write. */
    private fun writeCertFiles(profile: VpnProfile): VpnProfile? {
        val certPem = profile.certPem ?: return null
        val keyPem = profile.keyPem ?: return null

        val profileDir = File(context.filesDir, "profiles/${profile.id}")
        profileDir.mkdirs()
        val newCert = File(profileDir, "client.crt")
        val newKey = File(profileDir, "client.key")
        newCert.writeText(certPem)
        newKey.writeText(keyPem)

        return profile.copy(
            certPath = newCert.absolutePath,
            keyPath = newKey.absolutePath,
        )
    }

    /**
     * One copy of the private key: the file in profiles/<id>/. Inline keyPem
     * (import, older profiles.json) is written there and dropped; if it can't
     * be written the profile is kept as is rather than lose the key.
     */
    private fun withoutInlineKey(profile: VpnProfile): VpnProfile {
        if (profile.keyPem == null) return profile
        return runCatching { writeCertFiles(profile) }.getOrNull()?.copy(keyPem = null) ?: profile
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
                    put("certPath", p.certPath)
                    put("keyPath", p.keyPath)
                    if (p.certPem != null) put("certPem", p.certPem)
                    // The key is never written here — see withoutInlineKey(). A
                    // profile whose key file couldn't be written keeps it inline.
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
                    put("relayEnabled", p.relayEnabled)
                    if (p.relayAddr != null) put("relayAddr", p.relayAddr)
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
