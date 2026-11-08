package dev.luisnquin.upgrade

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
import android.net.NetworkCapabilities
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.view.Surface
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.view.ViewGroup
import android.view.WindowInsets
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    // One document picker at a time.
    private var pendingDocument: MethodChannel.Result? = null
    private var pendingBytes: ByteArray? = null

    private var warm = false
    private var evicted = false

    private var dictation: Dictation? = null

    private val files by lazy { FileBridge(this) }
    private var shared: MethodChannel? = null
    private var launcher: MethodChannel? = null

    override fun provideFlutterEngine(context: Context): FlutterEngine {
        warm = UpgradeEngine.started
        return UpgradeEngine.obtain(context, flutterShellArgs.toArray())
    }

    // The Android 12+ splash fades itself out over the app window it already
    // covers, and measurement put ~130ms of the boot log under that fade.
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (secured) window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            splashScreen.setOnExitAnimationListener { view -> view.remove() }
        }
        if (intent?.action == TransferService.OPEN) TransferService.deliver("openTransfers")
        if (savedInstanceState == null) LauncherWidget.opened(intent)
        if (!warm) return
        UpgradeEngine.orientation?.let { super.setRequestedOrientation(it) }
        super.setFrameworkHandlesBack(UpgradeEngine.handlesBack)
        val replay = savedInstanceState?.getBoolean(REPLAY_TAP) ?: true
        if (replay && notificationTap(intent)) {
            flutterEngine?.activityControlSurface?.onNewIntent(intent)
        }
    }

    override fun detachFromFlutterEngine() {
        super.detachFromFlutterEngine()
        evicted = true
    }

    override fun onStart() {
        super.onStart()
        if (evicted) recreate()
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        outState.putBoolean(REPLAY_TAP, evicted)
    }

    override fun onResume() {
        super.onResume()
        hintFrameRate()
        if (SharedInbox.waiting()) shared?.invokeMethod("shared", null)
        TransferService.takeWaiting()?.let { shared?.invokeMethod(it, null) }
    }

    // The IME drops a show request from an unfocused window, and onNewIntent, onResume and
    // the first frame can all precede focus, so take waits for it and focus delivers.
    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus && LauncherWidget.isWaiting()) launcher?.invokeMethod("opened", null)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (evicted) setIntent(intent)
        if (intent.action == TransferService.OPEN) TransferService.deliver("openTransfers")
        LauncherWidget.opened(intent)
    }

    private var hinted: SurfaceView? = null

    private fun hintFrameRate() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return
        val flutterView = findViewById<ViewGroup>(FLUTTER_VIEW_ID) ?: return
        val surfaceView = (0 until flutterView.childCount)
            .map(flutterView::getChildAt)
            .filterIsInstance<SurfaceView>()
            .firstOrNull() ?: return
        if (surfaceView === hinted) return
        hinted = surfaceView
        surfaceView.holder.addCallback(object : SurfaceHolder.Callback {
            override fun surfaceCreated(holder: SurfaceHolder) = hintFrameRate(holder.surface)
            override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {}
            override fun surfaceDestroyed(holder: SurfaceHolder) {}
        })
        val surface = surfaceView.holder.surface
        if (surface.isValid) hintFrameRate(surface)
    }

    private fun hintFrameRate(surface: Surface) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            surface.setFrameRate(
                FRAME_RATE,
                Surface.FRAME_RATE_COMPATIBILITY_DEFAULT,
                Surface.CHANGE_FRAME_RATE_ONLY_IF_SEAMLESS,
            )
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            surface.setFrameRate(FRAME_RATE, Surface.FRAME_RATE_COMPATIBILITY_DEFAULT)
        }
    }

    override fun setRequestedOrientation(orientation: Int) {
        UpgradeEngine.orientation = orientation
        super.setRequestedOrientation(orientation)
    }

    override fun setFrameworkHandlesBack(frameworkHandlesBack: Boolean) {
        UpgradeEngine.handlesBack = frameworkHandlesBack
        super.setFrameworkHandlesBack(frameworkHandlesBack)
    }

    private fun notificationTap(intent: Intent) =
        intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY == 0 &&
            (intent.action == "SELECT_NOTIFICATION" || intent.action == "SELECT_FOREGROUND_NOTIFICATION")

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        MethodChannel(messenger, "dev.luisnquin.upgrade/device")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "model" -> result.success(Build.MODEL)
                    // PackageManager already knows the version name and code the
                    // apk was signed with, so no package carries them into Dart.
                    "build" -> result.success(buildInfo())
                    "saveDocument" -> saveDocument(call.argument<String>("name") ?: "upgrade.bundle",
                        call.argument<String>("mime") ?: "application/octet-stream",
                        call.argument<ByteArray>("bytes") ?: ByteArray(0),
                        result)
                    "openDocument" -> openDocument(result)
                    "ime" -> result.success(imeShown())
                    "vpn" -> result.success(vpnUp())
                    "chat" -> result.success(ChatNative.prepare(applicationContext))
                    "chatKept" -> result.success(ChatService.kept(applicationContext))
                    "keepChat" -> {
                        ChatService.keep(applicationContext, call.arguments == true)
                        result.success(null)
                    }
                    "awake" -> {
                        if (call.arguments == true) {
                            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        } else {
                            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        }
                        result.success(null)
                    }
                    "secure" -> {
                        secured = call.arguments == true
                        if (secured) {
                            window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                        } else {
                            window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        shared = MethodChannel(messenger, "dev.luisnquin.upgrade/files").also { channel ->
            channel.setMethodCallHandler(files::handle)
            SharedInbox.listener = { channel.invokeMethod("shared", null) }
            TransferService.listener = { channel.invokeMethod(it, null) }
        }

        launcher = MethodChannel(messenger, LauncherWidget.CHANNEL).also { channel ->
            channel.setMethodCallHandler { call, result ->
                if (call.method == "take" && !hasWindowFocus()) {
                    result.success(null)
                } else {
                    LauncherWidget.handle(applicationContext, call, result)
                }
            }
            channel.invokeMethod("app", null)
        }

        MethodChannel(messenger, "dev.luisnquin.upgrade/pip")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "available" -> result.success(pipAvailable())
                    "enter" -> result.success(
                        enterPip(call.argument<Int>("width"), call.argument<Int>("height")),
                    )
                    else -> result.notImplemented()
                }
            }

        MethodChannel(messenger, "dev.luisnquin.upgrade/linux")
            .setMethodCallHandler { call, result ->
                PhoneLinux.handle(this, call.method, call.arguments as? Map<*, *>, result)
            }

        MethodChannel(messenger, "dev.luisnquin.upgrade/browser")
            .setMethodCallHandler { call, result -> BrowserProxy.handle(this, call, result) }

        val speech = MethodChannel(messenger, "dev.luisnquin.upgrade/speech")
        dictation?.destroy()
        dictation = Dictation(this, speech).also { speech.setMethodCallHandler(it::handle) }

        UpgradeEngine.pip(isInPictureInPictureMode)
        UpgradeEngine.stream(applicationContext, messenger)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        super.cleanUpFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        MethodChannel(messenger, "dev.luisnquin.upgrade/device").setMethodCallHandler(null)
        MethodChannel(messenger, "dev.luisnquin.upgrade/pip").setMethodCallHandler(null)
        MethodChannel(messenger, "dev.luisnquin.upgrade/speech").setMethodCallHandler(null)
        MethodChannel(messenger, "dev.luisnquin.upgrade/linux").setMethodCallHandler(null)
        MethodChannel(messenger, "dev.luisnquin.upgrade/browser").setMethodCallHandler(null)
        shared?.setMethodCallHandler(null)
        shared = null
        SharedInbox.listener = null
        TransferService.listener = null
        launcher?.setMethodCallHandler(null)
        launcher = null
        dictation?.destroy()
        dictation = null
    }

    override fun onPause() {
        super.onPause()
        dictation?.pause()
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != RECORD_AUDIO_REQUEST) return
        dictation?.onPermission(grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED)
    }

    // Per app: a VPN that excludes this app reads as none, which is what its dials get.
    private fun vpnUp(): Boolean? {
        val connectivity = getSystemService(ConnectivityManager::class.java) ?: return null
        val network = connectivity.activeNetwork ?: return null
        val caps = connectivity.getNetworkCapabilities(network) ?: return null
        return caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
    }

    // The embedding swallows insets while it thinks an IME animation runs, and one cut short
    // leaves it swallowing; the window's own insets go to the view past that listener.
    private fun imeShown(): Boolean? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return null
        val view = findViewById<View>(FLUTTER_VIEW_ID) ?: return null
        val insets = view.rootWindowInsets ?: return null
        val shown = insets.isVisible(WindowInsets.Type.ime())
        if (!shown) view.onApplyWindowInsets(insets)
        return shown
    }

    private fun pipAvailable() = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
        packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)

    // The system will not give the window more height than the ratio asks for,
    // and clamps anything past 2.39:1.
    private fun pipParams(width: Int?, height: Int?): PictureInPictureParams {
        val builder = PictureInPictureParams.Builder()
            .setAspectRatio(pipRatio(width, height))
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setAutoEnterEnabled(false)
            builder.setSeamlessResizeEnabled(false)
        }
        return builder.build()
    }

    private fun pipRatio(width: Int?, height: Int?): Rational {
        if (width == null || height == null || width <= 0 || height <= 0) return Rational(16, 9)
        val ratio = width.toFloat() / height
        return when {
            ratio > 2.39f -> Rational(239, 100)
            ratio < 1 / 2.39f -> Rational(100, 239)
            else -> Rational(width, height)
        }
    }

    private fun enterPip(width: Int?, height: Int?): Boolean {
        if (!pipAvailable() || isInPictureInPictureMode) return false
        return enterPictureInPictureMode(pipParams(width, height))
    }

    override fun onPictureInPictureModeChanged(
        inPip: Boolean,
        newConfig: Configuration,
    ) {
        super.onPictureInPictureModeChanged(inPip, newConfig)
        UpgradeEngine.pip(inPip)
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
        if (files.onActivityResult(requestCode, resultCode, data)) return
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

// Swiping the task away used to take the engine with it, and on the Pixel 10 Pro Fold's PowerVR driver that
// Vulkan teardown can hang for good while the watcher service keeps the process alive.
internal object UpgradeEngine {
    private var engine: FlutterEngine? = null
    private var streamed = false

    var pipEvents: EventChannel.EventSink? = null
    var inPip = false
        private set
    var orientation: Int? = null
    var handlesBack = false

    val started get() = engine != null

    fun obtain(context: Context, shellArgs: Array<String>): FlutterEngine =
        engine ?: FlutterEngine(context.applicationContext, shellArgs).also { engine = it }

    fun pip(mode: Boolean) {
        if (mode == inPip) return
        inPip = mode
        pipEvents?.success(mode)
    }

    fun stream(context: Context, messenger: BinaryMessenger) {
        if (streamed) return
        streamed = true

        EventChannel(messenger, "dev.luisnquin.upgrade/pip/mode")
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
                    pipEvents = sink
                    // Replayed: a subscriber that arrives after the window did
                    // would otherwise draw the whole app into a corner tile.
                    sink.success(inPip)
                }

                override fun onCancel(arguments: Any?) {
                    pipEvents = null
                }
            })

        EventChannel(messenger, "dev.luisnquin.upgrade/device/throttle")
            .setStreamHandler(
                ThrottleStreamHandler(context, context.getSystemService(Context.POWER_SERVICE) as PowerManager),
            )

        EventChannel(messenger, "dev.luisnquin.upgrade/linux/state")
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
                    PhoneLinux.sink = sink
                    PhoneLinux.changed(context)
                }

                override fun onCancel(arguments: Any?) {
                    PhoneLinux.sink = null
                }
            })

        EventChannel(messenger, "dev.luisnquin.upgrade/device/network")
            .setStreamHandler(
                NetworkStreamHandler(
                    context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager,
                ),
            )
    }
}

private const val FRAME_RATE = 60f

private const val SAVE_DOCUMENT = 3901
private const val OPEN_DOCUMENT = 3902
private const val REPLAY_TAP = "upgrade.replayTap"

private var secured = false

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
