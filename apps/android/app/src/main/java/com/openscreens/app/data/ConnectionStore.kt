package com.openscreens.app.data

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

/**
 * In-memory list of saved servers. Persistence will be added once the Rust core
 * owns the connection database; the UI only observes [connections].
 */
class ConnectionStore(private val initial: List<Connection> = sampleConnections()) {

    private val _connections = MutableStateFlow(initial)
    val connections: StateFlow<List<Connection>> = _connections.asStateFlow()

    fun find(id: String): Connection? = _connections.value.firstOrNull { it.id == id }

    fun save(connection: Connection) {
        _connections.update { current ->
            val index = current.indexOfFirst { it.id == connection.id }
            if (index == -1) {
                current + connection
            } else {
                current.toMutableList().also { it[index] = connection }
            }
        }
    }

    fun markConnected(id: String, at: Long = System.currentTimeMillis()) {
        _connections.update { current ->
            current.map { connection ->
                if (connection.id == id) connection.copy(lastConnectedAt = at) else connection
            }
        }
    }
}

private fun sampleConnections(now: Long = System.currentTimeMillis()): List<Connection> {
    val hour = 60L * 60L * 1000L
    return listOf(
        Connection(
            id = "sample-studio",
            name = "Studio Mac",
            host = "192.168.1.24",
            port = 5900,
            lastConnectedAt = now - 2 * hour,
        ),
        Connection(
            id = "sample-loft",
            name = "Loft Server",
            host = "loft.local",
            port = 5901,
            ssh = SshCredentials(username = "ops"),
            lastConnectedAt = now - 3 * 24 * hour,
        ),
    )
}
