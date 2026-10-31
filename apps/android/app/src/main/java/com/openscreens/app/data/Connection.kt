package com.openscreens.app.data

import java.util.UUID

/** Explicit card colours; `null` on a connection keeps the name-derived colour. */
enum class ConnectionAccent {
    Teal,
    Rose,
    Indigo,
    Amber,
    Slate,
    Violet,
    Emerald,
    Sky,
}

data class Connection(
    val id: String = UUID.randomUUID().toString(),
    val name: String,
    val accent: ConnectionAccent? = null,
    val host: String,
    val port: Int = DEFAULT_VNC_PORT,
    val username: String = "",
    val vncPassword: String = "",
    val ssh: SshCredentials? = null,
    /** Full wg-quick configuration text; routes the session through userspace WireGuard. */
    val wireGuardConfig: String? = null,
    /** Streaming quality for this device. */
    val quality: QualityPreset = QualityPreset.Balanced,
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
    val authMode: SshAuthMode = SshAuthMode.Password,
    val keyId: String = "",
) {
    companion object {
        const val DEFAULT_SSH_PORT = 22
    }
}
