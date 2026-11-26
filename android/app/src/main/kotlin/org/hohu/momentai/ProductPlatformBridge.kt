package org.hohu.momentai

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

/** Same wire protocol as iOS. Capture outlives the Flutter activity. */
internal class ProductPlatformBridge(
    private val context: Context,
    messenger: BinaryMessenger,
    private val openCamera: (MethodChannel.Result) -> Unit,
    private val transfer: SessionTransferBridge
) {
    private val runtime = RecordingRuntime.get(context)
    private val player = CommittedAudioPlayer(context.applicationContext)
    private val database = Executors.newSingleThreadExecutor { Thread(it, "momentai-session-io") }
    private val main = Handler(Looper.getMainLooper())

    init {
        MethodChannel(
            messenger,
            "org.hohu.momentai.poc/methods"
        ).setMethodCallHandler(::captureCall)
        EventChannel(
            messenger,
            "org.hohu.momentai.poc/events"
        ).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                runtime.events = { events.success(it) }
                events.success(runtime.latest)
            }
            override fun onCancel(arguments: Any?) {
                runtime.events = null
            }
        })
        EventChannel(
            messenger,
            "org.hohu.momentai.poc/playback_events"
        ).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                player.events = { events.success(it) }
                events.success(player.latest)
            }
            override fun onCancel(arguments: Any?) {
                player.events = null
            }
        })
    }

    fun sessionCall(call: MethodCall, result: MethodChannel.Result): Boolean {
        when (call.method) {
            "listSessions" -> data(result) { SessionStore.list(SessionStore.root(context)) }
            "getSession" -> data(result) { sessionById(call).use { it.summary() } }
            "storageOverview" -> data(result) { SessionStore.storage(context) }
            "renameSession" -> data(result) {
                check(!transfer.busy) {
                    NativeStrings.text(R.string.native_wait_for_sharing_or_importing_to_finish_104)
                }
                sessionById(call).use { store ->
                    check(runtime.latest["directory"] != store.directory.path || !runtime.active)
                    store.rename(call.argument<String>("title") ?: error("Missing title."))
                    store.summary()
                }
            }
            "deleteSession" -> data(result) {
                check(!transfer.busy) {
                    NativeStrings.text(R.string.native_wait_for_sharing_or_importing_to_finish_104)
                }
                val directory = sessionById(call).use { store ->
                    check(runtime.latest["directory"] != store.directory.path || !runtime.active)
                    check(store.status() in SessionStore.terminalStates)
                    check(
                        player.latest["directory"] != store.directory.path ||
                            player.latest["state"] == "idle"
                    ) { "Stop playback before deleting." }
                    store.directory
                }
                check(directory.deleteRecursively()) { "Could not delete Session." }
                null
            }
            else -> return false
        }
        return true
    }

    private fun captureCall(call: MethodCall, result: MethodChannel.Result) {
        val reply = reply(result)
        if (call.method == "start" && transfer.busy) {
            result.error(
                "transfer_busy",
                NativeStrings.text(R.string.native_wait_for_sharing_or_importing_to_finish_104),
                null
            )
            return
        }
        when (call.method) {
            "exportSession", "shareExport" -> transfer.handle(call, result)
            "start" -> player.stop { stopped ->
                if (stopped.isFailure) {
                    reply(stopped)
                } else {
                    runtime.start(
                        call.argument<String>("title")
                            ?: NativeStrings.text(R.string.native_new_recording_44),
                        reply
                    )
                }
            }
            "stop" -> runtime.stop(reply)
            "pauseRecording" -> runtime.pause(reply)
            "resumeRecording" -> runtime.resume(reply)
            "snapshot" -> runtime.snapshot(reply)
            "setASRMode" -> runtime.setAsrMode(call.argument<String>("mode") ?: "normal", reply)
            "committedChunks" -> data(result) {
                session(call).use { it.chunks(call.argument<Number>("afterSample")?.toLong() ?: 0) }
            }
            "timeline" -> data(result) { session(call).use { it.timeline() } }
            "commitTranscriptSegment" -> data(result) {
                session(call).use {
                    it.commitTranscript(
                        call.argument<Map<*, *>>("segment") ?: error("Missing transcript.")
                    )
                }
                null
            }
            "commitStage1Event" -> data(result) {
                session(call).use {
                    it.event(
                        call.argument<String>("type") ?: error("Missing event type."),
                        call.argument<Number>("sampleOffset")?.toLong() ?: error("Missing sample."),
                        call.argument<Map<String, Any?>>("payload") ?: emptyMap()
                    )
                }
                null
            }
            "openCamera" -> openCamera(result)
            "addBookmark" -> runtime.addCapture("bookmark", reply = reply)
            "addThought" -> runtime.addCapture(
                "thought",
                call.argument<String>("text") ?: "",
                reply
            )
            "scanRecovery" -> data(result) {
                SessionStore.list(SessionStore.root(context)).filter {
                    it["state"] !in SessionStore.terminalStates &&
                        !(runtime.active && runtime.latest["directory"] == it["directory"])
                }.map { row ->
                    SessionStore(File(row["directory"].toString())).use {
                        SessionRecovery.preview(it)
                    }
                }
            }
            "recover" -> data(result) {
                session(call).use { store ->
                    check(!runtime.active || runtime.latest["directory"] != store.directory.path)
                    SessionRecovery.recover(store)
                }
            }
            "startPlayback" -> {
                if (runtime.active) {
                    result.error("recording_active", "Stop recording before playback.", null)
                } else {
                    player.play(
                        call.argument<String>("directory") ?: "",
                        call.argument<Number>("sampleOffset")?.toLong() ?: 0,
                        call.argument<String>("anchorId") ?: "",
                        call.argument<String>("anchorType") ?: "timeline",
                        reply
                    )
                }
            }
            "getPlaybackSound" -> player.soundSettings(reply)
            "setPlaybackSound" -> player.setSound(
                call.argument<Number>("volume")?.toFloat() ?: Float.NaN,
                call.argument<Boolean>("enhanced") ?: false,
                reply
            )
            "pausePlayback" -> player.pause(reply)
            "resumePlayback" -> player.resume(reply)
            "seekPlayback" -> player.seek(
                call.argument<Number>("sampleOffset")?.toLong() ?: 0,
                reply
            )
            "stopPlayback" -> player.stop(reply)
            "compatibilityReport" -> result.success(
                mapOf(
                    "platform" to "android",
                    "sampleRate" to 16000,
                    "channels" to 1,
                    "capture" to "AudioRecord"
                )
            )
            else -> result.notImplemented()
        }
    }

    private fun session(call: MethodCall): SessionStore = SessionStore(
        SessionStore.resolve(
            SessionStore.root(context),
            call.argument<String>("directory") ?: error("Missing directory.")
        )
    )

    private fun sessionById(call: MethodCall): SessionStore {
        val id = call.argument<String>("sessionId") ?: error("Missing Session id.")
        require(File(id).name == id && id.startsWith("session_"))
        return SessionStore(
            SessionStore.resolve(
                SessionStore.root(context),
                File(SessionStore.root(context), id).path
            )
        )
    }

    private fun data(result: MethodChannel.Result, action: () -> Any?) {
        database.execute {
            try {
                val value = action()
                main.post { result.success(value) }
            } catch (
                failure: Exception
            ) {
                android.util.Log.e("MomentAISession", "Session operation failed", failure)
                main.post { result.error("session_failed", failure.message, null) }
            }
        }
    }

    private fun reply(result: MethodChannel.Result): NativeReply = { value ->
        value.fold({ result.success(it) }, { result.error("capture_failed", it.message, null) })
    }

    fun detach() {
        runtime.events = null
        player.events = null
        player.close()
        database.shutdown()
    }
}
