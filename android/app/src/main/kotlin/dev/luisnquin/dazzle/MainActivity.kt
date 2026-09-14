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

    // One document picker at a time: the Dart call waiting on it, and for a
    // save, the bytes to write once the user has chosen where.
    private var pendingDocument: MethodChannel.Result? = null
    private var pendingBytes: ByteArray? = null

    // Picture-in-picture. The window the system parks in the corner is this
    // activity's own surface, so there is nothing to mirror and nothing to
    // render twice: Dart is told the mode changed and draws a panel sized for
    // it.
    private var pipEvents: EventChannel.EventSink? = null

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

        MethodChannel(messenger, "dev.luisnquin.dazzle/device")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "model" -> result.success(Build.MODEL)
                    // SPEC 39.16's build line. PackageManager already knows the
                    // version name and code the apk was signed with, so no
                    // package carries them into Dart.
                    "build" -> result.success(buildInfo())
                    // SPEC 39.93's bundle goes through the system picker, so
                    // the app never decides where the file lives.
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

    // Wide and short, because what the window carries is lines of text and the
    // system will not give it more height than the ratio asks for. The system
    // clamps anything past 2.39:1, which this is well inside.
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
            // Dismissed: nothing happened, and Dart says nothing about it.
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

// The default network is the one the app's sockets are on, so a handover
// straight from wifi to cell arrives here as a loss and an arrival even though
// the phone was never without a network — which is exactly the case a shell
// whose reconnect schedule is spent has to be dialled again for.
//
// Nothing is replayed on subscribe: the network the phone already had is what
// the waiting shells failed on.
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

    // The callback runs on a binder thread and an EventSink may only be touched
    // from the main one.
    private fun emit(up: Boolean) {
        main.post { events?.success(up) }
    }
}
