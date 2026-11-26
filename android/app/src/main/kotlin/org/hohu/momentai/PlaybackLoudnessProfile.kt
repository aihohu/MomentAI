package org.hohu.momentai

import kotlin.math.ceil
import kotlin.math.sqrt

/** Bounded, recording-wide analysis; a fixed gain avoids pumping between words. */
internal class PlaybackLoudnessProfile {
    private val levels = ArrayList<Double>()

    fun addPCM16(bytes: ByteArray) {
        require(bytes.size % 2 == 0)
        var offset = 0
        while (offset < bytes.size) {
            val end = minOf(offset + 3200, bytes.size)
            var energy = 0.0
            val count = (end - offset) / 2
            while (offset < end) {
                val sample = ((bytes[offset].toInt() and 255) or (bytes[offset + 1].toInt() shl 8)).toShort()
                val value = sample.toDouble() / 32768
                energy += value * value
                offset += 2
            }
            // Ignore near-silence below -60 dBFS and windows shorter than 50 ms.
            val rms = sqrt(energy / count.coerceAtLeast(1))
            if (count >= 800 && rms >= 0.001) levels.add(rms)
        }
    }

    fun gain(): Float {
        if (levels.size < 5) return 1f
        val sorted = levels.sorted()
        val reference = sorted[(ceil(sorted.size * 0.9).toInt() - 1).coerceAtLeast(0)]
        // Target -20 dBFS active-window RMS, with at most +30 dB of compensation.
        return (0.1 / reference).coerceIn(1.0, 31.6227766).toFloat()
    }
}
