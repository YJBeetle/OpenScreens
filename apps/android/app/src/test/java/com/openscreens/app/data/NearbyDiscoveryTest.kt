package com.openscreens.app.data

import org.junit.Assert.assertEquals
import org.junit.Test

class NearbyDiscoveryTest {
    @Test
    fun deduplicatesEndpointsAndSortsByName() {
        val servers = nearbyServers(
            listOf(
                NearbyServer("Zulu", "10.0.0.2", 5900),
                NearbyServer("alpha", "10.0.0.1", 5901),
                NearbyServer("Alpha Duplicate", "10.0.0.1", 5901),
                NearbyServer("Beta", "10.0.0.3", 5900),
            ),
        )

        assertEquals(listOf("alpha", "Beta", "Zulu"), servers.map { it.name })
    }

    @Test
    fun idAndAddressNormalizeHostAndDefaultPort() {
        val defaultPort = NearbyServer("Studio", "STUDIO.local", Connection.DEFAULT_VNC_PORT)
        assertEquals("studio.local:5900", defaultPort.id)
        assertEquals("STUDIO.local", defaultPort.address)

        val customPort = NearbyServer("Studio", "studio.local", 5901)
        assertEquals("studio.local:5901", customPort.address)
    }
}
