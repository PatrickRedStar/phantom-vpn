package com.phantom.vpn

import android.content.Intent
import android.net.VpnService
import android.os.Bundle
import android.widget.Button
import android.widget.CheckBox
import android.widget.EditText
import android.widget.TextView
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity

class MainActivity : AppCompatActivity() {

    private lateinit var etServerAddr: EditText
    private lateinit var etServerName: EditText
    private lateinit var cbInsecure:   CheckBox
    private lateinit var tvStatus:     TextView

    private val vpnPermissionLauncher = registerForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) { result ->
        if (result.resultCode == RESULT_OK) {
            startVpn()
        } else {
            tvStatus.text = "VPN permission denied"
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        etServerAddr = findViewById(R.id.et_server_addr)
        etServerName = findViewById(R.id.et_server_name)
        cbInsecure   = findViewById(R.id.cb_insecure)
        tvStatus     = findViewById(R.id.tv_status)

        // Restore saved settings
        val prefs = getSharedPreferences("phantom", MODE_PRIVATE)
        etServerAddr.setText(prefs.getString("server_addr", "89.110.109.128:8443"))
        etServerName.setText(prefs.getString("server_name", ""))
        cbInsecure.isChecked = prefs.getBoolean("insecure", true)

        findViewById<Button>(R.id.btn_connect).setOnClickListener {
            savePrefs()
            val permIntent = VpnService.prepare(this)
            if (permIntent != null) {
                vpnPermissionLauncher.launch(permIntent)
            } else {
                startVpn()
            }
        }

        findViewById<Button>(R.id.btn_disconnect).setOnClickListener {
            stopVpn()
        }
    }

    private fun savePrefs() {
        getSharedPreferences("phantom", MODE_PRIVATE).edit()
            .putString("server_addr", etServerAddr.text.toString())
            .putString("server_name", etServerName.text.toString())
            .putBoolean("insecure",   cbInsecure.isChecked)
            .apply()
    }

    private fun startVpn() {
        val serverAddr = etServerAddr.text.toString().trim()
        if (serverAddr.isEmpty()) {
            tvStatus.text = "Enter server address"
            return
        }
        val serverName = etServerName.text.toString().trim()
            .ifBlank { serverAddr.substringBefore(":") }
        val insecure = cbInsecure.isChecked

        val intent = Intent(this, PhantomVpnService::class.java).apply {
            action = PhantomVpnService.ACTION_START
            putExtra(PhantomVpnService.EXTRA_SERVER_ADDR, serverAddr)
            putExtra(PhantomVpnService.EXTRA_SERVER_NAME, serverName)
            putExtra(PhantomVpnService.EXTRA_INSECURE,    insecure)
        }
        startForegroundService(intent)
        tvStatus.text = "Connecting to $serverAddr…"
    }

    private fun stopVpn() {
        val intent = Intent(this, PhantomVpnService::class.java).apply {
            action = PhantomVpnService.ACTION_STOP
        }
        startService(intent)
        tvStatus.text = "Disconnected"
    }
}
