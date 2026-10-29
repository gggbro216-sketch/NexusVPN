package com.nexusvpn.bridge

import android.content.Context
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import io.nekohasekai.libbox.InterfaceUpdateListener
import org.json.JSONObject

/**
 * Tracks the underlying (non-VPN) default network.
 *
 * registerDefaultNetworkCallback() would report our own VPN once it is up, so a
 * NetworkRequest (which by default carries NOT_VPN) is used instead. Updates are
 * forwarded to sing-box (default interface for socket binding) and to the UI.
 */
object NetworkMonitor {
    private const val TAG = "NexusNetworkMonitor"

    private var connectivity: ConnectivityManager? = null
    private var thread: HandlerThread? = null
    private var handler: Handler? = null
    private var registered = false

    @Volatile var currentNetwork: Network? = null
        private set
    @Volatile private var coreListener: InterfaceUpdateListener? = null
    @Volatile private var lastType = ""
    @Volatile private var lastInterface = ""

    /** Receives JSON: {available, type, metered, interface, changed_type}. */
    @Volatile var appListener: ((String) -> Unit)? = null

    @Synchronized
    fun start(context: Context) {
        if (registered) return
        val cm = context.applicationContext.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        connectivity = cm
        val t = HandlerThread("nexus-network").also { it.start() }
        thread = t
        handler = Handler(t.looper)
        val request = NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_RESTRICTED)
            .build()
        try {
            when {
                Build.VERSION.SDK_INT >= 31 -> cm.registerBestMatchingNetworkCallback(request, callback, handler!!)
                Build.VERSION.SDK_INT >= 26 -> cm.requestNetwork(request, callback, handler!!)
                else -> cm.registerDefaultNetworkCallback(callback)
            }
            registered = true
        } catch (e: Exception) {
            Log.e(TAG, "register network callback failed", e)
        }
        if (currentNetwork == null && Build.VERSION.SDK_INT >= 23) {
            // Before any callback arrives, the active network is the best guess
            // (correct while our VPN is not running).
            val active = cm.activeNetwork
            val caps = active?.let { cm.getNetworkCapabilities(it) }
            if (caps != null && !caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) currentNetwork = active
        }
    }

    fun setCoreListener(listener: InterfaceUpdateListener?) {
        coreListener = listener
        if (listener != null) handler?.post { pushToCore(currentNetwork) }
    }

    fun snapshotJson(): String = describe(currentNetwork, false).toString()

    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            currentNetwork = network
            onChanged(network)
        }

        override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) {
            if (network == currentNetwork) onChanged(network)
        }

        override fun onLinkPropertiesChanged(network: Network, lp: LinkProperties) {
            if (network == currentNetwork) onChanged(network)
        }

        override fun onLost(network: Network) {
            if (network == currentNetwork) {
                currentNetwork = null
                onChanged(null)
            }
        }
    }

    private fun onChanged(network: Network?) {
        pushToCore(network)
        val info = describe(network, true)
        // Capability callbacks fire often (signal strength etc.); only report real changes.
        if (info.optBoolean("changed_type")) appListener?.invoke(info.toString())
    }

    private fun pushToCore(network: Network?) {
        val listener = coreListener ?: return
        val cm = connectivity ?: return
        try {
            if (network == null) {
                listener.updateDefaultInterface("", -1, false, false)
                return
            }
            // LinkProperties may lag behind onAvailable; retry briefly.
            repeat(10) {
                val lp = cm.getLinkProperties(network)
                val name = lp?.interfaceName
                if (name != null) {
                    val index = try {
                        java.net.NetworkInterface.getByName(name)?.index ?: -1
                    } catch (e: Exception) {
                        -1
                    }
                    if (index >= 0) {
                        val caps = cm.getNetworkCapabilities(network)
                        val metered = caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED) == false
                        listener.updateDefaultInterface(name, index, metered, false)
                        return
                    }
                }
                Thread.sleep(100)
            }
        } catch (e: Exception) {
            Log.e(TAG, "update default interface failed", e)
        }
    }

    private fun describe(network: Network?, trackChange: Boolean): JSONObject {
        val cm = connectivity
        val obj = JSONObject()
        if (network == null || cm == null) {
            obj.put("available", false).put("type", "none").put("metered", false).put("interface", "")
            obj.put("changed_type", trackChange && lastType != "none")
            if (trackChange) lastType = "none"
            return obj
        }
        val caps = cm.getNetworkCapabilities(network)
        val type = when {
            caps == null -> "other"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cellular"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "ethernet"
            else -> "other"
        }
        val iface = cm.getLinkProperties(network)?.interfaceName ?: ""
        obj.put("available", true).put("type", type)
        obj.put("metered", caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED) == false)
        obj.put("interface", iface)
        obj.put("changed_type", trackChange && (type != lastType || iface != lastInterface))
        if (trackChange) {
            lastType = type
            lastInterface = iface
        }
        return obj
    }
}
