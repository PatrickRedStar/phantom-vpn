package com.ghoststream.vpn.data

import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map

private val Context.dataStore: DataStore<Preferences> by preferencesDataStore(name = "ghoststream_prefs")

class PreferencesStore(private val context: Context) {

    companion object {
        private val SERVER_ADDR = stringPreferencesKey("server_addr")
        private val SERVER_NAME = stringPreferencesKey("server_name")
        private val INSECURE    = booleanPreferencesKey("insecure")
        private val CERT_PATH   = stringPreferencesKey("cert_path")
        private val KEY_PATH    = stringPreferencesKey("key_path")
        private val CA_CERT_PATH = stringPreferencesKey("ca_cert_path")
        private val TUN_ADDR    = stringPreferencesKey("tun_addr")
        private val DNS_SERVERS = stringPreferencesKey("dns_servers")
        private val THEME             = stringPreferencesKey("theme")
        private val SPLIT_ROUTING     = booleanPreferencesKey("split_routing")
        private val DIRECT_COUNTRIES  = stringPreferencesKey("direct_countries")
        private val PER_APP_MODE      = stringPreferencesKey("per_app_mode")
        private val PER_APP_LIST      = stringPreferencesKey("per_app_list")
    }

    val config: Flow<VpnConfig> = context.dataStore.data.map { prefs ->
        VpnConfig(
            serverAddr = prefs[SERVER_ADDR] ?: "",
            serverName = prefs[SERVER_NAME] ?: "",
            insecure   = prefs[INSECURE] ?: false,
            certPath   = prefs[CERT_PATH] ?: "",
            keyPath    = prefs[KEY_PATH] ?: "",
            caCertPath = prefs[CA_CERT_PATH],
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
            if (config.caCertPath != null) {
                prefs[CA_CERT_PATH] = config.caCertPath
            }
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
}
