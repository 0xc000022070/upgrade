package dev.luisnquin.striked

import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.view.View
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.android.FlutterActivityLaunchConfigs.BackgroundMode
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class ComposeActivity : FlutterActivity() {
    private var launcher: MethodChannel? = null

    override fun provideFlutterEngine(context: Context): FlutterEngine =
        StrikedEngine.obtain(context, flutterShellArgs.toArray())

    override fun getBackgroundMode() = BackgroundMode.transparent

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        LauncherWidget.opened(intent)
        super.setFrameworkHandlesBack(true)
        view()?.alpha = 0f
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        LauncherWidget.opened(intent)
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus && LauncherWidget.isWaiting()) launcher?.invokeMethod("opened", null)
    }

    override fun onStop() {
        super.onStop()
        if (!isFinishing) finish()
    }

    override fun detachFromFlutterEngine() {
        super.detachFromFlutterEngine()
        finish()
    }

    // A translucent window that asks for an orientation is refused on Android 8.
    override fun setRequestedOrientation(orientation: Int) {}

    override fun setFrameworkHandlesBack(frameworkHandlesBack: Boolean) {
        super.setFrameworkHandlesBack(true)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        launcher = MethodChannel(messenger, LauncherWidget.CHANNEL).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "take" -> if (hasWindowFocus()) {
                        LauncherWidget.handle(applicationContext, call, result)
                    } else {
                        result.success(null)
                    }
                    "composeShown" -> {
                        view()?.alpha = 1f
                        result.success(null)
                    }
                    "closeCompose" -> {
                        view()?.alpha = 0f
                        finish()
                        @Suppress("DEPRECATION")
                        overridePendingTransition(0, 0)
                        result.success(null)
                    }
                    "openApp" -> {
                        startActivity(
                            LauncherWidget.openIntent(this, call.argument<String>("target") ?: LauncherWidget.COMPOSE),
                        )
                        finish()
                        result.success(null)
                    }
                    else -> LauncherWidget.handle(applicationContext, call, result)
                }
            }
        }
        StrikedEngine.stream(applicationContext, messenger)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        launcher?.invokeMethod("composeGone", null)
        launcher?.setMethodCallHandler(null)
        launcher = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    private fun view() = findViewById<View>(FLUTTER_VIEW_ID)
}
