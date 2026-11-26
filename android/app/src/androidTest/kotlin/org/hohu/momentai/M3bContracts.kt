package org.hohu.momentai

import android.app.Instrumentation
import android.content.Intent
import android.graphics.Bitmap
import android.os.Bundle
import android.os.SystemClock
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class M3bContracts(private val instrumentation: Instrumentation, private val checks: MutableList<String>) {
    private val context get() = instrumentation.targetContext

    fun storage() {
        val root = File(context.cacheDir, "m3b-contract-${UUID.randomUUID()}").apply { mkdirs() }
        val schema = context.resources.openRawResource(R.raw.session_schema).bufferedReader().use {
            it.readText()
        }
        val jpeg = ByteArrayOutputStream().also { stream ->
            Bitmap.createBitmap(24, 24, Bitmap.Config.ARGB_8888).also {
                it.eraseColor(android.graphics.Color.GREEN)
                it.compress(Bitmap.CompressFormat.JPEG, 90, stream)
                it.recycle()
            }
        }.toByteArray()
        check(PhotoCaptureActivity.canonicalJpeg(jpeg + ByteArray(128)).contentEquals(jpeg))
        check(runCatching { PhotoCaptureActivity.canonicalJpeg(byteArrayOf(1, 2, 3)) }.isFailure)
        checks += "camera_jpeg_padding_normalized_and_incomplete_rejected"
        try {
            SessionStore(File(root, "session_mixed"), schema, "same sample").use { store ->
                store.setStatus("recording")
                store.commitPcm(ByteArray(32000))
                store.event("anchor_probe")
                store.addCapture("image", elapsedNs = 1, epoch = "test")
                store.addCapture("bookmark", elapsedNs = 2, epoch = "test")
                store.commitPcm(ByteArray(32000))
                store.commitTranscript(
                    mapOf(
                        "segmentId" to "same_anchor",
                        "sessionId" to store.id,
                        "startSample" to 16000,
                        "endSample" to 32000,
                        "text" to "同一锚点公开文字",
                        "isFinal" to true
                    )
                )
                val timeline = store.timeline()
                check(timeline.size == 4 && timeline.all { it["sampleOffset"] == 16000L })
                io.flutter.plugin.common.StandardMessageCodec.INSTANCE.encodeMessage(timeline)
                checks += "mixed_transcript_and_photo_same_anchor_sort_and_encode"
            }
            SessionStore(
                File(root, "session_recovery"),
                schema,
                "M3b public fixture"
            ).use { store ->
                store.setStatus("recording")
                store.commitPcm(ByteArray(32000) { (it % 101).toByte() })
                val first = store.addCapture("bookmark", elapsedNs = 1, epoch = "test")
                val second = store.addCapture("bookmark", elapsedNs = 2, epoch = "test")
                val thought = store.addCapture("thought", "公开随想测试", 3, "test")
                check(
                    first["eventId"] != second["eventId"] &&
                        first["sampleOffset"] == second["sampleOffset"]
                )
                check(thought["text"] == "公开随想测试" && thought["sampleOffset"] == 16000L)
                check(runCatching { store.addCapture("thought", " ", 4, "test") }.isFailure)
                check(
                    runCatching {
                        store.addCapture("thought", "字".repeat(4001), 4, "test")
                    }.isFailure
                )
                checks += "annotations_distinct_and_bounded_at_committed_sample"
                io.flutter.plugin.common.StandardMessageCodec.INSTANCE.encodeMessage(
                    store.timeline()
                )
                val concurrent = java.util.concurrent.Executors.newFixedThreadPool(2)
                try {
                    val reads = concurrent.submit {
                        repeat(20) {
                            SessionStore(store.directory).use { reader ->
                                reader.timeline()
                                check(
                                    reader.db.rawQuery("PRAGMA journal_mode", null).use {
                                        it.moveToFirst()
                                        it.getString(0)
                                    } ==
                                        "wal"
                                )
                            }
                        }
                    }
                    val writes = concurrent.submit {
                        repeat(20) {
                            SessionStore(store.directory).use { writer ->
                                writer.event("m3b_concurrent_probe")
                            }
                        }
                    }
                    reads.get(20, TimeUnit.SECONDS)
                    writes.get(20, TimeUnit.SECONDS)
                } finally {
                    concurrent.shutdownNow()
                }
                checks += "concurrent_store_connections_keep_wal_and_timeline_codec"
                val image = store.addCapture("image", elapsedNs = 5, epoch = "test")
                val imageId = image["eventId"].toString()
                val committed = store.commitImage(imageId, jpeg)
                check(committed["captureState"] == "committed")
                check(store.commitImage(imageId, jpeg) == committed)
                check(runCatching { store.commitImage(imageId, jpeg + 0) }.isFailure)
                checks += "image_durable_commit_and_idempotence"
                val pending = store.addCapture("image", elapsedNs = 6, epoch = "test")
                File(pending["assetPath"].toString()).writeBytes(jpeg) // Crash after rename, before database commit.
                val partial = store.addCapture("image", elapsedNs = 7, epoch = "test")
                File(partial["assetPath"].toString() + ".part").writeBytes(jpeg.copyOf(20))
                val missing = store.addCapture("image", elapsedNs = 8, epoch = "test")
                store.setStatus("paused")
                store.event("user_pause_began", payload = mapOf("pause_id" to "pause_test"))
                store.addCapture("bookmark", elapsedNs = 9, epoch = "test")
                check(store.highWater() == 16000L)
                CaptureReceipt(store.directory, store.id).save(17000, 16000, "recording", true)
                File(store.directory, "audio/chunk_000001.pcm").writeBytes(ByteArray(1000))
                val outcome = SessionRecovery.recover(store)
                check(outcome["rpoKnown"] == true && outcome["rpoPass"] == true)
                check(outcome["rpoMs"] == 363L && outcome["quarantinedFiles"] == 1)
                check(outcome["imageCommittedCount"] == 2 && outcome["imageFailedCount"] == 2)
                check(outcome["capturePendingCount"] == 0)
                check(File(partial["assetPath"].toString() + ".part.quarantine").isFile)
                check(
                    store.captureEvents().first {
                        it["eventId"] == missing["eventId"]
                    }["captureState"] ==
                        "failed"
                )
                check(store.timeline().any { it["type"] == "user_pause_ended" })
                check(
                    store.summary()["bookmarkCount"] == 3L && store.summary()["thoughtCount"] == 1L
                )
                checks += "recovery_reconciles_pending_images_and_closes_pause"
                val again = SessionRecovery.recover(store)
                check(again["rpoMs"] == outcome["rpoMs"] && store.summary()["recoveryCount"] == 1L)
                check(store.timeline().count { it["type"] == "session_recovered" } == 1)
                store.verifyChunks()
                checks += "recovery_idempotent_and_original_pcm_preserved"
                File(committed["assetPath"].toString()).writeBytes(ByteArray(jpeg.size))
                SessionRecovery.recover(store)
                check(
                    store.captureEvents().first { it["eventId"] == imageId }["captureState"] ==
                        "failed"
                )
                checks += "repeated_recovery_detects_later_image_corruption"
            }
            SessionStore(File(root, "session_legacy"), schema, "legacy").use { store ->
                store.setStatus("recording")
                store.commitPcm(ByteArray(320))
                check(SessionRecovery.preview(store)["rpoKnown"] == false)
                check(SessionRecovery.recover(store)["rpoPass"] == false)
                checks += "missing_receipt_never_claims_zero_loss"
            }
            SessionStore(File(root, "session_stopping"), schema, "stopping").use { store ->
                store.setStatus("recording")
                store.commitPcm(ByteArray(320))
                val pending = store.addCapture("image", elapsedNs = 1, epoch = "stop")
                val saved = store.addCapture("image", elapsedNs = 2, epoch = "stop")
                store.commitImage(saved["eventId"].toString(), jpeg)
                store.finishPendingImages()
                store.failImage(saved["eventId"].toString(), "late cancellation")
                check(store.captureEvents().none { it["captureState"] == "pending" })
                check(
                    store.captureEvents().first {
                        it["eventId"] == saved["eventId"]
                    }["captureState"] ==
                        "committed"
                )
                check(
                    runCatching {
                        store.commitImage(pending["eventId"].toString(), jpeg)
                    }.isFailure
                )
                checks += "stop_settles_pending_photos_and_late_cancel_preserves_committed_image"
            }
            SessionStore(File(root, "session_corrupt"), schema, "corrupt").use { store ->
                store.setStatus("recording")
                val pcm = store.commitPcm(ByteArray(320))
                File(pcm["path"].toString()).writeBytes(byteArrayOf(1, 2))
                check(runCatching { SessionRecovery.recover(store) }.isFailure)
                check(File(pcm["path"].toString()).readBytes().contentEquals(byteArrayOf(1, 2)))
                check(store.highWater() == 160L && store.status() == "recording")
                checks += "corrupt_committed_pcm_preserved_and_recovery_rejected"
            }
        } finally {
            root.deleteRecursively()
        }
    }

    fun capture(crash: Boolean = false, enduranceSeconds: Int = 0) {
        instrumentation.runOnMainSync {
            context.startActivity(
                Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
        }
        SystemClock.sleep(2000)
        val runtime = RecordingRuntime.get(context)
        try {
            call {
                runtime.start(
                    if (crash) {
                        "M3b 进程退出验收"
                    } else if (enduranceSeconds >=
                        1800
                    ) {
                        "M3b 长录音验收"
                    } else if (enduranceSeconds > 0) {
                        "M3b 锁屏短测"
                    } else {
                        "M3b 中断恢复短测"
                    },
                    it
                )
            }
            SystemClock.sleep(2300)
            val first = call { runtime.addCapture("bookmark", reply = it) } as Map<*, *>
            call { runtime.addCapture("thought", "M3b 公开测试随想", it) }
            val rejected = runCatching { call { runtime.addCapture("thought", " ", it) } }
            check(rejected.isFailure && runtime.latest["state"] == "recording")
            checks += "invalid_annotation_does_not_interrupt_microphone"
            if (crash) {
                SystemClock.sleep(1300)
                runtime.crashForRecoveryTest()
                SystemClock.sleep(10000)
                error("Crash injection did not terminate the process")
            }
            call { runtime.interruptForTest("M3b 模拟系统静音", it) }
            val interrupted = runtime.latest
            check(
                interrupted["state"] == "interrupted" &&
                    interrupted["capturedMs"] == interrupted["committedMs"]
            )
            SystemClock.sleep(650)
            check(runtime.latest["capturedMs"] == interrupted["capturedMs"])
            call { runtime.resume(it) }
            SystemClock.sleep(1400)
            call { runtime.setAvailableStorageForTest(0, it) }
            SystemClock.sleep(350)
            check(runtime.latest["state"] == "interrupted")
            check(runtime.latest["capturedMs"] == runtime.latest["committedMs"])
            call { runtime.setAvailableStorageForTest(null, it) }
            call { runtime.resume(it) }
            SystemClock.sleep(600)
            checks += "low_storage_guard_stops_input_and_preserves_tail"
            call { runtime.pause(it) }
            val paused = runtime.latest
            val mark = call { runtime.addCapture("bookmark", reply = it) } as Map<*, *>
            SystemClock.sleep(500)
            check(runtime.latest["capturedMs"] == paused["capturedMs"])
            check((mark["sampleOffset"] as Long) >= (first["sampleOffset"] as Long))
            call { runtime.resume(it) }
            if (enduranceSeconds > 0) {
                check(enduranceSeconds in 10..14400)
                shell("input keyevent KEYCODE_HOME")
                shell("input keyevent KEYCODE_SLEEP")
                val deadline = SystemClock.elapsedRealtime() + (enduranceSeconds + 120) * 1000L
                var reported = -1L
                while ((runtime.latest["capturedMs"] as Number).toLong() <
                    enduranceSeconds * 1000L
                ) {
                    check(runtime.latest["state"] == "recording") {
                        "Endurance capture interrupted"
                    }
                    check(SystemClock.elapsedRealtime() < deadline) {
                        "Endurance sample clock stalled"
                    }
                    SystemClock.sleep(1000)
                    val minute = (runtime.latest["capturedMs"] as Number).toLong() / 60000
                    if (minute != reported) {
                        reported = minute
                        instrumentation.sendStatus(
                            1,
                            Bundle().apply {
                                putString("stream", "M3b captured minutes: $minute\n")
                            }
                        )
                    }
                }
            } else {
                SystemClock.sleep(1200)
            }
            val stopped = call { runtime.stop(it) } as Map<*, *>
            check(stopped["state"] == "completed_with_gaps")
            check(stopped["capturedMs"] == stopped["committedMs"])
            SessionStore(File(stopped["directory"].toString())).use { store ->
                store.verifyChunks()
                check(store.timeline().any { it["type"] == "audio_interruption_began" })
                check(store.timeline().any { it["type"] == "audio_interruption_ended" })
                val receipt = CaptureReceipt.read(store.directory)!!
                check(receipt.getLong("receivedSamples") == store.highWater())
                check(
                    store.summary()["bookmarkCount"] == 2L && store.summary()["thoughtCount"] == 1L
                )
                if (enduranceSeconds > 0) {
                    val metrics = store.timeline().last {
                        it["type"] == "session_stopped"
                    }["payload"] as Map<*, *>
                    val off = (metrics["backgroundOrScreenOffSamples"] as Number).toLong()
                    if (enduranceSeconds >= 1800) check(off.toDouble() / store.highWater() >= 0.95)
                    check(store.highWater() >= enduranceSeconds * 16000L)
                    instrumentation.sendStatus(
                        1,
                        Bundle().apply {
                            putString(
                                "stream",
                                "M3b sample metrics: ${org.json.JSONObject(metrics)}\n"
                            )
                        }
                    )
                }
            }
            checks += "real_interrupt_resume_preserves_gap_and_all_received_samples"
            checks += "paused_annotations_keep_sample_clock"
        } finally {
            runCatching { call { runtime.setAvailableStorageForTest(null, it) } }
            if (runtime.active) runCatching { call { runtime.stop(it) } }
            if (enduranceSeconds > 0) shell("input keyevent KEYCODE_WAKEUP")
        }
    }

    private fun shell(command: String) {
        android.os.ParcelFileDescriptor.AutoCloseInputStream(
            instrumentation.uiAutomation.executeShellCommand(command)
        ).use {
            it.readBytes()
        }
    }

    private fun call(operation: (NativeReply) -> Unit): Any? {
        val latch = CountDownLatch(1)
        var result: Result<Any?>? = null
        instrumentation.runOnMainSync {
            operation {
                result = it
                latch.countDown()
            }
        }
        check(latch.await(20, TimeUnit.SECONDS)) { "Native callback timeout" }
        return result!!.getOrThrow()
    }
}
