package dev.luisnquin.upgrade

import android.app.Activity
import android.app.Application
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.text.SpannableString
import android.text.Spanned
import android.text.style.ForegroundColorSpan
import android.util.SizeF
import android.view.View
import android.widget.RemoteViews
import android.widget.RemoteViewsService
import com.pravera.flutter_foreground_task.FlutterForegroundTaskLifecycleListener
import com.pravera.flutter_foreground_task.FlutterForegroundTaskPlugin
import com.pravera.flutter_foreground_task.FlutterForegroundTaskStarter
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale
import kotlin.math.roundToInt

class UpgradeApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        FlutterForegroundTaskPlugin.addTaskLifecycleListener(LauncherWidget.WatcherTask(this))
    }
}

class LauncherWidget : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        manager.updateAppWidget(ids, barViews(context))
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

        override fun onTaskDestroy() = dropWatcher(context)

        override fun onEngineWillDestroy() {
            channel?.setMethodCallHandler(null)
            channel = null
        }
    }

    companion object {
        const val CHANNEL = "dev.luisnquin.upgrade/launcher"

        const val OPEN = "dev.luisnquin.upgrade.LAUNCHER"
        const val TARGET = "target"
        private const val SEND = "send"
        private const val HOME = "home"
        private const val AGENTS = "agents"
        const val INPUT_BAR = "inputBar"
        private const val PLUGINS = "plugins"
        const val SHEET = "sheet"
        const val BAR_SHEET = "barSheet"
        const val COMPOSE = "compose"
        private const val RUN = "run"
        private const val SENT = "sent"

        private const val PREFS = "upgrade.launcher"
        private const val KEY_TALLY = "tally"
        private const val KEY_TALLY_BOOT = "tally_boot"
        private const val KEY_BAR = "bar"
        private const val KEY_TARGET = "target"
        private const val KEY_TARGET_DETAIL = "target_detail"
        private const val KEY_SENDS = "sends"
        private const val KEY_LIVE = "live"
        private const val KEY_LIVE_BOOT = "live_boot"
        private const val KEY_USAGE = "usage"

        private const val KEPT_SENDS = 10
        private const val SEND_LIST_HEIGHT = 160f
        private const val USAGE_CARD_ROW = 80f
        private const val USAGE_FRAME = 32f
        private const val USAGE_PAIR_WIDTH = 400f
        private const val USAGE_COMPACT_PAIR_WIDTH = 300f
        private const val USAGE_CARD_ROWS = 3
        private const val USAGE_WINDOWS = 3
        private const val USAGE_CELLS = 10
        private const val USAGE_BAR_WIDTH = 100f
        private const val USAGE_BAR_HEIGHT = 8f
        private const val USAGE_EVEN_DAY = 100 / 7.0

        private var waiting: Map<String, String?>? = null

        fun handle(context: Context, call: MethodCall, result: MethodChannel.Result) {
            when (call.method) {
                "tally" -> {
                    val tally = call.argument<Int>("blocked")?.let { blocked ->
                        JSONObject().put("blocked", blocked).put("working", call.argument<Int>("working") ?: 0)
                    }
                    writeTally(context, tally)
                    result.success(null)
                }
                "bar" -> {
                    prefs(context).edit().putString(KEY_BAR, call.argument<String>("label")).apply()
                    redraw(context)
                    result.success(null)
                }
                "target" -> {
                    prefs(context).edit()
                        .putString(KEY_TARGET, call.argument<String>("directory"))
                        .putString(KEY_TARGET_DETAIL, call.argument<String>("detail"))
                        .apply()
                    redraw(context)
                    result.success(null)
                }
                "send" -> {
                    putSend(context, JSONObject(call.arguments as Map<*, *>))
                    result.success(null)
                }
                "settle" -> {
                    settle(context, call.argument<List<String>>("running").orEmpty().toSet())
                    result.success(null)
                }
                "sends" -> result.success(openSends(context))
                "live" -> {
                    writeLive(context, call.argument<Map<String, Any?>>("states")?.let { JSONObject(it) })
                    result.success(null)
                }
                "usage" -> {
                    val accounts = call.argument<List<Any?>>("accounts")?.let { JSONArray(it).toString() }
                    prefs(context).edit().putString(KEY_USAGE, accounts).apply()
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
            val target = intent.getStringExtra(TARGET) ?: return
            waiting = mapOf(TARGET to target, SEND to intent.getStringExtra(SEND))
        }

        fun isWaiting() = waiting != null

        fun openIntent(context: Context, target: String): Intent =
            Intent(context, MainActivity::class.java)
                .setAction(OPEN)
                .putExtra(TARGET, target)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)

        fun dropWatcher(context: Context) {
            prefs(context).edit().remove(KEY_TALLY).remove(KEY_LIVE).apply()
            redraw(context)
        }

        private fun writeTally(context: Context, tally: JSONObject?) {
            prefs(context).edit()
                .putString(KEY_TALLY, tally?.toString())
                .putInt(KEY_TALLY_BOOT, boot(context))
                .apply()
            redraw(context)
        }

        private fun writeLive(context: Context, live: JSONObject?) {
            prefs(context).edit()
                .putString(KEY_LIVE, live?.toString())
                .putInt(KEY_LIVE_BOOT, boot(context))
                .apply()
            redraw(context)
        }

        private fun putSend(context: Context, row: JSONObject) {
            val id = row.optString("id")
            if (id.isEmpty()) return
            val rows = sends(context).filter { it.optString("id") != id }.toMutableList()
            rows.add(row)
            rows.sortByDescending { it.optLong("at") }
            storeSends(context, rows.take(KEPT_SENDS))
        }

        private fun settle(context: Context, running: Set<String>) {
            val rows = sends(context)
            var moved = false
            for (row in rows) {
                if (row.optString("state") != "SENDING" || row.optString("id") in running) continue
                row.put("state", "FAILED").put("reason", "INTERRUPTED")
                moved = true
            }
            if (moved) storeSends(context, rows)
        }

        private fun openSends(context: Context): List<Map<String, Any?>> = sends(context)
            .filter { it.optString("state") == "SENT" && it.has("pane") && it.has("host") }
            .map { row ->
                mapOf(
                    "id" to row.optString("id"),
                    "host" to row.optString("host"),
                    "session" to row.optString("session").ifEmpty { null },
                    "pane" to row.optString("pane"),
                )
            }

        private fun storeSends(context: Context, rows: List<JSONObject>) {
            prefs(context).edit().putString(KEY_SENDS, JSONArray(rows).toString()).apply()
            redraw(context)
        }

        private fun sends(context: Context): List<JSONObject> {
            val array = try {
                JSONArray(prefs(context).getString(KEY_SENDS, null) ?: return emptyList())
            } catch (_: org.json.JSONException) {
                // ignored: the app rewrites the rows on its next send, so a corrupt value only empties the list.
                return emptyList()
            }
            return (0 until array.length()).mapNotNull { array.optJSONObject(it) }
        }

        private fun live(context: Context): JSONObject {
            val prefs = prefs(context)
            if (prefs.getInt(KEY_LIVE_BOOT, -2) != boot(context)) return JSONObject()
            return try {
                JSONObject(prefs.getString(KEY_LIVE, null) ?: return JSONObject())
            } catch (_: org.json.JSONException) {
                // ignored: the watcher rewrites live states on its next report; until then none are drawn.
                JSONObject()
            }
        }

        private fun tally(context: Context): JSONObject? {
            val prefs = prefs(context)
            if (prefs.getInt(KEY_TALLY_BOOT, -2) != boot(context)) return null
            return try {
                JSONObject(prefs.getString(KEY_TALLY, null) ?: return null)
            } catch (_: org.json.JSONException) {
                // ignored: the watcher rewrites the tally on its next report; until then the row stays hidden.
                null
            }
        }

        private fun boot(context: Context) =
            Settings.Global.getInt(context.contentResolver, Settings.Global.BOOT_COUNT, -1)

        private fun prefs(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

        fun redraw(context: Context) {
            val manager = AppWidgetManager.getInstance(context) ?: return
            val bars = manager.getAppWidgetIds(ComponentName(context, LauncherWidget::class.java))
            if (bars.isNotEmpty()) manager.updateAppWidget(bars, barViews(context))
            for (id in manager.getAppWidgetIds(ComponentName(context, UsageWidget::class.java))) {
                manager.updateAppWidget(id, usageViews(context, id))
            }
            val sends = manager.getAppWidgetIds(ComponentName(context, SendWidget::class.java))
            if (sends.isEmpty()) return
            for (id in sends) manager.updateAppWidget(id, sendViews(context, id))
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
                @Suppress("DEPRECATION")
                manager.notifyAppWidgetViewDataChanged(sends, R.id.send_rows)
            }
        }

        private fun barViews(context: Context): RemoteViews {
            val bar = prefs(context).getString(KEY_BAR, null)
            return RemoteViews(context.packageName, R.layout.launcher_widget).apply {
                setTextViewText(R.id.launcher_bar_label, bar ?: "NO INPUT BAR")
                setOnClickPendingIntent(
                    R.id.launcher_bar,
                    if (bar == null) open(context, PLUGINS) else composeDoor(context, BAR_SHEET),
                )
            }
        }

        fun sendViews(context: Context, widgetId: Int): RemoteViews =
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
                sendViews(context, widgetId, widgetSize(context, widgetId).height >= SEND_LIST_HEIGHT)
            } else {
                RemoteViews(
                    mapOf(
                        SizeF(0f, 0f) to sendViews(context, widgetId, false),
                        SizeF(0f, SEND_LIST_HEIGHT) to sendViews(context, widgetId, true),
                    ),
                )
            }

        // Some launchers report these sizes in pixels; a width past the screen's is taken as one.
        private fun widgetSize(context: Context, widgetId: Int): SizeF {
            val options = AppWidgetManager.getInstance(context).getAppWidgetOptions(widgetId)
            val config = context.resources.configuration
            val landscape = config.orientation == Configuration.ORIENTATION_LANDSCAPE
            val sizes = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                @Suppress("DEPRECATION")
                options.getParcelableArrayList<SizeF>(AppWidgetManager.OPTION_APPWIDGET_SIZES).orEmpty()
            } else {
                emptyList()
            }
            val size = if (landscape) sizes.maxByOrNull { it.width } else sizes.minByOrNull { it.width }
            val width = size?.width ?: options.getInt(
                if (landscape) AppWidgetManager.OPTION_APPWIDGET_MAX_WIDTH else AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH,
            ).toFloat()
            val height = size?.height ?: options.getInt(
                if (landscape) AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT else AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT,
            ).toFloat()
            val density = context.resources.displayMetrics.density
            return if (width > config.screenWidthDp) SizeF(width / density, height / density) else SizeF(width, height)
        }

        private fun sendViews(context: Context, widgetId: Int, list: Boolean): RemoteViews {
            val target = prefs(context).getString(KEY_TARGET, null)
            val detail = prefs(context).getString(KEY_TARGET_DETAIL, null)
            val views = RemoteViews(context.packageName, R.layout.send_widget).apply {
                setTextViewText(R.id.send_target, target ?: "NO TARGET")
                setTextViewText(R.id.send_target_detail, detail ?: "")
                setViewVisibility(R.id.send_target_detail, if (target == null || detail == null) View.GONE else View.VISIBLE)
                setOnClickPendingIntent(R.id.send_input, composeDoor(context))
            }
            if (!list) return views
            val tally = tallyText(context, tally(context))
            return views.apply {
                setViewVisibility(R.id.send_more, View.VISIBLE)
                setViewVisibility(R.id.send_tally, if (tally == null) View.GONE else View.VISIBLE)
                setTextViewText(R.id.send_tally, tally ?: "")
                setOnClickPendingIntent(R.id.send_tally, open(context, AGENTS))
                setPendingIntentTemplate(R.id.send_rows, rowTemplate(context))
                setEmptyView(R.id.send_rows, R.id.send_empty)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    val live = live(context)
                    val items = RemoteViews.RemoteCollectionItems.Builder()
                        .setHasStableIds(true)
                        .setViewTypeCount(1)
                    for (row in sends(context)) {
                        items.addItem(row.optString("id").hashCode().toLong(), rowViews(context, row, live))
                    }
                    setRemoteAdapter(R.id.send_rows, items.build())
                } else {
                    val service = Intent(context, SendRowsService::class.java)
                        .putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, widgetId)
                    service.data = Uri.parse(service.toUri(Intent.URI_INTENT_SCHEME))
                    @Suppress("DEPRECATION")
                    setRemoteAdapter(R.id.send_rows, service)
                }
            }
        }

        private fun tallyText(context: Context, tally: JSONObject?): CharSequence? {
            val blocked = tally?.optInt("blocked") ?: 0
            val working = tally?.optInt("working") ?: 0
            if (blocked <= 0 && working <= 0) return null
            val head = if (blocked > 0) "$blocked BLOCKED" else ""
            val text = listOf(head, if (working > 0) "$working WORKING" else "")
                .filter { it.isNotEmpty() }
                .joinToString(" · ")
            return SpannableString(text).apply {
                if (head.isNotEmpty()) {
                    setSpan(
                        ForegroundColorSpan(context.getColor(R.color.launcher_danger)),
                        0,
                        head.length,
                        Spanned.SPAN_EXCLUSIVE_EXCLUSIVE,
                    )
                }
            }
        }

        fun rowViews(context: Context, row: JSONObject, live: JSONObject): RemoteViews {
            val state = row.optString("state")
            val known = if (state == "SENT") live.optJSONObject(row.optString("id")) else null
            val target = row.optString("target")
            val (label, colour) = when {
                state == "SENDING" -> "SENDING" to R.color.launcher_dim
                state == "FAILED" -> "FAILED" to R.color.launcher_danger
                known != null -> known.optString("state").let { word ->
                    word to if (known.optBoolean("dim")) R.color.launcher_disabled else stateColour(word)
                }
                else -> "SENT" to R.color.launcher_ink
            }
            val line = when {
                state == "FAILED" -> listOf(row.optString("reason"), target)
                    .filter { it.isNotEmpty() }
                    .joinToString(" · ")
                else -> known?.optString("line")?.takeIf { it.isNotEmpty() } ?: target
            }
            val tap = if (state == "SENDING" || state == "FAILED") SENT else RUN
            return RemoteViews(context.packageName, R.layout.send_row).apply {
                setTextViewText(R.id.send_row_state, label)
                setTextColor(R.id.send_row_state, context.getColor(colour))
                setTextViewText(R.id.send_row_title, row.optString("title"))
                setTextViewText(R.id.send_row_time, clock(row.optLong("at")))
                setTextViewText(R.id.send_row_line, line)
                setOnClickFillInIntent(
                    R.id.send_row,
                    Intent().putExtra(TARGET, tap).putExtra(SEND, row.optString("id")),
                )
            }
        }

        fun rows(context: Context): Pair<List<JSONObject>, JSONObject> = sends(context) to live(context)

        private fun stateColour(word: String) = when (word) {
            "WORKING" -> R.color.launcher_warning
            "BLOCKED" -> R.color.launcher_danger
            "DONE" -> R.color.launcher_ink
            else -> R.color.launcher_dim
        }

        // The options can describe the other display of a foldable, so from Android 12 the launcher picks the
        // layout. Breakpoints form a grid, so the nearest one that fits is the one just below the drawn size.
        fun usageViews(context: Context, widgetId: Int): RemoteViews {
            val accounts = usage(context)
            val now = System.currentTimeMillis()
            val bars = HashMap<JSONObject, Bitmap>()
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
                return usageViews(context, widgetSize(context, widgetId), accounts, now, bars)
            }
            val widths = listOf(0f, USAGE_COMPACT_PAIR_WIDTH, USAGE_PAIR_WIDTH)
            val row = usageCardRow(context)
            val heights = listOf(0f) + (1..USAGE_CARD_ROWS).map { USAGE_FRAME + it * row }
            val sizes = widths.flatMap { width -> heights.map { SizeF(width, it) } }
            return RemoteViews(sizes.associateWith { usageViews(context, it, accounts, now, bars) })
        }

        private fun usageViews(
            context: Context,
            size: SizeF,
            accounts: List<JSONObject>,
            now: Long,
            bars: MutableMap<JSONObject, Bitmap>,
        ): RemoteViews {
            val row = usageCardRow(context)
            val cards = size.height >= USAGE_FRAME + row
            val columns = if (size.width >= if (cards) USAGE_PAIR_WIDTH else USAGE_COMPACT_PAIR_WIDTH) 2 else 1
            return RemoteViews(
                context.packageName,
                if (cards) R.layout.usage_widget_tall else R.layout.usage_widget,
            ).apply {
                removeAllViews(R.id.usage_rows)
                setViewVisibility(R.id.usage_empty, if (accounts.isEmpty()) View.VISIBLE else View.GONE)
                setViewVisibility(R.id.usage_rows, if (accounts.isEmpty()) View.GONE else View.VISIBLE)
                val rows = if (cards) ((size.height - USAGE_FRAME) / row).toInt().coerceAtLeast(1) else 1
                for (pair in accounts.take(rows * columns).chunked(columns)) {
                    addView(R.id.usage_rows, usagePair(context, pair, now, cards, bars))
                }
                setOnClickPendingIntent(R.id.usage_field, open(context, HOME))
            }
        }

        // A card is mostly text, so its height follows the font scale; under it the WEEK line clips.
        private fun usageCardRow(context: Context): Float =
            USAGE_CARD_ROW * context.resources.configuration.fontScale.coerceAtLeast(1f)

        private fun usage(context: Context): List<JSONObject> {
            val array = try {
                JSONArray(prefs(context).getString(KEY_USAGE, null) ?: return emptyList())
            } catch (_: org.json.JSONException) {
                // ignored: the app rewrites usage on its next read; until then none is drawn.
                return emptyList()
            }
            return (0 until array.length()).mapNotNull { array.optJSONObject(it) }
        }

        private fun usageWindows(account: JSONObject): List<JSONObject> {
            val windows = account.optJSONArray("windows") ?: return emptyList()
            return (0 until windows.length()).mapNotNull { windows.optJSONObject(it) }.take(USAGE_WINDOWS)
        }

        private fun usagePair(
            context: Context,
            accounts: List<JSONObject>,
            now: Long,
            card: Boolean,
            bars: MutableMap<JSONObject, Bitmap>,
        ): RemoteViews =
            RemoteViews(context.packageName, R.layout.usage_pair).apply {
                for ((index, account) in accounts.withIndex()) {
                    if (index > 0) addView(R.id.usage_pair, RemoteViews(context.packageName, R.layout.usage_divider))
                    addView(R.id.usage_pair, usageAccount(context, account, now, card, bars))
                }
            }

        private fun usageAccount(
            context: Context,
            account: JSONObject,
            now: Long,
            card: Boolean,
            bars: MutableMap<JSONObject, Bitmap>,
        ): RemoteViews {
            val windows = usageWindows(account)
            val captured = account.optLong("captured", 0L)
            val brand = brandColour(account.optString("agent"))
            val mark = when (account.optString("agent")) {
                "codex" -> R.drawable.agent_codex
                "claude" -> R.drawable.agent_claude
                else -> null
            }
            return RemoteViews(context.packageName, R.layout.usage_account).apply {
                if (mark == null) {
                    setViewVisibility(R.id.usage_mark, View.GONE)
                } else {
                    setImageViewResource(R.id.usage_mark, mark)
                    setInt(R.id.usage_mark, "setColorFilter", context.getColor(brand ?: R.color.launcher_ink))
                }
                if (!card) {
                    setTextViewText(R.id.usage_name, sharesLine(context, windows, now, brand))
                    return@apply
                }
                setTextViewText(R.id.usage_name, account.optString("name"))
                if (captured > 0) {
                    setViewVisibility(R.id.usage_age, View.VISIBLE)
                    setTextViewText(R.id.usage_age, clock(captured))
                }
                daysLine(context, account, brand)?.let { line ->
                    addView(
                        R.id.usage_lines,
                        RemoteViews(context.packageName, R.layout.usage_line).apply {
                            setTextViewText(R.id.usage_line, line)
                        },
                    )
                }
                for (window in windows) addView(R.id.usage_lines, windowRow(context, window, now, brand, bars))
            }
        }

        /** The app counts the days at a midnight it stamps; past the next one its today is yesterday. */
        private fun daysLine(context: Context, account: JSONObject, brand: Int?): CharSequence? {
            val midnight = Calendar.getInstance().apply {
                set(Calendar.HOUR_OF_DAY, 0)
                set(Calendar.MINUTE, 0)
                set(Calendar.SECOND, 0)
                set(Calendar.MILLISECOND, 0)
            }
            val day = account.optLong("day", 0L)
            val today = if (account.has("today")) account.optInt("today") else null
            val yesterday = if (account.has("yesterday")) account.optInt("yesterday") else null
            val (shown, before) = when (day) {
                midnight.timeInMillis -> today to yesterday
                midnight.apply { add(Calendar.DAY_OF_YEAR, -1) }.timeInMillis -> null to today
                else -> return null
            }
            if (shown == null && before == null) return null
            val line = android.text.SpannableStringBuilder()
            for ((label, share) in listOf("TODAY" to shown, "YDAY" to before)) {
                if (line.isNotEmpty()) line.append("  ")
                line.append("$label ")
                val start = line.length
                line.append(share?.let { "$it%" } ?: "—")
                val colour = when {
                    share == null -> R.color.launcher_disabled
                    share > USAGE_EVEN_DAY -> R.color.launcher_warning
                    else -> brand ?: R.color.launcher_accent
                }
                line.setSpan(ForegroundColorSpan(context.getColor(colour)), start, line.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            }
            return line
        }

        private fun sharesLine(context: Context, windows: List<JSONObject>, now: Long, brand: Int?): CharSequence {
            val line = android.text.SpannableStringBuilder()
            for (window in windows) {
                if (line.isNotEmpty()) line.append("  ")
                line.append("${window.optString("label")} ")
                val start = line.length
                line.append("${window.optInt("used")}%")
                line.setSpan(
                    ForegroundColorSpan(context.getColor(windowColour(window, now, brand))),
                    start,
                    line.length,
                    Spanned.SPAN_EXCLUSIVE_EXCLUSIVE,
                )
            }
            return line
        }

        private fun windowRow(
            context: Context,
            window: JSONObject,
            now: Long,
            brand: Int?,
            bars: MutableMap<JSONObject, Bitmap>,
        ): RemoteViews {
            val colour = context.getColor(windowColour(window, now, brand))
            val resets = window.optLong("resets", 0L)
            return RemoteViews(context.packageName, R.layout.usage_window).apply {
                setTextViewText(R.id.usage_window_label, window.optString("label"))
                setImageViewBitmap(R.id.usage_window_bar, bars.getOrPut(window) { cellsBitmap(context, window, now, colour) })
                setTextViewText(R.id.usage_window_share, "${window.optInt("used")}%")
                setTextColor(R.id.usage_window_share, colour)
                setTextViewText(R.id.usage_window_reset, if (resets > 0) "↻ ${clock(resets)}" else "")
            }
        }

        private fun cellsBitmap(context: Context, window: JSONObject, now: Long, colour: Int): Bitmap {
            val density = context.resources.displayMetrics.density
            val width = (USAGE_BAR_WIDTH * density).roundToInt()
            val height = (USAGE_BAR_HEIGHT * density).roundToInt()
            val gap = 2 * density
            val cell = (width - gap * (USAGE_CELLS - 1)) / USAGE_CELLS
            val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(bitmap)
            val paint = Paint()
            val lit = window.optDouble("share", window.optInt("used").toDouble()).coerceIn(0.0, 100.0) / 100 * USAGE_CELLS
            for (i in 0 until USAGE_CELLS) {
                val left = i * (cell + gap)
                paint.color = context.getColor(R.color.launcher_border)
                canvas.drawRect(left, 0f, left + cell, height.toFloat(), paint)
                val share = (lit - i).coerceIn(0.0, 1.0)
                if (share > 0) {
                    paint.color = colour
                    paint.alpha = (255 * maxOf(share, 0.35)).roundToInt()
                    canvas.drawRect(left, 0f, left + cell, height.toFloat(), paint)
                }
            }
            pace(window, now)?.let { pace ->
                val x = (width * pace).coerceIn(density, width - density)
                paint.color = context.getColor(R.color.launcher_ink)
                canvas.drawRect(x - density, 0f, x + density, height.toFloat(), paint)
            }
            return bitmap
        }

        private fun brandColour(agent: String): Int? = when (agent) {
            "codex" -> R.color.launcher_codex
            "claude" -> R.color.launcher_claude
            else -> null
        }

        private fun pace(window: JSONObject, now: Long): Float? {
            val resets = window.optLong("resets", 0L)
            val minutes = window.optLong("minutes", 0L)
            if (resets <= 0 || minutes <= 0) return null
            return (1f - (resets - now) / (minutes * 60_000f)).coerceIn(0f, 1f)
        }

        private fun windowColour(window: JSONObject, now: Long, brand: Int?): Int {
            val resets = window.optLong("resets", 0L)
            val used = window.optInt("used")
            val pace = pace(window, now)
            return when {
                resets in 1 until now -> R.color.launcher_disabled
                window.optBoolean("hit") || used >= 90 -> R.color.launcher_danger
                brand != null -> brand
                pace != null && window.optDouble("share", used.toDouble()) / 100 > pace + 0.1 -> R.color.launcher_warning
                else -> R.color.launcher_accent
            }
        }

        private fun clock(at: Long): String {
            val then = Calendar.getInstance().apply { timeInMillis = at }
            val now = Calendar.getInstance()
            val today = then.get(Calendar.YEAR) == now.get(Calendar.YEAR) &&
                then.get(Calendar.DAY_OF_YEAR) == now.get(Calendar.DAY_OF_YEAR)
            val pattern = if (today) "HH:mm" else "MMM d"
            return SimpleDateFormat(pattern, Locale.US).format(Date(at)).uppercase(Locale.US)
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

        private fun composeDoor(context: Context, target: String = SHEET): PendingIntent = PendingIntent.getActivity(
            context,
            target.hashCode(),
            Intent(context, ComposeDoor::class.java).putExtra(TARGET, target),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        private fun rowTemplate(context: Context): PendingIntent = PendingIntent.getActivity(
            context,
            RUN.hashCode(),
            Intent(context, MainActivity::class.java)
                .setAction(OPEN)
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE else 0,
        )
    }
}

class SendWidget : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        for (id in ids) manager.updateAppWidget(id, LauncherWidget.sendViews(context, id))
    }

    override fun onAppWidgetOptionsChanged(context: Context, manager: AppWidgetManager, id: Int, options: Bundle) {
        manager.updateAppWidget(id, LauncherWidget.sendViews(context, id))
    }
}

class UsageWidget : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        for (id in ids) manager.updateAppWidget(id, LauncherWidget.usageViews(context, id))
    }

    override fun onAppWidgetOptionsChanged(context: Context, manager: AppWidgetManager, id: Int, options: Bundle) {
        manager.updateAppWidget(id, LauncherWidget.usageViews(context, id))
    }
}

class SendRowsService : RemoteViewsService() {
    override fun onGetViewFactory(intent: Intent): RemoteViewsFactory = Rows(applicationContext)

    private class Rows(private val context: Context) : RemoteViewsFactory {
        private var rows: List<JSONObject> = emptyList()
        private var live = JSONObject()

        override fun onCreate() {}

        override fun onDataSetChanged() {
            val (sends, known) = LauncherWidget.rows(context)
            rows = sends
            live = known
        }

        override fun onDestroy() {}

        override fun getCount() = rows.size

        override fun getViewAt(position: Int): RemoteViews =
            LauncherWidget.rowViews(context, rows[position], live)

        override fun getLoadingView(): RemoteViews? = null

        override fun getViewTypeCount() = 1

        override fun getItemId(position: Int) = rows[position].optString("id").hashCode().toLong()

        override fun hasStableIds() = true
    }
}

class ComposeDoor : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val target = intent.getStringExtra(LauncherWidget.TARGET) ?: LauncherWidget.SHEET
        startActivity(
            if (UpgradeEngine.inPip) {
                LauncherWidget.openIntent(
                    this,
                    if (target == LauncherWidget.BAR_SHEET) LauncherWidget.INPUT_BAR else LauncherWidget.COMPOSE,
                )
            } else {
                Intent(this, ComposeActivity::class.java)
                    .setAction(LauncherWidget.OPEN)
                    .putExtra(LauncherWidget.TARGET, target)
                    .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            },
        )
        finish()
    }
}
