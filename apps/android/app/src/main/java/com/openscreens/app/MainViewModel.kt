package com.openscreens.app

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import com.openscreens.app.data.AppSettings
import com.openscreens.app.data.Connection
import com.openscreens.app.data.ConnectionStore
import com.openscreens.app.data.LibrarySortOrder
import com.openscreens.app.data.QualityPreset
import com.openscreens.app.data.UpdateChannel
import com.openscreens.app.data.SettingsStore
import com.openscreens.app.data.SshKey
import com.openscreens.app.data.SshKeyStore
import com.openscreens.app.data.ThemeMode
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

class MainViewModel(application: Application) : AndroidViewModel(application) {

    private val connectionStore = ConnectionStore(application)
    val connections = connectionStore.connections
    val groups = connectionStore.groups

    private val sshKeyStore = SshKeyStore(application)
    val sshKeys = sshKeyStore.keys

    private val settingsStore = SettingsStore(application)
    private val _settings = MutableStateFlow(settingsStore.load())
    val settings = _settings.asStateFlow()

    private val _route = MutableStateFlow<Route>(Route.Library)
    val route = _route.asStateFlow()

    fun connection(id: String): Connection? = connectionStore.find(id)

    fun saveConnection(connection: Connection) {
        connectionStore.save(connection)
    }

    fun markConnected(id: String) {
        connectionStore.markConnected(id)
    }

    fun addGroup(name: String) {
        connectionStore.addGroup(name)
    }

    fun renameGroup(id: String, name: String) {
        connectionStore.renameGroup(id, name)
    }

    fun deleteGroup(id: String) {
        connectionStore.deleteGroup(id)
    }

    fun moveConnection(id: String, offset: Int, orderedIds: List<String>) {
        connectionStore.moveConnection(id, offset, orderedIds)
    }

    fun setLibrarySort(sort: LibrarySortOrder) {
        _settings.update { it.copy(librarySort = sort) }
        settingsStore.save(_settings.value)
    }

    fun sshKey(id: String?): SshKey? = sshKeyStore.find(id)

    fun generateSshKey(name: String): Result<SshKey> = runCatching {
        val generated = uniffi.rfb_ffi.generateSshKey()
        SshKey(
            name = name,
            privateKeyPem = generated.privateKeyPem,
            publicKey = generated.publicKeyOpenssh,
            fingerprint = generated.fingerprint,
        ).also(sshKeyStore::add)
    }

    fun importSshKey(name: String, pem: String, passphrase: String): Result<SshKey> = runCatching {
        val pass = passphrase.ifBlank { null }
        val fingerprint = uniffi.rfb_ffi.sshKeyFingerprint(pem, pass)
        val publicKey = uniffi.rfb_ffi.sshPublicKey(pem, pass)
        SshKey(
            name = name,
            privateKeyPem = pem,
            publicKey = publicKey,
            fingerprint = fingerprint,
            passphrase = passphrase,
        ).also(sshKeyStore::add)
    }

    fun deleteSshKey(id: String) {
        sshKeyStore.delete(id)
    }

    fun setThemeMode(mode: ThemeMode) {
        _settings.update { it.copy(themeMode = mode) }
        settingsStore.save(_settings.value)
    }

    fun setConnectionQuality(id: String, quality: QualityPreset) {
        val connection = connectionStore.find(id) ?: return
        connectionStore.save(connection.copy(quality = quality))
    }

    fun setUpdateChannel(channel: UpdateChannel) {
        _settings.update { it.copy(updateChannel = channel) }
        settingsStore.save(_settings.value)
    }

    fun navigate(route: Route) {
        _route.value = route
    }

    fun back() {
        if (_route.value != Route.Library) {
            _route.value = Route.Library
        }
    }
}

sealed interface Route {
    data object Library : Route
    data object Settings : Route
    data object SshKeys : Route
    data class Editor(val connectionId: String?, val draft: Connection? = null) : Route
    data class Session(val connectionId: String) : Route
}
