package com.openscreens.app.ui.session

import org.junit.Assert.assertEquals
import org.junit.Test

class SessionToolbarLayoutTest {
    @Test
    fun reservesOneFullSlotForOverflowInPortrait() {
        assertEquals(6, sessionToolbarInlineCount(actionCount = 12, widthPx = 352, actionWidthPx = 48))
        // 1440 px minus 8 dp of bar padding, at 3.5 px per dp.
        assertEquals(7, sessionToolbarInlineCount(actionCount = 12, widthPx = 1412, actionWidthPx = 168))
    }

    @Test
    fun dropsAWholeActionAtTheExactFitBoundary() {
        assertEquals(12, sessionToolbarInlineCount(actionCount = 12, widthPx = 576, actionWidthPx = 48))
        assertEquals(10, sessionToolbarInlineCount(actionCount = 12, widthPx = 575, actionWidthPx = 48))
    }

    @Test
    fun keepsAllActionsInlineWhenTheyFitAWideOrObserveOnlySession() {
        assertEquals(12, sessionToolbarInlineCount(actionCount = 12, widthPx = 800, actionWidthPx = 48))
        assertEquals(7, sessionToolbarInlineCount(actionCount = 7, widthPx = 352, actionWidthPx = 48))
    }

    @Test
    fun leavesOnlyOverflowWithOneAvailableSlot() {
        assertEquals(0, sessionToolbarInlineCount(actionCount = 12, widthPx = 48, actionWidthPx = 48))
    }
}
