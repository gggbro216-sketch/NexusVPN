package com.nexusvpn.bridge

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import io.nekohasekai.libbox.CommandServer
import io.nekohasekai.libbox.CommandServerHandler
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.OverrideOptions
import io.nekohasekai.libbox.SetupOptions
import io.nekohasekai.libbox.SystemProxyStatus
import org.json.JSONObject
import java.io.File
import java.util.concurrent.Executors

/**
 * Per-process owner of libbox.
 *
 * Process layout:
 *  - ":vpn" process: [NexusVpnService] runs the VPN core session here, so the
 *    VPN survives when the Godot UI process exits (Godot kills its own process
 *    on quit).
 *  - UI process: [NexusVpnPlugin]; observes the core through [CoreClient]
 *    (libbox command socket) and [CoreState] broadcasts. Short latency-test
 *    sessions (no TUN) also run here, only while no VPN session exists.
 */
object BoxCore {
    private const val TAG = "NexusBoxCore"

    const val STOPPED = 0
    const val STARTING = 1
    const val STARTED = 2
    const val STOPPING = 3

    const val ALERT_CHANNEL = "nexus_alerts"
    const val VPN_CHANNEL = "nexus_vpn"

    lateinit var appContext: Context
        private set
    private var setupDone = false

    /** Serialises start/stop work of this process off the main thread. */
    val executor = Executors.newSingleThreadExecutor { r -> Thread(r, "nexus-core") }

    /** Set in the :vpn process while the VPN service is alive. */
    @Volatile var vpnService: NexusVpnService? = null

    private var server: CommandServer? = null

    /** Xray child process of the current session (null if the profile runs on sing-box). */
    @Volatile var xray: XrayProcess? = null
        private set
    private val pendingLogs = ArrayList<Pair<Int, String>>()

    /** Local ports of the Xray inbounds declared in [config] (XrayBridge layout). */
    fun xrayPorts(config: String): List<Int> = runCatching {
        val arr = org.json.JSONObject(config).getJSONArray("inbounds")
        (0 until arr.length()).map { arr.getJSONObject(it).getInt("port") }
    }.getOrDefault(emptyList())

    /**
     * Starts Xray for this session. Its log lines go into the core log stream
     * (visible in the app's diagnostics); [onExit] fires if it dies unexpectedly.
     * Returns "" or an error.
     */
    fun startXray(config: String, name: String, onExit: ((String) -> Unit)?): String {
        stopXray()
        val x = XrayProcess(appContext, name)
        x.onLog = { level, line -> coreLog(level, line) }
        x.onUnexpectedExit = onExit
        val err = x.start(config, xrayPorts(config))
        if (err.isEmpty()) xray = x
        return err
    }

    fun stopXray() {
        xray?.stop()
        xray = null
    }

    /** Writes into sing-box's log stream (buffered until the core runs). */
    fun coreLog(level: Int, message: String) {
        val srv = server
        if (srv == null) {
            synchronized(pendingLogs) {
                pendingLogs.add(level to message)
                if (pendingLogs.size > 200) pendingLogs.removeAt(0)
            }
            return
        }
        runCatching { srv.writeMessage(level, message) }
    }

    private fun flushLogs() {
        val srv = server ?: return
        val items = synchronized(pendingLogs) { ArrayList(pendingLogs).also { pendingLogs.clear() } }
        for ((level, msg) in items) runCatching { srv.writeMessage(level, msg) }
    }

    @Synchronized
    fun init(context: Context, source: String) {
        if (setupDone) return
        appContext = context.applicationContext
        val working = File(appContext.filesDir, "sing-box").apply { mkdirs() }
        val options = SetupOptions().apply {
            basePath = appContext.filesDir.path
            workingPath = working.path
            tempPath = appContext.cacheDir.path
            // golang/go#68760 workaround, same condition as the official client.
            fixAndroidStack = Build.VERSION.SDK_INT in 24..25 || Build.VERSION.SDK_INT >= 28
            logMaxLines = 3000
            debug = false
            crashReportSource = source
            appVersion = "1"
            appMarketingVersion = "0.1.0"
        }
        Libbox.setup(options)
        createChannels()
        NetworkMonitor.start(appContext)
        setupDone = true
        Log.i(TAG, "libbox ${Libbox.version()} ready ($source)")
    }

    fun version(): String = Libbox.version()

    /** Validates a configuration with the real core. Returns "" or the error. */
    fun checkConfig(config: String): String = try {
        Libbox.checkConfig(config)
        ""
    } catch (e: Exception) {
        e.message ?: e.toString()
    }

    /** Starts a core session in this process. Throws on failure. */
    fun startServer(config: String, override: OverrideOptions = OverrideOptions()) {
        closeServer()
        val srv = CommandServer(serverHandler, BoxPlatform(appContext))
        srv.start()
        server = srv
        try {
            srv.startOrReloadService(config, override)
            flushLogs()
        } catch (e: Exception) {
            closeServer()
            throw e
        }
    }

    fun closeServer() {
        val srv = server ?: return
        server = null
        runCatching { srv.closeService() }.onFailure { Log.w(TAG, "closeService", it) }
        runCatching { srv.close() }
    }

    fun hasServer(): Boolean = server != null

    fun resetNetwork() {
        executor.execute { runCatching { server?.resetNetwork() } }
    }

    fun pause(idle: Boolean) {
        executor.execute { runCatching { if (idle) server?.pause() else server?.wake() } }
    }

    private val serverHandler = object : CommandServerHandler {
        override fun serviceStop() {
            // The core asked to stop (e.g. fatal error) or a client called ServiceClose.
            vpnService?.stopVpn("core requested stop")
        }

        override fun serviceReload() {
            throw UnsupportedOperationException("reload is driven by the app")
        }

        override fun getSystemProxyStatus(): SystemProxyStatus = SystemProxyStatus()
        override fun setSystemProxyEnabled(enabled: Boolean) =
            throw UnsupportedOperationException("system proxy is not supported")
        override fun triggerNativeCrash() = throw UnsupportedOperationException("not supported")
        override fun writeDebugMessage(message: String) {
            Log.d(TAG, message)
        }
        override fun connectSSHAgent(): Int = throw UnsupportedOperationException("not supported")
    }

    private fun createChannels() {
        if (Build.VERSION.SDK_INT < 26) return
        val nm = appContext.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.createNotificationChannel(NotificationChannel(VPN_CHANNEL,
            appContext.getString(R.string.nexus_channel_vpn), NotificationManager.IMPORTANCE_LOW).apply { setShowBadge(false) })
        nm.createNotificationChannel(NotificationChannel(ALERT_CHANNEL,
            appContext.getString(R.string.nexus_channel_alerts), NotificationManager.IMPORTANCE_DEFAULT))
    }

    fun postCoreNotification(title: String, body: String) {
        Notifications.alert(appContext, title, body)
    }
}

/**
 * VPN session state shared across processes: persisted to a small file (read
 * by the UI on startup) and announced with an app-private broadcast.
 */
object CoreState {
    const val ACTION_STATE = "com.nexusvpn.bridge.CORE_STATE"

    private fun file(context: Context) = File(context.filesDir, "nexus_core_state.json")

    /** Called by the service process. */
    fun publish(context: Context, state: Int, message: String, startedAt: Long, profileId: String, profileName: String) {
        val json = JSONObject()
            .put("state", state)
            .put("message", message)
            .put("started_at", startedAt)
            .put("profile_id", profileId)
            .put("profile_name", profileName)
            .put("pid", android.os.Process.myPid())
            .toString()
        runCatching {
            val tmp = File(context.filesDir, "nexus_core_state.json.tmp")
            tmp.writeText(json)
            tmp.renameTo(file(context))
        }
        context.sendBroadcast(Intent(ACTION_STATE).setPackage(context.packageName).putExtra("json", json))
    }

    /** Last published state; a STARTED state whose process is gone reads as STOPPED. */
    fun read(context: Context): JSONObject {
        val f = file(context)
        val obj = runCatching { JSONObject(f.readText()) }.getOrElse { JSONObject().put("state", BoxCore.STOPPED) }
        if (obj.optInt("state") != BoxCore.STOPPED && !processAlive(context, obj.optInt("pid"))) {
            obj.put("state", BoxCore.STOPPED).put("message", "")
        }
        return obj
    }

    private fun processAlive(context: Context, pid: Int): Boolean {
        if (pid <= 0) return false
        val am = context.getSystemService(Context.ACTIVITY_SERVICE) as android.app.ActivityManager
        return am.runningAppProcesses?.any { it.pid == pid } == true
    }
}
