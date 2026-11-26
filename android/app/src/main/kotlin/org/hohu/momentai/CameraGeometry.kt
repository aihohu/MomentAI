package org.hohu.momentai

import kotlin.math.min

/** Orientation and fit calculations for the rear-facing camera. */
internal object CameraGeometry {
    /** Map a rear-camera preview point into the unrotated sensor coordinate space. */
    fun sensorPoint(x: Float, y: Float, sensorDegrees: Int, displayDegrees: Int): Pair<Float, Float> {
        val u = x.coerceIn(0f, 1f)
        val v = y.coerceIn(0f, 1f)
        return when ((sensorDegrees - displayDegrees + 360) % 360) {
            90 -> Pair(v, 1f - u)
            180 -> Pair(1f - u, 1f - v)
            270 -> Pair(1f - v, u)
            else -> Pair(u, v)
        }
    }

    /** Keep the crop centered and inside the active array, including nonzero sensor offsets. */
    fun zoomCrop(left: Int, top: Int, width: Int, height: Int, zoom: Float): IntArray {
        require(width > 0 && height > 0 && zoom.isFinite() && zoom >= 1f)
        val cropWidth = (width / zoom).toInt().coerceAtLeast(1)
        val cropHeight = (height / zoom).toInt().coerceAtLeast(1)
        val x = left + (width - cropWidth) / 2
        val y = top + (height - cropHeight) / 2
        return intArrayOf(x, y, x + cropWidth, y + cropHeight)
    }

    fun jpegOrientation(sensorDegrees: Int, clockwiseDeviceDegrees: Int): Int {
        val device = ((clockwiseDeviceDegrees % 360 + 360) % 360 + 45) / 90 * 90
        return (sensorDegrees + device) % 360
    }

    fun previewScale(
        bufferWidth: Int,
        bufferHeight: Int,
        viewWidth: Int,
        viewHeight: Int,
        sensorDegrees: Int,
        displayDegrees: Int
    ): Pair<Float, Float> {
        require(bufferWidth > 0 && bufferHeight > 0 && viewWidth > 0 && viewHeight > 0)
        val swapped = (sensorDegrees + displayDegrees) % 180 != 0
        val width = if (swapped) bufferHeight else bufferWidth
        val height = if (swapped) bufferWidth else bufferHeight
        val x = viewWidth.toFloat() / width
        val y = viewHeight.toFloat() / height
        val fit = min(x, y)
        return Pair(fit / x, fit / y)
    }
}
