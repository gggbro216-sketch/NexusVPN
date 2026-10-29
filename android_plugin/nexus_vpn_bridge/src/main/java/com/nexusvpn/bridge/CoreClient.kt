package com.nexusvpn.bridge

import android.util.Log
import io.nekohasekai.libbox.CommandClient
import io.nekohasekai.libbox.CommandClientHandler
import io.nekohasekai.libbox.CommandClientOptions
import io.nekohasekai.libbox.ConnectionEvents
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.LogIterator
import io.nekohasekai.libbox.OutboundGroupItemIterator
import io.nekohasekai.libbox.OutboundGroupIterator
import io.nekohasekai.libbox.StatusMessage
import io.nekohasekai.libbox.StringIterator
import org.json.JSONArray
import org.json.JSONObject

/**
 * UI-process client of the running core (libbox command socket
 * <filesDir>/command.sock): traffic status, logs and URL-test results.
 * Also runs short latency-test core sessions (no TUN) in the UI process.
 */
object CoreClient {
    private const val TAG = "NexusCoreClient"
    private const val STATUS_INTERVAL_NS = 1_000_000_000L

    interface Listener {
        fun onStatus(json: String)
        fun onLogs(json: String)
        fun onUrlTest(json: String)
    }

    @Volatile var listener: Listener? = null
    @Volatile var latencySessionActive = false
        private set

    private var client: CommandClient? = null
    private val groupResults = HashMap<String, JSONObject>()

    /** Connects to the core of the current session (VPN or latency). Runs on BoxCore.executor. */
    fun connect() {
        disconnect()
        val options = CommandClientOptions().apply {
            addCommand(Libbox.CommandLog)
            addCommand(Libbox.CommandStatus)
            addCommand(Libbox.CommandGroup)
            statusInterval = STATUS_INTERVAL_NS
        }
        val c = CommandClient(handler, options)
        try {
            c.connect()
            client = c
        } catch (e: Exception) {
            Log.w(TAG, "connect failed: ${e.message}")
        }
    }

    fun disconnect() {
        val c = client ?: return
        client = null
        runCatching { c.disconnect() }
    }

    fun isConnected() = client != null

    fun urlTest(group: String): String {
        val c = client ?: return "not connected to the core"
        return try {
            c.urlTest(group)
            ""
        } catch (e: Exception) {
            e.message ?: e.toString()
        }
    }

    /**
     * Runs [config] (outbounds only, no TUN) in this process and URL-tests all
     * members of [group]. [done] receives JSON {ok, error, items: {tag: delay_ms or -1}}.
     */
    fun runLatencySession(config: String, xrayConfig: String, group: String, timeoutMs: Long, done: (String) -> Unit) {
        BoxCore.executor.execute {
            val result = JSONObject().put("ok", false).put("error", "").put("items", JSONObject())
            latencySessionActive = true
            try {
                synchronized(groupResults) { groupResults.clear() }
                if (xrayConfig.isNotEmpty()) {
                    val xerr = BoxCore.startXray(xrayConfig, "test", null)
                    if (xerr.isNotEmpty()) throw IllegalStateException(xerr)
                }
                BoxCore.startServer(config)
                connect()
                val begin = System.currentTimeMillis() - 1000
                var started = false
                val deadline = System.currentTimeMillis() + timeoutMs
                while (System.currentTimeMillis() < deadline) {
                    if (!started) started = urlTest(group).isEmpty()
                    Thread.sleep(250)
                    val members = synchronized(groupResults) { groupResults[group] }
                    if (started && members != null && members.length() > 0) {
                        var pending = false
                        for (key in members.keys()) {
                            if (members.getJSONObject(key).optLong("time") < begin) pending = true
                        }
                        if (!pending) break
                    }
                }
                val items = JSONObject()
                val members = synchronized(groupResults) { groupResults[group] }
                if (members != null) {
                    for (key in members.keys()) {
                        val item = members.getJSONObject(key)
                        val delay = if (item.optLong("time") >= begin) item.optInt("delay_ms") else -1
                        items.put(key, if (delay > 0) delay else -1)
                    }
                }
                result.put("ok", started).put("items", items)
                if (!started) result.put("error", "URL test could not be started")
            } catch (e: Exception) {
                Log.e(TAG, "latency session failed", e)
                result.put("error", e.message ?: e.toString())
            } finally {
                disconnect()
                BoxCore.closeServer()
                BoxCore.stopXray()
                latencySessionActive = false
            }
            done(result.toString())
        }
    }

    private val handler = object : CommandClientHandler {
        override fun connected() {}
        override fun disconnected(message: String) {
            Log.d(TAG, "disconnected: $message")
        }
        override fun setDefaultLogLevel(level: Int) {}
        override fun clearLogs() {}

        override fun writeLogs(messageList: LogIterator) {
            if (latencySessionActive) return
            val arr = JSONArray()
            while (messageList.hasNext()) {
                val e = messageList.next()
                arr.put(JSONArray().put(e.level).put(e.message))
            }
            if (arr.length() > 0) listener?.onLogs(arr.toString())
        }

        override fun writeStatus(message: StatusMessage) {
            if (latencySessionActive || !message.trafficAvailable) return
            val obj = JSONObject()
                .put("up", message.uplink)
                .put("down", message.downlink)
                .put("up_total", message.uplinkTotal)
                .put("down_total", message.downlinkTotal)
                .put("connections", message.connectionsOut)
                .put("memory", message.memory)
            listener?.onStatus(obj.toString())
        }

        override fun writeGroups(message: OutboundGroupIterator) {
            while (message.hasNext()) {
                val g = message.next()
                val members = JSONObject()
                val items = g.items
                while (items.hasNext()) {
                    val it = items.next()
                    // URLTestTime is in seconds; convert to ms for the app.
                    members.put(it.tag, JSONObject().put("delay_ms", it.urlTestDelay).put("time", it.urlTestTime * 1000L))
                }
                synchronized(groupResults) { groupResults[g.tag] = members }
                if (!latencySessionActive) {
                    listener?.onUrlTest(JSONObject().put("group", g.tag).put("items", members).toString())
                }
            }
        }

        override fun writeOutbounds(message: OutboundGroupItemIterator) {}
        override fun initializeClashMode(modeList: StringIterator, currentMode: String) {}
        override fun updateClashMode(newMode: String) {}
        override fun writeConnectionEvents(events: ConnectionEvents) {}
    }
}
