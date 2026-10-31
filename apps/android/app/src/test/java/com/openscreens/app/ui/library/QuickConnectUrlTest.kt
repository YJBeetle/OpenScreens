package com.openscreens.app.ui.library

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class QuickConnectUrlTest {
    @Test
    fun bare_host_uses_the_default_port() {
        assertEquals(
            QuickConnectTarget("mac.local", 5900, null),
            parseQuickConnectUrl("mac.local"),
        )
    }

    @Test
    fun parses_scheme_host_and_username() {
        assertEquals(
            QuickConnectTarget("10.24.24.2", 5901, "alice"),
            parseQuickConnectUrl("vnc://alice@10.24.24.2:5901"),
        )
    }

    @Test
    fun drops_the_password_from_the_url() {
        assertEquals(
            QuickConnectTarget("host", 5900, "alice"),
            parseQuickConnectUrl("vnc://alice:secret@host"),
        )
    }

    @Test
    fun scheme_is_case_insensitive() {
        assertEquals(
            QuickConnectTarget("MAC", 5900, null),
            parseQuickConnectUrl("VNC://MAC"),
        )
    }

    @Test
    fun strips_ipv6_brackets() {
        assertEquals(
            QuickConnectTarget("fe80::1", 5900, null),
            parseQuickConnectUrl("vnc://[fe80::1]:5900"),
        )
    }

    @Test
    fun ignores_path_and_query() {
        assertEquals(
            QuickConnectTarget("host", 5900, null),
            parseQuickConnectUrl("vnc://host:5900/desktop?scale=1"),
        )
    }

    @Test
    fun trims_surrounding_space() {
        assertEquals(
            QuickConnectTarget("host", 5900, null),
            parseQuickConnectUrl("  vnc://host  "),
        )
    }

    @Test
    fun rejects_other_schemes() {
        assertNull(parseQuickConnectUrl("ssh://host"))
        assertNull(parseQuickConnectUrl("http://host"))
    }

    @Test
    fun rejects_empty_host() {
        assertNull(parseQuickConnectUrl(""))
        assertNull(parseQuickConnectUrl("   "))
        assertNull(parseQuickConnectUrl("vnc://"))
    }

    @Test
    fun rejects_invalid_ports() {
        assertNull(parseQuickConnectUrl("vnc://host:0"))
        assertNull(parseQuickConnectUrl("vnc://host:70000"))
    }

    @Test
    fun rejects_malformed_input() {
        assertNull(parseQuickConnectUrl("vnc://host with space"))
    }
}
