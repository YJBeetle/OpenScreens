package com.openscreens.app.data

import java.util.UUID

data class Connection(
    val id: String = UUID.randomUUID().toString(),
    val name: String,
    val host: String,
    val port: Int = DEFAULT_VNC_PORT,
    val username: String = "",
    val vncPassword: String = "",
    val ssh: SshCredentials? = null,
    val lastConnectedAt: Long? = null,
) {
    val address: String
        get() = "$host:$port"

    companion object {
        const val DEFAULT_VNC_PORT = 5900
    }
}

data class SshCredentials(
    val host: String = "",
    val username: String,
    val password: String = "",
    val port: Int = DEFAULT_SSH_PORT,
    val hostKeyFingerprint: String = "",
) {
    companion object {
        const val DEFAULT_SSH_PORT = 22
    }
}
