package dev.luisnquin.dazzle_shade

import android.app.ActivityManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.provider.Settings
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class DazzleShadePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var context: Context
    private var channel: MethodChannel? = null

    private val manager get() = context.getSystemService(NotificationManager::class.java)

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "dev.luisnquin.dazzle/shade").also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "channel" -> {
                    createChannel(
                        call.argument<String>("id")!!,
                        call.argument<String>("name")!!,
                        call.argument<List<String>>("retired") ?: emptyList(),
                    )
                    result.success(null)
                }
                "show" -> {
                    show(
                        id = call.argument<Int>("id")!!,
                        channelId = call.argument<String>("channel")!!,
                        title = call.argument<String>("title")!!,
                        body = call.argument<String>("body")!!,
                        payload = call.argument<String>("payload")!!,
                        ask = call.argument<String>("ask")!!,
                    )
                    result.success(null)
                }
                "cancel" -> {
                    manager.cancel(call.argument<Int>("id")!!)
                    result.success(null)
                }
                "dndAccess" -> result.success(manager.isNotificationPolicyAccessGranted)
                "askDndAccess" -> {
                    context.startActivity(
                        Intent(Settings.ACTION_NOTIFICATION_POLICY_ACCESS_SETTINGS)
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                    )
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("shade", e.message, null)
        }
    }

    private fun createChannel(id: String, name: String, retired: List<String>) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        for (old in retired) manager.deleteNotificationChannel(old)
        manager.createNotificationChannel(
            NotificationChannel(id, name, NotificationManager.IMPORTANCE_HIGH).apply {
                enableVibration(true)
                setBypassDnd(true)
            },
        )
    }

    private fun show(id: Int, channelId: String, title: String, body: String, payload: String, ask: String) {
        // The tap goes through flutter_local_notifications' own intent, so its launch details
        // and its tap callback answer it as if it had posted the notification itself.
        val intent = context.packageManager.getLaunchIntentForPackage(context.packageName)!!.apply {
            action = "SELECT_NOTIFICATION"
            putExtra("notificationId", id)
            putExtra("payload", payload)
        }
        val tap = PendingIntent.getActivity(
            context,
            id,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val repeat = manager.activeNotifications.any {
            it.id == id && it.tag == null && it.notification.extras.getString(ASK) == ask
        }
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, channelId)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(context)
                .setPriority(Notification.PRIORITY_HIGH)
                .setDefaults(Notification.DEFAULT_ALL)
        }
        builder
            .setSmallIcon(context.applicationInfo.icon)
            .setContentTitle(title)
            .setContentText(body)
            .setCategory(Notification.CATEGORY_STATUS)
            .setContentIntent(tap)
            .setAutoCancel(true)
            .setOnlyAlertOnce(repeat)
            .addExtras(Bundle().apply { putString(ASK, ask) })
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            builder.setAllowSystemGeneratedContextualActions(false)
        }
        manager.notify(id, builder.build())
        if (!repeat && inFront()) buzz()
    }

    private fun inFront(): Boolean {
        val state = ActivityManager.RunningAppProcessInfo()
        ActivityManager.getMyMemoryState(state)
        return state.importance == ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND
    }

    private fun buzz() {
        val vibrator = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            context.getSystemService(VibratorManager::class.java).defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            context.getSystemService(Vibrator::class.java)
        }
        if (!vibrator.hasVibrator()) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            vibrator.vibrate(VibrationEffect.createWaveform(PATTERN, -1))
        } else {
            @Suppress("DEPRECATION")
            vibrator.vibrate(PATTERN, -1)
        }
    }

    private companion object {
        const val ASK = "dev.luisnquin.dazzle.ask"
        val PATTERN = longArrayOf(0, 250, 150, 250)
    }
}
