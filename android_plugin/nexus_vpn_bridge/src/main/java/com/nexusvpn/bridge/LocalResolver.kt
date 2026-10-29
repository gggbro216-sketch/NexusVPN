package com.nexusvpn.bridge

import android.net.DnsResolver
import android.os.Build
import android.os.CancellationSignal
import android.system.ErrnoException
import io.nekohasekai.libbox.ExchangeContext
import io.nekohasekai.libbox.LocalDNSTransport
import java.net.InetAddress
import java.net.UnknownHostException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * sing-box "local" DNS server backed by the system resolver of the underlying
 * (non-VPN) network. Without it, sing-box falls back to /etc/resolv.conf,
 * which on Android points to [::1]:53 and fails — server host names (e.g. a
 * Hysteria2 server given by domain) could not be resolved.
 */
object LocalResolver : LocalDNSTransport {
    private const val RCODE_NXDOMAIN = 3
    private const val TIMEOUT_S = 10L
    private val executor = Executors.newCachedThreadPool { r -> Thread(r, "nexus-dns").apply { isDaemon = true } }

    override fun raw(): Boolean = Build.VERSION.SDK_INT >= 29

    override fun exchange(ctx: ExchangeContext, message: ByteArray) {
        if (Build.VERSION.SDK_INT < 29) throw UnsupportedOperationException("raw DNS requires Android 10")
        val network = NetworkMonitor.awaitNetwork(2000) ?: throw IllegalStateException("missing default interface")
        val done = CountDownLatch(1)
        var failure: Exception? = null
        val signal = CancellationSignal()
        ctx.onCancel { signal.cancel(); done.countDown() }
        DnsResolver.getInstance().rawQuery(network, message, DnsResolver.FLAG_NO_RETRY, executor, signal,
            object : DnsResolver.Callback<ByteArray> {
                override fun onAnswer(answer: ByteArray, rcode: Int) {
                    if (rcode == 0) ctx.rawSuccess(answer) else ctx.errorCode(rcode)
                    done.countDown()
                }

                override fun onError(error: DnsResolver.DnsException) {
                    val cause = error.cause
                    if (cause is ErrnoException) ctx.errnoCode(cause.errno) else failure = error
                    done.countDown()
                }
            })
        await(done, signal)
        failure?.let { throw it }
    }

    override fun lookup(ctx: ExchangeContext, network: String, domain: String) {
        val net = NetworkMonitor.awaitNetwork(2000) ?: throw IllegalStateException("missing default interface")
        if (Build.VERSION.SDK_INT < 29) {
            val answer = try {
                net.getAllByName(domain)
            } catch (e: UnknownHostException) {
                ctx.errorCode(RCODE_NXDOMAIN)
                return
            }
            ctx.success(answer.mapNotNull { it.hostAddress }.joinToString("\n"))
            return
        }
        val done = CountDownLatch(1)
        var failure: Exception? = null
        val signal = CancellationSignal()
        ctx.onCancel { signal.cancel(); done.countDown() }
        val callback = object : DnsResolver.Callback<List<InetAddress>> {
            override fun onAnswer(answer: List<InetAddress>, rcode: Int) {
                if (rcode == 0) ctx.success(answer.mapNotNull { it.hostAddress }.joinToString("\n"))
                else ctx.errorCode(rcode)
                done.countDown()
            }

            override fun onError(error: DnsResolver.DnsException) {
                val cause = error.cause
                if (cause is ErrnoException) ctx.errnoCode(cause.errno) else failure = error
                done.countDown()
            }
        }
        val type = when {
            network.endsWith("4") -> DnsResolver.TYPE_A
            network.endsWith("6") -> DnsResolver.TYPE_AAAA
            else -> -1
        }
        if (type >= 0) {
            DnsResolver.getInstance().query(net, domain, type, DnsResolver.FLAG_NO_RETRY, executor, signal, callback)
        } else {
            DnsResolver.getInstance().query(net, domain, DnsResolver.FLAG_NO_RETRY, executor, signal, callback)
        }
        await(done, signal)
        failure?.let { throw it }
    }

    private fun await(done: CountDownLatch, signal: CancellationSignal) {
        if (!done.await(TIMEOUT_S, TimeUnit.SECONDS)) {
            signal.cancel()
            throw IllegalStateException("DNS query timed out")
        }
    }
}
