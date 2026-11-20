package com.openscreens.app.data

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import android.util.Log
import java.io.File
import java.io.FileNotFoundException
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.getAndUpdate
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
    private val file = AtomicFile(File(context.applicationContext.filesDir, "connections.enc"))
    private val loaded = if (initial == null) load() else null
    private val _connections = MutableStateFlow(initial ?: loaded?.connections ?: sampleConnections())
    val connections: StateFlow<List<Connection>> = _connections.asStateFlow()
    internal val previews = ConnectionPreviewStore(
        File(context.applicationContext.noBackupFilesDir, "connection-previews"),
        initiallyEnabled = SettingsStore(context).load().showSessionPreviews,
        isSaved = { find(it) != null },
    )

    private val _groups = MutableStateFlow(loaded?.groups.orEmpty())
    val groups: StateFlow<List<ConnectionGroup>> = _groups.asStateFlow()

    init {
        if (initial == null && !file.baseFile.exists()) {
            persist()
        }
    }

    fun find(id: String): Connection? = _connections.value.firstOrNull { it.id == id }

    fun findGroup(id: String): ConnectionGroup? = _groups.value.firstOrNull { it.id == id }

    @Synchronized
    fun save(connection: Connection) {
        _connections.update { current ->
            val index = current.indexOfFirst { it.id == connection.id }
            if (index == -1) {
                current + connection
            } else {
                current.toMutableList().also {
                    it[index] = connection.copy(preferredDisplayId = current[index].preferredDisplayId)
                }
            }
        }
        persist()
    }

    @Synchronized
    fun deleteConnection(id: String): Boolean {
        val current = _connections.value
        val next = current.filterNot { it.id == id }
        if (next.size == current.size) return true
        if (!persist(next)) return false
        _connections.value = next
        previews.delete(id)
        return true
    }

    @Synchronized
    fun rememberLogin(source: Connection): Boolean {
        val current = find(source.id) ?: _connections.value.matchingEndpoint(source) ?: source
        if (!current.sameEndpoint(source)) return false
        val updated = current.copy(username = source.username, vncPassword = source.vncPassword)
        val next = _connections.value.toMutableList()
        val index = next.indexOfFirst { it.id == current.id }
        if (index >= 0) next[index] = updated else next.add(updated)
        if (!persist(next)) return false
        _connections.value = next
        return true
    }

    fun markConnected(id: String, at: Long = System.currentTimeMillis()) {
        updateConnection(id) { it.copy(lastConnectedAt = at) }
    }

    fun setQuality(id: String, quality: QualityPreset) {
        updateConnection(id) { it.copy(quality = quality) }
    }

    fun setPreferredDisplay(id: String, displayId: Int?) {
        updateConnection(id) { connection ->
            if (connection.rememberSelectedDisplay) {
                connection.copy(preferredDisplayId = displayId)
            } else {
                connection
            }
        }
    }

    @Synchronized
    private fun updateConnection(id: String, transform: (Connection) -> Connection) {
        val previous = _connections.getAndUpdate { current ->
            current.map { if (it.id == id) transform(it) else it }
        }
        if (previous != _connections.value) persist()
    }

    @Synchronized
    fun addGroup(name: String): ConnectionGroup {
        val group = ConnectionGroup(name = name.trim().ifEmpty { DEFAULT_GROUP_NAME })
        _groups.update { it + group }
        persist()
        return group
    }

    @Synchronized
    fun renameGroup(id: String, name: String) {
        val trimmed = name.trim()
        if (trimmed.isEmpty()) return
        _groups.update { groups ->
            groups.map { if (it.id == id) it.copy(name = trimmed) else it }
        }
        persist()
    }

    /** Removes a folder; its connections stay in the library without a group. */
    @Synchronized
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
    @Synchronized
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

    private fun load(): StoredLibrary? = try {
        decode(String(decrypt(file.readFully()), Charsets.UTF_8))
    } catch (_: FileNotFoundException) {
        null
    } catch (error: Exception) {
        Log.e(TAG, "Unable to read saved connections", error)
        null
    }

    private fun persist(connections: List<Connection> = _connections.value): Boolean = runCatching {
        val payload = encrypt(encode(connections, _groups.value).toByteArray(Charsets.UTF_8))
        val stream = file.startWrite()
        try {
            stream.write(payload)
            file.finishWrite(stream)
        } catch (error: Exception) {
            file.failWrite(stream)
            throw error
        }
    }.onFailure { error -> Log.e(TAG, "Unable to save connections", error) }.isSuccess

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
                .put("requestMacSharing", connection.requestMacSharing)
                .put("vncPassword", connection.vncPassword)
                .put("quality", connection.quality.name)
                .put("zoomEnabled", connection.zoomEnabled)
                .put("keepScreenAwake", connection.keepScreenAwake)
                .put("sharedClipboard", connection.sharedClipboard)
                .put("startInObserveMode", connection.startInObserveMode)
                .put("platform", connection.platform.name)
                .put("disconnectAction", connection.disconnectAction.name)
                .put("rememberSelectedDisplay", connection.rememberSelectedDisplay)
            connection.preferredDisplayId?.let { item.put("preferredDisplayId", it) }
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
                        requestMacSharing = item.optBoolean("requestMacSharing", false),
                        vncPassword = item.optString("vncPassword"),
                        wireGuardConfig = item.optString("wireGuardConfig").takeIf { it.isNotBlank() },
                        openVpnConfig = item.optString("openVpnConfig").takeIf { it.isNotBlank() },
                        quality = runCatching {
                            QualityPreset.valueOf(
                                item.optString("quality", QualityPreset.Balanced.name),
                            )
                        }.getOrDefault(QualityPreset.Balanced),
                        disconnectAction = DisconnectAction.fromStored(item.optString("disconnectAction")),
                        platform = RemotePlatform.entries.firstOrNull { it.name == item.optString("platform") }
                            ?: RemotePlatform.Other,
                        zoomEnabled = item.optBoolean("zoomEnabled", true),
                        keepScreenAwake = item.optBoolean("keepScreenAwake", false),
                        startInObserveMode = item.optBoolean("startInObserveMode", false),
                        rememberSelectedDisplay = item.optBoolean("rememberSelectedDisplay", true),
                        preferredDisplayId = item.opt("preferredDisplayId") as? Int,
                        // Legacy connections never granted automatic reads of local text.
                        sharedClipboard = item.optBoolean("sharedClipboard", false),
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

    companion object {
        @Volatile private var sharedInstance: ConnectionStore? = null

        fun shared(context: Context): ConnectionStore = sharedInstance ?: synchronized(this) {
            sharedInstance ?: ConnectionStore(context.applicationContext).also { sharedInstance = it }
        }

        private const val TAG = "ConnectionStore"
        private const val KEYSTORE = "AndroidKeyStore"
        private const val KEY_ALIAS = "openscreens.connections"
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
        private const val DEFAULT_GROUP_NAME = "Group"
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
