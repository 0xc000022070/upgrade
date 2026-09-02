package dev.luisnquin.hotline

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val power by lazy { getSystemService(Context.POWER_SERVICE) as PowerManager }

    // The Android 12+ splash fades itself out over the app window it is already
    // covering. SPEC 16c.1 gives the whole boot log 600ms, and measurement put
    // ~130ms of it under that fade, so the log was rolling where nobody could
    // read it. Dropping the splash view the moment the first frame is ready
    // hands those milliseconds back, and a hard cut is what 16c.1 asks for.
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            splashScreen.setOnExitAnimationListener { view -> view.remove() }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        MethodChannel(messenger, "dev.luisnquin.hotline/device")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "model" -> result.success(Build.MODEL)
                    else -> result.notImplemented()
                }
            }

        EventChannel(messenger, "dev.luisnquin.hotline/device/throttle")
            .setStreamHandler(ThrottleStreamHandler(this, power))
    }
}

// Battery saver and thermal pressure are two OS signals with one meaning for
// this app: stop spending frames on decoration. They are merged here rather than
// in Dart so the UI subscribes to the decision, not to the inputs. Either can
// arrive while the app is in front, and the static has to stop at that moment
// rather than at the next resume.
private class ThrottleStreamHandler(
    private val context: Context,
    private val power: PowerManager,
) : EventChannel.StreamHandler {
    private var receiver: BroadcastReceiver? = null
    private var thermal: PowerManager.OnThermalStatusChangedListener? = null
    private var events: EventChannel.EventSink? = null
    private var last: Boolean? = null

    override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
        events = sink
        // Replayed on subscribe: the app can be launched with either signal
        // already standing, and a stream that only reports changes would leave
        // it running until the first one arrived.
        emit()

        receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) = emit()
        }
        context.registerReceiver(
            receiver,
            IntentFilter(PowerManager.ACTION_POWER_SAVE_MODE_CHANGED),
        )

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            // The listener fires on the executor it is given, and an EventSink
            // may only be touched from the main thread.
            val listener = PowerManager.OnThermalStatusChangedListener { emit() }
            thermal = listener
            power.addThermalStatusListener(context.mainExecutor, listener)
        }
    }

    override fun onCancel(arguments: Any?) {
        receiver?.let { context.unregisterReceiver(it) }
        receiver = null
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            thermal?.let { power.removeThermalStatusListener(it) }
        }
        thermal = null
        events = null
        last = null
    }

    // MODERATE is the first status at which the OS is already throttling the
    // device to shed heat; LIGHT and NONE are normal running. Both listeners can
    // fire for a change that does not cross the line, so unchanged values are
    // dropped here rather than in Dart.
    private fun emit() {
        val throttled = power.isPowerSaveMode ||
            (
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q &&
                    power.currentThermalStatus >= PowerManager.THERMAL_STATUS_MODERATE
                )
        if (throttled == last) return
        last = throttled
        events?.success(throttled)
    }
}
