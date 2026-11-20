package com.openscreens.app.session

import java.util.BitSet

/** Tracks the preview's sampled points in remote coordinates, including cropped viewports. */
internal class DesktopPreviewCoverage(
    private val x: Int,
    private val y: Int,
    private val width: Int,
    private val height: Int,
) {
    private val step = maxOf(1, ceilDivide(width, 640), ceilDivide(height, 360))
    private val columns = ceilDivide(width, step)
    private val rows = ceilDivide(height, step)
    private val expected = BitSet(columns * rows).apply { set(0, columns * rows) }
    private val painted = BitSet(columns * rows)
    private var minimumPaintedSamples: Int? = null
    var complete = false
        private set

    /** Areas outside the advertised physical displays need no damage update. */
    fun restrictToDisplays(displays: List<DisplayScreen>, wholeDesktop: Boolean) {
        minimumPaintedSamples = null
        expected.clear()
        complete = false
        if (displays.size > 1 && displays.all { it.x == 0 && it.y == 0 }) {
            // Apple can report display sizes without origins. For the full
            // composite, require the total physical area, allowing for gaps
            // and rounding at sample-grid edges. A crop has no reliable area
            // estimate without origins, so require all its samples.
            expected.set(0, columns * rows)
            if (wholeDesktop) {
                val physicalSamples = displays.sumOf {
                    (it.width / step).toLong() * (it.height / step)
                }
                minimumPaintedSamples = physicalSamples.coerceAtMost((columns * rows).toLong())
                    .toInt().takeIf { it > 0 }
            }
            return
        }
        for (display in displays) {
            cover(expected, display.x, display.y, display.width, display.height)
        }
    }

    fun record(left: Int, top: Int, width: Int, height: Int) {
        if (!complete) cover(painted, left, top, width, height)
    }

    fun finishFrame(): Boolean {
        if (complete || expected.isEmpty) return complete
        val minimum = minimumPaintedSamples
        complete = if (minimum != null) {
            painted.cardinality() >= minimum
        } else {
            val missing = expected.clone() as BitSet
            missing.andNot(painted)
            missing.isEmpty
        }
        return complete
    }

    private fun cover(bits: BitSet, left: Int, top: Int, width: Int, height: Int) {
        val startColumn = ceilDivide((left - x).coerceIn(0, this.width), step)
        val endColumn = ceilDivide((left + width - x).coerceIn(0, this.width), step)
        val startRow = ceilDivide((top - y).coerceIn(0, this.height), step)
        val endRow = ceilDivide((top + height - y).coerceIn(0, this.height), step)
        for (row in startRow until endRow) {
            val start = row * columns
            bits.set(start + startColumn, start + endColumn)
        }
    }

    private fun ceilDivide(value: Int, by: Int): Int = (value + by - 1) / by
}
