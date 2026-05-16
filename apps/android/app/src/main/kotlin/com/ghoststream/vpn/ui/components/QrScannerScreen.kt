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
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
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
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.res.stringResource
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
import kotlinx.coroutines.suspendCancellableCoroutine

@Composable
fun QrScannerScreen(
    onResult: (String) -> Unit,
    onBack: () -> Unit,
) {
    val context = LocalContext.current
    val clipboard = LocalClipboardManager.current
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

    Box(Modifier.fillMaxSize().background(C.bg)) {
        if (hasCameraPermission) {
            CameraPreviewView(onBarcodeDetected = onResult)
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
                    Text(
                        text = stringResource(R.string.qr_close).uppercase(),
                        style = GsText.hdrMeta,
                        color = C.textDim,
                        modifier = Modifier.clickable { onBack() },
                    )
                },
            )
        }

        // Viewfinder
        val signalColor = C.signal
        Box(
            modifier = Modifier
                .size(240.dp)
                .align(Alignment.Center)
                .offset(y = (-20).dp),
        ) {
            // 4 corner brackets
            ViewfinderCorners()

            // Scanline
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
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .offset(y = scanY.dp)
                    .padding(horizontal = 4.dp)
                    .height(2.dp)
                    .background(
                        Brush.horizontalGradient(
                            listOf(Color.Transparent, signalColor, Color.Transparent),
                        ),
                    )
                    .drawBehind {
                        drawRect(
                            color = signalColor.copy(alpha = 0.3f),
                            topLeft = Offset(0f, -2f),
                            size = Size(size.width, size.height + 4f),
                        )
                    },
            )
        }

        // Hints
        Column(
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .padding(bottom = 108.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Text(
                text = stringResource(R.string.qr_hint_main),
                style = GsText.hint,
                color = C.bone,
            )
            Spacer(Modifier.height(8.dp))
            Text(
                text = stringResource(R.string.qr_hint_sub).uppercase(),
                style = GsText.labelMono,
                color = C.textFaint,
            )
        }

        // Paste CTA
        Box(
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .padding(bottom = 30.dp, start = 18.dp, end = 18.dp)
                .fillMaxWidth(),
        ) {
            DashedGhostCard(
                modifier = Modifier
                    .fillMaxWidth()
                    .background(C.bg.copy(alpha = 0.75f))
                    .clickable {
                        clipboard.getText()?.text?.let { onResult(it) }
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
                        color = C.textDim,
                    )
                    Text(
                        text = stringResource(R.string.qr_paste_tap).uppercase(),
                        style = GsText.labelMono,
                        color = C.signal,
                    )
                }
            }
        }
    }
}

@Composable
private fun ViewfinderCorners() {
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
                // TL
                drawLine(sig, Offset(0f, 0f), Offset(len, 0f), stroke)
                drawLine(sig, Offset(0f, 0f), Offset(0f, len), stroke)
                // TR
                drawLine(sig, Offset(w - len, 0f), Offset(w, 0f), stroke)
                drawLine(sig, Offset(w, 0f), Offset(w, len), stroke)
                // BL
                drawLine(sig, Offset(0f, h - len), Offset(0f, h), stroke)
                drawLine(sig, Offset(0f, h), Offset(len, h), stroke)
                // BR
                drawLine(sig, Offset(w - len, h), Offset(w, h), stroke)
                drawLine(sig, Offset(w, h - len), Offset(w, h), stroke)
                // glow
                drawLine(sigGlow, Offset(0f, 0f), Offset(len, 0f), stroke * 2.5f)
                drawLine(sigGlow, Offset(0f, 0f), Offset(0f, len), stroke * 2.5f)
                drawLine(sigGlow, Offset(w - len, 0f), Offset(w, 0f), stroke * 2.5f)
                drawLine(sigGlow, Offset(w, 0f), Offset(w, len), stroke * 2.5f)
                drawLine(sigGlow, Offset(0f, h - len), Offset(0f, h), stroke * 2.5f)
                drawLine(sigGlow, Offset(0f, h), Offset(len, h), stroke * 2.5f)
                drawLine(sigGlow, Offset(w - len, h), Offset(w, h), stroke * 2.5f)
                drawLine(sigGlow, Offset(w, h - len), Offset(w, h), stroke * 2.5f)
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

    DisposableEffect(Unit) {
        onDispose {
            runCatching { analysisExecutor.shutdown() }
            runCatching { scanner.close() }
        }
    }

    // Bind AFTER PreviewView lands in the compose tree (LaunchedEffect
    // body runs after first composition + layout). At that point
    // `previewView.surfaceProvider` is ready and won't be torn down
    // on the first layout pass.
    LaunchedEffect(lifecycleOwner, previewView) {
        val cameraProvider = ProcessCameraProvider.getInstance(context).awaitProvider()
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
 */
private suspend fun com.google.common.util.concurrent.ListenableFuture<ProcessCameraProvider>.awaitProvider():
    ProcessCameraProvider = suspendCancellableCoroutine { cont ->
    addListener(
        Runnable {
            runCatching { get() }
                .onSuccess { cont.resume(it) }
                .onFailure { cont.cancel(it) }
        },
        java.util.concurrent.Executors.newSingleThreadExecutor(),
    )
}
