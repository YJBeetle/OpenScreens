package com.openscreens.app.session

import org.junit.Assert.assertEquals
import org.junit.Test

class BgraBytesToArgbTest {
    @Test
    fun convertsBgraBytesToArgbPixels() {
        val pixels = byteArrayOf(0x30, 0x20, 0x10, 0x80.toByte())
        val out = IntArray(1)

        bgraBytesToArgb(pixels, 1, out)

        assertEquals(0x80102030.toInt(), out[0])
    }

    @Test
    fun ignoresBytesPastCount() {
        val pixels = byteArrayOf(
            0x01, 0x02, 0x03, 0x04,
            0x05, 0x06, 0x07, 0x08,
            0x09, 0x0A, 0x0B, 0x0C,
        )
        val out = IntArray(2)

        bgraBytesToArgb(pixels, 2, out)

        assertEquals(0x04030201, out[0])
        assertEquals(0x08070605, out[1])
    }
}
