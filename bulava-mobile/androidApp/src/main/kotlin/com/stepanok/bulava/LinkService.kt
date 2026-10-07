package com.stepanok.bulava

import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import com.stepanok.bulava.platform.AndroidPlatform

/**
 * Keeps the process — and with it the one connection to the Mac — alive while the app is closed,
 * so a question or an access request still arrives as a notification. It holds no state of its
 * own; the connection belongs to the application's controller.
 */
class LinkService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val mac = intent?.getStringExtra("mac")?.takeIf { it.isNotBlank() } ?: getString(R.string.app_name)
        val open = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE,
        )
        // What is going on at the Mac, at a glance, as the Mac's menu bar has it: the work that
        // runs by name, then what finished. What waits for an answer has its own notification.
        val platform = (application as BulavaApplication).platform
        val live = platform.lastLive
        val working = platform.lastSummary.working
        val body = when {
            live != null && live.running.isNotEmpty() -> getString(R.string.link_working, live.running.joinToString(", ") { it.title })
            live != null && live.over && live.ended.isNotEmpty() -> getString(R.string.link_done, live.ended.joinToString(", ") { it.title })
            live == null && working > 0 -> getString(R.string.link_working_count, working)
            else -> getString(R.string.link_running_body)
        }
        val notification = NotificationCompat.Builder(this, AndroidPlatform.CHANNEL_LINK)
            .setSmallIcon(R.drawable.ic_stat_bulava)
            .setContentTitle(getString(R.string.link_running, mac))
            .setContentText(body)
            .setContentIntent(open)
            .setOngoing(true)
            .setSilent(true)
            .setPriority(NotificationCompat.PRIORITY_MIN)
            .build()
        val type = if (Build.VERSION.SDK_INT >= 29) ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE else 0
        runCatching { ServiceCompat.startForeground(this, 1, notification, type) }
            .onFailure { stopSelf() }
        (application as BulavaApplication).controller.link.connect()
        return START_STICKY
    }
}
