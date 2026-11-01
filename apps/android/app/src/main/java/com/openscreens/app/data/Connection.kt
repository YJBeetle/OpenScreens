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
    /** Full .ovpn profile text; routes the session through userspace OpenVPN. */
    val openVpnConfig: String? = null,
    /** Streaming quality for this device. */
    val quality: QualityPreset = QualityPreset.Balanced,
    /** Two-finger pinch magnifies the remote image; off reserves two fingers for scrolling. */
    val zoomEnabled: Boolean = true,
    val lastConnectedAt: Long? = null,
    /** User-created library folder, when the connection belongs to one. */
    val groupId: String? = null,
) {
    val address: String
        get() = "$host:$port"

    companion object {
        const val DEFAULT_VNC_PORT = 5900
    }
}

data class ConnectionGroup(
    val id: String = UUID.randomUUID().toString(),
    val name: String,
)

/** How the library orders saved connections. */
enum class LibrarySortOrder { Manual, Az, Za, Recent }

/** Applies the chosen library order; manual keeps the stored sequence. */
fun List<Connection>.sortedForLibrary(sort: LibrarySortOrder): List<Connection> = when (sort) {
    LibrarySortOrder.Manual -> this
    LibrarySortOrder.Az -> sortedWith(
        compareBy(String.CASE_INSENSITIVE_ORDER) { connection: Connection -> connection.name },
    )
    LibrarySortOrder.Za -> sortedWith(
        compareByDescending(String.CASE_INSENSITIVE_ORDER) { connection: Connection -> connection.name },
    )
    LibrarySortOrder.Recent -> sortedByDescending { it.lastConnectedAt ?: 0L }
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
