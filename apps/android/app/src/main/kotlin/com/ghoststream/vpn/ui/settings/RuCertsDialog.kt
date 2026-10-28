package com.ghoststream.vpn.ui.settings

import android.content.ActivityNotFoundException
import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.provider.Settings
import android.security.KeyChain
import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.annotation.RequiresApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.ghoststream.vpn.R
import com.ghoststream.vpn.ui.components.GhostDialog
import com.ghoststream.vpn.ui.components.GhostDialogButton
import com.ghoststream.vpn.ui.components.GhostFullDialog
import com.ghoststream.vpn.ui.theme.C
import com.ghoststream.vpn.ui.theme.GsShapePill
import com.ghoststream.vpn.ui.theme.GsText
import com.ghoststream.vpn.ui.theme.InstrumentSerif
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

// Сертификаты Минцифры, ограниченные Name Constraints до .ru/.рф/.su
// (tools/ru-only-certs). Приложение не может поставить CA молча:
//  - API 26–29: KeyChain.createInstallIntent() — системный установщик, по очереди;
//  - API 30+: этот интент для CA запрещён, кладём файлы в Загрузки и показываем шаги.
private val CERTS = listOf(
    Triple(R.raw.ru_only_root, "ru-only-root.crt", "RU-only trust"),
    Triple(R.raw.ru_only_sub_ca, "ru-only-sub-ca.crt", "Russian Trusted Sub CA"),
)

@Composable
fun RuCertsDialog(onDismiss: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var showSteps by rememberSaveable { mutableStateOf(false) }

    // API < 30: -1 = idle, 0..n-1 = launch cert i, n = done.
    var keyChainStep by remember { mutableIntStateOf(-1) }
    val keyChainLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.StartActivityForResult(),
    ) { keyChainStep++ }
    LaunchedEffect(keyChainStep) {
        when (keyChainStep) {
            -1 -> Unit
            in CERTS.indices -> {
                val (res, _, name) = CERTS[keyChainStep]
                keyChainLauncher.launch(
                    KeyChain.createInstallIntent()
                        .putExtra(KeyChain.EXTRA_CERTIFICATE, context.resources.openRawResource(res).use { it.readBytes() })
                        .putExtra(KeyChain.EXTRA_NAME, name),
                )
            }
            else -> onDismiss()
        }
    }

    if (showSteps) {
        RuCertsStepsDialog(onDismiss = onDismiss)
        return
    }

    GhostFullDialog(
        onDismissRequest = onDismiss,
        title = stringResource(R.string.row_ru_certs),
        content = {
            Column(
                Modifier.verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) { RuCertsExplain() }
        },
        dismissButton = {
            GhostDialogButton(stringResource(R.string.action_not_now), onClick = onDismiss, color = C.textDim)
        },
        confirmButton = {
            GhostDialogButton(stringResource(R.string.action_install), onClick = {
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
                    keyChainStep = 0
                } else scope.launch {
                    try {
                        withContext(Dispatchers.IO) { saveToDownloads(context) }
                        showSteps = true
                    } catch (e: Exception) {
                        Toast.makeText(
                            context,
                            context.getString(R.string.rucert_save_failed, e.message ?: e.javaClass.simpleName),
                            Toast.LENGTH_LONG,
                        ).show()
                    }
                }
            })
        },
    )
}

@RequiresApi(Build.VERSION_CODES.Q)
private fun saveToDownloads(context: Context) {
    val resolver = context.contentResolver
    val collection = MediaStore.Downloads.EXTERNAL_CONTENT_URI
    val dir = Environment.DIRECTORY_DOWNLOADS + "/GhostStream/"
    for ((res, file, _) in CERTS) {
        // Наш файл с прошлого нажатия (в т.ч. «ru-only-root (1).crt») перезаписываем,
        // а не плодим новые копии. Файлы прошлой установки приложения нам не видны —
        // после переустановки одна копия «(1)» появится, дальше не растёт.
        val existing = resolver.query(
            collection,
            arrayOf(MediaStore.MediaColumns._ID),
            "${MediaStore.MediaColumns.DISPLAY_NAME} LIKE ? AND ${MediaStore.MediaColumns.RELATIVE_PATH}=?",
            arrayOf(file.removeSuffix(".crt") + "%", dir),
            null,
        )?.use { c -> if (c.moveToFirst()) ContentUris.withAppendedId(collection, c.getLong(0)) else null }
        val uri = existing ?: resolver.insert(collection, ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, file)
            put(MediaStore.MediaColumns.MIME_TYPE, "application/x-x509-ca-cert")
            put(MediaStore.MediaColumns.RELATIVE_PATH, dir)
        }) ?: error("MediaStore insert failed")
        resolver.openOutputStream(uri, "wt")!!.use { out ->
            context.resources.openRawResource(res).use { it.copyTo(out) }
        }
    }
}

@Composable
private fun RuCertsStepsDialog(onDismiss: () -> Unit) {
    val context = LocalContext.current
    GhostDialog(
        onDismissRequest = onDismiss,
        title = stringResource(R.string.rucert_steps_title),
        content = {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("✓", style = BodyStyle, color = C.signal)
                Spacer(Modifier.width(10.dp))
                Text(stringResource(R.string.rucert_saved), style = GsText.kvValue, color = C.textDim)
            }
            Spacer(Modifier.size(12.dp))
            Block {
                listOf(R.string.rucert_step_1, R.string.rucert_step_2, R.string.rucert_step_3)
                    .forEachIndexed { i, step ->
                        Row(Modifier.padding(bottom = 6.dp)) {
                            Box(
                                Modifier.size(20.dp).border(1.dp, C.signal, CircleShape),
                                contentAlignment = Alignment.Center,
                            ) { Text("${i + 1}", style = GsText.labelMonoSmall, color = C.signal) }
                            Spacer(Modifier.width(10.dp))
                            Text(stringResource(step), style = BodyStyle, color = C.bone)
                        }
                    }
                Text(stringResource(R.string.rucert_steps_note), style = BodyStyle, color = C.textDim)
            }
        },
        dismissButton = {
            GhostDialogButton(stringResource(R.string.action_done), onClick = onDismiss, color = C.textDim)
        },
        confirmButton = {
            GhostDialogButton(stringResource(R.string.action_open_settings), onClick = {
                try {
                    context.startActivity(Intent(Settings.ACTION_SECURITY_SETTINGS))
                } catch (_: ActivityNotFoundException) {
                    context.startActivity(Intent(Settings.ACTION_SETTINGS))
                }
            })
        },
    )
}

@Composable
private fun RuCertsExplain() {
    Text(
        buildAnnotatedString {
            append(stringResource(R.string.rucert_hero_a))
            withStyle(SpanStyle(fontStyle = FontStyle.Italic, color = C.signal)) {
                append(stringResource(R.string.rucert_hero_em))
            }
            append(stringResource(R.string.rucert_hero_b))
        },
        style = TextStyle(fontFamily = InstrumentSerif, fontSize = 25.sp, lineHeight = 29.sp),
        color = C.bone,
    )
    Block(stringResource(R.string.rucert_what_t)) {
        P(stringResource(R.string.rucert_what_d1))
        P(stringResource(R.string.rucert_what_d2))
    }
    Block(stringResource(R.string.rucert_scope_t)) {
        P(stringResource(R.string.rucert_scope_d))
        FlowRow(
            Modifier.padding(top = 4.dp),
            horizontalArrangement = Arrangement.spacedBy(6.dp),
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            listOf(".RU", ".РФ", ".SU").forEach { Zone(it, on = true) }
            Zone(".COM", on = false)
            Zone(stringResource(R.string.rucert_zone_rest), on = false)
        }
    }
    Block(stringResource(R.string.rucert_plus_t), C.signal) {
        listOf(R.string.rucert_plus_1, R.string.rucert_plus_2, R.string.rucert_plus_3)
            .forEach { Bullet("+", C.signal, stringResource(it)) }
    }
    Block(stringResource(R.string.rucert_risk_t), C.warn) {
        listOf(R.string.rucert_risk_1, R.string.rucert_risk_2, R.string.rucert_risk_3)
            .forEach { Bullet("!", C.warn, stringResource(it)) }
    }
    Block(stringResource(R.string.rucert_need_t)) { P(stringResource(R.string.rucert_need_d)) }
    Block(stringResource(R.string.rucert_remove_t)) { P(stringResource(R.string.rucert_remove_d), C.textDim) }
}

private val BodyStyle = GsText.bodyMedium.copy(lineHeight = 18.sp)

@Composable
private fun Block(title: String? = null, titleColor: Color = C.textDim, content: @Composable ColumnScope.() -> Unit) {
    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .background(C.bone.copy(alpha = 0.035f))
            .padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        if (title != null) {
            Text(title.uppercase(), style = GsText.labelMono, color = titleColor, modifier = Modifier.padding(bottom = 2.dp))
        }
        content()
    }
}

@Composable
private fun P(text: String, color: Color = C.bone) = Text(text, style = BodyStyle, color = color)

@Composable
private fun Bullet(mark: String, color: Color, text: String) {
    Row {
        Text(mark, style = BodyStyle, color = color, modifier = Modifier.width(16.dp))
        Text(text, style = BodyStyle, color = C.bone)
    }
}

@Composable
private fun Zone(text: String, on: Boolean) {
    Text(
        text.uppercase(),
        style = GsText.labelMonoSmall,
        color = if (on) C.signal else C.textFaint,
        textDecoration = if (on) null else TextDecoration.LineThrough,
        modifier = Modifier
            .border(1.dp, if (on) C.signal else C.hair, GsShapePill)
            .padding(horizontal = 8.dp, vertical = 4.dp),
    )
}
