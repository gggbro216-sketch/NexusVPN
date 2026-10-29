package com.nexusvpn.bridge

import io.nekohasekai.libbox.NetworkInterface as BoxNetworkInterface
import io.nekohasekai.libbox.NetworkInterfaceIterator
import io.nekohasekai.libbox.RoutePrefix
import io.nekohasekai.libbox.RoutePrefixIterator
import io.nekohasekai.libbox.StringIterator

/** Kotlin implementations of the gomobile iterator interfaces. */
class StringArrayIterator(private val items: List<String>) : StringIterator {
    private var index = 0
    override fun hasNext(): Boolean = index < items.size
    override fun len(): Int = items.size
    override fun next(): String = items[index++]
}

class InterfaceArrayIterator(private val items: List<BoxNetworkInterface>) : NetworkInterfaceIterator {
    private var index = 0
    override fun hasNext(): Boolean = index < items.size
    override fun next(): BoxNetworkInterface = items[index++]
}

fun StringIterator.toList(): List<String> {
    val out = ArrayList<String>()
    while (hasNext()) out.add(next())
    return out
}

fun RoutePrefixIterator.toList(): List<RoutePrefix> {
    val out = ArrayList<RoutePrefix>()
    while (hasNext()) out.add(next())
    return out
}
