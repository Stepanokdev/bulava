package com.stepanok.bulava.platform

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.MediaRecorder
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.ContextCompat
import java.io.File
import java.util.UUID
import kotlin.math.log10

/**
 * The microphone on Android: `MediaRecorder`, AAC in an MPEG-4 file — the M4A the Mac's Whisper
 * reads as it is.
 *
 * Mono at 16 kHz, because that is what Whisper hears anyway (it resamples everything to 16 kHz
 * mono first): more would only make the upload longer. At 32 kbps a minute is about a quarter of
 * a megabyte, so even half an hour stays far under what the link takes.
 *
 * The files live in the app's no-backup storage: a recording is on its way to being words, not
 * something to restore on a new phone.
 */
class AndroidVoice(
    private val context: Context,
    private val launcher: () -> AndroidLauncher?,
) : VoiceRecorder {
    private var recorder: MediaRecorder? = null

    private val folder: File get() = File(context.noBackupFilesDir, "voice").apply { mkdirs() }

    override fun permission(): MicPermission =
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
            MicPermission.Granted
        } else {
            // Android does not say "refused for good" outside an Activity. So it is always asked:
            // a phone that refused for good answers at once with no dialog, and that answer is
            // what sends him to the settings.
            MicPermission.NotAsked
        }

    override fun requestPermission(onResult: (Boolean) -> Unit) {
        val l = launcher() ?: return onResult(false)
        l.requestMicrophone(onResult)
    }

    override fun openSettings() {
        context.startActivity(
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${context.packageName}"))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        )
    }

    override fun newRecordingPath(): String = File(folder, "${UUID.randomUUID()}.m4a").absolutePath

    override fun start(path: String): Boolean {
        if (recorder != null) return false
        @Suppress("DEPRECATION")
        val r = if (Build.VERSION.SDK_INT >= 31) MediaRecorder(context) else MediaRecorder()
        return runCatching {
            r.setAudioSource(MediaRecorder.AudioSource.MIC)
            r.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
            r.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
            r.setAudioChannels(1)
            r.setAudioSamplingRate(16_000)
            r.setAudioEncodingBitRate(32_000)
            r.setOutputFile(path)
            r.prepare()
            r.start()
            recorder = r
            true
        }.getOrElse {
            runCatching { r.release() }
            false
        }
    }

    /** `maxAmplitude` is the loudest since the last call; on a log scale it reads like a meter. */
    override fun level(): Float {
        val amplitude = runCatching { recorder?.maxAmplitude ?: 0 }.getOrDefault(0)
        if (amplitude <= 0) return 0f
        val db = 20 * log10(amplitude / 32_767.0)
        return ((db + 50) / 50).toFloat().coerceIn(0f, 1f)
    }

    override fun stop(): Boolean {
        val r = recorder ?: return false
        recorder = null
        // `stop` throws when nothing was written — a recording stopped the instant it began.
        val ok = runCatching { r.stop() }.isSuccess
        runCatching { r.release() }
        return ok
    }

    override fun cancel() {
        val r = recorder ?: return
        recorder = null
        runCatching { r.stop() }
        runCatching { r.release() }
    }

    override fun read(path: String): ByteArray? = runCatching { File(path).takeIf { it.isFile }?.readBytes() }.getOrNull()

    override fun delete(path: String) {
        // Only what this class made: a note's path comes back from storage, and storage can be edited.
        val file = File(path)
        if (file.parentFile?.canonicalPath == folder.canonicalPath) file.delete()
    }

    override fun exists(path: String): Boolean = File(path).let { it.isFile && it.length() > 0 }
}
