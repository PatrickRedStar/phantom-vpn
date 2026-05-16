package com.ghoststream.vpn.ui.components

import android.Manifest
import android.annotation.SuppressLint
import android.content.pm.PackageManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import android.util.Log
import android.util.Size as AndroidSize
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.Preview
import androidx.camera.core.resolutionselector.AspectRatioStrategy
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.Saver
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.draw.scale
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import com.ghoststream.vpn.R
import com.ghoststream.vpn.ui.theme.C
import com.ghoststream.vpn.ui.theme.GsText
import com.google.mlkit.vision.barcode.BarcodeScannerOptions
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.common.InputImage
import java.util.concurrent.Executors
import kotlin.coroutines.resume
import kotlinx.coroutines.delay
import kotlinx.coroutines.suspendCancellableCoroutine

/**
 * Internal state of the QR scanner UI. The whole screen is a 2-phase
 * state machine: `Scanning` (default) and `Detected` (success). The
 * `Detected` phase runs ~720 ms of choreographed animation (corners
 * snap inward, scanline freezes + flashes, check icon springs in,
 * readout slides up, progress bar fills) before invoking `onResult`
 * and dismissing the screen. This is the user-visible feedback the
 * mockup specifies — without it, MLKit detection at frame 4 (~150 ms)
 * yields a "screen just closed itself" UX that reads as a glitch.
 */
private sealed class LockState {
    data object Scanning : LockState()
    data class Detected(val rawValue: String) : LockState()
}

/**
 * Saver for `LockState` so a rotation in mid-lock doesn't drop the user
 * back into the scanning phase. We only persist enough to re-enter the
 * dismissal animation: the raw QR value if we'd already detected one,
 * otherwise a sentinel string for the scanning phase.
 */
private val LockStateSaver = Saver<LockState, Any>(
    save = { state -> if (state is LockState.Detected) state.rawValue else "scanning" },
    restore = { saved ->
        when (saved) {
            "scanning" -> LockState.Scanning
            is String -> LockState.Detected(saved)
            else -> LockState.Scanning
        }
    },
)

/** Total time from detection to `onResult` invocation. */
private const val LOCK_TOTAL_MS = 720
/** Delay between detection and the check + readout appearing. */
private const val LOCK_CONFIRM_DELAY_MS = 120
/** Duration of the progress-to-dismiss bar fill. */
private const val LOCK_PROGRESS_MS = LOCK_TOTAL_MS - LOCK_CONFIRM_DELAY_MS

@Composable
fun QrScannerScreen(
    onResult: (String) -> Unit,
    onBack: () -> Unit,
) {
    val context = LocalContext.current
    val clipboard = LocalClipboardManager.current
    val haptics = LocalHapticFeedback.current
    var hasCameraPermission by remember {
        mutableStateOf(
            ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) ==
                PackageManager.PERMISSION_GRANTED,
        )
    }

    val permLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { hasCameraPermission = it }

    LaunchedEffect(Unit) {
        if (!hasCameraPermission) permLauncher.launch(Manifest.permission.CAMERA)
    }

    // Two-phase state machine. Detected only fires once — subsequent
    // barcodes are ignored while the success animation plays out.
    // `rememberSaveable` so a rotation between detection and the
    // dismissal animation doesn't reset the screen back to scanning.
    var lockState by rememberSaveable(stateSaver = LockStateSaver) {
        mutableStateOf<LockState>(LockState.Scanning)
    }

    // Single-shot lock arming: fire haptic, then schedule onResult after
    // the full lock-on choreography (LOCK_TOTAL_MS).
    LaunchedEffect(lockState) {
        val state = lockState
        if (state is LockState.Detected) {
            haptics.performHapticFeedback(HapticFeedbackType.LongPress)
            delay(LOCK_TOTAL_MS.toLong())
            onResult(state.rawValue)
        }
    }

    // Eased lock progress 0→1 over LOCK_CONFIRM_DELAY_MS. Drives corner
    // snap-in and lock-ring fade. Held at 1.0 for the remainder of the
    // detected phase so the visual stays "locked" until dismissal.
    val lockProgress by animateFloatAsState(
        targetValue = if (lockState is LockState.Detected) 1f else 0f,
        animationSpec = tween(
            durationMillis = LOCK_CONFIRM_DELAY_MS,
            easing = CubicBezierEasing(0.4f, 0f, 0.2f, 1f),
        ),
        label = "lockProgress",
    )

    Box(Modifier.fillMaxSize().background(C.bg)) {
        if (hasCameraPermission) {
            CameraPreviewView(
                onBarcodeDetected = { value ->
                    // Latch on the first detection. The CameraX analyzer
                    // keeps running but lockState=Detected suppresses
                    // further onResult calls and starts the dismissal
                    // timer above.
                    if (lockState is LockState.Scanning) {
                        lockState = LockState.Detected(value)
                    }
                },
            )
        } else {
            Column(
                modifier = Modifier.fillMaxSize(),
                verticalArrangement = Arrangement.Center,
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Text(
                    stringResource(R.string.qr_permission),
                    color = C.bone,
                    style = GsText.hint,
                )
            }
        }

        // Header overlay
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .background(C.bg.copy(alpha = 0.82f)),
        ) {
            ScreenHeader(
                brand = stringResource(R.string.brand_intake),
                meta = {
                    val closeLabel = stringResource(R.string.qr_close)
                    Text(
                        text = closeLabel.uppercase(),
                        style = GsText.hdrMeta,
                        color = C.textDim,
                        modifier = Modifier
                            .clickable { onBack() }
                            .semantics {
                                role = Role.Button
                                contentDescription = closeLabel
                            },
                    )
                },
            )
        }

        // Viewfinder
        val signalColor = C.signal
        val isDetected = lockState is LockState.Detected
        Box(
            modifier = Modifier
                .size(240.dp)
                .align(Alignment.Center)
                .offset(y = (-20).dp),
        ) {
            // 4 corner brackets — animate inward on lock.
            ViewfinderCorners(lockProgress = lockProgress)

            // Scanline — animates while scanning, snaps to centre + flashes on lock.
            val transition = rememberInfiniteTransition(label = "scanline")
            val scanY by transition.animateFloat(
                initialValue = 4f,
                targetValue = 228f,
                animationSpec = infiniteRepeatable(
                    animation = tween(2400),
                    repeatMode = RepeatMode.Reverse,
                ),
                label = "scanY",
            )
            // Fade out the moving scanline when locked.
            val scanlineAlpha by animateFloatAsState(
                targetValue = if (isDetected) 0f else 0.9f,
                animationSpec = tween(durationMillis = 220),
                label = "scanlineAlpha",
            )
            if (scanlineAlpha > 0.01f) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .offset(y = scanY.dp)
                        .padding(horizontal = 4.dp)
                        .height(2.dp)
                        .background(
                            Brush.horizontalGradient(
                                listOf(
                                    Color.Transparent,
                                    signalColor.copy(alpha = scanlineAlpha),
                                    Color.Transparent,
                                ),
                            ),
                        )
                        .drawBehind {
                            drawRect(
                                color = signalColor.copy(alpha = 0.3f * scanlineAlpha),
                                topLeft = Offset(0f, -2f),
                                size = Size(size.width, size.height + 4f),
                            )
                        },
                )
            }

            // Confirm check icon — spring scale-in once the readout phase begins.
            AnimatedVisibility(
                visible = isDetected,
                enter = scaleIn(
                    initialScale = 0.45f,
                    animationSpec = spring(
                        dampingRatio = Spring.DampingRatioMediumBouncy,
                        stiffness = Spring.StiffnessMedium,
                    ),
                ) + fadeIn(animationSpec = tween(180)),
                exit = scaleOut(targetScale = 0.9f) + fadeOut(),
                modifier = Modifier.align(Alignment.Center),
            ) {
                Box(
                    modifier = Modifier
                        .size(120.dp)
                        .drawBehind {
                            // Soft phosphor halo behind the check.
                            drawRect(
                                color = signalColor.copy(alpha = 0.18f),
                                size = size,
                            )
                        },
                    contentAlignment = Alignment.Center,
                ) {
                    androidx.compose.foundation.Canvas(
                        modifier = Modifier.size(56.dp),
                    ) {
                        // Manual checkmark via 2 strokes — keeps stroke
                        // control + halo cheaper than rasterising a vector.
                        val strokePx = 4.dp.toPx()
                        val w = size.width
                        val h = size.height
                        // First segment: down-right from upper-left.
                        drawLine(
                            color = signalColor,
                            start = Offset(w * 0.20f, h * 0.55f),
                            end = Offset(w * 0.42f, h * 0.78f),
                            strokeWidth = strokePx,
                            cap = androidx.compose.ui.graphics.StrokeCap.Round,
                        )
                        // Second segment: up-right through the corner.
                        drawLine(
                            color = signalColor,
                            start = Offset(w * 0.42f, h * 0.78f),
                            end = Offset(w * 0.82f, h * 0.30f),
                            strokeWidth = strokePx,
                            cap = androidx.compose.ui.graphics.StrokeCap.Round,
                        )
                    }
                }
            }
        }

        // Hints — fade out the moment we lock so the user's eye isn't
        // pulled away from the readout / check icon.
        val hintAlpha by animateFloatAsState(
            targetValue = if (isDetected) 0f else 1f,
            animationSpec = tween(220),
            label = "hintAlpha",
        )
        if (hintAlpha > 0.01f) {
            Column(
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .padding(bottom = 108.dp)
                    .scale(1f, 1f),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Text(
                    text = stringResource(R.string.qr_hint_main),
                    style = GsText.hint,
                    color = C.bone.copy(alpha = hintAlpha),
                )
                Spacer(Modifier.height(8.dp))
                Text(
                    text = stringResource(R.string.qr_hint_sub).uppercase(),
                    style = GsText.labelMono,
                    color = C.textFaint.copy(alpha = hintAlpha),
                )
            }
        }

        // Paste CTA — same fade as hints.
        if (hintAlpha > 0.01f) {
            Box(
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .padding(bottom = 30.dp, start = 18.dp, end = 18.dp)
                    .fillMaxWidth(),
            ) {
                DashedGhostCard(
                    modifier = Modifier
                        .fillMaxWidth()
                        .background(C.bg.copy(alpha = 0.75f * hintAlpha))
                        .clickable {
                            clipboard.getText()?.text?.let { value ->
                                if (lockState is LockState.Scanning) {
                                    lockState = LockState.Detected(value)
                                }
                            }
                        },
                ) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(vertical = 12.dp),
                        horizontalArrangement = Arrangement.Center,
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(
                            text = stringResource(R.string.qr_paste_cta).uppercase(),
                            style = GsText.labelMono,
                            color = C.textDim.copy(alpha = hintAlpha),
                        )
                        Text(
                            text = stringResource(R.string.qr_paste_tap).uppercase(),
                            style = GsText.labelMono,
                            color = C.signal.copy(alpha = hintAlpha),
                        )
                    }
                }
            }
        }

        // Success readout — appears with the check, holds for the rest of
        // the dismissal window. Slide-in from below, fade-in over 280 ms.
        AnimatedVisibility(
            visible = isDetected,
            enter = slideInVertically(
                initialOffsetY = { it / 3 },
                animationSpec = tween(
                    durationMillis = 280,
                    easing = CubicBezierEasing(0.4f, 0f, 0.2f, 1f),
                ),
            ) + fadeIn(tween(280)),
            exit = slideOutVertically(targetOffsetY = { -it / 6 }) + fadeOut(),
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .padding(bottom = 88.dp, start = 18.dp, end = 18.dp)
                .fillMaxWidth(),
        ) {
            ReadoutCard(rawValue = (lockState as? LockState.Detected)?.rawValue ?: "")
        }

        // Dismissal progress bar — fills over LOCK_PROGRESS_MS so the
        // user has a visible "we're about to close" indicator. Animation
        // is keyed on lockState so it actually starts when detection
        // happens, not from previous compositions.
        if (isDetected) {
            val fillProgress by animateFloatAsState(
                targetValue = 1f,
                animationSpec = tween(
                    durationMillis = LOCK_PROGRESS_MS,
                    easing = LinearEasing,
                ),
                label = "dismissProgress",
            )
            // Capture composable-only color reads OUT of the drawBehind
            // lambda — drawBehind runs in DrawScope, not Composable scope.
            val progressColor = C.signal
            val progressGlow = C.signal.copy(alpha = 0.5f)
            Box(
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .padding(bottom = 14.dp, start = 14.dp, end = 14.dp)
                    .fillMaxWidth()
                    .height(2.dp)
                    .background(C.bgElev2),
            ) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth(fillProgress)
                        .fillMaxSize()
                        .background(progressColor)
                        .drawBehind {
                            drawRect(
                                color = progressGlow,
                                topLeft = Offset(0f, -2f),
                                size = Size(size.width, size.height + 4f),
                            )
                        },
                )
            }
        }
    }
}

/**
 * Compact identity readout shown above the dismissal progress bar after
 * lock-on. Pulls the profile name from a `ghs://` conn-string when
 * present, otherwise shows a generic OK badge. Truncates the body so a
 * full identity blob doesn't blow up the layout.
 */
@Composable
private fun ReadoutCard(rawValue: String) {
    val profileName = rememberProfileName(rawValue)
    val preview = remember(rawValue) {
        rawValue.take(72) + if (rawValue.length > 72) "…" else ""
    }
    val borderColor = C.signal
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .background(C.bg.copy(alpha = 0.92f))
            .drawBehind {
                // Phosphor border with a faint halo.
                val stroke = 1.dp.toPx()
                drawRect(
                    color = borderColor,
                    topLeft = Offset(0f, 0f),
                    size = size,
                    style = androidx.compose.ui.graphics.drawscope.Stroke(width = stroke),
                )
            }
            .padding(horizontal = 14.dp, vertical = 12.dp),
    ) {
        Column {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = "QR_LOCK · CONN_STRING OK",
                    style = GsText.labelMono,
                    color = C.signal,
                )
                Text(
                    text = "1280×720",
                    style = GsText.labelMono,
                    color = C.textDim,
                )
            }
            Spacer(Modifier.height(6.dp))
            Text(
                text = profileName,
                style = GsText.hint,
                color = C.bone,
            )
            Spacer(Modifier.height(2.dp))
            Text(
                text = preview,
                style = GsText.labelMono,
                color = C.textDim,
                maxLines = 1,
            )
        }
    }
}

/**
 * Best-effort extraction of a profile label from a `ghs://` conn-string.
 * Falls back to a generic "PROFILE" badge if the value doesn't carry a
 * recognisable name (older format / clipboard paste of something else).
 */
@Composable
private fun rememberProfileName(rawValue: String): String = remember(rawValue) {
    runCatching {
        // ghs://<host>/<id>?name=...&…   identity often lives in 'name' or path.
        val nameKey = Regex("(?:[?&])name=([^&]+)").find(rawValue)?.groupValues?.getOrNull(1)
        if (!nameKey.isNullOrBlank()) {
            return@runCatching java.net.URLDecoder.decode(nameKey, "UTF-8")
        }
        // Fallback: host segment.
        val host = Regex("ghs://([^/?#]+)").find(rawValue)?.groupValues?.getOrNull(1)
        host?.takeIf { it.isNotBlank() } ?: "PROFILE"
    }.getOrDefault("PROFILE")
}

/**
 * Bracket corners that snap inward on `lockProgress` 0→1. At rest the
 * brackets sit at the viewfinder edges; at lock=1 they pull in 20 % of
 * the box size, framing the QR shape tighter — the "we got it" gesture.
 */
@Composable
private fun ViewfinderCorners(lockProgress: Float = 0f) {
    val sig = C.signal
    val sigGlow = sig.copy(alpha = 0.35f)
    Box(
        modifier = Modifier
            .fillMaxSize()
            .drawBehind {
                val len = 34.dp.toPx()
                val stroke = 2.dp.toPx()
                val w = size.width
                val h = size.height
                val snap = (w * 0.20f) * lockProgress

                // TL — origin (snap, snap)
                drawLine(sig, Offset(snap, snap), Offset(snap + len, snap), stroke)
                drawLine(sig, Offset(snap, snap), Offset(snap, snap + len), stroke)
                // TR — origin (w-snap, snap)
                drawLine(sig, Offset(w - snap - len, snap), Offset(w - snap, snap), stroke)
                drawLine(sig, Offset(w - snap, snap), Offset(w - snap, snap + len), stroke)
                // BL — origin (snap, h-snap)
                drawLine(sig, Offset(snap, h - snap - len), Offset(snap, h - snap), stroke)
                drawLine(sig, Offset(snap, h - snap), Offset(snap + len, h - snap), stroke)
                // BR — origin (w-snap, h-snap)
                drawLine(sig, Offset(w - snap - len, h - snap), Offset(w - snap, h - snap), stroke)
                drawLine(sig, Offset(w - snap, h - snap - len), Offset(w - snap, h - snap), stroke)

                // Glow halo — same coords with thicker stroke.
                val glowStroke = stroke * 2.5f
                drawLine(sigGlow, Offset(snap, snap), Offset(snap + len, snap), glowStroke)
                drawLine(sigGlow, Offset(snap, snap), Offset(snap, snap + len), glowStroke)
                drawLine(sigGlow, Offset(w - snap - len, snap), Offset(w - snap, snap), glowStroke)
                drawLine(sigGlow, Offset(w - snap, snap), Offset(w - snap, snap + len), glowStroke)
                drawLine(sigGlow, Offset(snap, h - snap - len), Offset(snap, h - snap), glowStroke)
                drawLine(sigGlow, Offset(snap, h - snap), Offset(snap + len, h - snap), glowStroke)
                drawLine(sigGlow, Offset(w - snap - len, h - snap), Offset(w - snap, h - snap), glowStroke)
                drawLine(sigGlow, Offset(w - snap, h - snap - len), Offset(w - snap, h - snap), glowStroke)
            },
    )
}

@Composable
@Suppress("DEPRECATION")
@SuppressLint("UnsafeOptInUsageError")
private fun CameraPreviewView(onBarcodeDetected: (String) -> Unit) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current

    // Single PreviewView that survives recomposition (scanline animation
    // ticks ~60 fps and would otherwise recreate the surface each frame).
    val previewView = remember {
        PreviewView(context).apply {
            // COMPATIBLE = TextureView. PERFORMANCE (SurfaceView default)
            // closed surfaces immediately on Samsung One UI 8 / Android 16
            // before the View was fully attached to the window, killing
            // the Camera2 session within ~18 s.
            implementationMode = PreviewView.ImplementationMode.COMPATIBLE
        }
    }

    // MLKit decode + frame analysis MUST NOT run on the UI thread: it
    // throttles compose's frame callbacks and One UI 8's Camera2 HAL
    // disconnects on missed frames.
    val analysisExecutor = remember { Executors.newSingleThreadExecutor() }

    // Narrow scanner to QR-only — Google explicitly recommends this for
    // speed. With all formats on, the decoder budgets per-frame work
    // across PDF417/Aztec/DataMatrix/EAN/UPC and can exhaust the frame
    // window before reaching QR, so QRs from a screen never decode.
    val scanner = remember {
        BarcodeScanning.getClient(
            BarcodeScannerOptions.Builder()
                .setBarcodeFormats(Barcode.FORMAT_QR_CODE)
                .build(),
        )
    }
    val detected = remember { mutableStateOf(false) }
    val currentOnDetected by rememberUpdatedState(onBarcodeDetected)
    val frameCounter = remember { java.util.concurrent.atomic.AtomicLong(0) }

    // Hold a reference so we can unbind on dispose. Otherwise Samsung
    // One UI 8 keeps the Camera2 device busy for ~18 s after the screen
    // leaves the composition, blocking the next QR open and other
    // camera apps.
    val cameraProviderState = remember { mutableStateOf<ProcessCameraProvider?>(null) }

    DisposableEffect(Unit) {
        onDispose {
            runCatching { cameraProviderState.value?.unbindAll() }
            runCatching { analysisExecutor.shutdown() }
            runCatching { scanner.close() }
        }
    }

    // Bind AFTER PreviewView lands in the compose tree (LaunchedEffect
    // body runs after first composition + layout). At that point
    // `previewView.surfaceProvider` is ready and won't be torn down
    // on the first layout pass.
    LaunchedEffect(lifecycleOwner, previewView) {
        val cameraProvider = ProcessCameraProvider.getInstance(context)
            .awaitProvider(ContextCompat.getMainExecutor(context))
        cameraProviderState.value = cameraProvider
        val preview = Preview.Builder().build().also {
            it.setSurfaceProvider(previewView.surfaceProvider)
        }

        // Default ImageAnalysis resolution is 640×480 — too low for QR
        // codes shown on a screen at 15-30 cm. Modules end up at ~2-3 px,
        // below MLKit's decodable limit. Request 1280×720 with closest-
        // higher fallback (Google's documented recommendation).
        val resolutionSelector = ResolutionSelector.Builder()
            .setAspectRatioStrategy(AspectRatioStrategy.RATIO_16_9_FALLBACK_AUTO_STRATEGY)
            .setResolutionStrategy(
                ResolutionStrategy(
                    AndroidSize(1280, 720),
                    ResolutionStrategy.FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER,
                ),
            )
            .build()

        val imageAnalysis = ImageAnalysis.Builder()
            .setResolutionSelector(resolutionSelector)
            .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
            // Explicit YUV — what MLKit expects natively, avoids any
            // RGBA conversion overhead.
            .setOutputImageFormat(ImageAnalysis.OUTPUT_IMAGE_FORMAT_YUV_420_888)
            .build()
            .also { ia ->
                ia.setAnalyzer(analysisExecutor) { imageProxy ->
                    val frameNum = frameCounter.incrementAndGet()
                    val mediaImage = imageProxy.image ?: run {
                        Log.w("QrScanner", "frame=$frameNum mediaImage null, skipping")
                        imageProxy.close()
                        return@setAnalyzer
                    }
                    // Log frame metadata once every 30 frames (~1s at 30fps)
                    // so we can verify resolution / rotation in logcat
                    // without spamming the log.
                    if (frameNum % 30L == 1L) {
                        Log.d(
                            "QrScanner",
                            "frame=$frameNum size=${mediaImage.width}x${mediaImage.height}" +
                                " rot=${imageProxy.imageInfo.rotationDegrees}" +
                                " fmt=${mediaImage.format}",
                        )
                    }
                    val input = InputImage.fromMediaImage(
                        mediaImage, imageProxy.imageInfo.rotationDegrees,
                    )
                    scanner.process(input)
                        .addOnSuccessListener { barcodes ->
                            if (barcodes.isNotEmpty()) {
                                Log.i(
                                    "QrScanner",
                                    "frame=$frameNum detected ${barcodes.size} QR(s)",
                                )
                            }
                            if (!detected.value) {
                                barcodes.firstOrNull()?.rawValue?.let { value ->
                                    detected.value = true
                                    currentOnDetected(value)
                                }
                            }
                        }
                        .addOnFailureListener { e ->
                            Log.w("QrScanner", "frame=$frameNum scanner failure", e)
                        }
                        .addOnCompleteListener { imageProxy.close() }
                }
            }
        runCatching {
            cameraProvider.unbindAll()
            cameraProvider.bindToLifecycle(
                lifecycleOwner,
                CameraSelector.DEFAULT_BACK_CAMERA,
                preview,
                imageAnalysis,
            )
            Log.i("QrScanner", "camera bound, resolution=1280x720 target, QR-only scanner")
        }.onFailure { Log.e("QrScanner", "bindToLifecycle failed", it) }
    }

    AndroidView(
        factory = { previewView },
        modifier = Modifier.fillMaxSize(),
    )
}

/**
 * Suspend wrapper around the ListenableFuture returned by
 * `ProcessCameraProvider.getInstance(context)`. Avoids pulling in
 * `kotlinx-coroutines-guava` just for one await.
 *
 * Takes an executor from the caller — previously we spawned a fresh
 * single-thread Executor on every QR open and never shut it down,
 * leaving one detached thread per scanner open. Use
 * `ContextCompat.getMainExecutor(context)` at the call site: the
 * listener fires once with the provider, main-thread cost is
 * negligible.
 */
private suspend fun com.google.common.util.concurrent.ListenableFuture<ProcessCameraProvider>.awaitProvider(
    executor: java.util.concurrent.Executor,
): ProcessCameraProvider = suspendCancellableCoroutine { cont ->
    addListener(
        Runnable {
            runCatching { get() }
                .onSuccess { cont.resume(it) }
                .onFailure { cont.cancel(it) }
        },
        executor,
    )
}
