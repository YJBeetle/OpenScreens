package com.openscreens.app.data

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.util.Log
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** A VNC server advertised over Bonjour on the local network. */
data class NearbyServer(
    val name: String,
    val host: String,
    val port: Int,
) {
    val id: String
        get() = "${host.lowercase()}:$port"

    val address: String
        get() = if (port == Connection.DEFAULT_VNC_PORT) host else "$host:$port"
}

/** Keeps one tile per endpoint and orders the nearby list by name. */
internal fun nearbyServers(entries: Collection<NearbyServer>): List<NearbyServer> {
    val seen = mutableSetOf<String>()
    return entries
        .sortedWith(compareBy(String.CASE_INSENSITIVE_ORDER) { it.name })
        .filter { seen.add(it.id) }
}

/**
 * Discovers `_rfb._tcp` services with Android's NSD stack. Callbacks arrive on
 * binder threads, so resolved state is guarded and published as an immutable
 * flow.
 */
class NearbyDiscovery(context: Context) {
    private val nsdManager =
        context.applicationContext.getSystemService(Context.NSD_SERVICE) as NsdManager

    private val _servers = MutableStateFlow<List<NearbyServer>>(emptyList())
    val servers: StateFlow<List<NearbyServer>> = _servers.asStateFlow()

    private val lock = Any()
    private val advertised = mutableSetOf<String>()
    private val resolved = linkedMapOf<String, NearbyServer>()
    private val pending = ArrayDeque<NsdServiceInfo>()
    private var resolvingName: String? = null
    private var listener: NsdManager.DiscoveryListener? = null
    private var active = false

    fun start() {
        synchronized(lock) {
            if (active) return
            active = true
            advertised.clear()
            resolved.clear()
            pending.clear()
            resolvingName = null
            publishLocked()

            val discovery = object : NsdManager.DiscoveryListener {
                override fun onDiscoveryStarted(serviceType: String) {
                    Log.d(TAG, "Browsing $serviceType")
                }

                override fun onServiceFound(serviceInfo: NsdServiceInfo) {
                    if (serviceInfo.serviceType != SERVICE_TYPE) return
                    synchronized(lock) {
                        if (!active) return
                        val name = serviceInfo.serviceName.orEmpty()
                        if (name.isEmpty()) return
                        advertised.add(name)
                        if (resolved.containsKey(name) || pending.any { it.serviceName == name }) {
                            return
                        }
                        pending.addLast(serviceInfo)
                        resolveNextLocked()
                    }
                }

                override fun onServiceLost(serviceInfo: NsdServiceInfo) {
                    synchronized(lock) {
                        val name = serviceInfo.serviceName.orEmpty()
                        advertised.remove(name)
                        resolved.remove(name)
                        pending.removeAll { it.serviceName == name }
                        publishLocked()
                    }
                }

                override fun onDiscoveryStopped(serviceType: String) {
                    Log.d(TAG, "Stopped browsing $serviceType")
                }

                override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                    Log.e(TAG, "Unable to browse $serviceType: $errorCode")
                    synchronized(lock) {
                        active = false
                        listener = null
                    }
                }

                override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {
                    Log.w(TAG, "Unable to stop browsing $serviceType: $errorCode")
                }
            }
            listener = discovery
            try {
                nsdManager.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, discovery)
            } catch (error: Exception) {
                Log.e(TAG, "Unable to start discovery", error)
                active = false
                listener = null
            }
        }
    }

    fun stop() {
        var current: NsdManager.DiscoveryListener? = null
        synchronized(lock) {
            if (!active) return
            active = false
            current = listener
            listener = null
            advertised.clear()
            resolved.clear()
            pending.clear()
            resolvingName = null
            publishLocked()
        }
        if (current != null) {
            runCatching { nsdManager.stopServiceDiscovery(current) }
                .onFailure { Log.w(TAG, "Unable to stop discovery", it) }
        }
    }

    @Suppress("DEPRECATION") // The callback resolver is the only NSD option below API 34.
    private fun resolveNextLocked() {
        if (!active || resolvingName != null) return
        val next = pending.removeFirstOrNull() ?: return
        val name = next.serviceName.orEmpty()
        resolvingName = name
        val resolveListener = object : NsdManager.ResolveListener {
            override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                Log.w(TAG, "Unable to resolve ${serviceInfo.serviceName}: $errorCode")
                synchronized(lock) {
                    if (resolvingName == name) resolvingName = null
                    resolveNextLocked()
                }
            }

            override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
                synchronized(lock) {
                    if (resolvingName == name) resolvingName = null
                    if (active && advertised.contains(name)) {
                        val host = serviceInfo.host?.hostAddress
                            ?.substringBefore('%')
                            ?.trimEnd('.')
                            ?.takeIf { it.isNotBlank() }
                        if (host != null && serviceInfo.port > 0) {
                            resolved[name] = NearbyServer(
                                name = name,
                                host = host,
                                port = serviceInfo.port,
                            )
                            publishLocked()
                        }
                    }
                    resolveNextLocked()
                }
            }
        }
        try {
            nsdManager.resolveService(next, resolveListener)
        } catch (error: Exception) {
            Log.e(TAG, "Unable to resolve $name", error)
            resolvingName = null
            resolveNextLocked()
        }
    }

    private fun publishLocked() {
        _servers.value = nearbyServers(resolved.values)
    }

    private companion object {
        const val TAG = "NearbyDiscovery"
        const val SERVICE_TYPE = "_rfb._tcp."
    }
}
