package dev.luisnquin.striked

import android.annotation.SuppressLint
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import kotlin.math.log10
import kotlin.math.sqrt

const val RECORD_RATE = 16000

private const val MAX_RECORD_SECONDS = 120
private const val RECORD_LEVEL_EVERY_MS = 80L

class Recorder(private val channel: MethodChannel) {
    private val main = Handler(Looper.getMainLooper())
    private var record: AudioRecord? = null
    private var reader: Thread? = null
    private val pcm = ByteArrayOutputStream()

    @Volatile private var running = false

    val recording get() = record != null

    @SuppressLint("MissingPermission")
    fun start(): Boolean {
        if (record != null) return true
        val minimum = AudioRecord.getMinBufferSize(
            RECORD_RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
        )
        if (minimum <= 0) return false
        val made = try {
            AudioRecord(
                MediaRecorder.AudioSource.VOICE_RECOGNITION,
                RECORD_RATE,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                minimum * 4,
            )
        } catch (_: IllegalArgumentException) {
            // ignored: a rejected recorder answers unavailable to Dart.
            return false
        }
        if (made.state != AudioRecord.STATE_INITIALIZED) {
            made.release()
            return false
        }
        synchronized(pcm) { pcm.reset() }
        try {
            made.startRecording()
        } catch (_: IllegalStateException) {
            made.release()
            return false
        }
        record = made
        running = true
        reader = Thread({ read(made, minimum) }, "striked-recorder").also { it.start() }
        return true
    }

    fun finish(): ByteArray? {
        if (!halt()) return null
        return synchronized(pcm) { pcm.toByteArray().also { pcm.reset() } }
    }

    fun discard() {
        halt()
        synchronized(pcm) { pcm.reset() }
    }

    fun cut() {
        if (record == null || !running) return
        running = false
        emit(mapOf("type" to "cut"))
    }

    private fun halt(): Boolean {
        val made = record ?: return false
        running = false
        reader?.join()
        reader = null
        try {
            made.stop()
        } catch (_: IllegalStateException) {
            // ignored: a recorder that never started has nothing to stop.
        }
        made.release()
        record = null
        return true
    }

    private fun read(made: AudioRecord, size: Int) {
        val buffer = ShortArray(size / 2)
        val bytes = ByteArray(buffer.size * 2)
        val cap = MAX_RECORD_SECONDS * RECORD_RATE * 2
        var levelAt = 0L
        while (running) {
            val count = made.read(buffer, 0, buffer.size)
            if (count <= 0) continue
            var sum = 0.0
            for (i in 0 until count) {
                val sample = buffer[i].toInt()
                bytes[2 * i] = (sample and 0xff).toByte()
                bytes[2 * i + 1] = (sample shr 8 and 0xff).toByte()
                sum += sample.toDouble() * sample
            }
            val full = synchronized(pcm) {
                pcm.write(bytes, 0, count * 2)
                pcm.size() >= cap
            }
            val now = SystemClock.uptimeMillis()
            if (now - levelAt >= RECORD_LEVEL_EVERY_MS) {
                levelAt = now
                emit(mapOf("type" to "level", "level" to level(sum / count)))
            }
            if (full) main.post { cut() }
        }
    }

    private fun level(meanSquare: Double): Double {
        val rms = sqrt(meanSquare) / 32768.0
        val db = if (rms > 0) 20 * log10(rms) else -100.0
        return ((db + 60) / 45).coerceIn(0.0, 1.0)
    }

    private fun emit(event: Map<String, Any>) {
        main.post { channel.invokeMethod("event", event) }
    }
}
