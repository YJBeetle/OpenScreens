package com.openscreens.app.ui.session

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.openscreens.app.data.Connection
import com.openscreens.app.session.CredentialChallenge

/** Lives with the session composition. Only an accepted, opted-in attempt reaches storage. */
internal class SessionLogin(connection: Connection) {
    var attempt by mutableStateOf(connection)
        private set
    var generation by mutableIntStateOf(0)
        private set
    var rememberLogin by mutableStateOf(false)
        private set
    var challenge by mutableStateOf<CredentialChallenge?>(null)
        private set

    fun failed(required: CredentialChallenge?) {
        challenge = required
        if (required != null) attempt = attempt.copy(vncPassword = "")
    }

    fun retry(username: String, password: String, remember: Boolean) {
        val required = challenge ?: return
        if (password.isEmpty() || (required == CredentialChallenge.MissingUsername && username.isBlank())) return
        challenge = null
        rememberLogin = remember
        attempt = attempt.copy(username = username.trim(), vncPassword = password)
        generation++
    }

    fun accepted(): Connection? {
        if (!rememberLogin || challenge != null) return null
        rememberLogin = false
        return attempt
    }
}
