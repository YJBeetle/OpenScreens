package com.openscreens.app.ui.session

import org.junit.Assert.*
import org.junit.Test

class SessionRecoveryTest {
    @Test fun repeatedDropsExhaustBudgetUntilManualRetryOrStableConnection() {
        val recovery = SessionRecovery()
        listOf(1000L, 2000L, 4000L).forEach { delay ->
            recovery.failed("Network", retryable = true)
            assertEquals(delay, recovery.nextDelayMillis)
            assertTrue(recovery.takeRetry(manual = false))
            assertFalse(recovery.takeRetry(manual = true))
        }
        recovery.failed("Network", retryable = true)
        assertNull(recovery.nextDelayMillis)
        assertFalse(recovery.takeRetry(manual = false))
        assertTrue(recovery.takeRetry(manual = true))
        recovery.failed("Network", retryable = true)
        assertEquals(1000L, recovery.nextDelayMillis)
        assertTrue(recovery.takeRetry(manual = false))
        recovery.stable()
        recovery.failed("Network", retryable = true)
        assertEquals(1000L, recovery.nextDelayMillis)
    }

    @Test fun setupErrorsRequireExplicitRetry() {
        val recovery = SessionRecovery()
        recovery.failed("Tunnel settings", retryable = false)
        assertNull(recovery.nextDelayMillis)
        assertFalse(recovery.takeRetry(manual = false))
        assertTrue(recovery.takeRetry(manual = true))
    }
}
