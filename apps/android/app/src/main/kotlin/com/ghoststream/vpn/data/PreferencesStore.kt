package com.ghoststream.vpn.data

import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map

private val Context.dataStore: DataStore<Preferences> by preferencesDataStore(name = "ghoststream_prefs")

class PreferencesStore(private val context: Context) {

    companion object {
        private val SERVER_ADDR = stringPreferencesKey("server_addr")
        private val SERVER_NAME = stringPreferencesKey("server_name")
        private val INSECURE    = booleanPreferencesKey("insecure")
        private val CERT_PATH   = stringPreferencesKey("cert_path")
        private val KEY_PATH    = stringPreferencesKey("key_path")
        private val TUN_ADDR    = stringPreferencesKey("tun_addr")
        private val DNS_SERVERS = stringPreferencesKey("dns_servers")
        private val THEME             = stringPreferencesKey("theme")
        private val SPLIT_ROUTING     = booleanPreferencesKey("split_routing")
        private val DIRECT_COUNTRIES  = stringPreferencesKey("direct_countries")
        private val PER_APP_MODE      = stringPreferencesKey("per_app_mode")
        private val PER_APP_LIST      = stringPreferencesKey("per_app_list")
        private val AUTO_START_ON_BOOT = booleanPreferencesKey("auto_start_on_boot")
        private val WAS_RUNNING        = booleanPreferencesKey("was_running")
        private val LAST_TUNNEL_PARAMS = stringPreferencesKey("last_tunnel_params")
        private val LANGUAGE_OVERRIDE  = stringPreferencesKey("language_override")
        private val APP_ICON           = stringPreferencesKey("app_icon")
    }

    /** "ru" | "en" | null (follow system) */
    val languageOverride: Flow<String?> = context.dataStore.data.map { prefs ->
        prefs[LANGUAGE_OVERRIDE]?.takeIf { it.isNotBlank() }
    }

    suspend fun setLanguageOverride(code: String?) {
        context.dataStore.edit {
            if (code.isNullOrBlank()) it.remove(LANGUAGE_OVERRIDE) else it[LANGUAGE_OVERRIDE] = code
        }
    }

    val autoStartOnBoot: Flow<Boolean> = context.dataStore.data.map { it[AUTO_START_ON_BOOT] ?: false }

    suspend fun setAutoStartOnBoot(enabled: Boolean) {
        context.dataStore.edit { it[AUTO_START_ON_BOOT] = enabled }
    }

    // "was user-intent: running" — true between user-tapped Connect and user-tapped Disconnect.
    // Used by BootReceiver and by Service after process kill.
    suspend fun setWasRunning(running: Boolean) {
        context.dataStore.edit { it[WAS_RUNNING] = running }
    }
    fun wasRunningBlocking(): Boolean = runCatching {
        kotlinx.coroutines.runBlocking {
            context.dataStore.data.map { it[WAS_RUNNING] ?: false }.first()
        }
    }.getOrDefault(false)

    // Last successful ACTION_START extras as JSON — service re-reads when intent=null.
    suspend fun saveLastTunnelParams(json: String) {
        context.dataStore.edit { it[LAST_TUNNEL_PARAMS] = json }
    }
    fun loadLastTunnelParamsBlocking(): String? = runCatching {
        kotlinx.coroutines.runBlocking {
            context.dataStore.data.map { it[LAST_TUNNEL_PARAMS] }.first()
        }
    }.getOrNull()

    val config: Flow<VpnConfig> = context.dataStore.data.map { prefs ->
        VpnConfig(
            serverAddr = prefs[SERVER_ADDR] ?: "",
            serverName = prefs[SERVER_NAME] ?: "",
            insecure   = prefs[INSECURE] ?: false,
            certPath   = prefs[CERT_PATH] ?: "",
            keyPath    = prefs[KEY_PATH] ?: "",
            tunAddr    = prefs[TUN_ADDR] ?: "10.7.0.2/24",
            dnsServers = (prefs[DNS_SERVERS] ?: "8.8.8.8,1.1.1.1")
                .split(",").filter { it.isNotBlank() },
            splitRouting    = prefs[SPLIT_ROUTING] ?: false,
            directCountries = (prefs[DIRECT_COUNTRIES] ?: "")
                .split(",").filter { it.isNotBlank() },
            perAppMode      = prefs[PER_APP_MODE] ?: "none",
            perAppList      = (prefs[PER_APP_LIST] ?: "")
                .split(",").filter { it.isNotBlank() },
        )
    }

    suspend fun saveConfig(config: VpnConfig) {
        context.dataStore.edit { prefs ->
            prefs[SERVER_ADDR] = config.serverAddr
            prefs[SERVER_NAME] = config.serverName
            prefs[INSECURE]    = config.insecure
            prefs[CERT_PATH]   = config.certPath
            prefs[KEY_PATH]    = config.keyPath
            prefs[TUN_ADDR]    = config.tunAddr
            prefs[DNS_SERVERS]      = config.dnsServers.joinToString(",")
            prefs[SPLIT_ROUTING]    = config.splitRouting
            prefs[DIRECT_COUNTRIES] = config.directCountries.joinToString(",")
            prefs[PER_APP_MODE]     = config.perAppMode
            prefs[PER_APP_LIST]     = config.perAppList.joinToString(",")
        }
    }

    val theme: Flow<String> = context.dataStore.data.map { prefs ->
        prefs[THEME] ?: "system"
    }

    suspend fun setTheme(theme: String) {
        context.dataStore.edit { it[THEME] = theme }
    }

    /** "bone" | "scope" */
    val appIcon: Flow<String> = context.dataStore.data.map { prefs ->
        prefs[APP_ICON] ?: "bone"
    }

    suspend fun setAppIcon(icon: String) {
        context.dataStore.edit { it[APP_ICON] = icon }
    }
}
