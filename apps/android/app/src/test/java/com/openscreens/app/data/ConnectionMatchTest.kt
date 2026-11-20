package com.openscreens.app.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ConnectionMatchTest {
    @Test fun nearbyAndQuickConnectReuseSavedEndpointWithItsSettings() {
        val saved = Connection(name = "Office", host = "office.local.", username = "alice", vncPassword = "existing")
        val target = Connection(name = "Discovered", host = "OFFICE.local")
        val library = listOf(saved)
        assertEquals(saved, library.matchingEndpoint(target))
        assertEquals(saved, library.matchingEndpoint(target.copy(username = "alice")))
        assertNull(library.matchingEndpoint(target.copy(username = "bob")))
        assertNull(library.matchingEndpoint(target.copy(port = 5901)))
    }
}
