package com.openscreens.app.data

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Log
import java.io.File
import java.security.KeyStore
import java.util.UUID
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

enum class SshAuthMode { Password, PrivateKey }

data class SshKey(
    val id: String = UUID.randomUUID().toString(),
    val name: String,
    val privateKeyPem: String,
    val publicKey: String,
    val fingerprint: String,
    val passphrase: String = "",
)

/** SSH private keys, stored in an encrypted app-private file. */
class SshKeyStore(context: Context) {
    private val file = File(context.applicationContext.filesDir, "ssh_keys.enc")
    private val _keys = MutableStateFlow(load() ?: emptyList())
    val keys: StateFlow<List<SshKey>> = _keys.asStateFlow()

    fun find(id: String?): SshKey? = id?.let { wanted -> _keys.value.firstOrNull { it.id == wanted } }

    fun add(key: SshKey) {
        _keys.update { current -> current + key }
        persist()
    }

    fun delete(id: String) {
        _keys.update { current -> current.filterNot { it.id == id } }
        persist()
    }

    private fun load(): List<SshKey>? {
        if (!file.exists()) return null
        return runCatching {
            decode(String(decrypt(file.readBytes()), Charsets.UTF_8))
        }.onFailure { error ->
            Log.e(TAG, "Unable to read SSH keys", error)
        }.getOrNull()
    }

    private fun persist() {
        runCatching {
            file.writeBytes(encrypt(encode(_keys.value).toByteArray(Charsets.UTF_8)))
        }.onFailure { error ->
            Log.e(TAG, "Unable to save SSH keys", error)
        }
    }

    private fun encode(keys: List<SshKey>): String {
        val array = JSONArray()
        keys.forEach { key ->
            array.put(
                JSONObject()
                    .put("id", key.id)
                    .put("name", key.name)
                    .put("privateKeyPem", key.privateKeyPem)
                    .put("publicKey", key.publicKey)
                    .put("fingerprint", key.fingerprint)
                    .put("passphrase", key.passphrase),
            )
        }
        return JSONObject().put("version", 1).put("keys", array).toString()
    }

    private fun decode(text: String): List<SshKey> {
        val array = JSONObject(text).getJSONArray("keys")
        return buildList {
            for (index in 0 until array.length()) {
                val item = array.getJSONObject(index)
                add(
                    SshKey(
                        id = item.getString("id"),
                        name = item.getString("name"),
                        privateKeyPem = item.getString("privateKeyPem"),
                        publicKey = item.optString("publicKey"),
                        fingerprint = item.optString("fingerprint"),
                        passphrase = item.optString("passphrase"),
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
        const val TAG = "SshKeyStore"
        const val KEYSTORE = "AndroidKeyStore"
        const val KEY_ALIAS = "openscreens.sshkeys"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
    }
}
