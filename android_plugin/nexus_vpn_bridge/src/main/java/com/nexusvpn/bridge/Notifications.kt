package com.nexusvpn.bridge

import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build

/** Builds the foreground-service and alert notifications (no androidx dependency). */
object Notifications {
    const val VPN_ID = 1101
    private const val ALERT_ID = 1102

    private fun builder(context: Context, channel: String): Notification.Builder =
        if (Build.VERSION.SDK_INT >= 26) Notification.Builder(context, channel)
        else @Suppress("DEPRECATION") Notification.Builder(context)

    private fun launchIntent(context: Context): PendingIntent? {
        val intent = context.packageManager.getLaunchIntentForPackage(context.packageName) ?: return null
        intent.addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT)
        return PendingIntent.getActivity(context, 0, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
    }

    fun vpn(context: Context, title: String, text: String): Notification {
        val stop = Intent(context, NexusVpnService::class.java).setAction(NexusVpnService.ACTION_STOP)
        val stopPi = PendingIntent.getService(context, 1, stop, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val b = builder(context, BoxCore.VPN_CHANNEL)
            .setSmallIcon(R.drawable.nexus_ic_vpn)
            .setContentTitle(title)
            .setContentText(text)
            .setOngoing(true)
            .setShowWhen(false)
            .setCategory(Notification.CATEGORY_SERVICE)
            .setContentIntent(launchIntent(context))
        @Suppress("DEPRECATION")
        b.addAction(Notification.Action.Builder(0, context.getString(R.string.nexus_notif_stop), stopPi).build())
        if (Build.VERSION.SDK_INT >= 31) b.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
        return b.build()
    }

    fun alert(context: Context, title: String, text: String) {
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 24 && !nm.areNotificationsEnabled()) return
        val n = builder(context, BoxCore.ALERT_CHANNEL)
            .setSmallIcon(R.drawable.nexus_ic_vpn)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(Notification.BigTextStyle().bigText(text))
            .setAutoCancel(true)
            .setContentIntent(launchIntent(context))
            .build()
        nm.notify(ALERT_ID, n)
    }
}
