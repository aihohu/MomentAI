package org.hohu.momentai

import org.junit.Assert.assertEquals
import org.junit.Test

class CameraZoomScaleTest {
    @Test
    fun fullDeviceRangeFitsOneTrackWithClampedEnds() {
        for (maximum in listOf(1f, 40f, 120f)) {
            val scale = CameraZoomScale(0.5f, maximum)
            assertEquals(0.5f, scale.factorAtFraction(-1f), 0f)
            assertEquals(maximum, scale.factorAtFraction(1f), 0f)
            assertEquals(maximum, scale.factorAtFraction(2f), 0f)
            assertEquals(kotlin.math.sqrt(0.5f * maximum), scale.factorAtFraction(0.5f), 0.0001f)
            assertEquals(0f, scale.fraction(0.5f), 0f)
            assertEquals(1f, scale.fraction(maximum), 0f)
        }
        assertEquals(0f, CameraZoomScale(1f, 1f).fraction(1f), 0f)
    }

    @Test
    fun zoomHonorsDifferentDeviceRangesWithoutAnEightTimesCap() {
        for ((minimum, maximum) in listOf(0.5f to 40f, 1f to 120f, 1f to 1f)) {
            val scale = CameraZoomScale(minimum, maximum)
            assertEquals(minimum, scale.factor(-10f), 0f)
            assertEquals(maximum, scale.factor(scale.span + 10f), 0f)
            assertEquals(maximum, scale.factor(scale.position(maximum)), 0.0001f)
        }
    }

    @Test
    fun equalRatiosHaveEqualTravelAndIntermediateValuesRemainContinuous() {
        val scale = CameraZoomScale(0.5f, 40f)
        assertEquals(scale.position(2f) - scale.position(1f), scale.position(40f) - scale.position(20f), 0.0001f)
        assertEquals(17.3f, scale.factor(scale.position(17.3f)), 0.0001f)
    }
}
