package dev.luisnquin.striked

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

class TransferService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val shown = latest ?: finished ?: build(this, "MOVING", "", -1, ongoing = true)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(ID, shown, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(ID, shown)
        }
        running = this
        finished?.let { if (latest == null) done(this, it) }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        if (running === this) running = null
        super.onDestroy()
    }

    companion object {
        const val OPEN = "dev.luisnquin.striked.TRANSFERS"
        private const val STOP = "dev.luisnquin.striked.STOP_TRANSFERS"
        private const val CHANNEL = "transfers"
        private const val ID = 7301

        var listener: ((String) -> Unit)? = null
        private var waiting: String? = null

        fun deliver(method: String) {
            val heard = listener ?: return run { waiting = method }
            heard(method)
        }

        fun takeWaiting(): String? = waiting.also { waiting = null }

        private var running: TransferService? = null
        private var latest: Notification? = null
        private var finished: Notification? = null

        fun moving(context: Context, title: String, text: String, percent: Int) {
            val notification = build(context, title, text, percent, ongoing = true)
            latest = notification
            finished = null
            if (running != null) {
                manager(context).notify(ID, notification)
                return
            }
            val intent = Intent(context, TransferService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun done(context: Context, title: String) =
            done(context, build(context, title, "", null, ongoing = false))

        private fun done(context: Context, notification: Notification) {
            latest = null
            finished = notification
            manager(context).notify(ID, notification)
            val service = running ?: return
            finished = null
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                service.stopForeground(Service.STOP_FOREGROUND_DETACH)
            } else {
                @Suppress("DEPRECATION")
                service.stopForeground(false)
            }
            service.stopSelf()
            running = null
        }

        private fun manager(context: Context) =
            context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        private fun build(
            context: Context,
            title: String,
            text: String,
            percent: Int?,
            ongoing: Boolean,
        ): Notification {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                manager(context).createNotificationChannel(
                    NotificationChannel(CHANNEL, "File transfers", NotificationManager.IMPORTANCE_LOW),
                )
            }
            val open = PendingIntent.getActivity(
                context,
                ID,
                Intent(context, MainActivity::class.java)
                    .setAction(OPEN)
                    .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(context, CHANNEL)
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(context)
            }
            builder
                .setSmallIcon(context.applicationInfo.icon)
                .setContentTitle(title)
                .setContentIntent(open)
                .setOngoing(ongoing)
                .setAutoCancel(!ongoing)
                .setOnlyAlertOnce(true)
                .setShowWhen(false)
            if (text.isNotEmpty()) builder.setContentText(text)
            if (ongoing) {
                val stop = PendingIntent.getBroadcast(
                    context,
                    ID,
                    Intent(context, TransferStopReceiver::class.java).setAction(STOP),
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                )
                @Suppress("DEPRECATION")
                builder.addAction(0, "STOP", stop)
            }
            if (percent != null) builder.setProgress(100, percent.coerceAtLeast(0), percent < 0)
            return builder.build()
        }
    }
}

class TransferStopReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) =
        TransferService.deliver("stopTransfers")
}
