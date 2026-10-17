package dev.luisnquin.striked

import android.app.Application
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.provider.Settings
import android.widget.RemoteViews
import com.pravera.flutter_foreground_task.FlutterForegroundTaskLifecycleListener
import com.pravera.flutter_foreground_task.FlutterForegroundTaskPlugin
import com.pravera.flutter_foreground_task.FlutterForegroundTaskStarter
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class StrikedApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        FlutterForegroundTaskPlugin.addTaskLifecycleListener(LauncherWidget.WatcherTask(this))
    }
}

class LauncherWidget : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        manager.updateAppWidget(ids, views(context))
    }

    class WatcherTask(private val context: Context) : FlutterForegroundTaskLifecycleListener {
        private var channel: MethodChannel? = null

        override fun onEngineCreate(flutterEngine: FlutterEngine?) {
            val messenger = flutterEngine?.dartExecutor?.binaryMessenger ?: return
            channel = MethodChannel(messenger, CHANNEL).also {
                it.setMethodCallHandler { call, result -> handle(context, call, result) }
            }
        }

        override fun onTaskStart(starter: FlutterForegroundTaskStarter) {}

        override fun onTaskRepeatEvent() {}

        override fun onTaskDestroy() = tally(context, null)

        override fun onEngineWillDestroy() {
            channel?.setMethodCallHandler(null)
            channel = null
        }
    }

    companion object {
        const val CHANNEL = "dev.luisnquin.striked/launcher"

        private const val OPEN = "dev.luisnquin.striked.LAUNCHER"
        private const val TARGET = "target"
        private const val AGENTS = "agents"
        private const val INPUT_BAR = "inputBar"
        private const val PLUGINS = "plugins"

        private const val PREFS = "striked.launcher"
        private const val KEY_TALLY = "tally"
        private const val KEY_BOOT = "tally_boot"
        private const val KEY_BAR = "bar"

        private var waiting: String? = null

        fun handle(context: Context, call: MethodCall, result: MethodChannel.Result) {
            when (call.method) {
                "tally" -> {
                    tally(context, call.argument<String>("line"))
                    result.success(null)
                }
                "bar" -> {
                    prefs(context).edit().putString(KEY_BAR, call.argument<String>("label")).apply()
                    redraw(context)
                    result.success(null)
                }
                "take" -> result.success(waiting.also { waiting = null })
                else -> result.notImplemented()
            }
        }

        fun opened(intent: Intent?) {
            if (intent?.action != OPEN) return
            if (intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0) return
            waiting = intent.getStringExtra(TARGET) ?: return
        }

        fun isWaiting() = waiting != null

        fun tally(context: Context, line: String?) {
            prefs(context).edit()
                .putString(KEY_TALLY, line)
                .putInt(KEY_BOOT, boot(context))
                .apply()
            redraw(context)
        }

        private fun boot(context: Context) =
            Settings.Global.getInt(context.contentResolver, Settings.Global.BOOT_COUNT, -1)

        private fun prefs(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

        private fun redraw(context: Context) {
            val manager = AppWidgetManager.getInstance(context) ?: return
            val ids = manager.getAppWidgetIds(ComponentName(context, LauncherWidget::class.java))
            if (ids.isEmpty()) return
            manager.updateAppWidget(ids, views(context))
        }

        private fun views(context: Context): RemoteViews {
            val prefs = prefs(context)
            val line = prefs.getString(KEY_TALLY, null)
                ?.takeIf { prefs.getInt(KEY_BOOT, -2) == boot(context) }
            val bar = prefs.getString(KEY_BAR, null)
            return RemoteViews(context.packageName, R.layout.launcher_widget).apply {
                setTextViewText(R.id.launcher_tally, line ?: "NOT WATCHING")
                setTextViewText(R.id.launcher_bar_label, bar ?: "NO INPUT BAR")
                setOnClickPendingIntent(R.id.launcher_tally, open(context, AGENTS))
                setOnClickPendingIntent(
                    R.id.launcher_bar,
                    open(context, if (bar == null) PLUGINS else INPUT_BAR),
                )
            }
        }

        private fun open(context: Context, target: String): PendingIntent = PendingIntent.getActivity(
            context,
            target.hashCode(),
            Intent(context, MainActivity::class.java)
                .setAction(OPEN)
                .putExtra(TARGET, target)
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }
}
