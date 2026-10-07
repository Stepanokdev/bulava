package com.stepanok.bulava

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Bundle
import android.provider.Settings
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import com.google.mlkit.vision.barcode.BarcodeScanner
import com.google.mlkit.vision.barcode.BarcodeScannerOptions
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.common.InputImage
import com.stepanok.bulava.link.LinkClient
import com.stepanok.bulava.ui.components.BulavaButton
import com.stepanok.bulava.ui.components.ButtonKind
import com.stepanok.bulava.ui.components.IconAction
import com.stepanok.bulava.ui.theme.BulavaTheme
import com.stepanok.bulava.ui.theme.Bulava
import com.stepanok.bulava.ui.theme.Icons
import java.util.concurrent.Executors

/**
 * Reads the pairing code off the Mac's screen. The camera is on only while this screen is, and
 * nothing it sees leaves the phone: the code is decoded here, on the device.
 */
class ScanActivity : ComponentActivity() {
    private var permitted by mutableStateOf(false)
    /** The camera or the code reader would not start; the screen says so instead of going dark. */
    private var broken by mutableStateOf(false)
    @Volatile private var delivered = false
    private var scanner: BarcodeScanner? = null
    private val analysis = Executors.newSingleThreadExecutor()

    private val ask = registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted -> permitted = granted }

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        permitted = ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED
        if (!permitted) ask.launch(Manifest.permission.CAMERA)
        setContent {
            BulavaTheme(dark = true) {
                Box(Modifier.fillMaxSize().background(Color.Black)) {
                    if (broken) {
                        Column(
                            Modifier.align(Alignment.Center).padding(32.dp),
                            horizontalAlignment = Alignment.CenterHorizontally,
                            verticalArrangement = Arrangement.spacedBy(12.dp),
                        ) {
                            Text(stringResource(R.string.scan_camera_failed), style = Bulava.type.body, color = Color.White,
                                textAlign = TextAlign.Center)
                            BulavaButton(stringResource(R.string.scan_close), { finish() })
                        }
                    } else if (permitted) {
                        AndroidView(factory = { context -> PreviewView(context).also { bind(it) } }, modifier = Modifier.fillMaxSize())
                        Box(
                            Modifier.align(Alignment.Center).size(260.dp)
                                .border(2.dp, Bulava.colors.accentEmphasis, RoundedCornerShape(20.dp)),
                        )
                        Text(
                            stringResource(R.string.scan_hint), style = Bulava.type.callout, color = Color.White,
                            textAlign = TextAlign.Center,
                            modifier = Modifier.align(Alignment.BottomCenter).padding(horizontal = 32.dp, vertical = 96.dp),
                        )
                    } else {
                        Column(
                            Modifier.align(Alignment.Center).padding(32.dp),
                            horizontalAlignment = Alignment.CenterHorizontally,
                            verticalArrangement = Arrangement.spacedBy(12.dp),
                        ) {
                            Text(stringResource(R.string.scan_camera_needed), style = Bulava.type.body, color = Color.White,
                                textAlign = TextAlign.Center)
                            BulavaButton(stringResource(R.string.scan_allow), { ask.launch(Manifest.permission.CAMERA) })
                            BulavaButton(stringResource(R.string.scan_open_settings), {
                                startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName")))
                            }, kind = ButtonKind.Quiet)
                        }
                    }
                    IconAction(Icons.Close, stringResource(R.string.scan_close), { finish() },
                        Modifier.align(Alignment.TopEnd).statusBarsPadding().padding(8.dp), tint = Color.White)
                }
            }
        }
    }

    override fun onResume() {
        super.onResume()
        val now = ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED
        if (now != permitted) permitted = now
    }

    /**
     * Starts the camera and the code reader. Every step of it can fail on some phone — no back
     * camera, a camera another app holds, a reader that will not load — and the first version let
     * any of them take the whole app down. Now each one ends on a screen that says so and offers
     * the way that needs no camera here: the phone's own camera app, whose page pairs Bulava.
     */
    private fun bind(view: PreviewView) {
        val future = ProcessCameraProvider.getInstance(this)
        future.addListener({
            // The screen may have been closed while the camera was still starting.
            if (isFinishing || isDestroyed) return@addListener
            try {
                val provider = future.get()
                val preview = Preview.Builder().build().also { it.surfaceProvider = view.surfaceProvider }
                val reader = BarcodeScanning.getClient(
                    BarcodeScannerOptions.Builder().setBarcodeFormats(Barcode.FORMAT_QR_CODE).build(),
                ).also { scanner = it }
                val analysisUseCase = ImageAnalysis.Builder()
                    .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST).build()
                analysisUseCase.setAnalyzer(analysis) { proxy -> read(reader, proxy) }
                provider.unbindAll()
                provider.bindToLifecycle(this, CameraSelector.DEFAULT_BACK_CAMERA, preview, analysisUseCase)
            } catch (e: Exception) {
                failed(e)
            } catch (e: LinkageError) {
                failed(e)
            }
        }, ContextCompat.getMainExecutor(this))
    }

    private fun failed(cause: Throwable) {
        Log.w(TAG, "the camera or the code reader would not start", cause)
        broken = true
    }

    /**
     * One frame. Only a Bulava pairing code ends the scan: a Wi-Fi code, a menu or a poster in view
     * is looked past and the camera stays on, rather than closing it onto the paste screen.
     */
    private fun read(reader: BarcodeScanner, proxy: ImageProxy) {
        val media = proxy.image
        if (media == null || delivered) { proxy.close(); return }
        try {
            reader.process(InputImage.fromMediaImage(media, proxy.imageInfo.rotationDegrees))
                .addOnSuccessListener { codes ->
                    codes.firstNotNullOfOrNull { code -> code.rawValue?.takeIf { LinkClient.parsePairing(it) != null } }
                        ?.let { deliver(it) }
                }
                .addOnCompleteListener { proxy.close() }
        } catch (e: Exception) {
            // Thrown before the task existed, so nothing else would close this frame, and the next
            // one would never come.
            proxy.close()
        }
    }

    private fun deliver(code: String) {
        if (delivered) return
        delivered = true
        setResult(RESULT_OK, Intent().putExtra(EXTRA_CODE, code))
        finish()
    }

    override fun onDestroy() {
        // The reader holds native memory; left open, every visit to this screen kept another one.
        scanner?.close()
        scanner = null
        analysis.shutdown()
        super.onDestroy()
    }

    companion object {
        const val EXTRA_CODE = "code"
        private const val TAG = "BulavaScan"
    }
}
