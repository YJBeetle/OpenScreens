package com.openscreens.app.data

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Log
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import org.json.JSONArray
import org.json.JSONObject

/**
 * Saved servers, persisted in app-private storage. The JSON payload is encrypted
 * with an AES/GCM key held by Android Keystore so credentials are not written in
 * plaintext.
 */
class ConnectionStore(
    context: Context,
    initial: List<Connection>? = null,
) {
    private val file = File(context.applicationContext.filesDir, "connections.enc")
    private val loaded = if (initial == null) load() else null
    private val _connections = MutableStateFlow(initial ?: loaded?.connections ?: sampleConnections())
    val connections: StateFlow<List<Connection>> = _connections.asStateFlow()

    private val _groups = MutableStateFlow(loaded?.groups.orEmpty())
    val groups: StateFlow<List<ConnectionGroup>> = _groups.asStateFlow()

    init {
        if (initial == null && !file.exists()) {
            persist()
        }
    }

    fun find(id: String): Connection? = _connections.value.firstOrNull { it.id == id }

    fun findGroup(id: String): ConnectionGroup? = _groups.value.firstOrNull { it.id == id }

    fun save(connection: Connection) {
        _connections.update { current ->
            val index = current.indexOfFirst { it.id == connection.id }
            if (index == -1) {
                current + connection
            } else {
                current.toMutableList().also { it[index] = connection }
            }
        }
        persist()
    }

    fun markConnected(id: String, at: Long = System.currentTimeMillis()) {
        _connections.update { current ->
            current.map { connection ->
                if (connection.id == id) connection.copy(lastConnectedAt = at) else connection
            }
        }
        persist()
    }

    fun addGroup(name: String): ConnectionGroup {
        val group = ConnectionGroup(name = name.trim().ifEmpty { DEFAULT_GROUP_NAME })
        _groups.update { it + group }
        persist()
        return group
    }

    fun renameGroup(id: String, name: String) {
        val trimmed = name.trim()
        if (trimmed.isEmpty()) return
        _groups.update { groups ->
            groups.map { if (it.id == id) it.copy(name = trimmed) else it }
        }
        persist()
    }

    /** Removes a folder; its connections stay in the library without a group. */
    fun deleteGroup(id: String) {
        _groups.update { groups -> groups.filterNot { it.id == id } }
        _connections.update { connections ->
            connections.map {
                if (it.groupId == id) it.copy(groupId = null) else it
            }
        }
        persist()
    }

    /** Moves a connection past its neighbour in the supplied manual order. */
    fun moveConnection(id: String, offset: Int, orderedIds: List<String>) {
        val index = orderedIds.indexOf(id)
        val neighbourIndex = index + offset
        if (index < 0 || neighbourIndex !in orderedIds.indices) return
        val neighbourId = orderedIds[neighbourIndex]
        _connections.update { current ->
            val from = current.indexOfFirst { it.id == id }
            val to = current.indexOfFirst { it.id == neighbourId }
            if (from < 0 || to < 0) return@update current
            current.toMutableList().also { list ->
                val moved = list[from]
                list[from] = list[to]
                list[to] = moved
            }
        }
        persist()
    }

    private fun load(): StoredLibrary? {
        if (!file.exists()) return null
        return runCatching {
            decode(String(decrypt(file.readBytes()), Charsets.UTF_8))
        }.onFailure { error ->
            Log.e(TAG, "Unable to read saved connections", error)
        }.getOrNull()
    }

    private fun persist() {
        runCatching {
            val payload = encode(_connections.value, _groups.value)
            file.writeBytes(encrypt(payload.toByteArray(Charsets.UTF_8)))
        }.onFailure { error ->
            Log.e(TAG, "Unable to save connections", error)
        }
    }

    private fun encode(
        connections: List<Connection>,
        groups: List<ConnectionGroup>,
    ): String {
        val array = JSONArray()
        connections.forEach { connection ->
            val item = JSONObject()
                .put("id", connection.id)
                .put("name", connection.name)
                .put("host", connection.host)
                .put("port", connection.port)
                .put("username", connection.username)
                .put("vncPassword", connection.vncPassword)
                .put("quality", connection.quality.name)
                .put("zoomEnabled", connection.zoomEnabled)
            connection.accent?.let { item.put("accent", it.name) }
            connection.wireGuardConfig?.let { item.put("wireGuardConfig", it) }
            connection.openVpnConfig?.let { item.put("openVpnConfig", it) }
            connection.ssh?.let { ssh ->
                item.put(
                    "ssh",
                    JSONObject()
                        .put("host", ssh.host)
                        .put("username", ssh.username)
                        .put("password", ssh.password)
                        .put("port", ssh.port)
                        .put("hostKeyFingerprint", ssh.hostKeyFingerprint)
                        .put("authMode", ssh.authMode.name)
                        .put("keyId", ssh.keyId),
                )
            }
            connection.lastConnectedAt?.let { item.put("lastConnectedAt", it) }
            connection.groupId?.let { item.put("groupId", it) }
            array.put(item)
        }
        val groupArray = JSONArray()
        groups.forEach { group ->
            groupArray.put(
                JSONObject()
                    .put("id", group.id)
                    .put("name", group.name),
            )
        }
        return JSONObject()
            .put("version", 2)
            .put("connections", array)
            .put("groups", groupArray)
            .toString()
    }

    private fun decode(text: String): StoredLibrary {
        val root = JSONObject(text)
        val array = root.getJSONArray("connections")
        val connections = buildList {
            for (index in 0 until array.length()) {
                val item = array.getJSONObject(index)
                val ssh = item.optJSONObject("ssh")?.let {
                    SshCredentials(
                        host = it.optString("host"),
                        username = it.optString("username"),
                        password = it.optString("password"),
                        port = it.optInt("port", SshCredentials.DEFAULT_SSH_PORT),
                        hostKeyFingerprint = it.optString("hostKeyFingerprint"),
                        authMode = runCatching {
                            SshAuthMode.valueOf(it.optString("authMode", SshAuthMode.Password.name))
                        }.getOrDefault(SshAuthMode.Password),
                        keyId = it.optString("keyId"),
                    )
                }
                add(
                    Connection(
                        id = item.getString("id"),
                        name = item.getString("name"),
                        accent = ConnectionAccent.entries.firstOrNull {
                            it.name == item.optString("accent")
                        },
                        host = item.getString("host"),
                        port = item.optInt("port", Connection.DEFAULT_VNC_PORT),
                        username = item.optString("username"),
                        vncPassword = item.optString("vncPassword"),
                        wireGuardConfig = item.optString("wireGuardConfig").takeIf { it.isNotBlank() },
                        openVpnConfig = item.optString("openVpnConfig").takeIf { it.isNotBlank() },
                        quality = runCatching {
                            QualityPreset.valueOf(
                                item.optString("quality", QualityPreset.Balanced.name),
                            )
                        }.getOrDefault(QualityPreset.Balanced),
                        zoomEnabled = item.optBoolean("zoomEnabled", true),
                        ssh = ssh,
                        lastConnectedAt = if (item.has("lastConnectedAt") && !item.isNull("lastConnectedAt")) {
                            item.getLong("lastConnectedAt")
                        } else {
                            null
                        },
                        groupId = item.optString("groupId").takeIf { it.isNotBlank() },
                    ),
                )
            }
        }
        val groupsArray = root.optJSONArray("groups")
        val groups = buildList {
            if (groupsArray != null) {
                for (index in 0 until groupsArray.length()) {
                    val item = groupsArray.getJSONObject(index)
                    add(
                        ConnectionGroup(
                            id = item.getString("id"),
                            name = item.getString("name"),
                        ),
                    )
                }
            }
        }
        return StoredLibrary(connections = connections, groups = groups)
    }

    private fun secretKey(): SecretKey {
        val keyStore = KeyStore.getInstance(KEYSTORE).apply { load(null) }
        (keyStore.getEntry(KEY_ALIAS, null) as? KeyStore.SecretKeyEntry)?.secretKey?.let { return it }

        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE)
        generator.init(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .build(),
        )
        return generator.generateKey()
    }

    private fun encrypt(plain: ByteArray): ByteArray {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, secretKey())
        val iv = cipher.iv
        return byteArrayOf(iv.size.toByte()) + iv + cipher.doFinal(plain)
    }

    private fun decrypt(payload: ByteArray): ByteArray {
        require(payload.isNotEmpty()) { "empty payload" }
        val ivLength = payload[0].toInt() and 0xFF
        val ivEnd = 1 + ivLength
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(
            Cipher.DECRYPT_MODE,
            secretKey(),
            GCMParameterSpec(128, payload.copyOfRange(1, ivEnd)),
        )
        return cipher.doFinal(payload.copyOfRange(ivEnd, payload.size))
    }

    private data class StoredLibrary(
        val connections: List<Connection>,
        val groups: List<ConnectionGroup>,
    )

    private companion object {
        const val TAG = "ConnectionStore"
        const val KEYSTORE = "AndroidKeyStore"
        const val KEY_ALIAS = "openscreens.connections"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val DEFAULT_GROUP_NAME = "Group"
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
