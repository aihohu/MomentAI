package org.hohu.momentai

import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class PlaybackPreparationCacheTest {
    @Test
    fun repeatedAnchorsReusePreparationUntilStopOrSessionChange() {
        val cache = PlaybackPreparationCache()
        var loads = 0
        fun prepare(path: String) = cache.prepare(path) {
            loads++
            PreparedPlaybackSource(emptyList(), 16000, path, 2f)
        }
        val first = prepare("first")
        repeat(20) { assertSame(first, prepare("first")) }
        assertEquals(1, loads)
        assertEquals("second", prepare("second").sessionId)
        assertEquals(2, loads)
        cache.clear()
        prepare("second")
        assertEquals(3, loads)
    }

    @Test
    fun failedVerificationCannotReuseAnEarlierSource() {
        val cache = PlaybackPreparationCache()
        val first = PreparedPlaybackSource(emptyList(), 16000, "first", 1f)
        cache.prepare("first") { first }
        assertTrue(runCatching { cache.prepare("broken") { error("Audio checksum mismatch") } }.isFailure)
        var loads = 0
        cache.prepare("first") {
            loads++
            first
        }
        assertEquals(1, loads)
        assertTrue(runCatching { cache.prepare("broken") { error("Audio checksum mismatch") } }.isFailure)
    }
}
