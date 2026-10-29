package com.nexusvpn.bridge

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import android.os.Process
import android.system.OsConstants
import android.util.Log
import io.nekohasekai.libbox.BridgeOptions
import io.nekohasekai.libbox.BridgeSession
import io.nekohasekai.libbox.ConnectionOwner
import io.nekohasekai.libbox.InterfaceUpdateListener
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.LocalDNSTransport
import io.nekohasekai.libbox.NeighborUpdateListener
import io.nekohasekai.libbox.NetworkInterfaceIterator
import io.nekohasekai.libbox.Notification
import io.nekohasekai.libbox.PlatformInterface
import io.nekohasekai.libbox.PlatformUser
import io.nekohasekai.libbox.ShellSession
import io.nekohasekai.libbox.StringIterator
import io.nekohasekai.libbox.TunOptions
import io.nekohasekai.libbox.WIFIState
import java.net.InetSocketAddress
import io.nekohasekai.libbox.NetworkInterface as BoxNetworkInterface

/**
 * sing-box platform interface for Android.
 *
 * TUN creation and socket protection are delegated to the running
 * [NexusVpnService]. During latency tests no service runs: there is no TUN, and
 * sockets need no protection because no VPN routes exist.
 */
class BoxPlatform(private val context: Context) : PlatformInterface {
    private val connectivity = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager

    override fun usePlatformAutoDetectInterfaceControl(): Boolean = true

    override fun autoDetectInterfaceControl(fd: Int) {
        val service = BoxCore.vpnService ?: return
        // Excludes the core's own sockets from the VPN: prevents routing loops.
        if (!service.protect(fd)) throw IllegalStateException("android: VpnService.protect($fd) failed")
    }

    override fun openTun(options: TunOptions): Int {
        val service = BoxCore.vpnService ?: throw IllegalStateException("android: TUN requires the VPN service")
        return service.openTun(options)
    }

    // System resolver of the underlying network; sing-box's built-in fallback
    // reads /etc/resolv.conf, which does not work on Android.
    override fun localDNSTransport(): LocalDNSTransport = LocalResolver

    override fun findConnectionOwner(
        ipProtocol: Int,
        sourceAddress: String,
        sourcePort: Int,
        destinationAddress: String,
        destinationPort: Int,
    ): ConnectionOwner {
        val owner = if (Build.VERSION.SDK_INT >= 29) {
            val uid = connectivity.getConnectionOwnerUid(
                ipProtocol,
                InetSocketAddress(sourceAddress, sourcePort),
                InetSocketAddress(destinationAddress, destinationPort),
            )
            if (uid == Process.INVALID_UID) throw IllegalStateException("android: connection owner not found")
            ConnectionOwner().also { it.userId = uid }
        } else {
            Libbox.findConnectionOwner(ipProtocol, sourceAddress, sourcePort, destinationAddress, destinationPort)
        }
        val packages = context.packageManager.getPackagesForUid(owner.userId)?.toList() ?: emptyList()
        owner.userName = packages.firstOrNull() ?: ""
        owner.setAndroidPackageNames(StringArrayIterator(packages))
        return owner
    }

    override fun startDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {
        NetworkMonitor.start(context)
        NetworkMonitor.setCoreListener(listener)
    }

    override fun closeDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {
        NetworkMonitor.setCoreListener(null)
    }

    override fun getInterfaces(): NetworkInterfaceIterator {
        val result = ArrayList<BoxNetworkInterface>()
        val javaInterfaces = try {
            java.net.NetworkInterface.getNetworkInterfaces()?.toList() ?: emptyList()
        } catch (e: Exception) {
            emptyList()
        }
        @Suppress("DEPRECATION")
        for (network in connectivity.allNetworks) {
            val lp = connectivity.getLinkProperties(network) ?: continue
            val caps = connectivity.getNetworkCapabilities(network) ?: continue
            if (caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) continue
            val name = lp.interfaceName ?: continue
            val ji = javaInterfaces.find { it.name == name } ?: continue
            val bi = BoxNetworkInterface()
            bi.name = name
            bi.index = ji.index
            runCatching { bi.mtu = ji.mtu }
            // Zone ids ("%wlan0") must be stripped: Go parses these as netip.Prefix.
            bi.addresses = StringArrayIterator(ji.interfaceAddresses.mapNotNull { ia ->
                val host = ia.address?.hostAddress?.substringBefore('%') ?: return@mapNotNull null
                "$host/${ia.networkPrefixLength}"
            })
            bi.dnsServer = StringArrayIterator(lp.dnsServers.mapNotNull { it.hostAddress?.substringBefore('%') })
            bi.gateway = StringArrayIterator(lp.routes
                .filter { it.destination.prefixLength == 0 }
                .mapNotNull { it.gateway }
                .filterNot { it.isAnyLocalAddress }
                .mapNotNull { it.hostAddress?.substringBefore('%') })
            bi.type = when {
                caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> Libbox.InterfaceTypeWIFI
                caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> Libbox.InterfaceTypeCellular
                caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> Libbox.InterfaceTypeEthernet
                else -> Libbox.InterfaceTypeOther
            }
            var flags = 0
            if (caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) flags = OsConstants.IFF_UP or OsConstants.IFF_RUNNING
            if (ji.isLoopback) flags = flags or OsConstants.IFF_LOOPBACK
            if (ji.isPointToPoint) flags = flags or OsConstants.IFF_POINTOPOINT
            if (ji.supportsMulticast()) flags = flags or OsConstants.IFF_MULTICAST
            bi.flags = flags
            bi.metered = !caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
            result.add(bi)
        }
        return InterfaceArrayIterator(result)
    }

    override fun underNetworkExtension(): Boolean = false
    override fun includeAllNetworks(): Boolean = false
    override fun readWIFIState(): WIFIState? = null
    override fun clearDNSCache() {}

    override fun sendNotification(notification: Notification) {
        BoxCore.postCoreNotification(notification.title, notification.body)
    }

    override fun cancelNotification(identifier: String, typeID: Int) {}

    override fun startNeighborMonitor(listener: NeighborUpdateListener) {}
    override fun closeNeighborMonitor(listener: NeighborUpdateListener) {}
    override fun registerMyInterface(name: String) {}

    override fun usePlatformShell(): Boolean = false
    override fun checkPlatformShell() = throw UnsupportedOperationException("shell is not supported")
    override fun openShellSession(user: PlatformUser, command: String, environ: StringIterator, term: String, rows: Int, cols: Int): ShellSession =
        throw UnsupportedOperationException("shell is not supported")
    override fun lookupUser(username: String): PlatformUser = throw UnsupportedOperationException("not supported")
    override fun lookupSFTPServer(): String = throw UnsupportedOperationException("not supported")
    override fun readSystemSSHHostKey(): String = throw UnsupportedOperationException("not supported")
    override fun tailscaleHostname(): String = ""
    override fun usePlatformBridge(): Boolean = false
    override fun createBridge(options: BridgeOptions): BridgeSession = throw UnsupportedOperationException("bridge is not supported")

    companion object {
        private const val TAG = "NexusBoxPlatform"
        fun log(msg: String) = Log.d(TAG, msg)
    }
}
