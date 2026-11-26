package org.hohu.momentai

import java.io.File
import org.json.JSONObject

internal typealias JsonMap = Map<String, Any?>

/** The portable v1 text contract, shared with the Swift/Dart golden fixtures. */
internal object PortableText {
    const val SPEAKER_CAPABILITY = "speakerDiarizationV1"
    const val NOTICE = "说话人按整段音频估计，不是逐字对齐；多人、重叠或归属不确定的段落不能确定每句话由谁说。"
    const val METADATA_LIMIT = 20L * 1024 * 1024
    fun read(file: File): JsonMap {
        require(file.length() <= METADATA_LIMIT) { "元数据文件过大。" }
        return SessionStore.jsonMap(JSONObject(file.readText(Charsets.UTF_8)))
    }

    // Explicit JSON ordering for fingerprints; do not depend on JSONObject key order.
    fun encode(value: Any?): String = when (value) {
        null -> "null"
        is String -> JSONObject.quote(value).replace("\\/", "/")
        is Map<*, *> -> value.entries.joinToString(",", "{", "}") {
            encode(it.key.toString()) + ":" +
                encode(it.value)
        }
        is Iterable<*> -> value.joinToString(",", "[", "]") { encode(it) }
        is Boolean, is Number -> value.toString()
        else -> error("无效 JSON 值。")
    }
    fun hash(text: String) = "sha256:" + SessionStore.sha256(text.toByteArray(Charsets.UTF_8))
    fun fingerprint(timeline: List<JsonMap>): String = hash(
        encode(
            timeline.filter {
                it["kind"] ==
                    "transcript"
            }
                .sortedWith(
                    compareBy<JsonMap> {
                        it.num("startSample")
                    }.thenBy { it.num("endSample") }.thenBy { it.str("segmentId") }
                )
                .map {
                    linkedMapOf(
                        "segmentId" to it["segmentId"],
                        "startSample" to it.num("startSample"),
                        "endSample" to it.num("endSample"),
                        "text" to it["text"]
                    )
                }
        )
    )

    fun project(directory: File, id: String, samples: Long, timeline: List<JsonMap>): Pair<List<JsonMap>, JsonMap> {
        val fp = fingerprint(timeline)
        val sources = timeline.filter {
            it["kind"] == "transcript"
        }.associateBy { it.str("segmentId") }
        val file = File(directory, "full_text_refinement.json")
        val refined = mutableMapOf<String, String>()
        var status = "live"
        var payload: JsonMap = emptyMap()
        if (file.exists()) {
            val parsed = runCatching { read(file) }
            if (parsed.isFailure) {
                status = "failed"
            } else {
                payload = parsed.getOrThrow()
                if (payload["status"] == "failed") status = "failed"
                if (payload["status"] == "ready") {
                    val valid = runCatching {
                        require(
                            payload.num("schemaVersion") == 4L &&
                                payload.num("composerVersion") == 4L &&
                                payload["sessionId"] == id &&
                                payload.num("sourceAudioSamples") == samples &&
                                payload.num("sampleRate") == 16000L &&
                                payload["sourceTimelineFingerprint"] == fp
                        )
                        val seen = mutableSetOf<String>()
                        for (row in payload.rows("timelineProjection")) {
                            val key = row.str("segmentId")
                            val source = sources[key] ?: error("未知精修段。")
                            require(
                                seen.add(
                                    key
                                ) && row.num("startSample") == source.num("startSample") &&
                                    row.num("endSample") == source.num("endSample")
                            )
                            val text = row["refinedText"] as? String ?: ""
                            if (row["fallback"] != true && text.isNotBlank()) refined[key] = text
                        }
                    }.isSuccess
                    status =
                        if (valid) {
                            if (refined.size ==
                                sources.size
                            ) {
                                "ready"
                            } else {
                                "partial"
                            }
                        } else {
                            "stale"
                        }
                    if (!valid) refined.clear()
                }
            }
        }
        val isRefined = status in setOf("ready", "partial")
        val enriched = timeline.map { row ->
            if (row["kind"] != "transcript") {
                row
            } else {
                val text = refined[row["segmentId"]]
                row + mapOf(
                    "liveText" to row["text"],
                    "refinedText" to text,
                    "displayText" to (text ?: row["text"]),
                    "textLayer" to
                        if (text != null) {
                            "refined"
                        } else if (isRefined) {
                            "fallback"
                        } else {
                            "live"
                        }
                )
            }
        }
        val segments = enriched.filter { it["kind"] == "transcript" }.map { row ->
            mapOf(
                "segmentId" to row["segmentId"], "startSample" to row["startSample"],
                "endSample" to row["endSample"],
                "startMs" to row["startMs"], "endMs" to row["endMs"], "text" to row["displayText"],
                "liveText" to row["text"], "rawText" to (row["rawText"] ?: row["text"]),
                "refinedText" to row["refinedText"], "textLayer" to row["textLayer"]
            )
        }
        val full = if (isRefined) (payload["fullText"] as? String)?.trim().orEmpty() else ""
        return enriched to
            mapOf(
                "schemaVersion" to 1, "format" to "org.hohu.momentai.canonical-text",
                "status" to status, "defaultTextLayer" to if (isRefined) "refined" else "live",
                "modelId" to if (isRefined) payload["modelId"] ?: "" else "",
                "composerVersion" to if (isRefined) 4 else 0,
                "sourceTimelineFingerprint" to fp, "sourceAudioSamples" to samples,
                "sampleRate" to 16000,
                "createdAt" to if (isRefined) payload["createdAt"] ?: "" else "",
                "fullText" to
                    full.ifEmpty { segments.joinToString("\n\n") { it["text"].toString() } },
                "segmentCount" to segments.size, "refinedSegmentCount" to refined.size,
                "fallbackSegmentCount" to if (isRefined) sources.size - refined.size else 0,
                "segments" to segments
            )
    }

    fun validateCanonical(doc: JsonMap, timeline: List<JsonMap>, samples: Long) {
        val canonical = doc["canonicalText"]?.jsonMap()
        if (canonical == null) {
            require(timeline.none { it["textLayer"] == "refined" }) { "精修来源声明缺失。" }
            return
        }
        val transcripts = timeline.filter { it["kind"] == "transcript" }
        val segments = canonical.rows("segments")
        require(
            canonical.num("schemaVersion") == 1L &&
                canonical["format"] == "org.hohu.momentai.canonical-text" &&
                canonical.num(
                    "sourceAudioSamples"
                ) == samples && canonical.num("sampleRate") == 16000L &&
                canonical["sourceTimelineFingerprint"] == fingerprint(timeline) &&
                segments.size == transcripts.size &&
                canonical.num("segmentCount") == transcripts.size.toLong() &&
                canonical["fullText"] is String
        ) { "文字来源或段落映射无效。" }
        val status = canonical.str("status")
        require(status in setOf("ready", "partial", "live", "stale", "failed"))
        val refined = status in setOf("ready", "partial")
        require(canonical["defaultTextLayer"] == if (refined) "refined" else "live")
        require(!refined || canonical.num("composerVersion") == 4L)
        var refinedCount = 0L
        var fallbackCount = 0L
        for ((segment, item) in segments.zip(transcripts)) {
            val layer = item["textLayer"] ?: "live"
            require(
                segment["segmentId"] == item["segmentId"] &&
                    segment.num("startSample") == item.num("startSample") &&
                    segment.num("endSample") == item.num("endSample") &&
                    segment["liveText"] == item["text"] && segment["text"] == item["displayText"] &&
                    segment["textLayer"] == layer
            ) { "精修段与实时原文不对应。" }
            if (layer == "refined" && refined) {
                require(
                    item.str("refinedText") == item["displayText"] &&
                        item["refinedText"] == segment["refinedText"]
                )
                refinedCount++
            } else {
                require(layer == if (refined) "fallback" else "live")
                require(item["displayText"] == item["text"])
                if (refined) fallbackCount++
            }
        }
        require(
            canonical.num("refinedSegmentCount") == refinedCount &&
                canonical.num("fallbackSegmentCount") == fallbackCount &&
                (status != "ready" || fallbackCount == 0L) &&
                (status != "partial" || fallbackCount > 0)
        ) {
            "精修计数或状态不一致。"
        }
    }

    private fun labels(doc: JsonMap): JsonMap = doc["labelEdits"]?.jsonMap()?.get("current")?.jsonMap() ?: emptyMap()
    private fun strings(map: JsonMap, key: String): Map<String, String> = map[key]?.jsonMap()?.mapValues {
        require(it.value is String)
        it.value as String
    } ?: emptyMap()
    private fun defaultName(id: String) = "说话人 " + id.removePrefix("speaker_")
    fun validateSpeakers(doc: JsonMap, id: String, samples: Long) {
        require(
            doc.num("schemaVersion") == 1L && doc["status"] == "ready" && doc["sessionId"] == id &&
                doc.str("modelId").toByteArray().size <= 1024 && doc["createdAt"] is String &&
                doc.num("sampleRate") == 16000L && doc.num("sourceAudioSamples") == samples &&
                samples > 0 &&
                Regex("sha256:[0-9a-f]{64}").matches(doc.str("sourceChunkFingerprint"))
        ) { "说话人来源无效。" }
        require((doc["algorithmVersion"]?.let { doc.num("algorithmVersion") } ?: 1L) in 1..5)
        listOf("processingMs", "peakRssBytes", "windowCount").forEach { doc.num(it) }
        val rtf = doc["realTimeFactor"] as? Number ?: error("无效耗时。")
        require(rtf.toDouble().isFinite() && rtf.toDouble() >= 0)
        if (doc["requestedSpeakerCount"] != null) require(doc.num("requestedSpeakerCount") in 1..12)
        val segments = doc.rows("segments")
        require(segments.size <= 100000)
        for (s in segments) {
            require(
                s.str("speakerId").length <= 80 &&
                    Regex("speaker_[1-9][0-9]*").matches(s.str("speakerId")) &&
                    s.num("startSample") < s.num("endSample") && s.num("endSample") <= samples
            )
        }
        val states = mutableListOf<JsonMap>()
        doc["labelEdits"]?.jsonMap()?.let { edits ->
            val history = edits.rows("history")
            require(
                edits.num("schemaVersion") == 1L && history.size <= 20 &&
                    edits.num("revision") >= history.size
            )
            states.add(edits.obj("current"))
            states.addAll(history)
        }
        val rawIds = segments.map { it.str("speakerId") }.toSet()
        for (state in states) {
            require(state["names"] is Map<*, *> && state["mergedInto"] is Map<*, *>)
            val names = strings(state, "names")
            val merged = strings(state, "mergedInto")
            for ((a, b) in merged) require(a in rawIds && b in rawIds && a != b && b !in merged)
            val active = rawIds.map { merged[it] ?: it }.toSet()
            for ((key, name) in names) {
                require(
                    key in active && name.isNotEmpty() && name == name.trim() &&
                        name.codePointCount(0, name.length) <= 40 &&
                        name.none { it.code < 32 || it.code in setOf(127, 0x2028, 0x2029) }
                )
            }
            require(active.map { names[it] ?: defaultName(it) }.toSet().size == active.size)
            val ends = mutableMapOf<String, MutableMap<String, Long>>()
            for (s in segments.sortedBy { it.num("startSample") }) {
                val raw = s.str("speakerId")
                val effective = merged[raw] ?: raw
                val group = ends.getOrPut(effective) { mutableMapOf() }
                require(
                    group.none {
                        it.key != raw && it.value > s.num("startSample")
                    }
                ) { "不能合并同时发言的说话人。" }
                group[raw] = maxOf(group[raw] ?: 0, s.num("endSample"))
            }
        }
        if (doc["speakerCount"] != null) {
            val merged = strings(labels(doc), "mergedInto")
            require(
                doc.num("speakerCount") == rawIds.map {
                    merged[it] ?: it
                }.toSet().size.toLong()
            )
        }
    }

    fun speakerProjection(canonical: JsonMap, doc: JsonMap): JsonMap {
        val label = labels(doc)
        val names = strings(label, "names")
        val merged = strings(label, "mergedInto")
        val raw = doc.rows("segments").sortedBy { it.num("startSample") }
        val texts = canonical.rows("segments")
        var next = 0
        val activeRaw = mutableListOf<JsonMap>()
        val byId = texts.sortedBy { it.num("startSample") }.associate { text ->
            val start = text.num("startSample")
            val end = text.num("endSample")
            activeRaw.removeAll { it.num("endSample") <= start }
            while (next < raw.size && raw[next].num("startSample") < end) {
                if (raw[next].num("endSample") > start) activeRaw.add(raw[next])
                next++
            }
            val clips = activeRaw.mapNotNull { s ->
                val a = maxOf(start, s.num("startSample"))
                val b = minOf(end, s.num("endSample"))
                if (b <= a) null else Triple(merged[s.str("speakerId")] ?: s.str("speakerId"), a, b)
            }.sortedBy { it.second }
            val durations = mutableMapOf<String, Long>()
            val active = mutableMapOf<String, Long>()
            var covered = 0L
            var cursor = start
            var overlap = false
            for ((id, a, b) in clips) {
                durations[id] = (durations[id] ?: 0) + b - a
                if (active.any { it.key != id && it.value > a }) overlap = true
                active[id] = maxOf(active[id] ?: 0, b)
                val left = maxOf(cursor, a)
                val right = maxOf(left, b)
                covered += right - left
                cursor = right
            }
            val ids = durations.keys.sortedWith(
                compareByDescending<String> {
                    durations[it]
                }.thenBy { it }
            )
            val displayNames = ids.map { names[it] ?: defaultName(it) }
            val state = when {
                ids.isEmpty() -> "unattributed"
                overlap -> "overlap"
                ids.size > 1 -> "multiple"
                covered * 5 >= (end - start) * 4 -> "single"
                else -> "uncertain"
            }
            val joined = displayNames.joinToString("、")
            val description = when (state) {
                "single" -> joined
                "multiple" -> "多人轮流：$joined"
                "overlap" -> "多人 · 有重叠：$joined"
                "uncertain" -> "归属不确定：$joined"
                else -> "说话人未确定"
            }
            text.str("segmentId") to
                mapOf(
                    "segmentId" to text["segmentId"], "startSample" to start, "endSample" to end,
                    "text" to text["text"], "textLayer" to text["textLayer"], "speakerIds" to ids,
                    "displayNames" to displayNames,
                    "attribution" to state, "coveredSamples" to covered, "label" to description
                )
        }
        val version =
            hash(
                encode(
                    listOf(
                        1,
                        doc["modelId"],
                        doc["algorithmVersion"] ?: 1,
                        doc["createdAt"],
                        doc["labelEdits"]?.jsonMap()?.get("revision") ?: 0,
                        doc.rows("segments").map {
                            listOf(it["speakerId"], it["startSample"], it["endSample"])
                        },
                        names.keys.sorted().map {
                            listOf(it, names[it])
                        },
                        merged.keys.sorted().map { listOf(it, merged[it]) }
                    )
                )
            )
        val textVersion =
            hash(
                encode(
                    listOf(
                        1,
                        canonical["status"],
                        canonical["defaultTextLayer"],
                        canonical["modelId"],
                        canonical["sourceTimelineFingerprint"],
                        canonical["fullText"],
                        texts.map {
                            listOf(
                                it["segmentId"],
                                it["startSample"],
                                it["endSample"],
                                it["text"],
                                it["textLayer"]
                            )
                        }
                    )
                )
            )
        return mapOf(
            "schemaVersion" to 1,
            "format" to "org.hohu.momentai.speaker-text",
            "speakerVersion" to version,
            "textVersion" to textVersion,
            "sourceTimelineFingerprint" to canonical["sourceTimelineFingerprint"],
            "notice" to NOTICE,
            "fullText" to canonical["fullText"],
            "segments" to texts.map { byId.getValue(it.str("segmentId")) }
        )
    }

    fun localFingerprint(store: SessionStore, destination: File = store.directory): String {
        val boundaries = store.timeline().filter {
            it["type"] in
                setOf(
                    "audio_interruption_began",
                    "audio_interruption_ended",
                    "user_pause_began",
                    "user_pause_ended"
                )
        }.map { it.num("sampleOffset") }.filter {
            it > 0 &&
                it < store.highWater()
        }.distinct().sorted()
        val chunks = store.chunks().map { c ->
            linkedMapOf(
                "index" to c["index"],
                "path" to File(destination, "audio/" + File(c.str("path")).name).path,
                "startSample" to c["startSample"],
                "endSample" to c["endSample"],
                "fileStartSample" to c["startSample"],
                "sampleRate" to 16000
            )
        }
        return hash(encode(linkedMapOf("chunks" to chunks, "boundaries" to boundaries)))
    }
    fun loadSpeakers(store: SessionStore): JsonMap? {
        val file = File(store.directory, "speaker_diarization.json")
        if (!file.exists()) {
            require(!File(file.path + ".backup").exists()) { NativeStrings.text(R.string.speaker_changes_pending) }
            return null
        }
        val doc = read(file)
        if (doc["status"] == "failed") return null
        validateSpeakers(doc, store.id, store.highWater())
        require(doc["sourceChunkFingerprint"] == localFingerprint(store)) { NativeStrings.text(R.string.speaker_result_stale) }
        return doc
    }
    fun rendered(projection: JsonMap): String {
        val rows = projection.rows("segments")
        val paragraphs = rows.joinToString("\n\n") { "[" + it["label"] + "] " + it["text"] }
        val full = projection["fullText"].toString()
        val prefix = if (rows.joinToString("\n\n") { it["text"].toString() } ==
            full
        ) {
            ""
        } else {
            "连续全文\n\n$full\n\n按段说话人\n\n"
        }
        return "$NOTICE\n\n$prefix$paragraphs"
    }
}

internal fun Any?.jsonMap(): JsonMap {
    require(this is Map<*, *> && keys.all { it is String }) { "无效的对象。" }
    @Suppress("UNCHECKED_CAST")
    return this as JsonMap
}
internal fun JsonMap.obj(key: String) = get(key).jsonMap()
internal fun JsonMap.rows(key: String): List<JsonMap> {
    val list = get(key)
    require(list is List<*>) { "无效的列表：$key" }
    return list.map { it.jsonMap() }
}
internal fun JsonMap.num(key: String): Long {
    val value = get(key)
    require(
        value is Number && value.toDouble().isFinite() && value.toDouble() >= 0 &&
            value.toDouble() <= 9007199254740991.0 && value.toDouble() == value.toLong().toDouble()
    ) {
        "无效的整数：$key"
    }
    return value.toLong()
}
internal fun JsonMap.str(key: String): String {
    val value = get(key)
    require(value is String && value.isNotBlank() && value.toByteArray().size <= 1048576) {
        "无效的文字：$key"
    }
    return value
}
