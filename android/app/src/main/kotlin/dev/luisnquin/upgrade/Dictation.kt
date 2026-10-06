package dev.luisnquin.upgrade

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

const val RECORD_AUDIO_REQUEST = 3903

private const val RESTART_DELAY_MS = 150L
private const val MAX_IDLE_RESTARTS = 3
private const val LEVEL_EVERY_MS = 80L

class Dictation(
    private val activity: Activity,
    private val channel: MethodChannel,
) : RecognitionListener {
    private var recognizer: SpeechRecognizer? = null
    private var onDevice = false
    private var wanted = false
    private var listening = false
    private var asking: MethodChannel.Result? = null
    private val handler = Handler(Looper.getMainLooper())
    private val restart = Runnable { if (wanted) listen() else ended() }
    private var idleRestarts = 0
    private var rebuilt = false
    private var levelAt = 0L

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> start(result)
            "stop" -> { stop(); result.success(null) }
            "cancel" -> { cancel(); result.success(null) }
            else -> result.notImplemented()
        }
    }

    private fun start(result: MethodChannel.Result) {
        if (!SpeechRecognizer.isRecognitionAvailable(activity)) {
            result.success("unavailable")
            return
        }
        if (activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            if (asking != null) {
                result.success("denied")
                return
            }
            asking = result
            activity.requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), RECORD_AUDIO_REQUEST)
            return
        }
        wanted = true
        idleRestarts = 0
        rebuilt = false
        listen()
        result.success("listening")
    }

    fun onPermission(granted: Boolean) {
        val result = asking ?: return
        asking = null
        result.success(if (granted) "granted" else "denied")
    }

    fun stop() {
        if (!wanted && !listening) return
        wanted = false
        handler.removeCallbacks(restart)
        if (listening) recognizer?.stopListening() else ended()
    }

    fun cancel() {
        wanted = false
        listening = false
        handler.removeCallbacks(restart)
        recognizer?.cancel()
    }

    fun destroy() {
        cancel()
        handler.removeCallbacksAndMessages(null)
        recognizer?.destroy()
        recognizer = null
    }

    private fun listen() {
        val current = recognizer ?: create().also { recognizer = it }
        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
            putExtra(RecognizerIntent.EXTRA_CALLING_PACKAGE, activity.packageName)
        }
        listening = true
        current.startListening(intent)
    }

    private fun create(): SpeechRecognizer {
        onDevice = Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
            SpeechRecognizer.isOnDeviceRecognitionAvailable(activity)
        val made = if (onDevice && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            SpeechRecognizer.createOnDeviceSpeechRecognizer(activity)
        } else {
            SpeechRecognizer.createSpeechRecognizer(activity)
        }
        made.setRecognitionListener(this)
        return made
    }

    // The on-device service errors on a language it has no model for instead of handing
    // over, so the default recognizer is asked, still told to prefer offline.
    private fun fallBack() {
        recognizer?.destroy()
        val made = SpeechRecognizer.createSpeechRecognizer(activity)
        made.setRecognitionListener(this)
        recognizer = made
        onDevice = false
    }

    private fun emit(type: String, text: String? = null) {
        channel.invokeMethod("event", mapOf("type" to type, "text" to text))
    }

    private fun ended() = emit("end")

    private fun resume() {
        if (!wanted) {
            ended()
            return
        }
        handler.removeCallbacks(restart)
        handler.postDelayed(restart, RESTART_DELAY_MS)
    }

    private fun rebuild() {
        recognizer?.destroy()
        recognizer = null
    }

    private fun first(results: Bundle?): String =
        results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull()?.trim() ?: ""

    override fun onPartialResults(partialResults: Bundle?) {
        val text = first(partialResults)
        if (text.isNotEmpty()) emit("partial", text)
    }

    override fun onResults(results: Bundle?) {
        listening = false
        val text = first(results)
        if (text.isNotEmpty()) {
            emit("final", text)
        } else if (wanted && ++idleRestarts >= MAX_IDLE_RESTARTS) {
            wanted = false
        }
        resume()
    }

    override fun onError(error: Int) {
        listening = false
        val missingLanguage = Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
            (error == SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED ||
                error == SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE)
        val silent = error == SpeechRecognizer.ERROR_NO_MATCH ||
            error == SpeechRecognizer.ERROR_SPEECH_TIMEOUT
        val broken = error == SpeechRecognizer.ERROR_CLIENT ||
            error == SpeechRecognizer.ERROR_RECOGNIZER_BUSY
        when {
            !wanted && (silent || broken) -> ended()
            missingLanguage && onDevice -> {
                fallBack()
                resume()
            }
            silent && ++idleRestarts < MAX_IDLE_RESTARTS -> resume()
            silent -> {
                wanted = false
                ended()
            }
            broken && !rebuilt -> {
                rebuilt = true
                rebuild()
                resume()
            }
            error == SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> {
                wanted = false
                emit("failed", "denied")
                ended()
            }
            else -> {
                wanted = false
                emit("failed", error.toString())
                ended()
            }
        }
    }

    override fun onReadyForSpeech(params: Bundle?) {}
    override fun onBeginningOfSpeech() {
        idleRestarts = 0
        rebuilt = false
    }

    // rmsdB runs roughly -2 (silence) to 10 (a raised voice).
    override fun onRmsChanged(rmsdB: Float) {
        val now = SystemClock.uptimeMillis()
        if (now - levelAt < LEVEL_EVERY_MS) return
        levelAt = now
        val level = ((rmsdB + 2f) / 12f).coerceIn(0f, 1f)
        channel.invokeMethod("event", mapOf("type" to "level", "level" to level.toDouble()))
    }
    override fun onBufferReceived(buffer: ByteArray?) {}
    override fun onEndOfSpeech() {}
    override fun onEvent(eventType: Int, params: Bundle?) {}
}
