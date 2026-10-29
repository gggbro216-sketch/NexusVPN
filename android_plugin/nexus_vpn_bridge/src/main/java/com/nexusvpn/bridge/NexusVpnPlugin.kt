package com.nexusvpn.bridge

import android.Manifest
import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.graphics.BitmapFactory
import android.net.Uri
import android.net.VpnService
import android.os.Build
import android.provider.OpenableColumns
import android.provider.Settings
import android.util.Log
import com.google.android.gms.common.ConnectionResult
import com.google.android.gms.common.GoogleApiAvailability
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.codescanner.GmsBarcodeScannerOptions
import com.google.mlkit.vision.codescanner.GmsBarcodeScanning
import org.godotengine.godot.Godot
import org.godotengine.godot.plugin.GodotPlugin
import org.godotengine.godot.plugin.SignalInfo
import org.godotengine.godot.plugin.UsedByGodot
import org.json.JSONObject
import java.util.concurrent.Executors

/**
 * Godot Android plugin "NexusVpnBridge": the only API GDScript uses to reach
 * native functionality. Long-running work never blocks the Godot thread;
 * results come back as signals (JSON payloads where structured).
 */
class NexusVpnPlugin(godot: Godot) : GodotPlugin(godot), CoreClient.Listener {
    companion object {
        private const val TAG = "NexusVpnPlugin"
        const val API_VERSION = 2
        private const val REQ_VPN = 0x4E01
        private const val REQ_PICK_FILE = 0x4E02
        private const val REQ_SAVE_FILE = 0x4E03
        private const val REQ_PICK_QR_IMAGE = 0x4E04
        private const val REQ_NOTIFICATIONS = 0x4E05
        private const val MAX_FILE_BYTES = 8 * 1024 * 1024
    }

    private val io = Executors.newSingleThreadExecutor { r -> Thread(r, "nexus-io") }
    @Volatile private var resumed = true
    private var pickTag = ""
    private var pendingSaveContent: ByteArray? = null

    override fun getPluginName() = "NexusVpnBridge"

    override fun getPluginSignals(): Set<SignalInfo> = setOf(
        SignalInfo("vpn_permission_result", java.lang.Boolean::class.java),
        SignalInfo("core_state", Integer::class.java, String::class.java),
        SignalInfo("core_status", String::class.java),
        SignalInfo("core_logs", String::class.java),
        SignalInfo("url_test_result", String::class.java),
        SignalInfo("latency_result", String::class.java),
        SignalInfo("network_changed", String::class.java),
        SignalInfo("apps_loaded", String::class.java),
        SignalInfo("file_picked", String::class.java, String::class.java, String::class.java, String::class.java),
        SignalInfo("file_saved", java.lang.Boolean::class.java, String::class.java),
        SignalInfo("qr_scanned", String::class.java, String::class.java),
        SignalInfo("notification_permission_result", java.lang.Boolean::class.java),
    )

    private var receiverRegistered = false
    /** A start intent was sent and the service has not yet reported STARTED/STOPPED. */
    @Volatile private var startPending = false

    /** State broadcasts from the :vpn process. */
    private val stateReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val json = intent.getStringExtra("json") ?: return
            val obj = runCatching { JSONObject(json) }.getOrNull() ?: return
            val state = obj.optInt("state")
            if (state == BoxCore.STARTED || state == BoxCore.STOPPED) startPending = false
            when (state) {
                BoxCore.STARTED -> BoxCore.executor.execute { CoreClient.connect() }
                BoxCore.STOPPED -> BoxCore.executor.execute { CoreClient.disconnect() }
            }
            emit("core_state", state, obj.optString("message"))
        }
    }

    override fun onGodotSetupCompleted() {
        super.onGodotSetupCompleted()
        val ctx = activity?.applicationContext ?: return
        try {
            BoxCore.init(ctx, "ui")
        } catch (e: Exception) {
            Log.e(TAG, "libbox setup failed", e)
        }
        CoreClient.listener = this
        NetworkMonitor.appListener = { json -> emit("network_changed", json) }
        if (!receiverRegistered) {
            val filter = IntentFilter(CoreState.ACTION_STATE)
            if (Build.VERSION.SDK_INT >= 33) ctx.registerReceiver(stateReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
            else ctx.registerReceiver(stateReceiver, filter)
            receiverRegistered = true
        }
        // UI restarted while the VPN kept running: attach to the core.
        if (CoreState.read(ctx).optInt("state") == BoxCore.STARTED) {
            BoxCore.executor.execute { CoreClient.connect() }
        }
    }

    override fun onMainResume() {
        super.onMainResume()
        resumed = true
    }

    override fun onMainPause() {
        super.onMainPause()
        resumed = false
    }

    override fun onMainDestroy() {
        if (CoreClient.listener === this) CoreClient.listener = null
        NetworkMonitor.appListener = null
        if (receiverRegistered) {
            runCatching { activity?.applicationContext?.unregisterReceiver(stateReceiver) }
            receiverRegistered = false
        }
        super.onMainDestroy()
    }

    /** Signals are delivered on Godot's thread. */
    private fun emit(name: String, vararg args: Any) {
        runOnHostThread { emitSignal(name, *args) }
    }

    // --- CoreClient.Listener (called on core threads) -------------------------------

    // High-frequency events are dropped while the UI is in the background; the
    // UI re-reads the current state when it resumes.
    override fun onStatus(json: String) {
        if (resumed) emit("core_status", json)
    }

    override fun onLogs(json: String) {
        if (resumed) emit("core_logs", json)
    }

    override fun onUrlTest(json: String) = emit("url_test_result", json)

    // --- core / VPN ------------------------------------------------------------

    @UsedByGodot
    fun getBridgeApiVersion(): Int = API_VERSION

    @UsedByGodot
    fun getCoreVersion(): String = runCatching { BoxCore.version() }.getOrDefault("")

    @UsedByGodot
    fun checkConfig(config: String): String = BoxCore.checkConfig(config)

    /** Validates an Xray config with the bundled Xray binary. Returns "" or the error. */
    @UsedByGodot
    fun checkXrayConfig(config: String): String {
        val ctx = activity ?: return "no activity"
        return XrayProcess.check(ctx, config)
    }

    @UsedByGodot
    fun getXrayVersion(): String {
        val ctx = activity ?: return ""
        val bin = XrayProcess.binary(ctx)
        if (!bin.canExecute()) return ""
        return runCatching {
            val p = ProcessBuilder(bin.path, "version").redirectErrorStream(true).start()
            val out = p.inputStream.bufferedReader().readLine() ?: ""
            p.waitFor()
            out.split(" ").getOrElse(1) { "" }
        }.getOrDefault("")
    }

    @UsedByGodot
    fun getCoreInfo(): String {
        val ctx = activity ?: return JSONObject().put("state", BoxCore.STOPPED).toString()
        return CoreState.read(ctx).toString()
    }

    @UsedByGodot
    fun isVpnPrepared(): Boolean {
        val act = activity ?: return false
        return VpnService.prepare(act) == null
    }

    @UsedByGodot
    fun requestVpnPermission() {
        val act = activity ?: return emit("vpn_permission_result", false)
        val intent = VpnService.prepare(act)
        if (intent == null) {
            emit("vpn_permission_result", true)
            return
        }
        runOnUiThread {
            try {
                act.startActivityForResult(intent, REQ_VPN)
            } catch (e: Exception) {
                Log.e(TAG, "cannot show VPN consent dialog", e)
                emit("vpn_permission_result", false)
            }
        }
    }

    /** Writes the config and starts [NexusVpnService]. Returns "" or an error. */
    @UsedByGodot
    fun startVpn(config: String, xrayConfig: String, profileId: String, profileName: String): String {
        val act = activity ?: return "no activity"
        if (VpnService.prepare(act) != null) return "VPN permission is not granted"
        if (CoreClient.latencySessionActive) return "server test in progress, try again in a few seconds"
        return try {
            NexusVpnService.configFile(act).writeText(config)
            val xf = NexusVpnService.xrayConfigFile(act)
            if (xrayConfig.isEmpty()) xf.delete() else xf.writeText(xrayConfig)
            NexusVpnService.saveMeta(act, profileId, profileName)
            val intent = Intent(act, NexusVpnService::class.java)
                .setAction(NexusVpnService.ACTION_START)
                .putExtra(NexusVpnService.EXTRA_PROFILE_ID, profileId)
                .putExtra(NexusVpnService.EXTRA_PROFILE_NAME, profileName)
            startPending = true
            if (Build.VERSION.SDK_INT >= 26) act.startForegroundService(intent) else act.startService(intent)
            ""
        } catch (e: Exception) {
            Log.e(TAG, "start service failed", e)
            e.message ?: e.toString()
        }
    }

    @UsedByGodot
    fun stopVpn() {
        val act = activity ?: return
        if (!startPending && CoreState.read(act).optInt("state") == BoxCore.STOPPED) {
            // Nothing is running (e.g. the service process died): report it.
            emit("core_state", BoxCore.STOPPED, "")
            return
        }
        try {
            act.startService(Intent(act, NexusVpnService::class.java)
                .setAction(NexusVpnService.ACTION_STOP).putExtra("from_app", true))
        } catch (e: Exception) {
            Log.e(TAG, "stop failed", e)
            emit("core_state", BoxCore.STOPPED, e.message ?: "")
        }
    }

    @UsedByGodot
    fun urlTest(group: String): String = CoreClient.urlTest(group)

    @UsedByGodot
    fun startLatencySession(config: String, xrayConfig: String, group: String, timeoutMs: Int): String {
        val act = activity ?: return "no activity"
        if (CoreState.read(act).optInt("state") != BoxCore.STOPPED) return "VPN is running"
        if (CoreClient.latencySessionActive) return "a test is already running"
        CoreClient.runLatencySession(config, xrayConfig, group, timeoutMs.toLong()) { json -> emit("latency_result", json) }
        return ""
    }

    @UsedByGodot
    fun resetNetwork() {
        val act = activity ?: return
        if (CoreState.read(act).optInt("state") != BoxCore.STARTED) return
        runCatching {
            act.startService(Intent(act, NexusVpnService::class.java).setAction(NexusVpnService.ACTION_RESET_NETWORK))
        }
    }

    /** Sends the app to the background instead of quitting (quitting would kill the UI process). */
    @UsedByGodot
    fun moveToBack() {
        val act = activity ?: return
        runOnUiThread { act.moveTaskToBack(true) }
    }

    @UsedByGodot
    fun getNetworkInfo(): String = NetworkMonitor.snapshotJson()

    @UsedByGodot
    fun openVpnSettings(): Boolean {
        val act = activity ?: return false
        return try {
            act.startActivity(Intent(Settings.ACTION_VPN_SETTINGS))
            true
        } catch (e: Exception) {
            false
        }
    }

    // --- secure storage ----------------------------------------------------------

    @UsedByGodot
    fun keystoreWrap(plainB64: String): String = KeystoreHelper.wrap(plainB64)

    @UsedByGodot
    fun keystoreUnwrap(wrappedB64: String): String = KeystoreHelper.unwrap(wrappedB64)

    // --- apps -------------------------------------------------------------------------

    @UsedByGodot
    fun loadInstalledApps() {
        val ctx = activity ?: return
        io.execute { emit("apps_loaded", runCatching { AppsHelper.listJson(ctx) }.getOrDefault("[]")) }
    }

    @UsedByGodot
    fun getAppIcon(pkg: String, size: Int): ByteArray {
        val ctx = activity ?: return ByteArray(0)
        return AppsHelper.iconPng(ctx, pkg, size)
    }

    // --- notifications -----------------------------------------------------------------

    @UsedByGodot
    fun requestNotificationPermission() {
        val act = activity ?: return
        if (Build.VERSION.SDK_INT < 33 ||
            act.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) {
            emit("notification_permission_result", true)
            return
        }
        runOnUiThread { act.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQ_NOTIFICATIONS) }
    }

    @UsedByGodot
    fun hasNotificationPermission(): Boolean {
        val act = activity ?: return false
        return Build.VERSION.SDK_INT < 33 ||
            act.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
    }

    override fun onMainRequestPermissionsResult(requestCode: Int, permissions: Array<out String>?, grantResults: IntArray?) {
        super.onMainRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQ_NOTIFICATIONS) {
            emit("notification_permission_result", grantResults?.firstOrNull() == PackageManager.PERMISSION_GRANTED)
        }
    }

    // --- files ----------------------------------------------------------------------------

    /** Opens the system file picker; result: file_picked(tag, name, content, error). */
    @UsedByGodot
    fun pickFile(tag: String) {
        val act = activity ?: return
        pickTag = tag
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType("*/*")
        runOnUiThread {
            try {
                act.startActivityForResult(intent, REQ_PICK_FILE)
            } catch (e: Exception) {
                emit("file_picked", tag, "", "", "no file picker available")
            }
        }
    }

    /** Opens the system "save as" dialog; result: file_saved(ok, info). */
    @UsedByGodot
    fun saveFile(name: String, mime: String, content: String) {
        val act = activity ?: return
        pendingSaveContent = content.toByteArray(Charsets.UTF_8)
        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE)
            .setType(mime.ifEmpty { "application/octet-stream" }).putExtra(Intent.EXTRA_TITLE, name)
        runOnUiThread {
            try {
                act.startActivityForResult(intent, REQ_SAVE_FILE)
            } catch (e: Exception) {
                pendingSaveContent = null
                emit("file_saved", false, "no file picker available")
            }
        }
    }

    @UsedByGodot
    fun shareText(text: String, title: String) {
        val act = activity ?: return
        val send = Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, text)
        runOnUiThread { runCatching { act.startActivity(Intent.createChooser(send, title)) } }
    }

    // --- QR ---------------------------------------------------------------------------------

    /** Scans a QR code with the camera (Google code scanner; needs Play services). */
    @UsedByGodot
    fun scanQr() {
        val act = activity ?: return
        val gms = GoogleApiAvailability.getInstance().isGooglePlayServicesAvailable(act)
        if (gms != ConnectionResult.SUCCESS) {
            emit("qr_scanned", "", "Google Play services unavailable: use \"QR from image\"")
            return
        }
        runOnUiThread {
            val options = GmsBarcodeScannerOptions.Builder().setBarcodeFormats(Barcode.FORMAT_QR_CODE).build()
            GmsBarcodeScanning.getClient(act, options).startScan()
                .addOnSuccessListener { emit("qr_scanned", it.rawValue ?: "", if (it.rawValue == null) "empty QR code" else "") }
                .addOnCanceledListener { emit("qr_scanned", "", "cancelled") }
                .addOnFailureListener { emit("qr_scanned", "", it.message ?: "scanner failed") }
        }
    }

    /** Picks an image and decodes a QR code from it (works without Play services). */
    @UsedByGodot
    fun scanQrFromImage() {
        val act = activity ?: return
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType("image/*")
        runOnUiThread {
            try {
                act.startActivityForResult(intent, REQ_PICK_QR_IMAGE)
            } catch (e: Exception) {
                emit("qr_scanned", "", "no image picker available")
            }
        }
    }

    @UsedByGodot
    fun generateQrPng(text: String, size: Int): ByteArray = try {
        QrHelper.encodePng(text, size)
    } catch (e: Exception) {
        ByteArray(0)
    }

    // --- activity results ---------------------------------------------------------------------

    override fun onMainActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onMainActivityResult(requestCode, resultCode, data)
        when (requestCode) {
            REQ_VPN -> emit("vpn_permission_result", resultCode == Activity.RESULT_OK)
            REQ_PICK_FILE -> {
                val uri = data?.data
                if (resultCode != Activity.RESULT_OK || uri == null) {
                    emit("file_picked", pickTag, "", "", "cancelled")
                } else {
                    val tag = pickTag
                    io.execute { readPicked(tag, uri) }
                }
            }
            REQ_SAVE_FILE -> {
                val uri = data?.data
                val content = pendingSaveContent
                pendingSaveContent = null
                if (resultCode != Activity.RESULT_OK || uri == null || content == null) {
                    emit("file_saved", false, "cancelled")
                } else {
                    io.execute {
                        try {
                            activity?.contentResolver?.openOutputStream(uri, "wt")?.use { it.write(content) }
                                ?: throw IllegalStateException("cannot open destination")
                            emit("file_saved", true, displayName(uri))
                        } catch (e: Exception) {
                            emit("file_saved", false, e.message ?: "write failed")
                        }
                    }
                }
            }
            REQ_PICK_QR_IMAGE -> {
                val uri = data?.data
                if (resultCode != Activity.RESULT_OK || uri == null) {
                    emit("qr_scanned", "", "cancelled")
                } else {
                    io.execute { decodeQrImage(uri) }
                }
            }
        }
    }

    private fun displayName(uri: Uri): String {
        val cr = activity?.contentResolver ?: return ""
        return runCatching {
            cr.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
                if (c.moveToFirst()) c.getString(0) else ""
            } ?: ""
        }.getOrDefault("")
    }

    private fun readPicked(tag: String, uri: Uri) {
        val cr = activity?.contentResolver
        if (cr == null) {
            emit("file_picked", tag, "", "", "no activity")
            return
        }
        try {
            val name = displayName(uri)
            val bytes = cr.openInputStream(uri)?.use { input ->
                val buf = java.io.ByteArrayOutputStream()
                val chunk = ByteArray(64 * 1024)
                var total = 0
                while (true) {
                    val n = input.read(chunk)
                    if (n < 0) break
                    total += n
                    if (total > MAX_FILE_BYTES) throw IllegalStateException("file is larger than 8 MB")
                    buf.write(chunk, 0, n)
                }
                buf.toByteArray()
            } ?: throw IllegalStateException("cannot open file")
            val text = String(bytes, Charsets.UTF_8)
            if (!text.toByteArray(Charsets.UTF_8).contentEquals(bytes)) throw IllegalStateException("file is not UTF-8 text")
            emit("file_picked", tag, name, text, "")
        } catch (e: Exception) {
            emit("file_picked", tag, "", "", e.message ?: "read failed")
        }
    }

    private fun decodeQrImage(uri: Uri) {
        try {
            val cr = activity?.contentResolver ?: throw IllegalStateException("no activity")
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            cr.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) }
            var sample = 1
            while (bounds.outWidth / sample > 2048 || bounds.outHeight / sample > 2048) sample *= 2
            val bmp = cr.openInputStream(uri)?.use {
                BitmapFactory.decodeStream(it, null, BitmapFactory.Options().apply { inSampleSize = sample })
            } ?: throw IllegalStateException("cannot decode image")
            val text = QrHelper.decode(bmp)
            bmp.recycle()
            if (text == null) emit("qr_scanned", "", "no QR code found in the image")
            else emit("qr_scanned", text, "")
        } catch (e: Exception) {
            emit("qr_scanned", "", e.message ?: "image decode failed")
        }
    }
}
