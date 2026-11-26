package org.hohu.momentai

import kotlin.math.abs
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PlaybackSignalProcessorTest {
    @Test
    fun recordingLevelsDetermineGainAndSilenceStaysUnchanged() {
        fun pcm(amplitude: Int): ByteArray = ByteArray(32000).also { bytes ->
            for (index in 0 until 16000) {
                val value = if (index % 2 == 0) amplitude else -amplitude
                bytes[index * 2] = value.toByte()
                bytes[index * 2 + 1] = (value shr 8).toByte()
            }
        }
        fun gain(amplitude: Int): Float = PlaybackLoudnessProfile().apply { addPCM16(pcm(amplitude)) }.gain()
        assertEquals(25.6f, gain(128), 0.001f)
        assertEquals(1f, gain(8000), 0f)
        assertEquals(1f, gain(0), 0f)
        assertEquals(1f, gain(10), 0f)
        assertEquals(31.6227766f, gain(40), 0.001f)
        val processor = PlaybackSignalProcessor().apply { compensationGain = gain(128) }
        processor.configure(1f, true)
        repeat(320) { processor.process(0) }
        assertEquals(0.1f, processor.process(128), 0.001f)
        assertTrue(processor.process(Short.MAX_VALUE) <= 0.999f)
        processor.configure(1f, false)
        repeat(320) { processor.process(0) }
        assertEquals(128f / 32768, processor.process(128), 0.000001f)
    }

    @Test
    fun originalPcmRoundTripsAndEnhancementBoundsBothPolarities() {
        val processor = PlaybackSignalProcessor().apply { compensationGain = 2f }
        val bytes = byteArrayOf(0, -128, -1, 127, 0, 8, 0, -8)
        val original = bytes.copyOf()
        processor.processPCM16(bytes)
        org.junit.Assert.assertArrayEquals(original, bytes)
        processor.configure(1f, true)
        repeat(320) { processor.process(0) }
        assertEquals(0.125f, processor.process(2048), 0.0001f)
        assertEquals(-0.125f, processor.process(-2048), 0.0001f)
        assertTrue(processor.process(Short.MAX_VALUE) <= 0.999f)
        assertTrue(processor.process(Short.MIN_VALUE) >= -0.999f)
    }

    @Test
    fun muteRampsWithoutStepsAndRemainsZeroWithEnhancement() {
        val processor = PlaybackSignalProcessor().apply { compensationGain = 2f }
        processor.configure(0f, false)
        var previous = 0.5f
        repeat(320) {
            val next = processor.process(16384)
            assertTrue(next <= previous)
            assertTrue(abs(next - previous) <= 0.002f)
            previous = next
        }
        assertEquals(0f, processor.process(Short.MAX_VALUE), 0f)
        processor.configure(0f, true)
        repeat(320) { assertEquals(0f, processor.process(Short.MAX_VALUE), 0f) }
        processor.configure(0.5f, true)
        repeat(320) { processor.process(0) }
        assertEquals(0.0625f, processor.process(2048), 0.0001f)
    }

    @Test(expected = IllegalArgumentException::class)
    fun invalidGainIsRejected() {
        PlaybackSignalProcessor().configure(Float.NaN, false)
    }
}
