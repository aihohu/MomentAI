package org.hohu.momentai

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test

class CameraGeometryTest {
    @Test
    fun focusPointTracksSensorAndDisplayRotation() {
        assertEquals(Pair(0.7f, 0.8f), CameraGeometry.sensorPoint(0.2f, 0.7f, 90, 0))
        assertEquals(Pair(0.2f, 0.7f), CameraGeometry.sensorPoint(0.2f, 0.7f, 90, 90))
        val reversed = CameraGeometry.sensorPoint(0.2f, 0.7f, 270, 0)
        assertEquals(0.3f, reversed.first, 0.0001f)
        assertEquals(0.2f, reversed.second, 0.0001f)
        assertEquals(Pair(1f, 1f), CameraGeometry.sensorPoint(-1f, 2f, 90, 0))
    }

    @Test
    fun zoomCropPreservesSensorOffsetsAndKeepsTheCenter() {
        assertArrayEquals(intArrayOf(10, 20, 4010, 3020), CameraGeometry.zoomCrop(10, 20, 4000, 3000, 1f))
        assertArrayEquals(intArrayOf(1010, 770, 3010, 2270), CameraGeometry.zoomCrop(10, 20, 4000, 3000, 2f))
        assertArrayEquals(intArrayOf(1760, 1332, 2260, 1707), CameraGeometry.zoomCrop(10, 20, 4000, 3000, 8f))
    }

    @Test
    fun rearCameraJpegTracksDeviceRotationForDifferentSensors() {
        val rotations = listOf(0, 90, 180, 270)
        assertEquals(listOf(90, 180, 270, 0), rotations.map { CameraGeometry.jpegOrientation(90, it) })
        assertEquals(listOf(270, 0, 90, 180), rotations.map { CameraGeometry.jpegOrientation(270, it) })
        assertEquals(rotations, rotations.map { CameraGeometry.jpegOrientation(0, it) })
    }

    @Test
    fun jpegRoundsOrientationAndAcceptsCounterclockwiseDisplayFallback() {
        assertEquals(90, CameraGeometry.jpegOrientation(90, 44))
        assertEquals(180, CameraGeometry.jpegOrientation(90, 45))
        assertEquals(90, CameraGeometry.jpegOrientation(90, 359))
        assertEquals(0, CameraGeometry.jpegOrientation(90, -90))
    }

    @Test
    fun previewFitsPortraitLandscapeAndResizedWindowsWithoutStretching() {
        val portrait = CameraGeometry.previewScale(640, 480, 1000, 1600, 90, 0)
        assertEquals(1f, portrait.first, 0.0001f)
        assertEquals(0.8333333f, portrait.second, 0.0001f)
        val landscape = CameraGeometry.previewScale(640, 480, 1600, 1000, 90, 90)
        assertEquals(0.8333333f, landscape.first, 0.0001f)
        assertEquals(1f, landscape.second, 0.0001f)
        val resized = CameraGeometry.previewScale(640, 480, 1050, 600, 90, 0)
        assertEquals(0.4285714f, resized.first, 0.0001f)
        assertEquals(1f, resized.second, 0.0001f)
    }
}
