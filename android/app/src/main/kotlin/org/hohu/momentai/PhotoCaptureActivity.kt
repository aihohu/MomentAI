package org.hohu.momentai

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.graphics.ImageFormat
import android.graphics.Rect
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureFailure
import android.hardware.camera2.CaptureRequest
import android.hardware.camera2.params.MeteringRectangle
import android.media.ImageReader
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.view.GestureDetector
import android.view.Gravity
import android.view.MotionEvent
import android.view.OrientationEventListener
import android.view.ScaleGestureDetector
import android.view.Surface
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.widget.Button
import android.widget.FrameLayout
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.activity.OnBackPressedCallback
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat

/** Camera-only native screen. It never opens an audio device or microphone session. */
class PhotoCaptureActivity :
    ComponentActivity(),
    SurfaceHolder.Callback {
    private val main = Handler(Looper.getMainLooper())
    private val cameraThread = HandlerThread("momentai-camera").apply { start() }
    private val cameraQueue = Handler(cameraThread.looper)
    private val runtime get() = RecordingRuntime.get(this)
    private lateinit var controls: CameraControlsView
    private var properties: CameraCharacteristics? = null
    private var activeArray = Rect()
    private var zoom = 1f
    private var minZoom = 1f
    private var maxZoom = 1f
    private var ratioZoom = false
    private var focusRegion: MeteringRectangle? = null
    private var manualFocus = false
    private var afMode = CaptureRequest.CONTROL_AF_MODE_OFF
    private var zoomAtGestureStart = 1f
    private val resetFocus = Runnable {
        manualFocus = false
        focusRegion = null
        refreshPreview()
    }
    private var tappedPoint: Pair<Float, Float>? = null
    private lateinit var surface: CameraSurface
    private lateinit var shutter: Button
    private lateinit var status: TextView
    private var device: CameraDevice? = null
    private var captureSession: CameraCaptureSession? = null
    private var images: ImageReader? = null
    private var sensorOrientation = 90
    private var previewWidth = 0
    private var previewHeight = 0
    private var deviceOrientation: Int? = null
    private val orientationListener by lazy {
        object : OrientationEventListener(this) {
            override fun onOrientationChanged(orientation: Int) {
                if (orientation != ORIENTATION_UNKNOWN) deviceOrientation = orientation
            }
        }
    }
    private var lastRecordingState = ""
    private val recordingStateListener: (String) -> Unit = { state ->
        if (state != lastRecordingState) {
            lastRecordingState = state
            if (!finishRequested) updateStatus()
        }
    }
    private var foreground = false
    private var generation = 0
    private var opening = false
    private var count = 0
    private var ticket: Map<*, *>? = null
    private var busy = false
    private var saving = false
    private var finishRequested = false
    private var fatalMessage: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        onBackPressedDispatcher.addCallback(
            this,
            object : OnBackPressedCallback(true) {
                override fun handleOnBackPressed() = requestFinish()
            }
        )
        NativeStrings.initialize(this)
        count = savedInstanceState?.getInt("count") ?: 0
        WindowCompat.setDecorFitsSystemWindows(window, false)
        WindowCompat.getInsetsController(window, window.decorView).apply {
            isAppearanceLightStatusBars = false
            isAppearanceLightNavigationBars = false
        }
        controls = CameraControlsView(this)
        ViewCompat.setOnApplyWindowInsetsListener(controls) { view, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout())
            view.setPadding(bars.left, bars.top, bars.right, bars.bottom)
            insets
        }
        surface = CameraSurface().also {
            it.holder.addCallback(this)
            it.isClickable = true
            it.contentDescription = NativeStrings.text(R.string.camera_preview_focus)
        }
        controls.preview.addView(surface, 0, FrameLayout.LayoutParams(-1, -1, Gravity.CENTER))
        controls.preview.addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ -> updatePreviewScale() }
        shutter = controls.shutter
        status = controls.status
        controls.back.setOnClickListener { requestFinish() }
        shutter.setOnClickListener { takePhoto() }
        configureGestures()
        controls.arrange(resources.configuration.orientation == Configuration.ORIENTATION_LANDSCAPE)
        setContentView(controls)
        updateStatus()
    }

    override fun onSaveInstanceState(outState: Bundle) {
        outState.putInt("count", count)
        super.onSaveInstanceState(outState)
    }
    override fun onResume() {
        super.onResume()
        foreground = true
        runtime.addStateListener(recordingStateListener)
        orientationListener.enable()
        openCamera()
    }
    override fun onPause() {
        foreground = false
        runtime.removeStateListener(recordingStateListener)
        main.removeCallbacks(resetFocus)
        orientationListener.disable()
        generation++
        opening = false
        shutter.isEnabled = false
        failPending(NativeStrings.text(R.string.native_photo_capture_was_interrupted_try_again_21))
        captureSession?.close()
        captureSession = null
        device?.close()
        device = null
        images?.close()
        images = null
        super.onPause()
    }
    override fun onDestroy() {
        cameraThread.quitSafely()
        super.onDestroy()
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        // Keep pending photo writes alive while the window rotates or resizes.
        controls.arrange(newConfig.orientation == Configuration.ORIENTATION_LANDSCAPE)
        focusRegion = null
        surface.post { updatePreviewScale() }
    }

    private fun displayRotationDegrees() = (surface.display?.rotation ?: Surface.ROTATION_0) * 90

    private fun updatePreviewScale() {
        val width = controls.preview.width
        val height = controls.preview.height
        if (previewWidth <= 0 || previewHeight <= 0 || width <= 0 || height <= 0) return
        val (x, y) = CameraGeometry.previewScale(
            previewWidth,
            previewHeight,
            width,
            height,
            sensorOrientation,
            displayRotationDegrees()
        )
        // Resize the actual surface instead of scaling a full-window layer outside its bounds.
        val fittedWidth = (width * x).toInt().coerceAtLeast(1)
        val fittedHeight = (height * y).toInt().coerceAtLeast(1)
        if (surface.layoutParams.width != fittedWidth || surface.layoutParams.height != fittedHeight) {
            surface.layoutParams = FrameLayout.LayoutParams(fittedWidth, fittedHeight, Gravity.CENTER)
        }
    }

    override fun surfaceCreated(holder: SurfaceHolder) {
        openCamera()
    }
    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) = Unit
    override fun surfaceDestroyed(holder: SurfaceHolder) = Unit

    @Suppress("MissingPermission", "DEPRECATION")
    private fun openCamera() {
        if (!foreground || !surface.holder.surface.isValid || opening || device != null) return
        if (checkSelfPermission(Manifest.permission.CAMERA) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            fatal(NativeStrings.text(R.string.native_allow_camera_access_first_15))
            return
        }
        if (!runtime.active) {
            fatal(NativeStrings.text(R.string.native_the_recording_has_ended_22))
            return
        }
        opening = true
        val token = ++generation
        try {
            val manager = getSystemService(CameraManager::class.java)
            val id = manager.cameraIdList.firstOrNull {
                manager.getCameraCharacteristics(it).get(CameraCharacteristics.LENS_FACING) ==
                    CameraCharacteristics.LENS_FACING_BACK
            } ?: error(NativeStrings.text(R.string.native_the_rear_camera_is_unavailable_23))
            val properties = manager.getCameraCharacteristics(id)
            this.properties = properties
            configureCameraControls(properties)
            sensorOrientation = properties.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 90
            val formats = properties.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)!!
            val size =
                formats.getOutputSizes(ImageFormat.JPEG).filter {
                    it.width.toLong() * it.height <=
                        4_000_000
                }
                    .maxByOrNull { it.width * it.height }
                    ?: formats.getOutputSizes(ImageFormat.JPEG).minBy {
                        it.width.toLong() *
                            it.height
                    }
            val previewSize =
                formats.getOutputSizes(SurfaceHolder::class.java).filter {
                    it.width <= 1920 &&
                        it.height <= 1080
                }
                    .sortedWith(
                        compareBy<android.util.Size> {
                            kotlin.math.abs(it.width.toDouble() / it.height - size.width.toDouble() / size.height)
                        }.thenByDescending { it.width.toLong() * it.height }
                    )
                    .firstOrNull()
                    ?: formats.getOutputSizes(SurfaceHolder::class.java).first()
            previewWidth = previewSize.width
            previewHeight = previewSize.height
            surface.holder.setFixedSize(previewWidth, previewHeight)
            updatePreviewScale()
            val reader = ImageReader.newInstance(size.width, size.height, ImageFormat.JPEG, 2)
            images = reader
            reader.setOnImageAvailableListener({ source ->
                val bytes = runCatching {
                    source.acquireNextImage()?.use { image ->
                        val buffer = image.planes[0].buffer
                        require(buffer.remaining().toLong() <= SessionStore.MAX_IMAGE_BYTES)
                        canonicalJpeg(ByteArray(buffer.remaining()).also { buffer.get(it) })
                    }
                }.getOrNull()
                main.post {
                    if (token != generation) return@post
                    if (bytes ==
                        null
                    ) {
                        failPending(
                            NativeStrings.text(R.string.native_could_not_read_the_photo_24)
                        )
                    } else {
                        savePhoto(bytes)
                    }
                }
            }, cameraQueue)
            manager.openCamera(
                id,
                object : CameraDevice.StateCallback() {
                    override fun onOpened(camera: CameraDevice) {
                        if (!foreground || token != generation) {
                            camera.close()
                            return
                        }
                        device = camera
                        opening = false
                        camera.createCaptureSession(
                            listOf(surface.holder.surface, reader.surface),
                            object : CameraCaptureSession.StateCallback() {
                                override fun onConfigured(session: CameraCaptureSession) {
                                    if (!foreground || token != generation) {
                                        session.close()
                                        return
                                    }
                                    captureSession = session
                                    try {
                                        refreshPreview()
                                        shutter.isEnabled = !busy
                                    } catch (failure: Exception) {
                                        fatal(
                                            failure.message
                                                ?: NativeStrings.text(
                                                    R.string.native_camera_preview_failed_25
                                                )
                                        )
                                    }
                                }
                                override fun onConfigureFailed(session: CameraCaptureSession) {
                                    fatal(
                                        NativeStrings.text(
                                            R.string.native_camera_configuration_failed_26
                                        )
                                    )
                                    session.close()
                                }
                            },
                            main
                        )
                    }
                    override fun onDisconnected(camera: CameraDevice) {
                        camera.close()
                        if (token ==
                            generation
                        ) {
                            fatal(
                                NativeStrings.text(R.string.native_the_camera_was_disconnected_27)
                            )
                        }
                    }
                    override fun onError(camera: CameraDevice, error: Int) {
                        camera.close()
                        if (token ==
                            generation
                        ) {
                            fatal(
                                NativeStrings.text(
                                    R.string.native_the_camera_is_temporarily_unavailable_s_28,
                                    (error).toString()
                                )
                            )
                        }
                    }
                },
                main
            )
        } catch (failure: Exception) {
            opening = false
            fatal(
                failure.message ?: NativeStrings.text(R.string.native_could_not_open_the_camera_29)
            )
        }
    }

    private fun configureCameraControls(characteristics: CameraCharacteristics) {
        activeArray = characteristics.get(CameraCharacteristics.SENSOR_INFO_ACTIVE_ARRAY_SIZE) ?: Rect(0, 0, 1, 1)
        val range = if (Build.VERSION.SDK_INT >= 30) characteristics.get(CameraCharacteristics.CONTROL_ZOOM_RATIO_RANGE) else null
        ratioZoom = range != null
        minZoom = range?.lower ?: 1f
        maxZoom = (range?.upper ?: characteristics.get(CameraCharacteristics.SCALER_AVAILABLE_MAX_DIGITAL_ZOOM) ?: 1f)
        zoom = zoom.coerceIn(minZoom, maxZoom)
        focusRegion = null
        manualFocus = false
        val modes = characteristics.get(CameraCharacteristics.CONTROL_AF_AVAILABLE_MODES) ?: intArrayOf()
        afMode = when {
            CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE in modes -> CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE
            CaptureRequest.CONTROL_AF_MODE_AUTO in modes -> CaptureRequest.CONTROL_AF_MODE_AUTO
            else -> CaptureRequest.CONTROL_AF_MODE_OFF
        }
        controls.configureZoom(minZoom, maxZoom, ::setZoom)
        controls.updateZoom(zoom)
    }

    private inner class CameraSurface : SurfaceView(this@PhotoCaptureActivity) {
        override fun performClick(): Boolean {
            super.performClick()
            val point = tappedPoint ?: Pair(width / 2f, height / 2f)
            tappedPoint = null
            if (!busy) focusAt(point.first, point.second)
            return true
        }
    }

    private fun configureGestures() {
        var pinched = false
        val scale = ScaleGestureDetector(
            this,
            object : ScaleGestureDetector.SimpleOnScaleGestureListener() {
                override fun onScaleBegin(detector: ScaleGestureDetector): Boolean {
                    pinched = true
                    zoomAtGestureStart = zoom
                    return !busy
                }
                override fun onScale(detector: ScaleGestureDetector): Boolean {
                    zoomAtGestureStart = (zoomAtGestureStart * detector.scaleFactor).coerceIn(minZoom, maxZoom)
                    setZoom(zoomAtGestureStart)
                    return true
                }
            }
        )
        val tap = GestureDetector(
            this,
            object : GestureDetector.SimpleOnGestureListener() {
                override fun onDown(event: MotionEvent) = true
                override fun onSingleTapUp(event: MotionEvent): Boolean {
                    if (!pinched && !busy) tappedPoint = Pair(event.x, event.y)
                    return true
                }
            }
        )
        surface.setOnTouchListener { view, event ->
            if (event.actionMasked == MotionEvent.ACTION_DOWN) pinched = false
            scale.onTouchEvent(event)
            tap.onTouchEvent(event)
            if (event.actionMasked == MotionEvent.ACTION_UP && !pinched) view.performClick()
            true
        }
    }

    private fun setZoom(value: Float) {
        if (busy || captureSession == null) {
            controls.updateZoom(zoom)
            return
        }
        zoom = value.coerceIn(minZoom, maxZoom)
        focusRegion = null
        manualFocus = false
        main.removeCallbacks(resetFocus)
        controls.updateZoom(zoom)
        refreshPreview()
    }

    private fun cropRegion(): Rect {
        if (ratioZoom) return Rect(activeArray)
        val crop = CameraGeometry.zoomCrop(activeArray.left, activeArray.top, activeArray.width(), activeArray.height(), zoom)
        return Rect(crop[0], crop[1], crop[2], crop[3])
    }

    private fun applyCameraSettings(request: CaptureRequest.Builder) {
        request.set(CaptureRequest.CONTROL_MODE, CaptureRequest.CONTROL_MODE_AUTO)
        if (Build.VERSION.SDK_INT >= 30 && ratioZoom) {
            request.set(CaptureRequest.CONTROL_ZOOM_RATIO, zoom)
        } else {
            request.set(CaptureRequest.SCALER_CROP_REGION, cropRegion())
        }
        request.set(CaptureRequest.CONTROL_AF_MODE, if (manualFocus) CaptureRequest.CONTROL_AF_MODE_AUTO else afMode)
        request.set(CaptureRequest.CONTROL_AE_MODE, CaptureRequest.CONTROL_AE_MODE_ON)
        focusRegion?.let { region ->
            if ((properties?.get(CameraCharacteristics.CONTROL_MAX_REGIONS_AF) ?: 0) > 0) {
                request.set(CaptureRequest.CONTROL_AF_REGIONS, arrayOf(region))
            }
            if ((properties?.get(CameraCharacteristics.CONTROL_MAX_REGIONS_AE) ?: 0) > 0) {
                request.set(CaptureRequest.CONTROL_AE_REGIONS, arrayOf(region))
            }
        }
    }

    private fun refreshPreview(triggerFocus: Boolean = false) {
        val camera = device ?: return
        val session = captureSession ?: return
        if (!foreground) return
        try {
            val request = camera.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW).apply {
                addTarget(surface.holder.surface)
                applyCameraSettings(this)
            }
            if (triggerFocus && manualFocus) {
                request.set(CaptureRequest.CONTROL_AF_TRIGGER, CaptureRequest.CONTROL_AF_TRIGGER_CANCEL)
                session.capture(request.build(), null, main)
                request.set(CaptureRequest.CONTROL_AF_TRIGGER, CaptureRequest.CONTROL_AF_TRIGGER_START)
                session.capture(request.build(), null, main)
                request.set(CaptureRequest.CONTROL_AF_TRIGGER, CaptureRequest.CONTROL_AF_TRIGGER_IDLE)
            }
            session.setRepeatingRequest(request.build(), null, main)
        } catch (failure: Exception) {
            fatal(failure.message ?: NativeStrings.text(R.string.native_camera_preview_failed_25))
        }
    }

    private fun focusAt(x: Float, y: Float) {
        if (captureSession == null || surface.width == 0 || surface.height == 0) return
        val (u, v) = CameraGeometry.sensorPoint(x / surface.width, y / surface.height, sensorOrientation, displayRotationDegrees())
        val crop = cropRegion()
        val width = (crop.width() / 8).coerceAtLeast(1)
        val height = (crop.height() / 8).coerceAtLeast(1)
        val left = (crop.left + crop.width() * u - width / 2).toInt().coerceIn(crop.left, crop.right - width)
        val top = (crop.top + crop.height() * v - height / 2).toInt().coerceIn(crop.top, crop.bottom - height)
        focusRegion = MeteringRectangle(Rect(left, top, left + width, top + height), MeteringRectangle.METERING_WEIGHT_MAX)
        manualFocus =
            properties?.get(CameraCharacteristics.CONTROL_AF_AVAILABLE_MODES)?.contains(CaptureRequest.CONTROL_AF_MODE_AUTO) == true
        controls.showFocus(x + surface.left, y + surface.top)
        refreshPreview(triggerFocus = true)
        main.removeCallbacks(resetFocus)
        main.postDelayed(resetFocus, 5000)
    }

    private fun takePhoto() {
        if (busy || captureSession == null) return
        busy = true
        shutter.isEnabled = false
        updateStatus()
        runtime.addCapture("image", reply = { result ->
            result.fold({ value ->
                ticket = value as Map<*, *>
                if (!foreground ||
                    finishRequested
                ) {
                    failPending(
                        NativeStrings.text(R.string.native_photo_capture_was_cancelled_30)
                    )
                    return@fold
                }
                try {
                    val camera =
                        device
                            ?: error(NativeStrings.text(R.string.native_the_camera_was_closed_31))
                    val reader =
                        images
                            ?: error(NativeStrings.text(R.string.native_the_camera_was_closed_31))
                    val request = camera.createCaptureRequest(
                        CameraDevice.TEMPLATE_STILL_CAPTURE
                    ).apply {
                        addTarget(reader.surface)
                        applyCameraSettings(this)
                        set(
                            CaptureRequest.JPEG_ORIENTATION,
                            CameraGeometry.jpegOrientation(
                                sensorOrientation,
                                deviceOrientation ?: -displayRotationDegrees()
                            )
                        )
                        set(CaptureRequest.JPEG_QUALITY, 90.toByte())
                    }
                    captureSession!!.capture(
                        request.build(),
                        object : CameraCaptureSession.CaptureCallback() {
                            override fun onCaptureFailed(session: CameraCaptureSession, request: CaptureRequest, failure: CaptureFailure) {
                                failPending(
                                    NativeStrings.text(
                                        R.string.native_could_not_take_the_photo_try_again_32
                                    )
                                )
                            }
                        },
                        main
                    )
                    val current = ticket
                    main.postDelayed({
                        if (ticket === current &&
                            !saving
                        ) {
                            failPending(
                                NativeStrings.text(
                                    R.string.native_the_camera_timed_out_try_again_33
                                )
                            )
                        }
                    }, 10000)
                } catch (failure: Exception) {
                    failPending(
                        failure.message
                            ?: NativeStrings.text(R.string.native_could_not_take_the_photo_34)
                    )
                }
            }, {
                busy = false
                status.text =
                    NativeStrings.text(R.string.native_not_saved_s_35, (it.message).toString())
                shutter.isEnabled =
                    foreground
                if (finishRequested) finishResult()
            })
        })
    }

    private fun savePhoto(bytes: ByteArray) {
        val pending = ticket ?: return
        if (saving) return
        saving = true
        runtime.commitPhoto(
            pending["directory"].toString(),
            pending["eventId"].toString(),
            bytes,
            null
        ) { result ->
            saving = false
            if (result.isSuccess) {
                ticket = null
                count++
                busy = false
                updateStatus()
                shutter.isEnabled =
                    foreground
                if (finishRequested) finishResult()
            } else {
                failPending(
                    NativeStrings.text(
                        R.string.native_could_not_save_the_photo_s_36,
                        (result.exceptionOrNull()?.message).toString()
                    )
                )
            }
        }
    }

    private fun failPending(message: String) {
        val pending = ticket ?: return
        if (saving) return // A durable write already in flight must finish, even when the screen closes.
        ticket = null
        runtime.commitPhoto(
            pending["directory"].toString(),
            pending["eventId"].toString(),
            null,
            message
        ) {
            busy = false
            status.text = message
            shutter.isEnabled =
                foreground && captureSession != null
            if (finishRequested) finishResult()
        }
    }

    private fun fatal(message: String) {
        fatalMessage = message
        status.text = message
        shutter.isEnabled =
            false
        failPending(message)
    }
    private fun requestFinish() {
        finishRequested = true
        if (!busy) {
            finishResult()
        } else {
            status.text =
                NativeStrings.text(R.string.camera_saving_before_return)
        }
    }
    private fun finishResult() {
        setResult(
            RESULT_OK,
            Intent().putExtra(
                "photoCount",
                count
            ).putExtra("cancelled", count == 0).putExtra("error", fatalMessage)
        )
        finish()
    }
    private fun updateStatus() {
        val audio = when (runtime.latest["state"]) {
            "paused" -> NativeStrings.text(R.string.native_recording_paused_38)
            "recording" -> NativeStrings.text(R.string.native_recording_continues_39)
            else -> NativeStrings.text(R.string.native_return_to_check_the_recording_40)
        }
        status.text =
            if (busy) {
                NativeStrings.text(
                    R.string.native_saving_photo_41
                )
            } else {
                audio + "\n" + NativeStrings.text(R.string.camera_saved_count, count.toString())
            }
    }

    companion object {
        // Some camera HALs leave alignment/blob padding after the JPEG EOI.
        // Only the complete JPEG payload enters the canonical asset store.
        internal fun canonicalJpeg(raw: ByteArray): ByteArray {
            var end = raw.size
            while (end >= 4 &&
                !(raw[end - 2] == 0xff.toByte() && raw[end - 1] == 0xd9.toByte())
            ) {
                end--
            }
            require(end >= 4) { "Camera returned an incomplete JPEG." }
            val jpeg = if (end == raw.size) raw else raw.copyOf(end)
            require(SessionStore.validJpeg(jpeg)) {
                "Camera returned an invalid JPEG (${raw.size} bytes)."
            }
            return jpeg
        }
    }
}
