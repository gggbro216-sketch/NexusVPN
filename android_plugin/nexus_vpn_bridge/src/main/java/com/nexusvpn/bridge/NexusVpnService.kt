package com.nexusvpn.bridge

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.os.PowerManager
import android.util.Log
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.OverrideOptions
import io.nekohasekai.libbox.TunOptions
import java.io.File

/**
 * Android VpnService hosting the sing-box core. Runs in the ":vpn" process.
 *
 * Started by the app (ACTION_START, config already written to [configFile]) or
 * by the system for Always-on VPN (no/unknown action: the last config is
 * reused). Runs as a foreground service with a persistent notification and
 * publishes its state through [CoreState].
 */
class NexusVpnService : VpnService() {
    companion object {
        private const val TAG = "NexusVpnService"
        const val ACTION_START = "com.nexusvpn.bridge.START"
        const val ACTION_STOP = "com.nexusvpn.bridge.STOP"
        const val ACTION_RESET_NETWORK = "com.nexusvpn.bridge.RESET_NETWORK"
        const val EXTRA_PROFILE_ID = "profile_id"
        const val EXTRA_PROFILE_NAME = "profile_name"

        fun configFile(context: Context) = File(context.filesDir, "nexus_active_config.json")
        private fun metaFile(context: Context) = File(context.filesDir, "nexus_active_profile.txt")

        fun saveMeta(context: Context, id: String, name: String) {
            metaFile(context).writeText("$id\n$name")
        }

        private fun readMeta(context: Context): Pair<String, String> {
            val f = metaFile(context)
            if (!f.exists()) return "" to ""
            val lines = f.readText().split("\n", limit = 2)
            return lines.getOrElse(0) { "" } to lines.getOrElse(1) { "" }
        }
    }

    private var tunFd: ParcelFileDescriptor? = null
    @Volatile private var state = BoxCore.STOPPED
    @Volatile private var stopping = false
    private var profileId = ""
    private var profileName = ""
    private var startedAt = 0L
    private var receiverRegistered = false

    private val idleReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (Build.VERSION.SDK_INT >= 23 && intent.action == PowerManager.ACTION_DEVICE_IDLE_MODE_CHANGED) {
                val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                BoxCore.pause(pm.isDeviceIdleMode)
            }
        }
    }

    private fun publish(s: Int, msg: String = "") {
        state = s
        CoreState.publish(this, s, msg, startedAt, profileId, profileName)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        BoxCore.init(this, "vpn")
        when (intent?.action) {
            ACTION_STOP -> {
                stopVpn(if (intent.getBooleanExtra("from_app", false)) "" else "stopped_by_user")
                return START_NOT_STICKY
            }
            ACTION_RESET_NETWORK -> {
                BoxCore.resetNetwork()
                return START_NOT_STICKY
            }
        }
        if (intent?.action == ACTION_START) {
            profileId = intent.getStringExtra(EXTRA_PROFILE_ID) ?: ""
            profileName = intent.getStringExtra(EXTRA_PROFILE_NAME) ?: ""
        } else {
            // Always-on VPN / system restart: reuse the last configuration.
            val meta = readMeta(this)
            profileId = meta.first
            profileName = meta.second
        }
        enterForeground(profileName, getString(R.string.nexus_notif_connecting))
        if (state == BoxCore.STARTED || state == BoxCore.STARTING) return START_NOT_STICKY
        val cfg = configFile(this)
        if (!cfg.exists()) {
            failAndStop("no saved configuration; open the app and connect once")
            return START_NOT_STICKY
        }
        BoxCore.vpnService = this
        stopping = false
        registerIdleReceiver()
        publish(BoxCore.STARTING)
        BoxCore.executor.execute {
            val config = try { cfg.readText() } catch (e: Exception) { "" }
            var err = if (config.isEmpty()) "configuration file is unreadable" else ""
            if (err.isEmpty()) {
                // Let the network callback deliver the underlying network first,
                // otherwise the core starts with "missing default interface".
                NetworkMonitor.awaitNetwork(3000)
                try {
                    BoxCore.startServer(config, OverrideOptions())
                } catch (e: Exception) {
                    err = e.message ?: e.toString()
                }
            }
            if (err.isNotEmpty()) {
                Log.e(TAG, "core start failed: $err")
                closeTun()
                BoxCore.vpnService = null
                startedAt = 0
                publish(BoxCore.STOPPED, err)
                Notifications.alert(this, getString(R.string.nexus_notif_stopped_error), err)
                stopSelfSafely()
            } else {
                startedAt = System.currentTimeMillis()
                publish(BoxCore.STARTED)
                updateNotification(profileName, getString(R.string.nexus_notif_connected))
            }
        }
        return START_NOT_STICKY
    }

    /** Called from [BoxPlatform.openTun] on a core thread. */
    fun openTun(options: TunOptions): Int {
        if (prepare(this) != null) throw IllegalStateException("android: VPN permission missing or revoked")
        val builder = Builder()
            .setSession(profileName.ifEmpty { "NEXUS VPN" })
            .setMtu(options.mtu)
        if (Build.VERSION.SDK_INT >= 29) builder.setMetered(false)

        val inet4 = options.inet4Address.toList()
        val inet6 = options.inet6Address.toList()
        for (a in inet4) builder.addAddress(a.address(), a.prefix())
        for (a in inet6) builder.addAddress(a.address(), a.prefix())

        if (options.autoRoute) {
            if (options.dnsMode.value != Libbox.DNSModeDisabled) {
                val dns = options.dnsServerAddress
                while (dns.hasNext()) builder.addDnsServer(dns.next())
            }
            // Route ranges already have route_exclude_address applied by sing-box.
            val r4 = options.inet4RouteRange.toList()
            if (r4.isNotEmpty()) r4.forEach { builder.addRoute(it.address(), it.prefix()) }
            else if (inet4.isNotEmpty()) builder.addRoute("0.0.0.0", 0)
            val r6 = options.inet6RouteRange.toList()
            if (r6.isNotEmpty()) r6.forEach { builder.addRoute(it.address(), it.prefix()) }
            else if (inet6.isNotEmpty()) builder.addRoute("::", 0)

            // Per-app routing. VpnService forbids mixing allowed and disallowed lists.
            val include = options.includePackage.toList()
            val exclude = options.excludePackage.toList()
            if (include.isNotEmpty()) {
                for (p in include) {
                    try { builder.addAllowedApplication(p) } catch (e: PackageManager.NameNotFoundException) {
                        Log.w(TAG, "allowed app not installed: $p")
                    }
                }
            } else {
                for (p in exclude) {
                    try { builder.addDisallowedApplication(p) } catch (e: PackageManager.NameNotFoundException) {
                        Log.w(TAG, "excluded app not installed: $p")
                    }
                }
            }
        }
        NetworkMonitor.currentNetwork?.let { builder.setUnderlyingNetworks(arrayOf(it)) }
        val pfd = builder.establish() ?: throw IllegalStateException("android: the app is not prepared for VPN or it was revoked")
        tunFd = pfd
        return pfd.fd
    }

    fun stopVpn(reason: String) {
        if (stopping) return
        stopping = true
        BoxCore.executor.execute {
            publish(BoxCore.STOPPING)
            closeTun()
            BoxCore.closeServer()
            BoxCore.vpnService = null
            startedAt = 0
            publish(BoxCore.STOPPED, reason)
            stopSelfSafely()
        }
    }

    override fun onRevoke() {
        // Another VPN app took over or the user revoked the permission.
        stopVpn("revoked")
    }

    override fun onDestroy() {
        unregisterIdleReceiver()
        if (BoxCore.vpnService === this) {
            BoxCore.executor.execute {
                closeTun()
                BoxCore.closeServer()
                BoxCore.vpnService = null
                if (state != BoxCore.STOPPED) {
                    startedAt = 0
                    publish(BoxCore.STOPPED, "service destroyed")
                }
            }
        }
        super.onDestroy()
    }

    private fun failAndStop(msg: String) {
        Log.e(TAG, msg)
        Notifications.alert(this, getString(R.string.nexus_notif_stopped_error), msg)
        publish(BoxCore.STOPPED, msg)
        stopSelfSafely()
    }

    private fun closeTun() {
        runCatching { tunFd?.close() }
        tunFd = null
    }

    private fun stopSelfSafely() {
        unregisterIdleReceiver()
        if (Build.VERSION.SDK_INT >= 24) stopForeground(STOP_FOREGROUND_REMOVE)
        else @Suppress("DEPRECATION") stopForeground(true)
        stopSelf()
    }

    private fun enterForeground(name: String, text: String) {
        val n = Notifications.vpn(this, name.ifEmpty { "NEXUS VPN" }, text)
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(Notifications.VPN_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SYSTEM_EXEMPTED)
        } else {
            startForeground(Notifications.VPN_ID, n)
        }
    }

    private fun updateNotification(name: String, text: String) {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as android.app.NotificationManager
        nm.notify(Notifications.VPN_ID, Notifications.vpn(this, name.ifEmpty { "NEXUS VPN" }, text))
    }

    private fun registerIdleReceiver() {
        if (receiverRegistered || Build.VERSION.SDK_INT < 23) return
        val filter = IntentFilter(PowerManager.ACTION_DEVICE_IDLE_MODE_CHANGED)
        if (Build.VERSION.SDK_INT >= 33) registerReceiver(idleReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        else registerReceiver(idleReceiver, filter)
        receiverRegistered = true
    }

    private fun unregisterIdleReceiver() {
        if (!receiverRegistered) return
        runCatching { unregisterReceiver(idleReceiver) }
        receiverRegistered = false
    }
}
