package com.nexusvpn.bridge

import android.content.Context
import android.util.Log
import java.io.File
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.TimeUnit

/**
 * Runs Xray-core (packaged as lib/<abi>/libxray.so, an executable) as a child
 * process. Used for profiles sing-box cannot run (XHTTP, VLESS encryption).
 * All of Xray's server connections go through sing-box's protected "direct"
 * outbound via sockopt.dialerProxy (see scripts/vpn/xray_bridge.gd), so this
 * process needs no VpnService.protect() itself.
 */
class XrayProcess(private val context: Context, private val name: String) {
    companion object {
        private const val TAG = "NexusXray"
        private const val MAX_LOG_LINES = 200

        fun binary(context: Context): File = File(context.applicationInfo.nativeLibraryDir, "libxray.so")

        /** Validates [config] with `xray run -test`. Returns "" or the error output. */
        fun check(context: Context, config: String): String {
            val bin = binary(context)
            if (!bin.canExecute()) return "Xray binary is missing from this build"
            val file = File(context.cacheDir, "nexus_xray_check.json")
            return try {
                file.writeText(config)
                val p = ProcessBuilder(bin.path, "run", "-test", "-c", file.path).redirectErrorStream(true).start()
                val out = p.inputStream.bufferedReader().readText()
                if (!p.waitFor(15, TimeUnit.SECONDS)) {
                    p.destroyForcibly()
                    "Xray config check timed out"
                } else if (p.exitValue() == 0) "" else out.lines().filter { it.isNotBlank() }.takeLast(4).joinToString("\n")
            } catch (e: Exception) {
                e.message ?: e.toString()
            } finally {
                file.delete()
            }
        }
    }

    @Volatile private var process: Process? = null
    @Volatile var stopping = false
        private set
    private val lines = ArrayDeque<String>()

    /** Receives each log line (level: 2 error, 3 warn, 4 info, 5 debug — sing-box numbering). */
    @Volatile var onLog: ((Int, String) -> Unit)? = null
    /** Called once if the process exits while not being stopped. */
    @Volatile var onUnexpectedExit: ((String) -> Unit)? = null

    /**
     * Starts Xray with [config] and waits until [ports] accept connections.
     * Returns "" or an error.
     */
    fun start(config: String, ports: List<Int>, timeoutMs: Long = 6000): String {
        stop()
        val bin = binary(context)
        if (!bin.canExecute()) return "Xray binary is missing from this build"
        val file = File(context.filesDir, "nexus_xray_$name.json")
        try {
            file.writeText(config)
            file.setReadable(false, false)
            file.setReadable(true, true)
        } catch (e: Exception) {
            return "cannot write Xray config: ${e.message}"
        }
        stopping = false
        val p = try {
            ProcessBuilder(bin.path, "run", "-c", file.path)
                .directory(context.filesDir)
                .redirectErrorStream(true)
                .start()
        } catch (e: Exception) {
            return "cannot start Xray: ${e.message}"
        }
        process = p
        Thread({
            try {
                p.inputStream.bufferedReader().forEachLine { line ->
                    synchronized(lines) {
                        lines.addLast(line)
                        while (lines.size > MAX_LOG_LINES) lines.removeFirst()
                    }
                    onLog?.invoke(levelOf(line), "[xray] $line")
                }
            } catch (_: Exception) {
            }
            val code = runCatching { p.waitFor() }.getOrDefault(-1)
            if (!stopping) {
                Log.e(TAG, "xray exited with $code")
                onUnexpectedExit?.invoke("Xray exited (code $code): ${tail(3)}")
            }
        }, "nexus-xray-$name").start()
        val deadline = System.currentTimeMillis() + timeoutMs
        for (port in ports) {
            while (!portOpen(port)) {
                if (!isAlive()) return "Xray failed to start: ${tail(4)}"
                if (System.currentTimeMillis() > deadline) {
                    stop()
                    return "Xray did not open its local port in time"
                }
                Thread.sleep(50)
            }
        }
        return ""
    }

    fun isAlive(): Boolean = process?.isAlive == true

    fun stop() {
        val p = process ?: return
        stopping = true
        process = null
        p.destroy()
        if (!runCatching { p.waitFor(2, TimeUnit.SECONDS) }.getOrDefault(false)) p.destroyForcibly()
        File(context.filesDir, "nexus_xray_$name.json").delete()
    }

    fun tail(n: Int): String = synchronized(lines) { lines.toList().takeLast(n).joinToString(" | ") }

    private fun portOpen(port: Int): Boolean = try {
        Socket().use { it.connect(InetSocketAddress("127.0.0.1", port), 200); true }
    } catch (_: Exception) {
        false
    }

    private fun levelOf(line: String): Int = when {
        line.contains("[Error]") -> 2
        line.contains("[Warning]") -> 3
        line.contains("[Debug]") -> 5
        else -> 4
    }
}
