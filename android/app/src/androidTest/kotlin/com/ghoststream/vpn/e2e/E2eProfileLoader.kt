package com.ghoststream.vpn.e2e

import android.content.Context
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.Base64
import java.util.UUID

data class E2eProfile(
    val id: String,
    val name: String,
    val serverAddr: String,
    val serverName: String,
    val tunAddr: String,
    val adminUrl: String?,
    val adminToken: String?,
)

object E2eProfileLoader {
    private const val ARG_PROFILE_B64 = "e2e_profile_b64"

    fun seedFromInstrumentationArgs(context: Context): E2eProfile {
        val args = InstrumentationRegistry.getArguments()
        val profileB64 = args.getString(ARG_PROFILE_B64)
            ?: error(
                "Missing instrumentation arg '$ARG_PROFILE_B64'. " +
                    "Run via script with android/local-test-profile.json."
            )

        val profileJson = runCatching {
            val decoded = Base64.getDecoder().decode(profileB64)
            String(decoded, Charsets.UTF_8)
        }.getOrElse {
            error("Invalid base64 in '$ARG_PROFILE_B64': ${it.message}")
        }
        val root = runCatching { JSONObject(profileJson) }.getOrElse {
            error("Invalid JSON in profile arg: ${it.message}")
        }

        val id = UUID.randomUUID().toString()
        val profileDir = File(context.filesDir, "profiles/$id").also { it.mkdirs() }
        val certFile = File(profileDir, "client.crt")
        val keyFile = File(profileDir, "client.key")
        val caFile = File(profileDir, "ca.crt")

        val cert = root.optString("cert")
        val key = root.optString("key")
        if (cert.isBlank() || key.isBlank()) {
            error("Profile JSON must contain non-empty 'cert' and 'key'")
        }
        certFile.writeText(cert)
        keyFile.writeText(key)
        val ca = root.optString("ca").takeIf { it.isNotBlank() }
        val caPath = if (ca != null) {
            caFile.writeText(ca)
            caFile.absolutePath
        } else null

        val admin = root.optJSONObject("admin")
        val adminUrl = admin?.optString("url")?.takeIf { it.isNotBlank() }
        val adminToken = admin?.optString("token")?.takeIf { it.isNotBlank() }

        val profile = JSONObject().apply {
            put("id", id)
            put("name", root.optString("name", "E2E Profile"))
            put("serverAddr", root.optString("addr"))
            put("serverName", root.optString("sni", root.optString("addr").substringBefore(":")))
            put("insecure", root.optBoolean("insecure", false))
            put("certPath", certFile.absolutePath)
            put("keyPath", keyFile.absolutePath)
            if (caPath != null) put("caCertPath", caPath)
            put("tunAddr", root.optString("tun", "10.7.0.2/24"))
            if (adminUrl != null) put("adminUrl", adminUrl)
            if (adminToken != null) put("adminToken", adminToken)
        }

        val store = JSONObject().apply {
            put("profiles", JSONArray().put(profile))
            put("activeId", id)
        }
        File(context.filesDir, "profiles.json").writeText(store.toString(2))

        return E2eProfile(
            id = id,
            name = profile.optString("name"),
            serverAddr = profile.optString("serverAddr"),
            serverName = profile.optString("serverName"),
            tunAddr = profile.optString("tunAddr"),
            adminUrl = adminUrl,
            adminToken = adminToken,
        )
    }

    fun seedFromInstrumentationArgsOrNull(context: Context): E2eProfile? {
        return runCatching { seedFromInstrumentationArgs(context) }.getOrNull()
    }

    fun resetProfilesStoreSingleton() {
        runCatching {
            val clazz = Class.forName("com.ghoststream.vpn.data.ProfilesStore")
            val field = clazz.getDeclaredField("INSTANCE")
            field.isAccessible = true
            field.set(null, null)
        }
    }
}
