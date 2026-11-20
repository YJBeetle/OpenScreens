package com.openscreens.app.ui.session

import com.openscreens.app.data.Connection
import com.openscreens.app.session.CredentialChallenge
import org.junit.Assert.*
import org.junit.Test

class SessionLoginTest {
    private val profile = Connection(name = "Studio", host = "studio.local")

    @Test fun rejectedAndUncheckedCredentialsNeverReachStorage() {
        val login = SessionLogin(profile)
        login.failed(CredentialChallenge.MissingUsername)
        login.retry("  ", "wrong", true)
        assertEquals(0, login.generation)
        login.retry(" user ", "wrong", true)
        login.failed(CredentialChallenge.Rejected)
        assertEquals("", login.attempt.vncPassword)
        assertNull(login.accepted())
        login.retry(" user ", " correct ", false)
        assertEquals("user", login.attempt.username)
        assertEquals(" correct ", login.attempt.vncPassword)
        assertNull(login.accepted())
        assertEquals(2, login.generation)
        assertEquals("", SessionLogin(profile).attempt.vncPassword)
    }

    @Test fun acceptedOptInCanBeSavedOnce() {
        val login = SessionLogin(profile)
        login.failed(CredentialChallenge.MissingPassword)
        login.retry("", "correct", true)
        assertEquals(profile.copy(vncPassword = "correct"), login.accepted())
        assertNull(login.accepted())
        assertEquals("correct", login.attempt.vncPassword)
    }
}
