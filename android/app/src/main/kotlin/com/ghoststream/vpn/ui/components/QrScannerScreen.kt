package com.ghoststream.vpn.ui.components

import android.Manifest
import android.content.pm.PackageManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.Preview
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
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
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
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.common.InputImage

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
private fun CameraPreviewView(onBarcodeDetected: (String) -> Unit) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    var detected by remember { mutableStateOf(false) }

    AndroidView(
        factory = { ctx ->
            PreviewView(ctx).apply {
                val cameraProviderFuture = ProcessCameraProvider.getInstance(ctx)
                cameraProviderFuture.addListener({
                    val cameraProvider = cameraProviderFuture.get()

                    val preview = Preview.Builder().build().also {
                        it.setSurfaceProvider(this@apply.surfaceProvider)
                    }

                    val imageAnalysis = ImageAnalysis.Builder()
                        .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                        .build()

                    val scanner = BarcodeScanning.getClient()

                    imageAnalysis.setAnalyzer(ContextCompat.getMainExecutor(ctx)) { imageProxy ->
                        @androidx.camera.core.ExperimentalGetImage
                        val mediaImage = imageProxy.image
                        if (mediaImage == null) {
                            imageProxy.close()
                            return@setAnalyzer
                        }
                        val inputImage = InputImage.fromMediaImage(
                            mediaImage, imageProxy.imageInfo.rotationDegrees,
                        )
                        scanner.process(inputImage)
                            .addOnSuccessListener { barcodes ->
                                if (!detected) {
                                    barcodes.firstOrNull()?.rawValue?.let { value ->
                                        detected = true
                                        onBarcodeDetected(value)
                                    }
                                }
                            }
                            .addOnCompleteListener { imageProxy.close() }
                    }

                    val cameraSelector = CameraSelector.DEFAULT_BACK_CAMERA
                    cameraProvider.unbindAll()
                    cameraProvider.bindToLifecycle(
                        lifecycleOwner, cameraSelector, preview, imageAnalysis,
                    )
                }, ContextCompat.getMainExecutor(ctx))
            }
        },
        modifier = Modifier.fillMaxSize(),
    )
}
