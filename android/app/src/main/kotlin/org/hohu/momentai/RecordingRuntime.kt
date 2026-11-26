package org.hohu.momentai

import android.Manifest
import android.annotation.SuppressLint
import android.app.Application
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioRecordingConfiguration
import android.media.AudioRouting
import android.media.MediaRecorder
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.StatFs
import android.os.SystemClock
import java.io.ByteArrayOutputStream
import java.util.UUID

typealias NativeReply = (Result<Any?>) -> Unit

/** One microphone owner and one ordered writer. ASR never runs on this thread. */
class RecordingRuntime private constructor(private val context: Context) {
    private val thread = HandlerThread(
        "momentai-capture",
        android.os.Process.THREAD_PRIORITY_AUDIO
    ).apply {
        start()
    }
    private val worker = Handler(thread.looper)
    private val main = Handler(Looper.getMainLooper())
    private var recorder: AudioRecord? = null
    private var store: SessionStore? = null
    private var receipt: CaptureReceipt? = null
    private val assets = java.util.concurrent.Executors.newSingleThreadExecutor {
        Thread(it, "momentai-assets")
    }
    private val epoch = UUID.randomUUID().toString()
    private var startedNs = 0L
    private var lastAudioAt = 0L
    private var routeId: Int? = null
    private var recordingCallback: AudioManager.AudioRecordingCallback? = null
    private var routeListener: AudioRouting.OnRoutingChangedListener? = null
    private var interruptionAt = 0L
    private var testAvailableBytes: Long? = null
    private var state = "idle"
    private var acceptedSamples = 0L
    private var committedSamples = 0L
    private var chunkCount = 0
    private var pendingPcm = ByteArrayOutputStream(32000)
    private val buffer = ByteArray(3200)
    private var pauseStarted = 0L
    private var pausedMs = 0L
    private var pauseCount = 0
    private var pauseId = ""
    private var asrMode = "normal"
    private var error: String? = null
    private var interrupted = false
    private var service: RecordingService? = null
    private var startReply: NativeReply? = null // Main-thread only.
    private val visibleActivities = java.util.concurrent.atomic.AtomicInteger(0)
    private val power get() = context.getSystemService(android.os.PowerManager::class.java)
    private var backgroundSamples = 0L
    private var screenOffSamples = 0L
    private var backgroundOrScreenOffSamples = 0L
    private var maximumReadGapMs = 0L
    private var maximumUncommittedSamples = 0L
    init {
        NativeStrings.initialize(context)
        (context as Application).registerActivityLifecycleCallbacks(object : Application.ActivityLifecycleCallbacks {
            override fun onActivityStarted(activity: android.app.Activity) {
                visibleActivities.incrementAndGet()
            }
            override fun onActivityStopped(activity: android.app.Activity) {
                visibleActivities.updateAndGet {
                    maxOf(
                        0,
                        it - 1
                    )
                }
            }
            override fun onActivityCreated(activity: android.app.Activity, state: android.os.Bundle?) = Unit
            override fun onActivityResumed(activity: android.app.Activity) = Unit
            override fun onActivityPaused(activity: android.app.Activity) = Unit
            override fun onActivitySaveInstanceState(activity: android.app.Activity, state: android.os.Bundle) = Unit
            override fun onActivityDestroyed(activity: android.app.Activity) = Unit
        })
    }

    @Volatile var latest: Map<String, Any?> = emptySnapshot()
        private set
    var events: ((Map<String, Any?>) -> Unit)? = null // Main-thread only.
    private val stateListeners = mutableSetOf<(String) -> Unit>()

    fun addStateListener(listener: (String) -> Unit) {
        check(Looper.myLooper() == Looper.getMainLooper())
        stateListeners.add(listener)
        listener(latest["state"].toString())
    }

    fun removeStateListener(listener: (String) -> Unit) {
        check(Looper.myLooper() == Looper.getMainLooper())
        stateListeners.remove(listener)
    }

    val active: Boolean get() = latest["state"] in activeStates || startReply != null

    fun start(title: String, reply: NativeReply) {
        check(Looper.myLooper() == Looper.getMainLooper())
        if (active) {
            reply(Result.failure(IllegalStateException("Recording is already active.")))
            return
        }
        if (context.checkSelfPermission(Manifest.permission.RECORD_AUDIO) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            reply(Result.failure(SecurityException("Microphone permission is required.")))
            return
        }
        startReply = reply
        try {
            val intent = Intent(
                context,
                RecordingService::class.java
            ).setAction(RecordingService.START).putExtra("title", title)
            if (Build.VERSION.SDK_INT >=
                26
            ) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
            main.postDelayed({
                if (startReply === reply) {
                    startReply = null
                    reply(Result.failure(IllegalStateException("Recording service did not start.")))
                    stop { }
                }
            }, 10000)
        } catch (failure: Exception) {
            startReply = null
            reply(Result.failure(failure))
        }
    }

    fun serviceStarted(owner: RecordingService, title: String) {
        // Never resurrect capture after a service timeout or process recreation.
        if (startReply == null) {
            owner.finishRecording()
            return
        }
        service = owner
        worker.post {
            try {
                check(
                    StatFs(SessionStore.root(context).path).availableBytes >=
                        SessionStore.MINIMUM_FREE_BYTES
                ) { "Insufficient free storage." }
                store?.close()
                store = null
                acceptedSamples = 0
                committedSamples = 0
                chunkCount = 0
                pendingPcm.reset()
                pauseStarted = 0
                pausedMs = 0
                pauseCount = 0
                error = null
                interrupted = false
                store = SessionStore.create(context, title)
                receipt = CaptureReceipt(store!!.directory, store!!.id)
                startedNs = SystemClock.elapsedRealtimeNanos()
                interruptionAt = 0
                backgroundSamples = 0
                screenOffSamples = 0
                backgroundOrScreenOffSamples = 0
                maximumReadGapMs = 0
                maximumUncommittedSamples = 0
                receipt!!.save(0, 0, "preparing", true)
                state = "preparing"
                publish()
                openMicrophone()
                state = "recording"
                store!!.transaction {
                    store!!.setStatus(state)
                    store!!.event("session_started")
                }
                receipt!!.save(acceptedSamples, committedSamples, state, true)
                publish("session_started")
                main.post {
                    val reply = startReply
                    startReply = null
                    reply?.invoke(Result.success(latest))
                }
                worker.post(readAudio)
            } catch (failure: Exception) {
                closeMicrophone()
                error = failure.message
                state = "failed_to_start"
                runCatching { store?.setStatus(state, stopped = true) }
                publish("start_failed")
                main.post {
                    val reply = startReply
                    startReply = null
                    reply?.invoke(Result.failure(failure))
                    owner.finishRecording()
                    service = null
                }
            }
        }
    }

    private fun openMicrophone() {
        if (context.checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            throw SecurityException("Microphone permission is required before opening audio capture.")
        }
        val minimum = AudioRecord.getMinBufferSize(
            16000,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT
        )
        check(minimum > 0) { "16 kHz PCM capture is unavailable." }
        val audio = AudioRecord.Builder()
            .setAudioSource(MediaRecorder.AudioSource.MIC)
            .setAudioFormat(
                AudioFormat.Builder().setSampleRate(
                    16000
                ).setChannelMask(AudioFormat.CHANNEL_IN_MONO)
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT).build()
            )
            .setBufferSizeInBytes(maxOf(minimum * 4, 64000)).build()
        recorder = audio
        check(audio.state == AudioRecord.STATE_INITIALIZED) { "Microphone initialization failed." }
        check(audio.sampleRate == 16000 && audio.channelCount == 1)
        routeId = null
        lastAudioAt = SystemClock.elapsedRealtime()
        val routing = AudioRouting.OnRoutingChangedListener {
            if (recorder !== audio ||
                state !in setOf("recording", "resuming", "preparing")
            ) {
                return@OnRoutingChangedListener
            }
            val current = audio.routedDevice?.id
            val previous = routeId
            routeId = current
            if (previous != null &&
                current != previous
            ) {
                interruptCapture(
                    IllegalStateException(
                        NativeStrings.text(
                            R.string.native_the_audio_input_device_changed_check_it_before_continuing_59
                        )
                    )
                )
            }
        }
        routeListener = routing
        audio.addOnRoutingChangedListener(routing, worker)
        if (Build.VERSION.SDK_INT >= 29) {
            val callback = object : AudioManager.AudioRecordingCallback() {
                override fun onRecordingConfigChanged(configs: MutableList<AudioRecordingConfiguration>) {
                    if (recorder !== audio || state != "recording") return
                    if (configs.any {
                            it.clientAudioSessionId == audio.audioSessionId &&
                                it.isClientSilenced
                        }
                    ) {
                        interruptCapture(
                            IllegalStateException(
                                NativeStrings.text(
                                    R.string.native_the_microphone_was_muted_by_the_system_or_is_in_use_by_another_ap_60
                                )
                            )
                        )
                    }
                }
            }
            recordingCallback = callback
            audio.registerAudioRecordingCallback(
                java.util.concurrent.Executor {
                    worker.post(it)
                },
                callback
            )
        }
        audio.startRecording()
        check(audio.recordingState == AudioRecord.RECORDSTATE_RECORDING) {
            "Microphone did not start."
        }
    }

    private val readAudio = object : Runnable {
        override fun run() {
            if (state != "recording") return
            try {
                check(
                    (testAvailableBytes ?: StatFs(store!!.directory.path).availableBytes) >=
                        32L * 1024 * 1024
                ) {
                    NativeStrings.text(
                        R.string.native_recording_interrupted_due_to_low_storage_free_up_space_then_resum_61
                    )
                }
                // Bounded work so pause/stop cannot starve behind incoming audio.
                repeat(8) {
                    val count = recorder!!.read(
                        buffer,
                        0,
                        buffer.size,
                        AudioRecord.READ_NON_BLOCKING
                    )
                    check(count >= 0 && count % 2 == 0) { "AudioRecord read failed: $count" }
                    if (count == 0) return@repeat
                    val now = SystemClock.elapsedRealtime()
                    maximumReadGapMs = maxOf(maximumReadGapMs, now - lastAudioAt)
                    lastAudioAt = now
                    acceptedSamples += count / 2
                    val screenOff = !power.isInteractive
                    val background = visibleActivities.get() == 0
                    if (screenOff) screenOffSamples += count / 2
                    if (background) backgroundSamples += count / 2
                    if (screenOff || background) backgroundOrScreenOffSamples += count / 2
                    maximumUncommittedSamples =
                        maxOf(maximumUncommittedSamples, acceptedSamples - committedSamples)
                    // Checkpoint native receive progress before publishing/committing a block.
                    receipt?.save(acceptedSamples, committedSamples, state)
                    var offset = 0
                    while (offset < count) {
                        val size = minOf(32000 - pendingPcm.size(), count - offset)
                        pendingPcm.write(buffer, offset, size)
                        offset += size
                        if (pendingPcm.size() == 32000) flushChunk()
                    }
                }
                check(SystemClock.elapsedRealtime() - lastAudioAt < 3000) {
                    NativeStrings.text(
                        R.string.native_no_microphone_audio_received_for_3_seconds_check_the_input_device_62
                    )
                }
                worker.postDelayed(this, 20)
            } catch (failure: Exception) {
                interruptCapture(failure)
            }
        }
    }

    private fun flushChunk() {
        if (pendingPcm.size() == 0) return
        val chunk = store!!.commitPcm(pendingPcm.toByteArray())
        pendingPcm.reset()
        committedSamples = (chunk["endSample"] as Number).toLong()
        chunkCount++
        publish("chunk_committed", chunk)
    }

    private fun interruptCapture(failure: Exception) {
        runCatching { closeMicrophone() }
        if (state == "interrupted") return
        interrupted = true
        interruptionAt = SystemClock.elapsedRealtime()
        error = failure.message ?: "Capture interrupted."
        runCatching { flushChunk() }
        state = "interrupted"
        runCatching {
            store?.transaction {
                store!!.setStatus(state)
                store!!.event("audio_interruption_began", payload = mapOf("reason" to error))
            }
        }
        runCatching { receipt?.save(acceptedSamples, committedSamples, state, true) }
        publish("audio_interruption_began")
    }

    fun pause(reply: NativeReply) = operation(reply) {
        check(state == "recording") { "Recording is not running." }
        state = "pausing"
        publish()
        closeMicrophone()
        flushChunk()
        pauseId = UUID.randomUUID().toString()
        pauseStarted = SystemClock.elapsedRealtime()
        pauseCount++
        store!!.transaction {
            store!!.setStatus("paused")
            store!!.event(
                "user_pause_began",
                payload = mapOf(
                    "schema_version" to 1,
                    "pause_id" to pauseId,
                    "started_at_unix_ms" to System.currentTimeMillis()
                )
            )
        }
        state = "paused"
        // Audio and pause facts are already durable. A diagnostic receipt
        // failure must not leave Flutter stuck in the transitional state.
        runCatching { receipt?.save(acceptedSamples, committedSamples, state, true) }
        publish("user_pause_began")
        latest
    }

    fun resume(reply: NativeReply) = operation(reply) {
        check(state == "paused" || state == "interrupted") {
            "Recording is not paused or interrupted."
        }
        val wasInterrupted = state == "interrupted"
        if (wasInterrupted) flushChunk()
        check(
            (testAvailableBytes ?: StatFs(store!!.directory.path).availableBytes) >=
                32L * 1024 * 1024
        ) { "Insufficient free storage." }
        state = "resuming"
        publish()
        openMicrophone()
        closePause("resumed")
        if (wasInterrupted) {
            store!!.event(
                "audio_interruption_ended",
                payload = mapOf(
                    "duration_ms" to
                        (SystemClock.elapsedRealtime() - interruptionAt),
                    "reason" to "user_resumed",
                    "hasGap" to true
                )
            )
        }
        error = null
        store!!.setStatus("recording")
        state = "recording"
        receipt?.save(acceptedSamples, committedSamples, state, true)
        publish(if (wasInterrupted) "audio_interruption_ended" else "user_pause_ended")
        worker.post(readAudio)
        latest
    }

    private fun closePause(reason: String) {
        if (pauseStarted == 0L) return
        val duration = SystemClock.elapsedRealtime() - pauseStarted
        store!!.event(
            "user_pause_ended",
            payload = mapOf(
                "schema_version" to 1,
                "pause_id" to pauseId,
                "duration_ms" to duration,
                "end_reason" to reason
            )
        )
        pausedMs += duration
        pauseStarted = 0
    }

    fun stop(reply: NativeReply) = operation(reply) {
        if (state !in activeStates) return@operation latest
        state = "finalizing"
        publish()
        closeMicrophone()
        flushChunk()
        closePause("stopped")
        // Let already accepted image writes finish. A shutter result arriving
        // after stop must not silently create an indefinitely pending asset.
        assets.submit { }.get(20, java.util.concurrent.TimeUnit.SECONDS)
        store!!.finishPendingImages()
        check(acceptedSamples == committedSamples) { "Not all received audio was committed." }
        state = if (interrupted) "completed_with_gaps" else "completed"
        store!!.transaction {
            store!!.event(
                "session_stopped",
                payload = mapOf(
                    "acceptedSamples" to acceptedSamples,
                    "committedSamples" to committedSamples, "userPauseCount" to pauseCount,
                    "totalUserPausedMs" to pausedMs,
                    "backgroundSamples" to backgroundSamples, "screenOffSamples" to screenOffSamples,
                    "backgroundOrScreenOffSamples" to backgroundOrScreenOffSamples,
                    "maximumReadGapMs" to maximumReadGapMs,
                    "maximumUncommittedSamples" to maximumUncommittedSamples
                )
            )
            store!!.setStatus(state, stopped = true)
        }
        runCatching { receipt?.save(acceptedSamples, committedSamples, state, true) }
        publish("session_stopped")
        main.post {
            service?.finishRecording()
            service = null
        }
        latest
    }

    fun snapshot(reply: NativeReply) = operation(reply) {
        publish()
        latest
    }
    fun setAsrMode(mode: String, reply: NativeReply) = operation(reply) {
        asrMode = mode
        publish()
        null
    }

    fun serviceDestroyed(owner: RecordingService) {
        if (service === owner) {
            service = null
            stop { }
        }
    }

    fun addCapture(type: String, text: String = "", reply: NativeReply) = operation(reply, false) {
        check(state in setOf("recording", "paused")) {
            NativeStrings.text(
                R.string.native_content_cannot_be_added_while_recording_is_interrupted_63
            )
        }
        if (type ==
            "thought"
        ) {
            require(text.trim().isNotEmpty() && text.codePointCount(0, text.length) <= 4000)
        }
        try {
            flushChunk()
        } catch (failure: Exception) {
            interruptCapture(failure)
            throw failure
        }
        val row = store!!.addCapture(
            type,
            text,
            SystemClock.elapsedRealtimeNanos() - startedNs,
            epoch
        )
        publish("capture_event")
        row + mapOf("directory" to store!!.directory.path)
    }

    fun commitPhoto(directory: String, eventId: String, bytes: ByteArray?, failure: String?, reply: NativeReply) {
        assets.execute {
            val result = runCatching {
                SessionStore(SessionStore.resolve(SessionStore.root(context), directory)).use {
                    if (failure != null) {
                        it.failImage(eventId, failure)
                        null
                    } else {
                        it.commitImage(eventId, bytes)
                    }
                }
            }
            main.post {
                reply(result)
                runCatching { events?.invoke(latest + ("event" to "capture_event")) }
            }
        }
    }

    internal fun interruptForTest(reason: String, reply: NativeReply) = operation(reply, false) {
        check(
            context.applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE !=
                0
        )
        interruptCapture(IllegalStateException(reason))
        latest
    }

    internal fun setAvailableStorageForTest(bytes: Long?, reply: NativeReply) = operation(reply, false) {
        check(
            context.applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE !=
                0
        )
        testAvailableBytes = bytes
        null
    }

    internal fun crashForRecoveryTest() {
        check(
            context.applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE !=
                0
        )
        worker.post {
            val bytes = org.json.JSONObject(
                mapOf(
                    "acceptedSamples" to acceptedSamples,
                    "committedSamples" to committedSamples,
                    "sessionId" to store!!.id
                )
            ).toString().toByteArray()
            java.io.FileOutputStream(
                java.io.File(store!!.directory, "test_crash_receipt.json")
            ).use {
                it.write(bytes)
                it.fd.sync()
            }
            android.os.Process.killProcess(android.os.Process.myPid())
        }
    }

    private fun closeMicrophone() {
        worker.removeCallbacks(readAudio)
        val audio = recorder
        recorder = null
        if (audio != null) {
            routeListener?.let { runCatching { audio.removeOnRoutingChangedListener(it) } }
            routeListener =
                null
            if (Build.VERSION.SDK_INT >=
                29
            ) {
                recordingCallback?.let {
                    runCatching { audio.unregisterAudioRecordingCallback(it) }
                }
            }
            recordingCallback = null
            try {
                if (audio.recordingState == AudioRecord.RECORDSTATE_RECORDING) audio.stop()
            } finally {
                audio.release()
            }
        }
    }

    private fun operation(reply: NativeReply, affectsCapture: Boolean = true, action: () -> Any?) {
        worker.post {
            try {
                val result = action()
                main.post { reply(Result.success(result)) }
            } catch (
                failure: Exception
            ) {
                if (affectsCapture && state in activeStates &&
                    state != "paused"
                ) {
                    interruptCapture(failure)
                }
                main.post { reply(Result.failure(failure)) }
            }
        }
    }

    private fun publish(event: String? = null, chunk: Map<String, Any?>? = null) {
        val value = mapOf(
            "state" to state, "sessionId" to (store?.id ?: ""),
            "directory" to (store?.directory?.path ?: ""), "capturedMs" to acceptedSamples / 16,
            "committedMs" to committedSamples / 16,
            "rpoMs" to (acceptedSamples - committedSamples) / 16,
            "canResumeAfterInterruption" to true, "chunkCount" to chunkCount, "event" to event,
            "chunk" to chunk, "error" to error,
            "userPauseCount" to pauseCount, "totalUserPausedMs" to pausedMs,
            "currentUserPauseMs" to
                if (pauseStarted == 0L) 0 else SystemClock.elapsedRealtime() - pauseStarted,
            "asr" to
                mapOf(
                    "mode" to asrMode,
                    "queueDepth" to 0,
                    "droppedBuffers" to 0,
                    "droppedSamples" to 0,
                    "failedSamples" to 0
                )
        )
        latest = value.filterKeys { it != "event" && it != "chunk" }
        main.post {
            // A detached or failed UI/ASR consumer must never stop native saving.
            runCatching { events?.invoke(value) }
            val recordingState = value["state"].toString()
            stateListeners.toList().forEach { listener -> runCatching { listener(recordingState) } }
            service?.updateRecordingState(recordingState)
        }
    }

    companion object {
        private val activeStates =
            setOf(
                "preparing",
                "recording",
                "pausing",
                "paused",
                "resuming",
                "interrupted",
                "finalizing"
            )

        // The singleton retains only applicationContext, never an Activity or Service.
        @SuppressLint("StaticFieldLeak")
        @Volatile
        private var instance: RecordingRuntime? = null
        fun get(context: Context): RecordingRuntime = instance ?: synchronized(this) {
            instance ?: RecordingRuntime(context.applicationContext).also { instance = it }
        }
        private fun emptySnapshot() = mapOf<String, Any?>(
            "state" to "idle",
            "sessionId" to "",
            "directory" to "",
            "capturedMs" to 0,
            "committedMs" to 0,
            "rpoMs" to 0,
            "chunkCount" to 0
        )
    }
}
