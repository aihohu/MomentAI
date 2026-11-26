package org.hohu.momentai

import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.database.sqlite.SQLiteDatabase
import android.os.StatFs
import android.system.Os
import android.system.OsConstants
import java.io.Closeable
import java.io.File
import java.io.FileOutputStream
import java.security.MessageDigest
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import java.util.UUID
import org.json.JSONArray
import org.json.JSONObject

/** Canonical v1 facts. PCM is durable before its row/high-water transaction. */
class SessionStore(val directory: File, schema: String? = null, title: String = "") : Closeable {
    val id = directory.name
    internal val db: SQLiteDatabase

    init {
        if (schema != null) {
            check(directory.mkdirs()) { "Session already exists." }
            check(File(directory, "audio").mkdir())
            check(File(directory, "assets").mkdir())
        }
        db = try {
            SQLiteDatabase.openDatabase(
                File(directory, "session.sqlite").path,
                null,
                SQLiteDatabase.OPEN_READWRITE or SQLiteDatabase.ENABLE_WRITE_AHEAD_LOGGING or
                    if (schema != null) SQLiteDatabase.CREATE_IF_NECESSARY else 0
            )
        } catch (failure: Exception) {
            if (schema != null) directory.deleteRecursively()
            throw failure
        }
        try {
            db.enableWriteAheadLogging()
            db.execSQL("PRAGMA synchronous=FULL")
            db.execSQL("PRAGMA foreign_keys=ON")
            // Some Android SQLite builds return a row even when setting this pragma.
            db.rawQuery("PRAGMA busy_timeout=5000", null).use { it.moveToFirst() }
            if (schema != null) {
                transaction {
                    schema.split(
                        ';'
                    ).map(String::trim).filter(String::isNotEmpty).forEach(db::execSQL)
                    db.execSQL(
                        "INSERT INTO session(id,title,status,started_at_wall,sample_rate) VALUES(?,?,'preparing',?,16000)",
                        arrayOf(
                            id,
                            title.trim().ifEmpty {
                                NativeStrings.text(R.string.native_new_recording_44)
                            },
                            now()
                        )
                    )
                }
            }
            check(number("SELECT COUNT(*) FROM session WHERE id=?", arrayOf(id)) == 1L)
        } catch (failure: Exception) {
            db.close()
            // Only a directory exclusively created by this constructor is removed.
            if (schema != null) directory.deleteRecursively()
            throw failure
        }
    }

    fun transaction(action: () -> Unit) {
        db.beginTransaction()
        try {
            action()
            db.setTransactionSuccessful()
        } finally {
            db.endTransaction()
        }
    }

    fun number(sql: String, args: Array<String>? = null): Long = db.rawQuery(sql, args).use {
        if (it.moveToFirst()) it.getLong(0) else 0L
    }

    fun highWater() = number("SELECT last_committed_sample FROM session")

    fun status(): String = db.rawQuery("SELECT status FROM session", null).use {
        it.moveToFirst()
        it.getString(0)
    }

    fun setStatus(state: String, stopped: Boolean = false) {
        val current = status()
        check(current !in terminalStates || current == state) { "Session is already terminal." }
        db.execSQL(
            if (stopped) "UPDATE session SET status=?,stopped_at_wall=?" else "UPDATE session SET status=?",
            if (stopped) arrayOf(state, now()) else arrayOf(state)
        )
    }

    fun event(type: String, sample: Long = highWater(), payload: Map<String, Any?> = emptyMap()) {
        require(sample >= 0 && sample <= highWater()) { "Event exceeds committed audio." }
        db.execSQL(
            "INSERT INTO events(type,sample_offset,wall_time,payload_json) VALUES(?,?,?,?)",
            arrayOf<Any>(type, sample, now(), JSONObject(payload).toString())
        )
    }

    fun commitPcm(bytes: ByteArray): Map<String, Any?> {
        require(bytes.isNotEmpty() && bytes.size % 2 == 0)
        val index = number("SELECT next_chunk_index FROM session").toInt()
        val start = highWater()
        val relative = "audio/chunk_%06d.pcm".format(Locale.US, index)
        val target = File(directory, relative)
        check(!target.exists()) { "Refusing to overwrite committed audio." }
        val part = File(target.path + ".part")
        FileOutputStream(part).use {
            it.write(bytes)
            it.fd.sync()
        }
        Os.rename(part.path, target.path)
        syncDirectory(target.parentFile!!)
        transaction {
            db.execSQL(
                "INSERT INTO chunks VALUES(?,?,?,?,?,?)",
                arrayOf<Any>(index, relative, bytes.size / 2, bytes.size, sha256(bytes), now())
            )
            db.execSQL(
                "UPDATE session SET last_committed_sample=?,next_chunk_index=?",
                arrayOf<Any>(start + bytes.size / 2, index + 1)
            )
        }
        return chunk(index, relative, start, bytes.size / 2L)
    }

    fun chunks(after: Long = 0): List<Map<String, Any?>> {
        val result = mutableListOf<Map<String, Any?>>()
        var start = 0L
        db.rawQuery(
            "SELECT chunk_index,path,sample_count FROM chunks ORDER BY chunk_index",
            null
        ).use {
            while (it.moveToNext()) {
                val count = it.getLong(2)
                if (start + count >
                    after
                ) {
                    result.add(chunk(it.getInt(0), it.getString(1), start, count))
                }
                start += count
            }
        }
        return result
    }

    private fun chunk(index: Int, path: String, start: Long, count: Long) = mapOf(
        "sessionId" to id,
        "directory" to directory.path,
        "index" to index,
        "path" to File(directory, path).path,
        "startSample" to start,
        "endSample" to start + count,
        "sampleCount" to count,
        "sampleRate" to 16000
    )

    fun commitTranscript(segment: Map<*, *>) {
        val segmentId = segment["segmentId"] as? String ?: error("Missing segment id.")
        val start = (segment["startSample"] as? Number)?.toLong() ?: -1
        val end = (segment["endSample"] as? Number)?.toLong() ?: -1
        val text = segment["text"] as? String ?: ""
        require(segmentId.isNotEmpty() && segment["sessionId"] == id && text.isNotBlank())
        require(start >= 0 && end >= start && end <= highWater()) {
            "Transcript exceeds committed audio."
        }
        val values = ContentValues().apply {
            put("segment_id", segmentId)
            put("session_id", id)
            put("start_sample", start)
            put("end_sample", end)
            put("start_ms", start / 16)
            put(
                "end_ms",
                end / 16
            )
            put("text", text)
            put("raw_text", segment["rawText"] as? String ?: text)
            put("language", segment["language"] as? String ?: "zh")
            put("source", segment["source"] as? String ?: "sherpa_onnx")
            put("model_id", segment["modelId"] as? String ?: "unknown")
            put(
                "is_final",
                if (segment["isFinal"] ==
                    false
                ) {
                    0
                } else {
                    1
                }
            )
            put("created_at_wall", now())
        }
        transaction {
            db.rawQuery(
                "SELECT start_sample,end_sample FROM transcript_segments WHERE segment_id=?",
                arrayOf(segmentId)
            ).use {
                if (it.moveToFirst()) {
                    require(it.getLong(0) == start && it.getLong(1) == end) {
                        "Transcript identity conflict."
                    }
                    db.execSQL(
                        "UPDATE transcript_segments SET text=?,is_final=MAX(is_final,?) WHERE segment_id=?",
                        arrayOf<Any>(text, if (segment["isFinal"] == false) 0 else 1, segmentId)
                    )
                } else {
                    db.insertOrThrow("transcript_segments", null, values)
                }
            }
        }
    }

    fun timeline(): List<Map<String, Any?>> {
        val result = mutableListOf<Map<String, Any?>>()
        db.rawQuery(
            "SELECT * FROM transcript_segments ORDER BY start_sample,created_at_wall",
            null
        ).use { c ->
            while (c.moveToNext()) {
                result.add(
                    mapOf(
                        "kind" to "transcript", "segmentId" to c.text("segment_id"),
                        "sessionId" to id,
                        "sampleOffset" to c.long("start_sample"),
                        "startSample" to c.long("start_sample"),
                        "endSample" to c.long("end_sample"), "startMs" to c.long("start_ms"),
                        "endMs" to c.long("end_ms"),
                        "text" to c.text("text"), "rawText" to c.text("raw_text"),
                        "language" to c.text("language"),
                        "source" to c.text("source"), "modelId" to c.text("model_id"),
                        "isFinal" to (c.long("is_final") == 1L),
                        "wallTime" to c.text("created_at_wall")
                    )
                )
            }
        }
        db.rawQuery("SELECT * FROM events ORDER BY seq", null).use { c ->
            while (c.moveToNext()) {
                result.add(
                    mapOf(
                        "kind" to "event",
                        "sequence" to c.long("seq"),
                        "type" to c.text("type"),
                        "sampleOffset" to c.long("sample_offset"),
                        "atMs" to c.long("sample_offset") / 16,
                        "wallTime" to c.text("wall_time"),
                        "payload" to jsonMap(JSONObject(c.text("payload_json")))
                    )
                )
            }
        }
        result.addAll(captureEvents())
        return result.sortedWith(
            compareBy<Map<String, Any?>> {
                (it["sampleOffset"] as Number).toLong()
            }
                .thenBy {
                    if (it["kind"] ==
                        "event"
                    ) {
                        0
                    } else {
                        1
                    }
                }.thenBy { (it["sequence"] as? Number)?.toLong() ?: 0L }
        )
    }

    fun summary(): Map<String, Any?> = db.rawQuery("SELECT * FROM session", null).use { c ->
        check(c.moveToFirst())
        val state = c.text("status")
        mapOf(
            "sessionId" to id, "directory" to directory.path, "title" to c.text("title"),
            "state" to state, "startedAtWall" to c.text("started_at_wall"),
            "stoppedAtWall" to c.text("stopped_at_wall"),
            "sampleRate" to 16000, "durationSamples" to c.long("last_committed_sample"),
            "durationMs" to c.long("last_committed_sample") / 16,
            "chunkCount" to c.long("next_chunk_index"),
            "recoveryCount" to c.long("recovery_count"),
            "hasConfirmedGaps" to (state == "completed_with_gaps"),
            "exportAvailable" to
                (
                    state in setOf("completed", "completed_with_gaps") &&
                        c.long("last_committed_sample") > 0
                    ),
            "transcriptCount" to number(
                "SELECT COUNT(*) FROM transcript_segments WHERE is_final=1"
            ),
            "imageCount" to captureCount("image"), "thoughtCount" to captureCount("thought"),
            "bookmarkCount" to captureCount("bookmark")
        )
    }

    private fun captureCount(type: String) = number(
        "SELECT COUNT(*) FROM capture_events WHERE type=? AND capture_state='committed'",
        arrayOf(type)
    )

    fun addCapture(type: String, text: String = "", elapsedNs: Long, epoch: String): Map<String, Any?> {
        require(type in setOf("image", "bookmark", "thought"))
        check(status() in setOf("recording", "paused")) {
            "Recording is not accepting annotations."
        }
        val normalized = text.trim()
        if (type ==
            "thought"
        ) {
            require(
                normalized.isNotEmpty() && normalized.codePointCount(
                    0,
                    normalized.length
                ) <= 4000
            )
        }
        val eventId = UUID.randomUUID().toString()
        val blob = if (type == "image") UUID.randomUUID().toString() else null
        val time = now()
        transaction {
            if (blob !=
                null
            ) {
                db.execSQL(
                    "INSERT INTO media_assets VALUES(?,?,'image','pending',?,'image/jpeg',0,'',?,?)",
                    arrayOf(blob, id, "assets/$blob.jpg", time, time)
                )
            }
            val sample = highWater()
            val payload = if (type ==
                "thought"
            ) {
                mapOf("text" to normalized, "source" to "user_text")
            } else {
                emptyMap()
            }
            db.execSQL(
                """INSERT INTO capture_events(event_id,session_id,type,sample_offset,at_ms,
                monotonic_elapsed_ns,wall_time,clock_epoch_id,capture_state,asset_blob_id,payload_json,created_at_wall,updated_at_wall)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)""",
                arrayOf<Any?>(
                    eventId, id, type, sample,
                    sample / 16,
                    elapsedNs, time, epoch,
                    if (blob ==
                        null
                    ) {
                        "committed"
                    } else {
                        "pending"
                    },
                    blob, JSONObject(payload).toString(), time, time
                )
            )
        }
        return captureEvents().first { it["eventId"] == eventId }
    }

    fun captureEvents(): List<Map<String, Any?>> {
        val rows = mutableListOf<Map<String, Any?>>()
        db.rawQuery(
            """SELECT e.*,a.blob_id,a.path,a.state AS asset_state,a.mime_type,a.byte_count,a.sha256
            FROM capture_events e LEFT JOIN media_assets a ON a.blob_id=e.asset_blob_id
            ORDER BY e.sample_offset,e.monotonic_elapsed_ns,e.seq""",
            null
        ).use { c ->
            while (c.moveToNext()) {
                val relative = c.text("path")
                val payload = jsonMap(JSONObject(c.text("payload_json"))).toMutableMap()
                payload.putAll(
                    mapOf(
                        "eventId" to c.text("event_id"),
                        "captureState" to c.text("capture_state"),
                        "blobId" to c.text("blob_id"),
                        "path" to relative,
                        "assetState" to c.text("asset_state"),
                        "mimeType" to c.text("mime_type"),
                        "byteCount" to c.long("byte_count"),
                        "sha256" to c.text("sha256")
                    )
                )
                rows.add(
                    mapOf(
                        "kind" to "captureEvent", "sequence" to c.long("seq"),
                        "eventId" to c.text("event_id"),
                        "type" to c.text("type"), "sampleOffset" to c.long("sample_offset"),
                        "atMs" to c.long("at_ms"),
                        "monotonicElapsedNs" to c.long("monotonic_elapsed_ns"),
                        "wallTime" to c.text("wall_time"),
                        "clockEpochId" to c.text("clock_epoch_id"),
                        "captureState" to c.text("capture_state"),
                        "assetPath" to if (relative.isEmpty()) "" else assetFile(relative).path,
                        "text" to (payload["text"] ?: ""), "payload" to payload
                    )
                )
            }
        }
        return rows
    }

    fun assetFile(relative: String): File = File(directory, relative).canonicalFile.also {
        require(it.parentFile == File(directory, "assets").canonicalFile) { "Invalid asset path." }
    }

    fun commitImage(eventId: String, bytes: ByteArray?): Map<String, Any?> {
        val row = captureEvents().first { it["eventId"] == eventId && it["type"] == "image" }
        val payload = row["payload"] as Map<*, *>
        val target = assetFile(payload["path"].toString())
        if (row["captureState"] == "committed") {
            check(bytes == null || sha256(bytes) == payload["sha256"]) {
                "Image identity conflict."
            }
            return row
        }
        check(row["captureState"] == "pending" && payload["assetState"] == "pending")
        if (bytes != null) {
            require(validJpeg(bytes)) { "Incomplete or oversized JPEG." }
            check(!target.exists()) { "Refusing to overwrite image." }
            val part = File(target.path + ".part")
            FileOutputStream(part).use {
                it.write(bytes)
                it.fd.sync()
            }
            Os.rename(part.path, target.path)
            syncDirectory(target.parentFile!!)
        }
        check(target.length() in 4..MAX_IMAGE_BYTES)
        val data = target.readBytes()
        check(validJpeg(data)) { "Incomplete JPEG." }
        transaction {
            db.execSQL(
                "UPDATE media_assets SET state='committed',byte_count=?,sha256=?,updated_at_wall=? WHERE blob_id=? AND state='pending'",
                arrayOf<Any>(data.size, sha256(data), now(), payload["blobId"].toString())
            )
            check(number("SELECT changes()") == 1L) { "Photo was cancelled before commit." }
            db.execSQL(
                "UPDATE capture_events SET capture_state='committed',updated_at_wall=? WHERE event_id=? AND capture_state='pending'",
                arrayOf(now(), eventId)
            )
            check(number("SELECT changes()") == 1L) { "Photo was cancelled before commit." }
        }
        return captureEvents().first { it["eventId"] == eventId }
    }

    fun failImage(eventId: String, reason: String, assetState: String = "failed", invalidateCommitted: Boolean = false) = transaction {
        require(assetState in setOf("failed", "missing", "corrupt"))
        if (!invalidateCommitted &&
            number(
                "SELECT COUNT(*) FROM capture_events WHERE event_id=? AND capture_state='committed'",
                arrayOf(eventId)
            ) >
            0
        ) {
            return@transaction
        }
        db.execSQL(
            "UPDATE media_assets SET state=?,updated_at_wall=? WHERE blob_id=(SELECT asset_blob_id FROM capture_events WHERE event_id=?)",
            arrayOf(assetState, now(), eventId)
        )
        db.execSQL(
            "UPDATE capture_events SET capture_state='failed',payload_json=?,updated_at_wall=? WHERE event_id=?",
            arrayOf(JSONObject(mapOf("error" to reason)).toString(), now(), eventId)
        )
    }

    fun finishPendingImages() {
        captureEvents().filter {
            it["type"] == "image" && it["captureState"] == "pending"
        }.forEach {
            failImage(
                it["eventId"].toString(),
                NativeStrings.text(
                    R.string.native_the_recording_ended_before_the_photo_finished_saving_64
                )
            )
        }
    }

    fun rename(title: String) {
        require(
            title.trim().isNotEmpty() && title.trim().codePointCount(0, title.trim().length) <= 120
        )
        check(status() in terminalStates)
        db.execSQL("UPDATE session SET title=?", arrayOf(title.trim()))
    }

    fun verifyChunks() {
        var count = 0
        var samples = 0L
        db.rawQuery("SELECT * FROM chunks ORDER BY chunk_index", null).use { c ->
            while (c.moveToNext()) {
                check(c.long("chunk_index") == count.toLong()) { "Non-contiguous audio chunks." }
                val file = File(directory, c.text("path")).canonicalFile
                check(file.parentFile == File(directory, "audio").canonicalFile)
                check(file.length() == c.long("byte_count") && file.length() <= 16L * 1024 * 1024)
                val bytes = file.readBytes()
                check(
                    bytes.size.toLong() == c.long("byte_count") &&
                        bytes.size.toLong() == c.long("sample_count") * 2
                )
                check(sha256(bytes) == c.text("sha256")) { "Audio checksum mismatch." }
                samples += bytes.size / 2
                count++
            }
        }
        check(
            samples == highWater() &&
                count.toLong() == number("SELECT next_chunk_index FROM session")
        )
    }

    override fun close() {
        db.close()
    }

    companion object {
        val terminalStates = setOf("completed", "completed_with_gaps", "failed_to_start")
        const val MAX_IMAGE_BYTES = 16L * 1024 * 1024
        fun validJpeg(bytes: ByteArray): Boolean {
            if (bytes.size.toLong() !in 4..MAX_IMAGE_BYTES || bytes[0] != 0xff.toByte() ||
                bytes[1] != 0xd8.toByte() || bytes[bytes.size - 2] != 0xff.toByte() ||
                bytes.last() != 0xd9.toByte()
            ) {
                return false
            }
            val bounds = android.graphics.BitmapFactory.Options().apply {
                inJustDecodeBounds = true
            }
            android.graphics.BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
            return bounds.outWidth in 1..8192 && bounds.outHeight in 1..8192 &&
                bounds.outWidth.toLong() * bounds.outHeight <= 32_000_000
        }
        const val MINIMUM_FREE_BYTES = 512L * 1024 * 1024
        fun root(context: Context): File = File(context.noBackupFilesDir, "MomentAI/Sessions").apply {
            mkdirs()
        }.canonicalFile
        fun resolve(root: File, path: String): File {
            val candidate = File(path).canonicalFile
            require(
                candidate.parentFile == root.canonicalFile && candidate.name.startsWith("session_")
            ) {
                "Invalid Session path."
            }
            require(File(candidate, "session.sqlite").isFile) { "Session not found." }
            return candidate
        }
        fun create(context: Context, title: String): SessionStore {
            require(title.trim().isNotEmpty() && title.length <= 240)
            val directory =
                File(root(context), "session_${System.currentTimeMillis()}_${UUID.randomUUID()}")
            return SessionStore(
                directory,
                context.resources.openRawResource(R.raw.session_schema).bufferedReader().use {
                    it.readText()
                },
                title
            )
        }
        fun list(root: File): List<Map<String, Any?>> = (root.listFiles() ?: emptyArray())
            .filter {
                it.isDirectory && it.name.startsWith("session_") &&
                    File(it, "session.sqlite").isFile
            }
            .map { SessionStore(resolve(root, it.path)).use { store -> store.summary() } }
            .sortedByDescending { it["startedAtWall"].toString() }
        fun storage(context: Context): Map<String, Any?> {
            val root = root(context)
            val stat = StatFs(root.path)
            return mapOf(
                "appUsedBytes" to root.walkTopDown().filter(File::isFile).sumOf(File::length),
                "availableBytes" to stat.availableBytes,
                "totalBytes" to stat.totalBytes,
                "minimumRequiredBytes" to MINIMUM_FREE_BYTES,
                "canStartRecording" to (stat.availableBytes >= MINIMUM_FREE_BYTES),
                "sessionCount" to list(root).size
            )
        }
        fun now(): String = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US).apply {
            timeZone =
                TimeZone.getTimeZone("UTC")
        }.format(Date())
        fun sha256(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") {
            "%02x".format(it)
        }
        fun syncDirectory(directory: File) {
            val fd = Os.open(directory.path, OsConstants.O_RDONLY, 0)
            try {
                Os.fsync(fd)
            } finally {
                Os.close(fd)
            }
        }
        fun jsonMap(value: JSONObject): Map<String, Any?> = value.keys().asSequence().associateWith {
            val item = value.get(it)
            jsonValue(item)
        }
        private fun jsonValue(item: Any?): Any? = when (item) {
            JSONObject.NULL, null -> null
            is JSONObject -> jsonMap(item)
            is JSONArray -> (0 until item.length()).map { jsonValue(item.get(it)) }
            else -> item
        }
    }
}

private fun Cursor.text(name: String) = getString(getColumnIndexOrThrow(name)) ?: ""
private fun Cursor.long(name: String) = getLong(getColumnIndexOrThrow(name))
