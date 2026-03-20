package com.phantom.vpn

import android.content.Intent
import android.net.VpnService
import android.os.Bundle
import android.util.Base64
import android.widget.Button
import android.widget.CheckBox
import android.widget.EditText
import android.widget.TextView
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import org.json.JSONObject
import java.io.File

class MainActivity : AppCompatActivity() {

    private lateinit var etConnStr:    EditText
    private lateinit var etServerAddr: EditText
    private lateinit var etServerName: EditText
    private lateinit var cbInsecure:   CheckBox
    private lateinit var etCertPath:   EditText
    private lateinit var etKeyPath:    EditText
    private lateinit var tvStatus:     TextView

    private val vpnPermissionLauncher = registerForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) { result ->
        if (result.resultCode == RESULT_OK) startVpn()
        else tvStatus.text = "VPN permission denied"
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        etConnStr    = findViewById(R.id.et_conn_str)
        etServerAddr = findViewById(R.id.et_server_addr)
        etServerName = findViewById(R.id.et_server_name)
        cbInsecure   = findViewById(R.id.cb_insecure)
        etCertPath   = findViewById(R.id.et_cert_path)
        etKeyPath    = findViewById(R.id.et_key_path)
        tvStatus     = findViewById(R.id.tv_status)

        val prefs = getSharedPreferences("phantom", MODE_PRIVATE)
        etServerAddr.setText(prefs.getString("server_addr", "89.110.109.128:8443"))
        etServerName.setText(prefs.getString("server_name", "nl2.bikini-bottom.com"))
        cbInsecure.isChecked = prefs.getBoolean("insecure", false)
        etCertPath.setText(prefs.getString("cert_path", ""))
        etKeyPath.setText(prefs.getString("key_path",   ""))

        tvStatus.text = "Не подключено"

        findViewById<Button>(R.id.btn_import).setOnClickListener {
            importConnStr()
        }
        findViewById<Button>(R.id.btn_connect).setOnClickListener {
            savePrefs()
            val permIntent = VpnService.prepare(this)
            if (permIntent != null) vpnPermissionLauncher.launch(permIntent)
            else startVpn()
        }
        findViewById<Button>(R.id.btn_disconnect).setOnClickListener {
            stopVpn()
        }
    }

    // ── Импорт строки подключения ─────────────────────────────────────────────

    private fun importConnStr() {
        val raw = etConnStr.text.toString().trim()
        if (raw.isEmpty()) {
            tvStatus.text = "Вставьте строку подключения в поле выше"
            return
        }
        try {
            // base64url без паддинга → добавляем =
            val padded = raw + "=".repeat((4 - raw.length % 4) % 4)
            val bytes  = Base64.decode(padded, Base64.URL_SAFE or Base64.NO_WRAP)
            val obj    = JSONObject(String(bytes, Charsets.UTF_8))

            val addr = obj.getString("addr")
            val sni  = obj.getString("sni")
            val tun  = obj.getString("tun")
            val cert = obj.getString("cert")
            val key  = obj.getString("key")

            // Сохраняем cert/key во внутреннее хранилище (не требует разрешений)
            val certFile = File(filesDir, "client.crt")
            val keyFile  = File(filesDir, "client.key")
            certFile.writeText(cert)
            keyFile.writeText(key)

            // Заполняем поля
            etServerAddr.setText(addr)
            etServerName.setText(sni)
            etCertPath.setText(certFile.absolutePath)
            etKeyPath.setText(keyFile.absolutePath)
            cbInsecure.isChecked = false

            // Сохраняем tun_addr отдельно (нет UI-поля, передаётся в сервис)
            getSharedPreferences("phantom", MODE_PRIVATE).edit()
                .putString("tun_addr", tun)
                .apply()

            savePrefs()
            etConnStr.text.clear()
            tvStatus.text = "Импортировано  ·  $addr  ·  tun $tun"
        } catch (e: Exception) {
            tvStatus.text = "Ошибка импорта: ${e.message}"
        }
    }

    // ── Сохранение настроек ───────────────────────────────────────────────────

    private fun savePrefs() {
        getSharedPreferences("phantom", MODE_PRIVATE).edit()
            .putString("server_addr", etServerAddr.text.toString())
            .putString("server_name", etServerName.text.toString())
            .putBoolean("insecure",   cbInsecure.isChecked)
            .putString("cert_path",   etCertPath.text.toString())
            .putString("key_path",    etKeyPath.text.toString())
            .apply()
    }

    // ── VPN управление ────────────────────────────────────────────────────────

    private fun startVpn() {
        val serverAddr = etServerAddr.text.toString().trim()
        if (serverAddr.isEmpty()) { tvStatus.text = "Введите адрес сервера"; return }

        val prefs   = getSharedPreferences("phantom", MODE_PRIVATE)
        val tunAddr = prefs.getString("tun_addr", "10.7.0.2/24") ?: "10.7.0.2/24"

        val intent = Intent(this, PhantomVpnService::class.java).apply {
            action = PhantomVpnService.ACTION_START
            putExtra(PhantomVpnService.EXTRA_SERVER_ADDR, serverAddr)
            putExtra(PhantomVpnService.EXTRA_SERVER_NAME, etServerName.text.toString().trim()
                .ifBlank { serverAddr.substringBefore(":") })
            putExtra(PhantomVpnService.EXTRA_INSECURE,  cbInsecure.isChecked)
            putExtra(PhantomVpnService.EXTRA_CERT_PATH, etCertPath.text.toString().trim())
            putExtra(PhantomVpnService.EXTRA_KEY_PATH,  etKeyPath.text.toString().trim())
            putExtra(PhantomVpnService.EXTRA_TUN_ADDR,  tunAddr)
        }
        startForegroundService(intent)
        tvStatus.text = "Подключение к $serverAddr…"
    }

    private fun stopVpn() {
        startService(Intent(this, PhantomVpnService::class.java).apply {
            action = PhantomVpnService.ACTION_STOP
        })
        tvStatus.text = "Не подключено"
    }
}
