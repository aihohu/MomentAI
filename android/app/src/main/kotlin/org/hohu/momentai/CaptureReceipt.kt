package org.hohu.momentai

import android.util.AtomicFile
import java.io.File
import org.json.JSONObject

/** Durable native receipt, separate from canonical facts. Never inferred from UI time. */
class CaptureReceipt(directory: File, private val sessionId: String) {
    private val file = AtomicFile(File(directory, "capture_receipt.json"))
    private var saved = -1L

    fun save(received: Long, committed: Long, state: String, force: Boolean = false) {
        if (!force && received - saved < INTERVAL_SAMPLES) return
        val bytes = JSONObject(
            mapOf(
                "version" to 1,
                "sessionId" to sessionId,
                "receivedSamples" to received,
                "committedSamples" to committed,
                "state" to state,
                "maxUncheckpointedSamples" to MAX_UNCHECKPOINTED_SAMPLES,
                "updatedAt" to SessionStore.now()
            )
        ).toString().toByteArray()
        val stream = file.startWrite()
        try {
            stream.write(bytes)
            file.finishWrite(stream)
            saved = received
        } catch (
            failure: Exception
        ) {
            file.failWrite(stream)
            throw failure
        }
    }

    companion object {
        const val INTERVAL_SAMPLES = 3200L

        // At most one 1600-sample read can cross the 200 ms checkpoint interval.
        const val MAX_UNCHECKPOINTED_SAMPLES = 4800L
        fun read(directory: File): JSONObject? = runCatching {
            val json =
                JSONObject(
                    AtomicFile(
                        File(directory, "capture_receipt.json")
                    ).openRead().bufferedReader().use {
                        it.readText()
                    }
                )
            require(json.getInt("version") == 1 && json.getString("sessionId") == directory.name)
            require(json.getLong("receivedSamples") >= json.getLong("committedSamples"))
            require(json.getLong("committedSamples") >= 0)
            require(json.getLong("maxUncheckpointedSamples") == MAX_UNCHECKPOINTED_SAMPLES)
            json
        }.getOrNull()
    }
}
