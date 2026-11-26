package org.hohu.momentai

import android.app.Activity
import android.app.Instrumentation
import android.content.BroadcastReceiver
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioManager
import android.os.Bundle
import android.os.Handler
import android.os.SystemClock
import java.io.File
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Dependency-free device contract suite; all storage fixtures live in cache. */
class M3aInstrumentation : Instrumentation() {
    private var capture = false
    private var m3b = false
    private var m3c = false
    private var crash = false
    private var enduranceSeconds = 0
    private val checks = mutableListOf<String>()

    override fun onCreate(arguments: Bundle?) {
        super.onCreate(arguments)
        capture = arguments?.getString("capture") == "true"
        m3b = arguments?.getString("m3b") == "true"
        m3c = arguments?.getString("m3c") == "true"
        crash = arguments?.getString("crash") == "true"
        enduranceSeconds = arguments?.getString("enduranceSeconds")?.toIntOrNull() ?: 0
        start()
    }

    override fun onStart() {
        val result = Bundle()
        try {
            storageContracts()
            if (m3c) M3cContracts(this, checks).run()
            if (capture) captureContract()
            if (m3b || crash || enduranceSeconds > 0) {
                val suite = M3bContracts(this, checks)
                suite.storage()
                if (capture || crash || enduranceSeconds > 0) suite.capture(crash, enduranceSeconds)
            }
            result.putString("checks", checks.joinToString(","))
            result.putInt("passed", checks.size)
            result.putString("stream", "Android capture contracts passed: ${checks.size}\n")
            finish(Activity.RESULT_OK, result)
        } catch (failure: Throwable) {
            result.putString("stream", failure.stackTraceToString())
            result.putString("error", failure.message)
            finish(Activity.RESULT_CANCELED, result)
        }
    }

    private fun storageContracts() {
        val root = File(targetContext.cacheDir, "m3a-contract-${UUID.randomUUID()}").apply {
            mkdirs()
        }
        val directory = File(root, "session_contract")
        val schema = targetContext.resources.openRawResource(
            R.raw.session_schema
        ).bufferedReader().use {
            it.readText()
        }
        val first = ByteArray(32000) { (it % 127).toByte() }
        val tail = ByteArray(642) { (it % 61).toByte() }
        try {
            val failed = File(root, "session_failed")
            check(runCatching { SessionStore(failed, "NOT SQL", "failed") }.isFailure)
            check(!failed.exists())
            checks += "failed_initialization_leaves_no_broken_session"
            SessionStore(directory, schema, "M3a contract").use { store ->
                store.setStatus("recording")
                store.event("session_started")
                val a = store.commitPcm(first)
                val b = store.commitPcm(tail)
                check(a["startSample"] == 0L && a["endSample"] == 16000L)
                check(b["startSample"] == 16000L && b["endSample"] == 16321L)
                check(File(a["path"].toString()).readBytes().contentEquals(first))
                check(File(b["path"].toString()).readBytes().contentEquals(tail))
                store.verifyChunks()
                checks += "pcm_durable_contiguous_tail"
                check(store.chunks(16000).size == 1 && store.chunks(16321).isEmpty())
                checks += "chunk_high_water_filter"
                val transcript = mapOf(
                    "segmentId" to "segment_1",
                    "sessionId" to store.id,
                    "startSample" to 12,
                    "endSample" to 16001,
                    "text" to "公开验收语句",
                    "isFinal" to true
                )
                store.commitTranscript(transcript)
                store.commitTranscript(transcript)
                check(store.timeline().count { it["kind"] == "transcript" } == 1)
                check(
                    runCatching {
                        store.commitTranscript(transcript + ("endSample" to 20000))
                    }.isFailure
                )
                check(
                    runCatching {
                        store.commitTranscript(transcript + ("sessionId" to "other"))
                    }.isFailure
                )
                checks += "transcript_idempotence_and_audio_bounds"
                store.transaction {
                    store.setStatus("paused")
                    store.event("user_pause_began")
                }
                val before = store.highWater()
                store.transaction {
                    store.setStatus("recording")
                    store.event("user_pause_ended")
                }
                check(before == store.highWater())
                checks += "pause_does_not_add_samples"
                store.event(
                    "asr_probe",
                    payload = mapOf("items" to listOf(mapOf("value" to 1), null))
                )
                val payload = store.timeline().first {
                    it["type"] == "asr_probe"
                }["payload"] as Map<*, *>
                check((payload["items"] as List<*>).size == 2)
                checks += "nested_event_payload_is_codec_safe"
                val oldFile = File(directory, "audio/chunk_000000.pcm")
                val oldBytes = oldFile.readBytes()
                oldFile.writeBytes(ByteArray(oldBytes.size))
                check(runCatching { store.verifyChunks() }.isFailure)
                oldFile.writeBytes(oldBytes)
                checks += "corruption_detected"
                val collision = File(directory, "audio/chunk_000002.pcm").apply {
                    writeText("orphan")
                }
                check(runCatching { store.commitPcm(tail) }.isFailure)
                check(collision.readText() == "orphan" && store.highWater() == before)
                collision.delete()
                checks += "refuses_audio_overwrite"
                check(
                    runCatching {
                        store.transaction {
                            store.setStatus("paused")
                            error("rollback")
                        }
                    }.isFailure
                )
                check(store.status() == "recording")
                checks += "transaction_rollback"
                store.transaction {
                    store.event("session_stopped")
                    store.setStatus("completed", true)
                }
                check(runCatching { store.setStatus("recording") }.isFailure)
                checks += "terminal_state_is_final"
            }
            SessionStore(directory).use {
                check(it.highWater() == 16321L && it.status() == "completed")
                check(it.summary()["transcriptCount"] == 1L)
                it.verifyChunks()
                checks += "reopen_preserves_audio_and_text"
            }
            check(
                runCatching {
                    SessionStore.resolve(root, File(root, "../outside").path)
                }.isFailure
            )
            checks += "path_escape_rejected"
        } finally {
            root.deleteRecursively()
        }
    }

    private fun captureContract() {
        startActivitySync(
            Intent(targetContext, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        )
        SystemClock.sleep(2500)
        val runtime = RecordingRuntime.get(targetContext)
        call { runtime.start("M3a 自动验收", it) }
        SystemClock.sleep(3100)
        val paused = call { runtime.pause(it) } as Map<*, *>
        check(paused["state"] == "paused")
        val sampleTime = (paused["capturedMs"] as Number).toLong()
        check(sampleTime >= 2000)
        SystemClock.sleep(1200)
        val still = call { runtime.snapshot(it) } as Map<*, *>
        check(still["capturedMs"] == paused["capturedMs"])
        check(still["committedMs"] == still["capturedMs"])
        call { runtime.resume(it) }
        val consumer = runtime.events
        runOnMainSync { runtime.events = { error("Simulated failed transcript consumer") } }
        SystemClock.sleep(2200)
        runOnMainSync { runtime.events = consumer }
        val stopped = call { runtime.stop(it) } as Map<*, *>
        check(stopped["state"] == "completed")
        check(stopped["capturedMs"] == stopped["committedMs"])
        check((stopped["capturedMs"] as Number).toLong() > sampleTime + 1000)
        SessionStore(File(stopped["directory"].toString())).use {
            it.verifyChunks()
            check(it.timeline().any { row -> row["type"] == "user_pause_began" })
            check(it.timeline().any { row -> row["type"] == "user_pause_ended" })
            check(it.timeline().any { row -> row["type"] == "session_stopped" })
        }
        checks += "real_microphone_pause_resume_safe_stop"
        checks += "consumer_failure_does_not_stop_capture"
        val playbackContext = PlaybackReceiverContext(targetContext)
        val player = CommittedAudioPlayer(playbackContext)
        try {
            call { player.play(stopped["directory"].toString(), 0, "test", "timeline", it) }
            SystemClock.sleep(700)
            check((player.latest["positionSample"] as Number).toLong() > 0)
            val pause = call { player.pause(it) } as Map<*, *>
            check(pause["state"] == "paused")
            val seek = call { player.seek(16000, it) } as Map<*, *>
            check(seek["positionSample"] == 16000L && seek["state"] == "paused")
            call { player.resume(it) }
            SystemClock.sleep(700)
            check((player.latest["positionSample"] as Number).toLong() > 16000)
            runOnMainSync {
                checkNotNull(playbackContext.receiver).onReceive(
                    targetContext,
                    Intent(AudioManager.ACTION_AUDIO_BECOMING_NOISY)
                )
            }
            call { player.soundSettings(it) } // Drain the serialized pause command.
            check(player.latest["state"] == "paused")
            val disconnectedPosition = player.latest["positionSample"]
            SystemClock.sleep(300)
            check(player.latest["positionSample"] == disconnectedPosition)
            call { player.resume(it) }
            check(player.latest["state"] == "playing")
            checks += "headphone_disconnect_pauses_until_explicit_resume"
            call { player.stop(it) }
            check(player.latest["state"] == "idle")
            checks += "real_playback_pause_seek_resume"
        } finally {
            runOnMainSync { player.close() }
        }
    }

    private fun call(operation: (NativeReply) -> Unit): Any? {
        val latch = CountDownLatch(1)
        var value: Result<Any?>? = null
        runOnMainSync {
            operation { result ->
                value = result
                latch.countDown()
            }
        }
        check(latch.await(15, TimeUnit.SECONDS)) { "Native operation timed out." }
        return value!!.getOrThrow()
    }
}

/** Capture the registered system receiver without broadcasting a protected intent. */
private class PlaybackReceiverContext(base: Context) : ContextWrapper(base) {
    var receiver: BroadcastReceiver? = null

    override fun registerReceiver(
        receiver: BroadcastReceiver?,
        filter: IntentFilter,
        broadcastPermission: String?,
        scheduler: Handler?
    ): Intent? {
        this.receiver = receiver
        return super.registerReceiver(receiver, filter, broadcastPermission, scheduler)
    }

    override fun registerReceiver(
        receiver: BroadcastReceiver?,
        filter: IntentFilter,
        broadcastPermission: String?,
        scheduler: Handler?,
        flags: Int
    ): Intent? {
        this.receiver = receiver
        return super.registerReceiver(receiver, filter, broadcastPermission, scheduler, flags)
    }
}
