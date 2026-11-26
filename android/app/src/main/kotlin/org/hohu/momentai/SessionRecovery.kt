package org.hohu.momentai

import android.system.Os
import java.io.File
import org.json.JSONObject

/** Called on the bridge's serial database queue, only for inactive Sessions. */
object SessionRecovery {
    fun preview(store: SessionStore): Map<String, Any?> {
        val received = CaptureReceipt.read(store.directory)
        val committed = store.highWater()
        val observed = maxOf(committed, received?.optLong("receivedSamples") ?: committed)
        val uncertainty = if (received?.optString("state") in
            setOf("paused", "interrupted", "completed", "completed_with_gaps")
        ) {
            0L
        } else {
            CaptureReceipt.MAX_UNCHECKPOINTED_SAMPLES
        }
        val upper = maxOf(0, observed + uncertainty - committed)
        val images = store.captureEvents().filter { it["type"] == "image" }
        return store.summary() +
            mapOf(
                "lastCommittedSample" to committed,
                "observedSamples" to observed,
                "rpoMs" to if (received == null) 0L else (upper + 15) / 16,
                "rpoKnown" to (received != null),
                "rpoIsUpperBound" to true,
                "rpoPass" to (received != null && upper <= 32000),
                "imageCommittedCount" to images.count { it["captureState"] == "committed" },
                "imagePendingCount" to images.count { it["captureState"] == "pending" }
            )
    }

    fun recover(store: SessionStore): Map<String, Any?> {
        // Fail closed on damaged committed audio; retain every original file and row.
        store.verifyChunks()
        val previous = store.db.rawQuery("SELECT * FROM recovery_report", null).use { c ->
            if (!c.moveToFirst()) {
                null
            } else {
                mapOf<String, Any?>(
                    "rpoMs" to c.getLong(c.getColumnIndexOrThrow("rpo_ms")),
                    "observedSamples" to c.getLong(c.getColumnIndexOrThrow("observed_samples")),
                    "discardedSamples" to c.getLong(c.getColumnIndexOrThrow("discarded_samples")),
                    "quarantinedFiles" to c.getLong(c.getColumnIndexOrThrow("quarantined_files"))
                )
            }
        }
        if (previous != null) {
            reconcileImages(store)
            val evidence = store.timeline().lastOrNull {
                it["type"] == "session_recovered"
            }?.get("payload") as? Map<*, *>
            return result(
                store,
                previous + mapOf("rpoKnown" to (evidence?.get("rpoKnown") == true))
            )
        }
        check(store.status() !in SessionStore.terminalStates) {
            "This record does not require recovery."
        }
        val estimate = preview(store)
        store.setStatus("recovering")
        reconcileImages(store)
        val registered = store.chunks().map { File(it["path"].toString()).canonicalFile }.toSet()
        val audio = File(store.directory, "audio")
        for (file in audio.listFiles().orEmpty()) {
            if (file.extension == "part" ||
                (file.extension == "pcm" && file.canonicalFile !in registered)
            ) {
                quarantine(file)
            }
        }
        val quarantined = audio.listFiles().orEmpty().filter { it.extension == "quarantine" }
        val discarded = quarantined.sumOf { it.length() / 2 }
        val rpo = maxOf((estimate["rpoMs"] as Number).toLong(), (discarded + 15) / 16)
        val report = estimate + mapOf(
            "rpoMs" to rpo,
            "discardedSamples" to discarded,
            "quarantinedFiles" to quarantined.size
        )
        store.transaction {
            closePause(store)
            store.event(
                "session_recovered",
                payload = mapOf(
                    "reason" to "process_ended",
                    "rpoMs" to rpo,
                    "rpoKnown" to estimate["rpoKnown"],
                    "rpoIsUpperBound" to true,
                    "observedSamples" to estimate["observedSamples"],
                    "discardedSamples" to discarded,
                    "quarantinedFiles" to quarantined.size,
                    "corruptChunks" to 0
                )
            )
            // An unexpected process end is explicit even when all durable blocks survive.
            store.setStatus("completed_with_gaps", stopped = true)
            store.db.execSQL("UPDATE session SET recovery_count=recovery_count+1")
            store.db.execSQL(
                "INSERT INTO recovery_report VALUES(?,?,?,?,?,?,?,?,?,?)",
                arrayOf(
                    store.id, "completed_with_gaps", store.highWater(), store.chunks().size,
                    estimate["observedSamples"], discarded, rpo, quarantined.size, 0, SessionStore.now()
                )
            )
        }
        return result(store, report)
    }

    private fun result(store: SessionStore, report: Map<String, Any?>): Map<String, Any?> {
        val events = store.captureEvents()
        return store.summary() + report +
            mapOf(
                "state" to store.status(),
                "lastCommittedSample" to store.highWater(),
                "rpoPass" to
                    (report["rpoKnown"] == true && (report["rpoMs"] as Number).toLong() <= 2000),
                "rpoIsUpperBound" to true,
                "corruptChunks" to 0,
                "imageCommittedCount" to
                    events.count { it["type"] == "image" && it["captureState"] == "committed" },
                "imageFailedCount" to
                    events.count { it["type"] == "image" && it["captureState"] == "failed" },
                "capturePendingCount" to events.count { it["captureState"] == "pending" }
            )
    }

    private fun closePause(store: SessionStore) {
        val open = mutableMapOf<String, Map<String, Any?>>()
        for (event in store.timeline().filter { it["kind"] == "event" }) {
            val payload = event["payload"] as? Map<*, *> ?: continue
            val id = payload["pause_id"] as? String ?: continue
            if (event["type"] == "user_pause_began") open[id] = event
            if (event["type"] == "user_pause_ended") open.remove(id)
        }
        for ((id, event) in open) {
            store.event(
                "user_pause_ended",
                (event["sampleOffset"] as Number).toLong(),
                mapOf(
                    "schema_version" to 1,
                    "pause_id" to id,
                    "end_reason" to "session_recovered",
                    "duration_unknown" to true
                )
            )
        }
    }

    private fun reconcileImages(store: SessionStore) {
        for (row in store.captureEvents().filter { it["type"] == "image" }) {
            val id = row["eventId"].toString()
            val payload = row["payload"] as Map<*, *>
            val target = store.assetFile(payload["path"].toString())
            val part = File(target.path + ".part")
            if (row["captureState"] == "pending") {
                if (part.exists()) quarantine(part)
                if (target.isFile) {
                    try {
                        store.commitImage(id, null)
                    } catch (
                        _: Exception
                    ) {
                        store.failImage(
                            id,
                            NativeStrings.text(
                                R.string.native_the_photo_was_not_fully_saved_the_original_file_was_kept_10
                            ),
                            "corrupt"
                        )
                    }
                } else {
                    store.failImage(
                        id,
                        NativeStrings.text(R.string.native_saving_the_photo_was_interrupted_11),
                        "missing"
                    )
                }
            } else if (row["captureState"] == "committed") {
                if (!target.isFile) {
                    store.failImage(
                        id,
                        NativeStrings.text(R.string.native_the_photo_file_is_missing_12),
                        "missing",
                        true
                    )
                } else {
                    val expected = (payload["byteCount"] as Number).toLong()
                    val valid =
                        target.length() == expected &&
                            target.length() <= SessionStore.MAX_IMAGE_BYTES &&
                            target.readBytes().let {
                                SessionStore.validJpeg(it) &&
                                    SessionStore.sha256(it) == payload["sha256"]
                            }
                    if (!valid) {
                        store.failImage(
                            id,
                            NativeStrings.text(
                                R.string.native_photo_verification_failed_the_original_file_was_kept_13
                            ),
                            "corrupt",
                            true
                        )
                    }
                }
            }
        }
    }

    private fun quarantine(file: File) {
        var destination = File(file.path + ".quarantine")
        if (destination.exists()) {
            destination =
                File(file.path + ".${java.util.UUID.randomUUID()}.quarantine")
        }
        Os.rename(file.path, destination.path)
        SessionStore.syncDirectory(file.parentFile!!)
    }
}
