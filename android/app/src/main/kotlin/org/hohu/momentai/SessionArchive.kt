package org.hohu.momentai

import android.content.Context
import android.os.StatFs
import android.system.Os
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream
import java.text.ParsePosition
import java.text.SimpleDateFormat
import java.util.Locale
import java.util.UUID

/** Serial-queue only. Imports become visible with one same-volume directory rename. */
internal class SessionArchive(
    private val context: Context,
    root: File = SessionStore.root(context),
    exportRoot: File = File(context.cacheDir, "MomentAIExports"),
    private val freeBytes: () -> Long = { StatFs(root.path).availableBytes },
    private val beforeCommit: () -> Unit = {}
) {
    init {
        NativeStrings.initialize(context)
    }
    private val root = root.canonicalFile
    private val exportRoot = exportRoot.canonicalFile
    private data class Pending(
        val token: String,
        val job: File,
        val payload: File,
        val document: JsonMap,
        val hash: String,
        val bytes: Long
    )
    private var pending: Pending? = null
    private fun space(bytes: Long) {
        require(freeBytes() >= bytes + SessionStore.MINIMUM_FREE_BYTES) {
            NativeStrings.text(
                R.string.native_not_enough_storage_leave_at_least_512_mib_free_and_try_again_65
            )
        }
    }
    fun cancel() {
        pending?.job?.deleteRecursively()
        pending = null
    }
    private fun store(id: String): SessionStore = SessionStore(SessionStore.resolve(root, File(root, validId(id)).path))
    private fun validId(id: String): String {
        require(id.length <= 160 && Regex("session_[a-zA-Z0-9_-]+").matches(id)) {
            NativeStrings.text(R.string.native_invalid_recording_id_66)
        }
        return id
    }
    fun share(id: String, format: String, readingText: String? = null): File {
        require(format in setOf("text", "markdown", "audio")) {
            NativeStrings.text(R.string.native_unsupported_sharing_format_67)
        }
        return store(id).use { store ->
            require(store.status() in setOf("completed", "completed_with_gaps")) {
                NativeStrings.text(R.string.native_finish_recording_first_68)
            }
            space(if (format == "audio") store.highWater() * 2 + 44 else 16 * 1024 * 1024)
            exportRoot.mkdirs()
            val ext = when (format) {
                "audio" -> "wav"
                "markdown" -> "md"
                else -> "txt"
            }
            val destination = File(exportRoot, id + "_" + UUID.randomUUID() + "." + ext)
            val partial = File(destination.path + ".part")
            try {
                if (format == "audio") {
                    writeAudio(store, partial)
                } else {
                    val (timeline, canonical) = PortableText.project(
                        store.directory,
                        id,
                        store.highWater(),
                        store.timeline()
                    )
                    val speakers = PortableText.loadSpeakers(store)?.let {
                        PortableText.speakerProjection(canonical, it)
                    }
                    writeText(
                        partial,
                        shareText(
                            store.summary(),
                            timeline,
                            canonical,
                            speakers,
                            format == "markdown",
                            if (format == "text") readingText else null
                        )
                    )
                }
                Os.rename(partial.path, destination.path)
                destination
            } finally {
                partial.delete()
            }
        }
    }
    fun readText(id: String, readingText: String? = null): String {
        val file = share(id, "text", readingText)
        return try {
            file.readText()
        } finally {
            file.delete()
        }
    }
    fun export(directory: String): JsonMap = SessionStore(SessionStore.resolve(root, directory)).use { store ->
        require(store.status() in setOf("completed", "completed_with_gaps")) {
            NativeStrings.text(R.string.native_finish_recording_first_68)
        }
        val samples = store.highWater()
        val imageRows = store.captureEvents().filter {
            it["type"] == "image" &&
                it["captureState"] == "committed"
        }
        val imageBytes = imageRows.sumOf { it.obj("payload").num("byteCount") }
        space((samples * 2 + imageBytes + 32 * 1024 * 1024) * 2)
        exportRoot.mkdirs()
        val jobName = store.id + "_" + UUID.randomUUID()
        val bundle = File(exportRoot, jobName)
        val partial = File(exportRoot, ".$jobName.part")
        val archive = File(exportRoot, "$jobName.momentai")
        val archivePart = File(archive.path + ".part")
        check(partial.mkdirs())
        try {
            val audioFile = File(partial, "audio/session.wav")
            audioFile.parentFile!!.mkdirs()
            writeAudio(store, audioFile)
            val audioArtifact = StoredSessionZip.artifact(partial, "audio/session.wav")
            val audio =
                audioArtifact +
                    mapOf(
                        "mimeType" to "audio/wav",
                        "codec" to "pcm_s16le",
                        "sampleRate" to 16000,
                        "channels" to 1,
                        "bitsPerSample" to 16,
                        "sampleCount" to samples,
                        "durationMs" to samples / 16
                    )
            val images = imageRows.map { row ->
                val asset = row.obj("payload")
                require(asset["assetState"] == "committed")
                val source = store.assetFile(asset.str("path"))
                require(
                    source.length() == asset.num("byteCount") &&
                        StoredSessionZip.sha(source) == asset["sha256"]
                ) {
                    NativeStrings.text(R.string.native_photo_verification_failed_69)
                }
                val event = row.str("eventId")
                require(Regex("[a-zA-Z0-9_-]+").matches(event)) {
                    NativeStrings.text(
                        R.string.native_the_photo_identifier_cannot_be_used_in_an_archive_70
                    )
                }
                val path = "images/$event.jpg"
                val file = File(partial, path)
                file.parentFile!!.mkdirs()
                source.inputStream().use { copy(it, file, PortableText.METADATA_LIMIT) }
                StoredSessionZip.artifact(partial, path) +
                    mapOf(
                        "eventId" to event,
                        "sampleOffset" to row.num("sampleOffset"),
                        "atMs" to row.num("sampleOffset") / 16,
                        "mimeType" to "image/jpeg"
                    )
            }
            val imagePaths = images.associate { it.str("eventId") to it.str("path") }
            val sourceTimeline = store.timeline().map { row ->
                val clean = row.toMutableMap()
                clean.remove("assetPath")
                val path = imagePaths[row["eventId"]]
                if (path != null) clean["mediaPath"] = path
                (row["payload"] as? Map<*, *>)?.let {
                    val payload = it.jsonMap().toMutableMap()
                    payload.remove("assetPath")
                    // Failed assets must never leak sandbox paths into a portable bundle.
                    payload.remove("path")
                    if (path != null) payload["path"] = path
                    clean["payload"] = payload
                }
                clean.toMap()
            }
            val (timeline, canonical) = PortableText.project(
                store.directory,
                store.id,
                samples,
                sourceTimeline
            )
            val summary =
                store.summary().filterKeys { it != "directory" } +
                    mapOf("lastCommittedSample" to samples)
            val speaker = PortableText.loadSpeakers(store)
            val projection = speaker?.let { PortableText.speakerProjection(canonical, it) }
            val document: JsonMap =
                mapOf(
                    "schemaVersion" to 1, "format" to "org.hohu.momentai.session-export",
                    "exportedAt" to SessionStore.now(), "session" to summary, "audio" to audio,
                    "images" to images,
                    "timeline" to timeline, "canonicalText" to canonical,
                    "capabilities" to
                        (
                            listOf("canonicalTextV1", "timelineTextLayersV1") +
                                if (speaker !=
                                    null
                                ) {
                                    listOf(PortableText.SPEAKER_CAPABILITY)
                                } else {
                                    emptyList()
                                }
                            )
                ) +
                    if (speaker ==
                        null
                    ) {
                        emptyMap()
                    } else {
                        mapOf(
                            "extensions" to mapOf(
                                PortableText.SPEAKER_CAPABILITY to
                                    mapOf(
                                        "schemaVersion" to 1,
                                        "sourceAudioSha256" to audio["sha256"],
                                        "document" to speaker,
                                        "textProjection" to projection
                                    )
                            )
                        )
                    }
            writeJson(File(partial, "session.json"), document)
            writeText(
                File(partial, "timeline.jsonl"),
                timeline.mapIndexed { index, item ->
                    PortableText.encode(
                        mapOf(
                            "schemaVersion" to 1,
                            "sessionId" to store.id,
                            "index" to index,
                            "item" to item
                        )
                    )
                }.joinToString("\n", postfix = if (timeline.isEmpty()) "" else "\n")
            )
            writeText(
                File(partial, "session.md"),
                archiveMarkdown(summary, timeline, canonical, projection)
            )
            val paths = (
                listOf("session.json", "session.md", "timeline.jsonl", "audio/session.wav") +
                    images.map { it.str("path") }
                ).sorted()
            val artifacts = paths.map { StoredSessionZip.artifact(partial, it) }
            writeJson(
                File(partial, "manifest.json"),
                mapOf(
                    "schemaVersion" to 1,
                    "format" to "org.hohu.momentai.archive",
                    "archiveFormat" to "zip-store",
                    "sessionId" to store.id,
                    "exportedAt" to SessionStore.now(),
                    "files" to artifacts
                )
            )
            StoredSessionZip.write(partial, paths + "manifest.json", archivePart)
            // Re-read our own wire container before making it available for sharing.
            StoredSessionZip(archivePart).use { require(it.entries.size == paths.size + 1) }
            check(!bundle.exists() && !archive.exists())
            Os.rename(partial.path, bundle.path)
            try {
                Os.rename(archivePart.path, archive.path)
            } catch (
                failure: Exception
            ) {
                bundle.deleteRecursively()
                throw failure
            }
            mapOf(
                "schemaVersion" to 1, "sessionId" to store.id, "exportId" to jobName,
                "directory" to bundle.path,
                "archivePath" to archive.path,
                "markdownPath" to File(
                    bundle,
                    "session.md"
                ).path,
                "jsonPath" to File(bundle, "session.json").path,
                "jsonlPath" to File(bundle, "timeline.jsonl").path,
                "audioPath" to File(bundle, "audio/session.wav").path,
                "manifestPath" to File(bundle, "manifest.json").path,
                "audioSamples" to samples, "durationMs" to samples / 16,
                "timelineItemCount" to timeline.size,
                "transcriptCount" to timeline.count { it["kind"] == "transcript" },
                "canonicalTextStatus" to canonical["status"],
                "canonicalTextLayer" to canonical["defaultTextLayer"],
                "refinedTranscriptCount" to canonical["refinedSegmentCount"],
                "fallbackTranscriptCount" to canonical["fallbackSegmentCount"],
                "imageCount" to images.size,
                "payloadFileCount" to paths.size, "archiveByteCount" to archive.length(),
                "archiveSha256" to StoredSessionZip.sha(archive),
                "sourceDatabaseSha256" to
                    StoredSessionZip.sha(File(store.directory, "session.sqlite")),
                "exportedAt" to SessionStore.now()
            )
        } finally {
            partial.deleteRecursively()
            archivePart.delete()
        }
    }
    fun prepare(input: InputStream, displayName: String): JsonMap {
        cancel()
        require(displayName.lowercase(Locale.ROOT).endsWith(".momentai")) {
            NativeStrings.text(R.string.native_select_a_complete_momentai_recording_71)
        }
        val token = UUID.randomUUID().toString()
        val job = File(root, ".Imports/$token").apply { check(mkdirs()) }
        try {
            space(64 * 1024 * 1024)
            val source = File(job, "source.momentai")
            val bytes =
                copy(input, source, StoredSessionZip.MAXIMUM_BYTES) { received ->
                    space(received * 2 + 64 * 1024 * 1024)
                }
            space(bytes * 2 + 64 * 1024 * 1024)
            val payload = File(job, "payload")
            val artifacts = StoredSessionZip(source).use { it.extract(payload) }
            val manifestFile = File(payload, "manifest.json")
            require(manifestFile.length() <= 2 * 1024 * 1024)
            val manifest = PortableText.read(manifestFile)
            require(
                manifest.num("schemaVersion") == 1L &&
                    manifest["format"] == "org.hohu.momentai.archive" &&
                    manifest["archiveFormat"] == "zip-store"
            ) {
                NativeStrings.text(R.string.native_unsupported_archive_version_72)
            }
            val declared = mutableSetOf<String>()
            for (entry in manifest.rows("files")) {
                val path = entry.str("path")
                val actual =
                    artifacts[path]
                        ?: error(NativeStrings.text(R.string.native_an_archive_file_is_missing_73))
                require(
                    path != "manifest.json" && declared.add(path) &&
                        entry.num("byteCount") == actual.num("byteCount") &&
                        entry["sha256"] == actual["sha256"]
                ) {
                    NativeStrings.text(
                        R.string.native_archive_size_or_hash_verification_failed_74
                    )
                }
            }
            require(declared == artifacts.keys - "manifest.json") {
                NativeStrings.text(R.string.native_the_manifest_has_missing_or_extra_files_75)
            }
            val document = PortableText.read(File(payload, "session.json"))
            validate(document, manifest, artifacts, payload)
            pending = Pending(token, job, payload, document, StoredSessionZip.sha(source), bytes)
            val session = document.obj("session")
            return mapOf(
                "token" to token, "sessionId" to session["sessionId"],
                "title" to session["title"],
                "startedAtWall" to session["startedAtWall"],
                "stoppedAtWall" to session["stoppedAtWall"],
                "durationSamples" to session["lastCommittedSample"], "archiveBytes" to bytes,
                "timelineItemCount" to document.rows("timeline").size,
                "hasConfirmedGaps" to (session["state"] == "completed_with_gaps"),
                "conflict" to File(root, session.str("sessionId")).exists()
            )
        } catch (failure: Exception) {
            job.deleteRecursively()
            throw failure
        }
    }
    fun commit(token: String, asCopy: Boolean): JsonMap {
        val job = pending
        require(job != null && job.token == token) {
            NativeStrings.text(
                R.string.native_the_import_preview_has_expired_select_the_file_again_76
            )
        }
        val source = job.document.obj("session")
        val sourceId = source.str("sessionId")
        val id = if (asCopy) {
            "session_import_" + UUID.randomUUID().toString().replace(
                "-",
                ""
            )
        } else {
            sourceId
        }
        val destination = File(root, validId(id))
        require(!destination.exists()) {
            NativeStrings.text(
                R.string.native_a_recording_with_this_id_already_exists_import_a_copy_to_preserve_77
            )
        }
        try {
            space(job.bytes + 64 * 1024 * 1024)
            val staged = File(job.job, id)
            materialize(job, staged, destination, asCopy)
            val summary = SessionStore(staged).use {
                it.verifyChunks()
                it.summary()
            }
            beforeCommit()
            space(0)
            require(!destination.exists()) {
                NativeStrings.text(R.string.native_recording_id_conflict_import_a_copy_78)
            }
            // Only this serial transfer queue creates imported IDs; the recording ID
            // generator uses a disjoint timestamp prefix. Never use REPLACE.
            Os.rename(staged.path, destination.path)
            SessionStore.syncDirectory(root)
            cancel()
            return summary +
                mapOf("directory" to destination.path, "importedFromSessionId" to sourceId)
        } catch (failure: Exception) {
            cancel()
            throw failure
        }
    }

    private fun validate(doc: JsonMap, manifest: JsonMap, artifacts: Map<String, JsonMap>, payload: File) {
        require(
            doc.num("schemaVersion") == 1L && doc["format"] == "org.hohu.momentai.session-export"
        )
        require(artifacts.keys.containsAll(StoredSessionZip.requiredPaths))
        val session = doc.obj("session")
        val audio = doc.obj("audio")
        val timeline = doc.rows("timeline")
        val images = doc.rows("images")
        require(timeline.size <= 100000)
        val id = validId(session.str("sessionId"))
        val samples = session.num("lastCommittedSample")
        require(
            id == manifest["sessionId"] &&
                session["state"] in setOf("completed", "completed_with_gaps") &&
                session.str("title").codePointCount(0, session.str("title").length) <= 120 &&
                date(session.str("stoppedAtWall")) >= date(session.str("startedAtWall")) &&
                session.num(
                    "sampleRate"
                ) == 16000L && samples in 1..StoredSessionZip.MAXIMUM_BYTES / 2 &&
                session.num("chunkCount") > 0
        )
        session.num("recoveryCount")
        val wav = artifacts.getValue("audio/session.wav")
        require(
            audio["path"] == "audio/session.wav" && audio["codec"] == "pcm_s16le" &&
                audio.num("sampleRate") == 16000L && audio.num("channels") == 1L &&
                audio.num("bitsPerSample") == 16L &&
                audio.num("sampleCount") == samples && audio.num("durationMs") == samples / 16 &&
                wav.num("byteCount") == samples * 2 + 44 &&
                audio.num("byteCount") == wav.num("byteCount") &&
                audio["sha256"] == wav["sha256"]
        ) {
            NativeStrings.text(R.string.native_invalid_audio_samples_length_or_hash_79)
        }
        File(payload, "audio/session.wav").inputStream().use { input ->
            val header = ByteArray(44)
            java.io.DataInputStream(input).readFully(header)
            require(header.contentEquals(wavHeader(samples))) {
                NativeStrings.text(R.string.native_unsupported_wav_format_80)
            }
        }
        val identities = mutableSetOf<String>()
        val imageItems = mutableMapOf<String, JsonMap>()
        for (item in timeline) {
            val sample = item.num("sampleOffset")
            require(sample <= samples)
            when (item.str("kind")) {
                "transcript" -> {
                    require(
                        identities.add("t:" + item.str("segmentId")) && item["sessionId"] == id &&
                            item.num("startSample") == sample && item.num("endSample") > sample &&
                            item.num("endSample") <= samples &&
                            item.num("startMs") == sample / 16 &&
                            item.num("endMs") == item.num("endSample") / 16 &&
                            item["isFinal"] == true
                    )
                    item.str("text")
                    require(item["liveText"] == null || item["liveText"] == item["text"])
                }
                "captureEvent" -> {
                    require(
                        identities.add("c:" + item.str("eventId")) &&
                            identities.add("cs:" + item.num("sequence")) &&
                            item["type"] in setOf("image", "thought", "bookmark") &&
                            item["captureState"] in setOf("committed", "failed", "tombstoned") &&
                            item.num("atMs") == sample / 16
                    )
                    item.num("monotonicElapsedNs")
                    val info = item.obj("payload")
                    if (item["type"] == "image" &&
                        item["captureState"] == "committed"
                    ) {
                        imageItems[item.str("eventId")] = item
                    }
                    if (item["type"] == "thought" &&
                        item["captureState"] == "committed"
                    ) {
                        require(info.str("text") == item["text"])
                    }
                }
                "event" -> {
                    require(
                        identities.add("e:" + item.num("sequence")) &&
                            item.num("atMs") == sample / 16
                    )
                    item.obj("payload")
                    item.str("type")
                }
                else -> error(NativeStrings.text(R.string.native_unsupported_timeline_type_81))
            }
        }
        var lastEnd = 0L
        for (row in timeline.filter {
            it["kind"] == "transcript"
        }.sortedBy { it.num("startSample") }) {
            require(row.num("startSample") >= lastEnd) {
                NativeStrings.text(R.string.native_transcript_time_ranges_overlap_82)
            }
            lastEnd =
                row.num("endSample")
        }
        val imagePaths = mutableSetOf<String>()
        val imageIds = mutableSetOf<String>()
        for (image in images) {
            val event = image.str("eventId")
            val path = image.str("path")
            val artifact =
                artifacts[path] ?: error(NativeStrings.text(R.string.native_a_photo_is_missing_83))
            val item =
                imageItems[event]
                    ?: error(NativeStrings.text(R.string.native_a_photo_has_no_matching_event_84))
            val info = item.obj("payload")
            require(
                imageIds.add(event) && imagePaths.add(path) && path.startsWith("images/") &&
                    item["mediaPath"] == path && info["path"] == path &&
                    info["assetState"] == "committed" &&
                    image.num("sampleOffset") == item.num("sampleOffset") &&
                    image.num("byteCount") == artifact.num("byteCount") &&
                    info.num("byteCount") == artifact.num("byteCount") &&
                    image["sha256"] == artifact["sha256"] &&
                    info["sha256"] == artifact["sha256"]
            )
            val imageFile = File(payload, path)
            require(imageFile.length() <= PortableText.METADATA_LIMIT)
            val bounds = android.graphics.BitmapFactory.Options().apply {
                inJustDecodeBounds = true
            }
            android.graphics.BitmapFactory.decodeFile(imageFile.path, bounds)
            require(
                bounds.outMimeType == "image/jpeg" && bounds.outWidth in 1..20000 &&
                    bounds.outHeight in 1..20000 &&
                    bounds.outWidth.toLong() * bounds.outHeight <= 50_000_000
            ) {
                NativeStrings.text(R.string.native_the_photo_is_damaged_or_exceeds_50_mp_85)
            }
        }
        require(
            imageIds == imageItems.keys &&
                imagePaths == artifacts.keys.filter { it.startsWith("images/") }.toSet()
        )
        var lineIndex = 0
        File(payload, "timeline.jsonl").bufferedReader().useLines { lines ->
            lines.filter { it.isNotEmpty() }.forEach { line ->
                require(lineIndex < timeline.size)
                val row = SessionStore.jsonMap(org.json.JSONObject(line))
                require(
                    row.num("schemaVersion") == 1L && row["sessionId"] == id &&
                        row.num("index") == lineIndex.toLong() &&
                        jsonEqual(row.obj("item"), timeline[lineIndex])
                ) {
                    NativeStrings.text(R.string.native_json_and_jsonl_content_do_not_match_86)
                }
                lineIndex++
            }
        }
        require(lineIndex == timeline.size)
        PortableText.validateCanonical(doc, timeline, samples)
        val extensions = doc["extensions"]?.jsonMap() ?: emptyMap()
        require(
            extensions.keys.all {
                it == PortableText.SPEAKER_CAPABILITY
            }
        ) { NativeStrings.text(R.string.native_unsupported_archive_extension_87) }
        val capabilities = doc["capabilities"] ?: emptyList<String>()
        require(
            capabilities is List<*> &&
                capabilities.all {
                    it in
                        setOf(
                            "canonicalTextV1",
                            "timelineTextLayersV1",
                            PortableText.SPEAKER_CAPABILITY
                        )
                }
        )
        val speaker = extensions[PortableText.SPEAKER_CAPABILITY]?.jsonMap()
        require((speaker != null) == capabilities.contains(PortableText.SPEAKER_CAPABILITY))
        if (speaker != null) {
            require(
                speaker.num("schemaVersion") == 1L && speaker["sourceAudioSha256"] == wav["sha256"]
            )
            val document = speaker.obj("document")
            PortableText.validateSpeakers(document, id, samples)
            require(
                jsonEqual(
                    speaker.obj("textProjection"),
                    PortableText.speakerProjection(doc.obj("canonicalText"), document)
                )
            ) {
                NativeStrings.text(
                    R.string.native_speaker_text_does_not_match_the_source_text_or_edits_88
                )
            }
        }
    }

    private fun materialize(job: Pending, staged: File, destination: File, asCopy: Boolean) {
        val source = job.document.obj("session")
        val id = destination.name
        val title = source.str("title")
        val timeline = job.document.rows("timeline")
        SessionStore(
            staged,
            context.resources.openRawResource(R.raw.session_schema).bufferedReader().use {
                it.readText()
            },
            title
        ).use { store ->
            File(job.payload, "audio/session.wav").inputStream().use { input ->
                java.io.DataInputStream(input).readFully(ByteArray(44))
                val buffer = ByteArray(960000)
                while (true) {
                    var count = 0
                    while (count <
                        buffer.size
                    ) {
                        val n = input.read(buffer, count, buffer.size - count)
                        if (n <
                            0
                        ) {
                            break
                        }
                        count += n
                    }
                    if (count == 0) break
                    store.commitPcm(buffer.copyOf(count))
                }
            }
            val paths = mutableMapOf<String, String>()
            for (image in job.document.rows("images")) {
                val path = "assets/" + UUID.randomUUID() + ".jpg"
                File(job.payload, image.str("path")).inputStream().use {
                    copy(it, File(staged, path), PortableText.METADATA_LIMIT)
                }
                paths[image.str("eventId")] = path
            }
            store.transaction {
                store.db.execSQL(
                    "UPDATE session SET title=?,status=?,started_at_wall=?,stopped_at_wall=?,recovery_count=?",
                    arrayOf(
                        if (asCopy) {
                            title.take(
                                110
                            ) + NativeStrings.text(R.string.export_copy)
                        } else {
                            title
                        },
                        source["state"],
                        source["startedAtWall"],
                        source["stoppedAtWall"],
                        source["recoveryCount"]
                    )
                )
                for (row in timeline) {
                    val sample = row.num("sampleOffset")
                    val wall = row["wallTime"] as? String ?: source.str("startedAtWall")
                    when (row["kind"]) {
                        "transcript" -> store.db.execSQL(
                            "INSERT INTO transcript_segments VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)",
                            arrayOf(
                                row["segmentId"], id, sample, row["endSample"], row["startMs"], row["endMs"], row["text"],
                                row["rawText"] ?: row["text"], row["language"] ?: "",
                                row["source"] ?: "import", row["modelId"] ?: "unknown", 1, wall
                            )
                        )
                        "captureEvent" -> {
                            val info = row.obj("payload").toMutableMap().apply {
                                remove("assetPath")
                                remove("path")
                            }
                            val path = paths[row["eventId"]]
                            val blob = if (path == null) null else "import_" + row["eventId"]
                            if (path !=
                                null
                            ) {
                                store.db.execSQL(
                                    "INSERT INTO media_assets VALUES(?,?,?,?,?,?,?,?,?,?)",
                                    arrayOf(
                                        blob, id, "image", "committed", path, "image/jpeg",
                                        info["byteCount"], info["sha256"], wall, wall
                                    )
                                )
                            }
                            store.db.execSQL(
                                "INSERT INTO capture_events(seq,event_id,session_id,type,sample_offset,at_ms," +
                                    "monotonic_elapsed_ns,wall_time,clock_epoch_id,capture_state,asset_blob_id," +
                                    "payload_json,created_at_wall,updated_at_wall) VALUES(?,?,?,?,?,?,?,?,?,?,?,?," +
                                    "?,?)",
                                arrayOf(
                                    row["sequence"], row["eventId"], id, row["type"], sample, row["atMs"], row["monotonicElapsedNs"], wall,
                                    row["clockEpochId"] ?: "import", row["captureState"], blob,
                                    PortableText.encode(
                                        info
                                    ),
                                    wall, wall
                                )
                            )
                        }
                        else -> store.db.execSQL(
                            "INSERT INTO events(seq,type,sample_offset,wall_time,payload_json) VALUES(?,?,?,?,?)",
                            arrayOf(
                                row["sequence"],
                                row["type"],
                                sample,
                                wall,
                                PortableText.encode(row["payload"])
                            )
                        )
                    }
                }
            }
            val speaker = job.document["extensions"]?.jsonMap()?.get(
                PortableText.SPEAKER_CAPABILITY
            )?.jsonMap()?.obj("document")
            if (speaker != null) {
                writeJson(
                    File(staged, "speaker_diarization.json"),
                    speaker +
                        mapOf(
                            "sessionId" to id,
                            "sourceChunkFingerprint" to
                                PortableText.localFingerprint(store, destination)
                        )
                )
            }
            val canonical = job.document["canonicalText"]?.jsonMap()
            if (canonical != null && canonical["status"] in setOf("ready", "partial")) {
                writeJson(
                    File(staged, "full_text_refinement.json"),
                    mapOf(
                        "schemaVersion" to 4,
                        "status" to "ready", "sessionId" to id,
                        "modelId" to (canonical["modelId"] ?: "import"),
                        "fullText" to canonical["fullText"],
                        "sourceAudioSamples" to store.highWater(),
                        "sampleRate" to 16000, "createdAt" to (canonical["createdAt"] ?: ""),
                        "composerVersion" to 4,
                        "sourceTimelineFingerprint" to canonical["sourceTimelineFingerprint"],
                        "segments" to emptyList<Any>(),
                        "canonicalTokens" to emptyList<Any>(), "imported" to true,
                        "timelineProjection" to timeline.filter { it["kind"] == "transcript" }.map {
                            mapOf(
                                "segmentId" to it["segmentId"],
                                "startSample" to it["startSample"],
                                "endSample" to it["endSample"],
                                "refinedText" to it["displayText"],
                                "fallback" to (it["textLayer"] != "refined")
                            )
                        }
                    )
                )
            }
            writeJson(
                File(staged, "import_provenance.json"),
                mapOf(
                    "schemaVersion" to 1,
                    "sourceSessionId" to source["sessionId"],
                    "sourceArchiveSha256" to job.hash,
                    "importedAt" to SessionStore.now(),
                    "sourceChunkCount" to source["chunkCount"],
                    "materializedChunkCount" to store.chunks().size,
                    "mode" to "portable-export-v1"
                )
            )
            store.verifyChunks()
            store.db.rawQuery("PRAGMA integrity_check", null).use {
                require(it.moveToFirst() && it.getString(0) == "ok")
            }
            store.db.rawQuery("PRAGMA foreign_key_check", null).use { require(!it.moveToFirst()) }
        }
        SessionStore.syncDirectory(File(staged, "audio"))
        SessionStore.syncDirectory(File(staged, "assets"))
        SessionStore.syncDirectory(staged)
    }
    private fun writeAudio(store: SessionStore, destination: File) {
        store.verifyChunks()
        FileOutputStream(destination).use { out ->
            out.write(wavHeader(store.highWater()))
            for (chunk in store.chunks()) {
                File(chunk.str("path")).inputStream().use {
                    it.copyTo(
                        out,
                        256 * 1024
                    )
                }
            }
            out.fd.sync()
        }
    }
    private fun shareText(
        session: JsonMap,
        timeline: List<JsonMap>,
        canonical: JsonMap,
        speaker: JsonMap?,
        markdown: Boolean,
        readingText: String? = null
    ): String {
        val layer = if (canonical["defaultTextLayer"] ==
            "refined"
        ) {
            NativeStrings.text(R.string.export_refined)
        } else {
            NativeStrings.text(R.string.export_live)
        }
        val title = session["title"].toString()
        val lines =
            mutableListOf(
                if (markdown) "# " + escape(title) else title,
                "",
                NativeStrings.text(R.string.export_source, layer)
            )
        if (session["state"] ==
            "completed_with_gaps"
        ) {
            lines.add(NativeStrings.text(R.string.export_gaps))
        }
        lines.add("")
        lines.add(
            readingText ?: speaker?.let(PortableText::rendered) ?: canonical["fullText"].toString()
        )
        val thoughts = timeline.filter {
            it["type"] == "thought" &&
                it["captureState"] == "committed"
        }
        if (thoughts.isNotEmpty()) {
            lines.add("")
            lines.add(
                if (markdown) {
                    NativeStrings.text(
                        R.string.export_thoughts_heading
                    )
                } else {
                    NativeStrings.text(R.string.export_thought_event)
                }
            )
            for (thought in thoughts) {
                lines.add("")
                lines.add("[" + time(thought.num("sampleOffset")) + "] " + thought["text"])
            }
        }
        return lines.joinToString("\n", postfix = "\n")
    }
    private fun archiveMarkdown(session: JsonMap, timeline: List<JsonMap>, canonical: JsonMap, speaker: JsonMap?): String {
        val lines =
            mutableListOf(
                shareText(session, timeline, canonical, speaker, true),
                NativeStrings.text(R.string.export_audio_link),
                "",
                NativeStrings.text(R.string.export_timeline),
                ""
            )
        val byId = speaker?.rows("segments")?.associateBy { it.str("segmentId") } ?: emptyMap()
        for (row in timeline) {
            val stamp = time(row.num("sampleOffset"))
            lines.add("<!-- sample_offset: " + row.num("sampleOffset") + " -->")
            when {
                row["kind"] == "transcript" -> lines.add(
                    "- [$stamp] " + (
                        byId[row["segmentId"]]?.get("label")?.let {
                            "[$it] "
                        } ?: ""
                        ) +
                        escape((row["displayText"] ?: row["text"]).toString())
                )
                row["type"] == "image" && row["captureState"] == "committed" -> lines.add(
                    NativeStrings.text(R.string.export_image_prefix, stamp) + row["mediaPath"] + ")"
                )
                row["type"] == "thought" -> lines.add(
                    NativeStrings.text(R.string.export_thought_prefix, stamp) +
                        escape(row["text"].toString())
                )
                row["type"] == "bookmark" -> lines.add(
                    NativeStrings.text(R.string.export_bookmark, stamp)
                )
                else -> lines.add("- [$stamp] " + escape(row["type"].toString()))
            }
        }
        return lines.joinToString("\n", postfix = "\n")
    }
    companion object {
        fun writeText(file: File, text: String) {
            val bytes = text.toByteArray(Charsets.UTF_8)
            require(bytes.size <= PortableText.METADATA_LIMIT) {
                NativeStrings.text(R.string.native_text_metadata_exceeds_20_mib_101)
            }
            FileOutputStream(file).use {
                it.write(bytes)
                it.fd.sync()
            }
        }
        fun writeJson(file: File, value: Any?) = writeText(file, PortableText.encode(value))
        fun copy(input: InputStream, destination: File, limit: Long, progress: (Long) -> Unit = {}): Long {
            var total = 0L
            FileOutputStream(destination).use { out ->
                val buffer = ByteArray(256 * 1024)
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    total += count
                    require(total <= limit) {
                        NativeStrings.text(R.string.native_the_file_exceeds_the_supported_size_102)
                    }
                    progress(total)
                    out.write(buffer, 0, count)
                }
                out.fd.sync()
            }
            return total
        }
        fun jsonEqual(a: Any?, b: Any?): Boolean = when {
            a is Number && b is Number -> a.toDouble() == b.toDouble()
            a is Map<*, *> && b is Map<*, *> ->
                a.keys == b.keys &&
                    a.all { jsonEqual(it.value, b[it.key]) }
            a is List<*> && b is List<*> ->
                a.size == b.size &&
                    a.zip(b).all { jsonEqual(it.first, it.second) }
            else -> a == b
        }
        private fun date(value: String): Long {
            val pattern = if (value.contains(
                    '.'
                )
            ) {
                "yyyy-MM-dd'T'HH:mm:ss.SSSXXX"
            } else {
                "yyyy-MM-dd'T'HH:mm:ssXXX"
            }
            val position = ParsePosition(0)
            val parsed = SimpleDateFormat(pattern, Locale.US).apply {
                isLenient = false
            }.parse(value, position)
            require(parsed != null && position.index == value.length) {
                NativeStrings.text(R.string.native_invalid_recording_timestamp_103)
            }
            return parsed.time
        }
        private fun time(samples: Long): String {
            val seconds = samples / 16000
            return String.format(
                Locale.US,
                "%02d:%02d:%02d",
                seconds / 3600,
                seconds / 60 % 60,
                seconds % 60
            )
        }
        private fun escape(text: String) = text.replace(
            "\\",
            "\\\\"
        ).replace("[", "\\[").replace("]", "\\]").replace("*", "\\*").replace("_", "\\_")
    }
}
