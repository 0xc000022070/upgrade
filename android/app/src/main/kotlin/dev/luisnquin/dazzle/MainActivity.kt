package dev.luisnquin.dazzle

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.app.PictureInPictureParams
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.util.Rational
import android.net.ConnectivityManager
import android.net.Network
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val power by lazy { getSystemService(Context.POWER_SERVICE) as PowerManager }
    private val connectivity by lazy {
        getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    }

    // One document picker at a time.
    private var pendingDocument: MethodChannel.Result? = null
    private var pendingBytes: ByteArray? = null

    private var pipEvents: EventChannel.EventSink? = null

    // The Android 12+ splash fades itself out over the app window it already
    // covers, and measurement put ~130ms of the boot log under that fade.
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            splashScreen.setOnExitAnimationListener { view -> view.remove() }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        MethodChannel(messenger, "dev.luisnquin.dazzle/device")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "model" -> result.success(Build.MODEL)
                    // PackageManager already knows the version name and code the
                    // apk was signed with, so no package carries them into Dart.
                    "build" -> result.success(buildInfo())
                    "saveDocument" -> saveDocument(call.argument<String>("name") ?: "dazzle.bundle",
                        call.argument<String>("mime") ?: "application/octet-stream",
                        call.argument<ByteArray>("bytes") ?: ByteArray(0),
                        result)
                    "openDocument" -> openDocument(result)
                    else -> result.notImplemented()
                }
            }

        MethodChannel(messenger, "dev.luisnquin.dazzle/pip")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "available" -> result.success(pipAvailable())
                    "enter" -> result.success(enterPip())
                    else -> result.notImplemented()
                }
            }

        EventChannel(messenger, "dev.luisnquin.dazzle/pip/mode")
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
                    pipEvents = sink
                    // Replayed: a subscriber that arrives after the window did
                    // would otherwise draw the whole app into a corner tile.
                    sink.success(isInPictureInPictureMode)
                }

                override fun onCancel(arguments: Any?) {
                    pipEvents = null
                }
            })

        EventChannel(messenger, "dev.luisnquin.dazzle/device/throttle")
            .setStreamHandler(ThrottleStreamHandler(this, power))

        EventChannel(messenger, "dev.luisnquin.dazzle/device/network")
            .setStreamHandler(NetworkStreamHandler(connectivity))
    }

    private fun pipAvailable() = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
        packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)

    // The system will not give the window more height than the ratio asks for,
    // and clamps anything past 2.39:1.
    private fun pipParams(): PictureInPictureParams {
        val builder = PictureInPictureParams.Builder()
            .setAspectRatio(Rational(16, 9))
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setAutoEnterEnabled(false)
            builder.setSeamlessResizeEnabled(false)
        }
        return builder.build()
    }

    private fun enterPip(): Boolean {
        if (!pipAvailable() || isInPictureInPictureMode) return false
        return enterPictureInPictureMode(pipParams())
    }

    override fun onPictureInPictureModeChanged(
        inPip: Boolean,
        newConfig: Configuration,
    ) {
        super.onPictureInPictureModeChanged(inPip, newConfig)
        pipEvents?.success(inPip)
    }

    private fun saveDocument(name: String, mime: String, bytes: ByteArray, result: MethodChannel.Result) {
        if (pendingDocument != null) {
            result.error("busy", "a document picker is already up", null)
            return
        }
        pendingDocument = result
        pendingBytes = bytes
        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = mime
            putExtra(Intent.EXTRA_TITLE, name)
        }
        startActivityForResult(intent, SAVE_DOCUMENT)
    }

    private fun openDocument(result: MethodChannel.Result) {
        if (pendingDocument != null) {
            result.error("busy", "a document picker is already up", null)
            return
        }
        pendingDocument = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
        }
        startActivityForResult(intent, OPEN_DOCUMENT)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != SAVE_DOCUMENT && requestCode != OPEN_DOCUMENT) return
        val result = pendingDocument ?: return
        val bytes = pendingBytes
        pendingDocument = null
        pendingBytes = null
        val uri: Uri? = if (resultCode == Activity.RESULT_OK) data?.data else null
        if (uri == null) {
            result.success(if (requestCode == SAVE_DOCUMENT) false else null)
            return
        }
        try {
            if (requestCode == SAVE_DOCUMENT) {
                contentResolver.openOutputStream(uri, "wt")?.use { it.write(bytes ?: ByteArray(0)) }
                    ?: throw IllegalStateException("no stream for $uri")
                result.success(true)
            } else {
                val read = contentResolver.openInputStream(uri)?.use { it.readBytes() }
                    ?: throw IllegalStateException("no stream for $uri")
                result.success(read)
            }
        } catch (e: Exception) {
            result.error("document", e.message, null)
        }
    }

    private fun buildInfo(): Map<String, Any> {
        val info = packageManager.getPackageInfo(packageName, 0)
        val code = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            info.longVersionCode
        } else {
            @Suppress("DEPRECATION")
            info.versionCode.toLong()
        }
        return mapOf("version" to (info.versionName ?: ""), "code" to code)
    }
}

private const val SAVE_DOCUMENT = 3901
private const val OPEN_DOCUMENT = 3902

// Battery saver and thermal pressure are merged here rather than in Dart, so the
// UI subscribes to the decision and not to the two inputs.
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
        // Replayed: the app can be launched with either signal already standing.
        emit()

        receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) = emit()
        }
        context.registerReceiver(
            receiver,
            IntentFilter(PowerManager.ACTION_POWER_SAVE_MODE_CHANGED),
        )

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            // An EventSink may only be touched from the main thread.
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

    // MODERATE is the first status at which the OS is already throttling to shed
    // heat. Both listeners fire for changes that do not cross the line.
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

// A handover straight from wifi to cell arrives here as a loss and an arrival
// even though the phone was never without a network. Nothing is replayed on
// subscribe: the network the phone already had is what the waiting shells failed on.
private class NetworkStreamHandler(
    private val connectivity: ConnectivityManager,
) : EventChannel.StreamHandler {
    private val main = Handler(Looper.getMainLooper())
    private var callback: ConnectivityManager.NetworkCallback? = null
    private var events: EventChannel.EventSink? = null

    override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
        events = sink
        val watcher = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) = emit(true)
            override fun onLost(network: Network) = emit(false)
        }
        callback = watcher
        connectivity.registerDefaultNetworkCallback(watcher)
    }

    override fun onCancel(arguments: Any?) {
        callback?.let { connectivity.unregisterNetworkCallback(it) }
        callback = null
        events = null
    }

    // The callback runs on a binder thread; an EventSink is main-thread only.
    private fun emit(up: Boolean) {
        main.post { events?.success(up) }
    }
}
