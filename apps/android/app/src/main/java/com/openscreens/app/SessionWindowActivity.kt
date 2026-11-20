package com.openscreens.app

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Surface
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.openscreens.app.data.ConnectionStore
import com.openscreens.app.data.SettingsStore
import com.openscreens.app.data.SshKeyStore
import com.openscreens.app.data.ThemeMode
import com.openscreens.app.ui.session.SessionScreen
import com.openscreens.app.ui.theme.OpenScreensTheme

/// A single remote session hosted in its own task, so freeform/desktop mode
/// can show several sessions side by side.
class SessionWindowActivity : ComponentActivity() {
    companion object {
        const val EXTRA_CONNECTION_ID = "connectionId"
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()

        val connectionStore = ConnectionStore.shared(applicationContext)
        val sshKeyStore = SshKeyStore(applicationContext)
        val settingsStore = SettingsStore(applicationContext)
        val connection = intent.getStringExtra(EXTRA_CONNECTION_ID)?.let(connectionStore::find)
        if (connection == null) {
            finish()
            return
        }

        setContent {
            val settings = remember { settingsStore.load() }
            val connections by connectionStore.connections.collectAsStateWithLifecycle()
            val current = connections.firstOrNull { it.id == connection.id } ?: connection
            val darkTheme = when (settings.themeMode) {
                ThemeMode.System -> isSystemInDarkTheme()
                ThemeMode.Light -> false
                ThemeMode.Dark -> true
            }

            OpenScreensTheme(darkTheme = darkTheme) {
                Surface(modifier = Modifier.fillMaxSize()) {
                    SessionScreen(
                        connection = current,
                        sshKey = sshKeyStore.find(current.ssh?.keyId),
                        quality = current.quality,
                        onQualityChange = { connectionStore.setQuality(current.id, it) },
                        onPreferredDisplayChange = { connectionStore.setPreferredDisplay(current.id, it) },
                        onConnected = { connectionStore.markConnected(connection.id) },
                        onExit = { finish() },
                    )
                }
            }
        }
    }
}
