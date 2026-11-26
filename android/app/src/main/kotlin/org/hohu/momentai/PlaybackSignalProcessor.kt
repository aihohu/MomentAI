package org.hohu.momentai

import kotlin.math.abs
import kotlin.math.exp
import kotlin.math.roundToInt

/** Playback-only gain with a 20 ms ramp and a bounded soft limiter. */
internal class PlaybackSignalProcessor {
    var compensationGain = 1f
    var volume = 1f
        private set
    var enhanced = false
        private set
    private var currentVolume = 1f
    private var mix = 0f
    private var remaining = 0

    fun configure(volume: Float, enhanced: Boolean) {
        require(volume.isFinite() && volume in 0f..1f)
        this.volume = volume
        this.enhanced = enhanced
        remaining = 320
    }

    fun reset() {
        currentVolume = 0f
        mix = if (enhanced) 1f else 0f
        remaining = 320
    }

    fun process(sample: Short): Float {
        if (remaining > 0) {
            currentVolume += (volume - currentVolume) / remaining
            mix += ((if (enhanced) 1f else 0f) - mix) / remaining
            remaining--
        }
        val original = sample.toFloat() / 32768f
        val amplified = original * compensationGain
        val magnitude = abs(amplified)
        val limited = if (magnitude <= 0.9f) {
            amplified
        } else {
            val peak = (0.9f + 0.1f * (1f - exp(-(magnitude - 0.9f) / 0.1f))).coerceAtMost(0.999f)
            if (amplified < 0) -peak else peak
        }
        return (original + mix * (limited - original)) * currentVolume
    }

    fun processPCM16(bytes: ByteArray) {
        require(bytes.size % 2 == 0)
        for (offset in bytes.indices step 2) {
            val sample = ((bytes[offset].toInt() and 255) or (bytes[offset + 1].toInt() shl 8)).toShort()
            val result = (process(sample) * 32768f).roundToInt().coerceIn(-32768, 32767)
            bytes[offset] = result.toByte()
            bytes[offset + 1] = (result shr 8).toByte()
        }
    }
}
