package com.openscreens.app.session

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DesktopPreviewCoverageTest {
    @Test
    fun waitsForACompleteInitialViewportAndAcceptsPaintWithoutInspectingColor() {
        val viewport = DesktopPreviewCoverage(x = 0, y = 0, width = 1280, height = 720)
        assertFalse(viewport.finishFrame())
        viewport.record(0, 0, 1280, 360)
        assertFalse(viewport.finishFrame())
        viewport.record(0, 360, 1280, 360)
        assertTrue(viewport.finishFrame())
    }

    @Test
    fun requiresOnlyTheCompleteOffsetViewport() {
        val viewport = DesktopPreviewCoverage(x = 1450, y = 900, width = 1001, height = 601)
        viewport.record(0, 0, 1280, 600)
        assertFalse(viewport.finishFrame())
        viewport.record(1440, 890, 1020, 620)
        assertTrue(viewport.finishFrame())
    }

    @Test
    fun physicalScreensCanLeaveGapsInALargeComposite() {
        val viewport = DesktopPreviewCoverage(x = 0, y = 0, width = 12032, height = 6042)
        val left = DisplayScreen(1, 0, 1080, 3840, 2160, 0)
        val right = DisplayScreen(2, 6000, 0, 6032, 6042, 0)
        viewport.restrictToDisplays(listOf(left, right), wholeDesktop = true)
        viewport.record(left.x, left.y, left.width, left.height)
        assertFalse(viewport.finishFrame())
        viewport.record(right.x, right.y, right.width, right.height)
        assertTrue(viewport.finishFrame())
    }

    @Test
    fun appleCompositeWithUnknownOriginsRequiresPhysicalAreaWithoutTheGaps() {
        val viewport = DesktopPreviewCoverage(x = 0, y = 0, width = 12032, height = 6042)
        viewport.restrictToDisplays(
            listOf(
                DisplayScreen(1, 0, 0, 3840, 2160, 0),
                DisplayScreen(2, 0, 0, 3840, 2160, 0),
                DisplayScreen(3, 0, 0, 4000, 6042, 0),
            ),
            wholeDesktop = true,
        )
        viewport.record(8032, 0, 4000, 6042)
        viewport.record(0, 2160, 3840, 2160)
        assertFalse(viewport.finishFrame())
        viewport.record(4100, 0, 3840, 2160)
        assertTrue(viewport.finishFrame())
    }

    @Test
    fun croppingIntoOnlyAGapDoesNotCreateAPreview() {
        val viewport = DesktopPreviewCoverage(x = 400, y = 0, width = 100, height = 100)
        viewport.restrictToDisplays(listOf(DisplayScreen(1, 0, 0, 200, 200, 0)), wholeDesktop = false)
        viewport.record(400, 0, 100, 100)
        assertFalse(viewport.finishFrame())
    }
}
