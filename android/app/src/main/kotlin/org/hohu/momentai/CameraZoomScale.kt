package org.hohu.momentai

import kotlin.math.ln
import kotlin.math.pow

/** Logarithmic travel gives the same finger distance to 1–2x and 20–40x. */
internal class CameraZoomScale(val minimum: Float, val maximum: Float) {
    init {
        require(minimum.isFinite() && maximum.isFinite() && minimum > 0 && maximum >= minimum)
    }

    fun position(value: Float): Float = ln(value.coerceIn(minimum, maximum) / minimum) / ln(2f)
    fun fraction(value: Float): Float = if (span > 0f) position(value) / span else 0f
    fun factorAtFraction(fraction: Float): Float = factor(fraction.coerceIn(0f, 1f) * span)
    fun factor(position: Float): Float {
        if (position <= 0f) return minimum
        if (position >= span) return maximum
        return (minimum * 2f.pow(position)).coerceIn(minimum, maximum)
    }
    val span: Float get() = ln(maximum / minimum) / ln(2f)
}
