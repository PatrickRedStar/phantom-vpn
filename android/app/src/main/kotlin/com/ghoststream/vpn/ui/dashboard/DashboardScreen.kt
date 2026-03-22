package com.ghoststream.vpn.ui.dashboard

import android.app.Activity
import android.net.VpnService
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowDownward
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.filled.SwapVert
import androidx.compose.material.icons.filled.Timer
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.ghoststream.vpn.service.VpnState
import com.ghoststream.vpn.ui.components.ConnectButton
import com.ghoststream.vpn.ui.components.StatCard
import com.ghoststream.vpn.ui.theme.GreenConnected
import com.ghoststream.vpn.ui.theme.RedError
import com.ghoststream.vpn.ui.theme.TextSecondary
import com.ghoststream.vpn.util.FormatUtils

@Composable
fun DashboardScreen(viewModel: DashboardViewModel = viewModel()) {
    val vpnState by viewModel.vpnState.collectAsStateWithLifecycle()
    val stats by viewModel.stats.collectAsStateWithLifecycle()
    val timerText by viewModel.timerText.collectAsStateWithLifecycle()
    val subscriptionText by viewModel.subscriptionText.collectAsStateWithLifecycle()
    val context = LocalContext.current
    val isAndroidTv = remember {
        context.packageManager.hasSystemFeature("android.software.leanback")
    }
    val focusRequester = remember { FocusRequester() }

    val vpnPermLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.StartActivityForResult(),
    ) { if (it.resultCode == Activity.RESULT_OK) viewModel.startVpn() }

    // На TV автоматически фокусируемся на кнопке подключения
    LaunchedEffect(Unit) {
        if (isAndroidTv) runCatching { focusRequester.requestFocus() }
    }

    val hPadding = if (isAndroidTv) 64.dp else 24.dp
    val btnSize = if (isAndroidTv) 160.dp else 122.dp
    val topSpacer = if (isAndroidTv) 64.dp else 48.dp

    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = hPadding, vertical = 24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Spacer(Modifier.height(topSpacer))

        ConnectButton(
            state = vpnState,
            focusRequester = focusRequester,
            modifier = Modifier.size(btnSize + 22.dp),
            onClick = {
                when (vpnState) {
                    is VpnState.Connected, is VpnState.Connecting -> viewModel.stopVpn()
                    else -> {
                        val perm = VpnService.prepare(context)
                        if (perm != null) vpnPermLauncher.launch(perm)
                        else viewModel.startVpn()
                    }
                }
            },
        )

        Spacer(Modifier.height(16.dp))

        Text(
            text = when (vpnState) {
                is VpnState.Disconnected  -> "Отключён"
                is VpnState.Connecting    -> "Подключение..."
                is VpnState.Connected     -> "Подключён"
                is VpnState.Error         -> "Ошибка: ${(vpnState as VpnState.Error).message}"
                is VpnState.Disconnecting -> "Отключение..."
            },
            style = MaterialTheme.typography.titleMedium,
            color = when (vpnState) {
                is VpnState.Connected -> GreenConnected
                is VpnState.Error     -> RedError
                else                  -> MaterialTheme.colorScheme.onSurface
            },
        )

        if (vpnState is VpnState.Connected) {
            Spacer(Modifier.height(8.dp))
            Text(
                text = timerText,
                style = MaterialTheme.typography.headlineLarge.copy(
                    fontFamily = FontFamily.Monospace,
                    fontWeight = FontWeight.Light,
                ),
                color = MaterialTheme.colorScheme.onSurface,
            )
            Spacer(Modifier.height(4.dp))
            Text(
                text = (vpnState as VpnState.Connected).serverName,
                style = MaterialTheme.typography.bodySmall,
                color = TextSecondary,
            )
            if (subscriptionText != null) {
                Spacer(Modifier.height(2.dp))
                Text(
                    text = subscriptionText!!,
                    style = MaterialTheme.typography.bodySmall,
                    color = if (subscriptionText!!.contains("⚠")) RedError else TextSecondary,
                )
            }
        }

        Spacer(Modifier.height(32.dp))

        if (vpnState is VpnState.Connected) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                StatCard(
                    icon = Icons.Filled.ArrowDownward,
                    label = "Download",
                    value = FormatUtils.formatSpeed(stats.bytesRx, stats.elapsedSecs),
                    subValue = FormatUtils.formatBytes(stats.bytesRx),
                    modifier = Modifier.weight(1f),
                )
                StatCard(
                    icon = Icons.Filled.ArrowUpward,
                    label = "Upload",
                    value = FormatUtils.formatSpeed(stats.bytesTx, stats.elapsedSecs),
                    subValue = FormatUtils.formatBytes(stats.bytesTx),
                    modifier = Modifier.weight(1f),
                )
            }
            Spacer(Modifier.height(12.dp))
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                StatCard(
                    icon = Icons.Filled.Timer,
                    label = "Сессия",
                    value = timerText,
                    modifier = Modifier.weight(1f),
                )
                StatCard(
                    icon = Icons.Filled.SwapVert,
                    label = "Пакеты",
                    value = "${stats.pktsRx + stats.pktsTx}",
                    subValue = "${stats.pktsRx} / ${stats.pktsTx}",
                    modifier = Modifier.weight(1f),
                )
            }
        }

        Spacer(Modifier.height(24.dp))
    }
}
