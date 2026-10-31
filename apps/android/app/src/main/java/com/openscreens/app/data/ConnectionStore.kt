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
    private val _connections = MutableStateFlow(initial ?: load() ?: sampleConnections())
    val connections: StateFlow<List<Connection>> = _connections.asStateFlow()

    init {
        if (initial == null && !file.exists()) {
            persist()
        }
    }

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

    private fun load(): List<Connection>? {
        if (!file.exists()) return null
        return runCatching {
            decode(String(decrypt(file.readBytes()), Charsets.UTF_8))
        }.onFailure { error ->
            Log.e(TAG, "Unable to read saved connections", error)
        }.getOrNull()
    }

    private fun persist() {
        runCatching {
            file.writeBytes(encrypt(encode(_connections.value).toByteArray(Charsets.UTF_8)))
        }.onFailure { error ->
            Log.e(TAG, "Unable to save connections", error)
        }
    }

    private fun encode(connections: List<Connection>): String {
        val array = JSONArray()
        connections.forEach { connection ->
            val item = JSONObject()
                .put("id", connection.id)
                .put("name", connection.name)
                .put("host", connection.host)
                .put("port", connection.port)
                .put("username", connection.username)
                .put("vncPassword", connection.vncPassword)
            connection.wireGuardConfig?.let { item.put("wireGuardConfig", it) }
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
            array.put(item)
        }
        return JSONObject()
            .put("version", 1)
            .put("connections", array)
            .toString()
    }

    private fun decode(text: String): List<Connection> {
        val array = JSONObject(text).getJSONArray("connections")
        return buildList {
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
                        host = item.getString("host"),
                        port = item.optInt("port", Connection.DEFAULT_VNC_PORT),
                        username = item.optString("username"),
                        vncPassword = item.optString("vncPassword"),
                        wireGuardConfig = item.optString("wireGuardConfig").takeIf { it.isNotBlank() },
                        ssh = ssh,
                        lastConnectedAt = if (item.has("lastConnectedAt") && !item.isNull("lastConnectedAt")) {
                            item.getLong("lastConnectedAt")
                        } else {
                            null
                        },
                    ),
                )
            }
        }
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

    private companion object {
        const val TAG = "ConnectionStore"
        const val KEYSTORE = "AndroidKeyStore"
        const val KEY_ALIAS = "openscreens.connections"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
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
