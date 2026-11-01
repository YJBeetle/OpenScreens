package com.openscreens.app.data

import org.junit.Assert.assertEquals
import org.junit.Test

class LibrarySortTest {
    private val alpha = Connection(id = "a", name = "alpha", host = "a.local", lastConnectedAt = 100)
    private val bravo = Connection(id = "b", name = "Bravo", host = "b.local", lastConnectedAt = 300)
    private val charlie = Connection(id = "c", name = "charlie", host = "c.local")
    private val library = listOf(bravo, charlie, alpha)

    private fun ids(connections: List<Connection>) = connections.map { it.id }

    @Test
    fun manualKeepsStoredOrder() {
        assertEquals(listOf("b", "c", "a"), ids(library.sortedForLibrary(LibrarySortOrder.Manual)))
    }

    @Test
    fun azIgnoresCase() {
        assertEquals(listOf("a", "b", "c"), ids(library.sortedForLibrary(LibrarySortOrder.Az)))
    }

    @Test
    fun zaIgnoresCase() {
        assertEquals(listOf("c", "b", "a"), ids(library.sortedForLibrary(LibrarySortOrder.Za)))
    }

    @Test
    fun recentPutsNeverConnectedLast() {
        assertEquals(
            listOf("b", "a", "c"),
            ids(library.sortedForLibrary(LibrarySortOrder.Recent)),
        )
    }
}
