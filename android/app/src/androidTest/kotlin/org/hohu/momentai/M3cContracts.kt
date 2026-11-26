package org.hohu.momentai

import android.app.Instrumentation
import android.graphics.Bitmap
import androidx.core.content.FileProvider
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.UUID

/** Public cross-platform fixtures and throwaway media only; never reads user Sessions. */
internal class M3cContracts(private val instrumentation: Instrumentation, private val checks: MutableList<String>) {
    private val context get() = instrumentation.targetContext
    private fun fixture(name: String) = instrumentation.context.assets.open(name)
    fun run() {
        val temp = File(context.cacheDir, "m3c-contract-" + UUID.randomUUID()).apply { mkdirs() }
        val root = File(temp, "Sessions").apply { mkdirs() }
        val exports = File(temp, "Exports")
        val transfer = SessionArchive(context, root, exports, { 10_000_000_000 })
        try {
            val golden = fixture("speaker-text-v1.json").use {
                SessionStore.jsonMap(org.json.JSONObject(it.bufferedReader().readText()))
            }
            val speaker = golden.obj("document")
            val canonical = golden.obj("canonical")
            PortableText.validateSpeakers(speaker, "session_public_m2", 64000)
            check(
                SessionArchive.jsonEqual(
                    PortableText.speakerProjection(canonical, speaker),
                    golden.obj("expected")
                )
            )
            checks += "speaker_projection_matches_swift_dart_public_golden"
            for (file in listOf(
                "invalid-compression.momentai",
                "invalid-extra-entry.momentai",
                "invalid-speaker-extension.momentai"
            )) {
                check(runCatching { fixture(file).use { transfer.prepare(it, file) } }.isFailure)
            }
            check(SessionStore.list(root).isEmpty())
            checks += "invalid_zip_and_speaker_fixtures_never_create_session"
            val legacy = fixture("legacy-v1.momentai").use {
                transfer.prepare(it, "legacy.momentai")
            }
            check(legacy["conflict"] == false)
            transfer.cancel()
            check(
                runCatching { transfer.commit(legacy.str("token"), false) }.isFailure &&
                    SessionStore.list(root).isEmpty()
            )
            checks += "cancel_import_invalidates_token_without_creating_record"
            val preview = fixture("speaker-v1.momentai").use {
                transfer.prepare(it, "speaker.momentai")
            }
            val imported = transfer.commit(preview.str("token"), false)
            check(imported["exportAvailable"] == true)
            val directory = File(imported.str("directory"))
            SessionStore(directory).use { store ->
                store.verifyChunks()
                val loaded = PortableText.loadSpeakers(store)!!
                check(loaded["labelEdits"] == speaker["labelEdits"])
                check(loaded["sourceChunkFingerprint"] == PortableText.localFingerprint(store))
            }
            checks += "portable_import_preserves_audio_and_rebinds_speaker_fingerprint"
            val stateDir = File(root, "session_export_availability")
            val schema = context.resources.openRawResource(
                R.raw.session_schema
            ).bufferedReader().use {
                it.readText()
            }
            SessionStore(stateDir, schema, "公开导出状态测试").use { store ->
                store.setStatus("recording")
                store.commitPcm(ByteArray(32000))
                check(store.summary()["exportAvailable"] == false)
                store.setStatus("completed")
                check(store.summary()["exportAvailable"] == true)
            }
            checks += "completed_audio_enables_product_share_entry_but_recording_does_not"
            val before = StoredSessionZip.sha(File(directory, "session.sqlite"))
            val conflict = fixture("speaker-v1.momentai").use {
                transfer.prepare(it, "speaker.momentai")
            }
            check(conflict["conflict"] == true)
            check(runCatching { transfer.commit(conflict.str("token"), false) }.isFailure)
            check(StoredSessionZip.sha(File(directory, "session.sqlite")) == before)
            val copy = transfer.commit(conflict.str("token"), true)
            check(
                copy["sessionId"] != imported["sessionId"] && copy.str("title").endsWith("（导入副本）")
            )
            SessionStore(File(copy.str("directory"))).use {
                check(PortableText.loadSpeakers(it)!!["sessionId"] == copy["sessionId"])
            }
            checks += "duplicate_id_preserves_original_and_copy_gets_new_identity"
            val exported = transfer.export(directory.path)
            File(
                exported.str("archivePath")
            ).copyTo(File(context.cacheDir, "m3c-public-speaker-export.momentai"), overwrite = true)
            val bundle = File(exported.str("directory"))
            val doc = PortableText.read(File(bundle, "session.json"))
            check(
                SessionArchive.jsonEqual(
                    doc.obj("extensions").obj(PortableText.SPEAKER_CAPABILITY).obj("textProjection"),
                    golden.obj("expected")
                )
            )
            val second =
                SessionArchive(
                    context,
                    File(temp, "Second").apply {
                        mkdirs()
                    },
                    File(temp, "SecondExports"),
                    { 10_000_000_000 }
                )
            val reread = File(exported.str("archivePath")).inputStream().use {
                second.prepare(it, "roundtrip.momentai")
            }
            val again = second.commit(reread.str("token"), false)
            SessionStore(File(again.str("directory"))).use {
                check(PortableText.loadSpeakers(it)!!["labelEdits"] == speaker["labelEdits"])
            }
            checks += "speaker_archive_roundtrip_preserves_projection_names_merges_and_undo"
            val speakerFile = File(directory, "speaker_diarization.json")
            val previousSpeaker = PortableText.read(speakerFile)
            try {
                SessionArchive.writeJson(speakerFile, previousSpeaker + ("algorithmVersion" to 5))
                val v5 = transfer.export(directory.path)
                val previewV5 = File(v5.str("archivePath")).inputStream().use {
                    second.prepare(it, "v5.momentai")
                }
                val importedV5 = second.commit(previewV5.str("token"), true)
                SessionStore(File(importedV5.str("directory"))).use {
                    val result = PortableText.loadSpeakers(it)!!
                    check(
                        result.num("algorithmVersion") == 5L &&
                            result["labelEdits"] == previousSpeaker["labelEdits"]
                    )
                }
                check(
                    runCatching {
                        PortableText.validateSpeakers(
                            previousSpeaker + ("algorithmVersion" to 6),
                            "session_public_m2",
                            64000
                        )
                    }.isFailure
                )
            } finally {
                SessionArchive.writeJson(speakerFile, previousSpeaker)
            }
            checks += "algorithm_v5_archive_roundtrip_preserves_labels_and_rejects_future_version"
            for (format in listOf("text", "markdown")) {
                val share = transfer.share(imported.str("sessionId"), format)
                val text = share.readText()
                check(
                    text.contains("林[主持]") && text.contains(PortableText.NOTICE) &&
                        text.contains("两人同时。")
                )
            }
            val wav = transfer.share(imported.str("sessionId"), "audio")
            check(
                wav.length() == 128044L &&
                    wav.inputStream().use {
                        it.readBytes().copyOfRange(0, 44)
                    }.contentEquals(wavHeader(64000))
            )
            checks += "txt_markdown_and_wav_shares_use_same_canonical_content"
            val readingText = "第一段。\n\n第二段。"
            val readingFile = transfer.share(imported.str("sessionId"), "text", readingText)
            val readingCopy = transfer.readText(imported.str("sessionId"), readingText)
            check(readingFile.readText() == readingCopy && readingCopy.contains(readingText))
            check(readingCopy.contains("文字来源：") && !readingCopy.contains(PortableText.NOTICE))
            check(PortableText.read(speakerFile) == previousSpeaker)
            checks += "reading_paragraphs_match_txt_and_copy_without_changing_speakers"
            val low = SessionArchive(context, root, exports, { 1 })
            check(
                runCatching {
                    fixture("speaker-v1.momentai").use { low.prepare(it, "speaker.momentai") }
                }.isFailure
            )
            check(runCatching { low.export(directory.path) }.isFailure)
            checks += "insufficient_space_rejects_transfer_before_publication"
            val failingRoot = File(temp, "Failing").apply { mkdirs() }
            val failing =
                SessionArchive(context, failingRoot, exports, {
                    10_000_000_000
                }, { error("injected commit failure") })
            val failurePreview = fixture("speaker-v1.momentai").use {
                failing.prepare(it, "failure.momentai")
            }
            check(runCatching { failing.commit(failurePreview.str("token"), false) }.isFailure)
            check(SessionStore.list(failingRoot).isEmpty())
            checks += "failed_materialization_never_publishes_partial_session"
            corruptionContracts(temp, transfer, exported)
            mediaContracts(root, transfer)
            iosReturnContracts(temp, golden)
            val shareRoot = File(context.cacheDir, "MomentAIExports").apply { mkdirs() }
            val shareFile = File(shareRoot, "public_contract_" + UUID.randomUUID() + ".txt").apply {
                writeText("公开分享契约")
            }
            try {
                val uri = FileProvider.getUriForFile(
                    context,
                    context.packageName + ".exports",
                    shareFile
                )
                check(
                    uri.scheme == "content" &&
                        context.contentResolver.openInputStream(uri)!!.use {
                            it.bufferedReader().readText()
                        } ==
                        "公开分享契约"
                )
                check(
                    runCatching {
                        FileProvider.getUriForFile(
                            context,
                            context.packageName + ".exports",
                            File(directory, "session.sqlite")
                        )
                    }.isFailure
                )
            } finally {
                shareFile.delete()
            }
            checks += "file_provider_reads_export_but_cannot_expose_session_database"
        } finally {
            transfer.cancel()
            temp.deleteRecursively()
        }
    }
    private fun iosReturnContracts(temp: File, golden: JsonMap) {
        for (kind in listOf("media", "speaker")) {
            val root = File(temp, "IOSReturn_$kind").apply { mkdirs() }
            val transfer =
                SessionArchive(context, root, File(temp, "IOSExports_$kind"), { 10_000_000_000 })
            val name = "ios-return-android-$kind-v1.momentai"
            val preview = fixture(name).use { transfer.prepare(it, name) }
            val imported = transfer.commit(preview.str("token"), false)
            SessionStore(File(imported.str("directory"))).use { store ->
                store.verifyChunks()
                if (kind == "media") {
                    check(store.status() == "completed_with_gaps")
                    check(
                        store.captureEvents().size == 3 &&
                            store.captureEvents().all { it.num("sampleOffset") == 32000L }
                    )
                    val image = store.captureEvents().single { it["type"] == "image" }
                    check(store.assetFile(image.obj("payload").str("path")).length() > 0)
                    check(
                        File(store.chunks().single().str("path")).readBytes().contentEquals(
                            ByteArray(64000) {
                                (
                                    it %
                                        97
                                    ).toByte()
                            }
                        )
                    )
                    val (_, canonical) = PortableText.project(
                        store.directory,
                        store.id,
                        32000,
                        store.timeline()
                    )
                    check(canonical["fullText"] == "精修连续全文。" && canonical["status"] == "ready")
                } else {
                    val speakers = PortableText.loadSpeakers(store)!!
                    check(speakers["labelEdits"] == golden.obj("document")["labelEdits"])
                    val exported = transfer.export(store.directory.path)
                    val doc = PortableText.read(File(exported.str("jsonPath")))
                    check(
                        SessionArchive.jsonEqual(
                            doc.obj(
                                "extensions"
                            ).obj(PortableText.SPEAKER_CAPABILITY).obj("textProjection"),
                            golden.obj("expected")
                        )
                    )
                }
            }
        }
        checks += "ios_reexport_returns_to_android_with_media_refinement_and_speaker_history"
    }
    private fun corruptionContracts(temp: File, transfer: SessionArchive, exported: JsonMap) {
        val original = File(exported.str("directory"))
        val names = original.walkTopDown().filter {
            it.isFile
        }.map { it.relativeTo(original).invariantSeparatorsPath }.toList()
        val mutations = listOf<(MutableMap<String, Any?>) -> Unit>(
            { doc ->
                doc["canonicalText"] =
                    doc.obj("canonicalText") + ("sourceTimelineFingerprint" to "sha256:bad")
            },
            { doc -> doc["capabilities"] = listOf("unknownV99") },
            { doc -> doc["session"] = doc.obj("session") + ("sessionId" to "../outside") },
            { doc -> doc["audio"] = doc.obj("audio") + ("sampleCount" to 1) },
            { doc ->
                doc["canonicalText"] = doc.obj("canonicalText") + ("refinedSegmentCount" to 99)
            }
        )
        for ((index, mutate) in mutations.withIndex()) {
            val payload = File(temp, "bad_$index").apply { mkdirs() }
            original.copyRecursively(payload, overwrite = true)
            val doc = PortableText.read(File(payload, "session.json")).toMutableMap()
            mutate(doc)
            SessionArchive.writeJson(File(payload, "session.json"), doc)
            val manifest = PortableText.read(File(payload, "manifest.json")) +
                (
                    "files" to
                        names.filter {
                            it != "manifest.json"
                        }.map { StoredSessionZip.artifact(payload, it) }
                    )
            SessionArchive.writeJson(File(payload, "manifest.json"), manifest)
            val archive = File(temp, "bad_$index.momentai")
            StoredSessionZip.write(payload, names, archive)
            check(
                runCatching {
                    archive.inputStream().use { transfer.prepare(it, archive.name) }
                }.isFailure
            )
        }
        val damaged = File(temp, "damaged.momentai")
        File(exported.str("archivePath")).copyTo(damaged)
        java.io.RandomAccessFile(damaged, "rw").use {
            it.seek(100)
            it.writeByte(it.readByte().toInt() xor 1)
        }
        check(
            runCatching {
                damaged.inputStream().use { transfer.prepare(it, damaged.name) }
            }.isFailure
        )
        checks += "semantic_tampering_unknown_capabilities_and_crc_damage_rejected"
        val noncanonical = File(temp, "noncanonical.momentai")
        val bytes = File(exported.str("archivePath")).readBytes()
        val central = bytes.u32(bytes.size - 6).toInt()
        // Match the historical repackaging error: clear UTF-8 in both headers.
        bytes[7] = 0
        bytes[central + 9] = 0
        noncanonical.writeBytes(bytes)
        check(
            runCatching {
                noncanonical.inputStream().use { transfer.prepare(it, noncanonical.name) }
            }.isFailure
        )
        checks += "noncanonical_zip_profile_rejected"
    }
    private fun mediaContracts(root: File, transfer: SessionArchive) {
        val directory = File(root, "session_public_media")
        val schema = context.resources.openRawResource(R.raw.session_schema).bufferedReader().use {
            it.readText()
        }
        val pcm = ByteArray(64000) { (it % 97).toByte() }
        val bitmap = Bitmap.createBitmap(8, 8, Bitmap.Config.ARGB_8888).apply {
            eraseColor(android.graphics.Color.GREEN)
        }
        val jpeg = ByteArrayOutputStream().also {
            bitmap.compress(Bitmap.CompressFormat.JPEG, 90, it)
        }.toByteArray()
        bitmap.recycle()
        SessionStore(directory, schema, "公开照片与精修测试").use { store ->
            store.setStatus("recording")
            store.commitPcm(pcm)
            val image = store.addCapture("image", "", 10, "public")
            store.commitImage(image.str("eventId"), jpeg)
            store.addCapture("thought", "公开随想", 11, "public")
            store.addCapture("bookmark", "", 12, "public")
            store.commitTranscript(
                mapOf(
                    "sessionId" to store.id,
                    "segmentId" to "public_1",
                    "startSample" to 0,
                    "endSample" to 32000,
                    "text" to "实时 / 引号\"与表情😀",
                    "isFinal" to true
                )
            )
            SessionArchive.writeJson(
                File(directory, "full_text_refinement.json"),
                mapOf(
                    "schemaVersion" to 4,
                    "composerVersion" to 4, "status" to "ready", "sessionId" to store.id,
                    "sourceAudioSamples" to 32000,
                    "sampleRate" to 16000,
                    "sourceTimelineFingerprint" to PortableText.fingerprint(store.timeline()),
                    "modelId" to "public-fixture", "fullText" to "精修连续全文。",
                    "createdAt" to SessionStore.now(),
                    "timelineProjection" to
                        listOf(
                            mapOf(
                                "segmentId" to "public_1",
                                "startSample" to 0,
                                "endSample" to 32000,
                                "refinedText" to "精修段落。",
                                "fallback" to false
                            )
                        )
                )
            )
            store.setStatus("completed_with_gaps", true)
        }
        val exported = transfer.export(directory.path)
        val doc = PortableText.read(File(exported.str("jsonPath")))
        check(doc.obj("canonicalText")["fullText"] == "精修连续全文。" && doc.rows("images").size == 1)
        val roundtrip = File(exported.str("archivePath")).inputStream().use {
            transfer.prepare(it, "media.momentai")
        }
        val imported = transfer.commit(roundtrip.str("token"), true)
        SessionStore(File(imported.str("directory"))).use { store ->
            store.verifyChunks()
            check(store.status() == "completed_with_gaps")
            val image = store.captureEvents().single { it["type"] == "image" }
            check(store.assetFile(image.obj("payload").str("path")).readBytes().contentEquals(jpeg))
            check(store.captureEvents().all { it.num("sampleOffset") == 32000L })
            check(File(store.chunks().single().str("path")).readBytes().contentEquals(pcm))
            val (_, canonical) = PortableText.project(
                store.directory,
                store.id,
                32000,
                store.timeline()
            )
            check(canonical["fullText"] == "精修连续全文。" && canonical["status"] == "ready")
        }
        checks += "photos_thoughts_bookmarks_refinement_and_gap_survive_copy_roundtrip"
        // Leave only public Android output in the test cache for independent iOS validation.
        val output = File(context.cacheDir, "m3c-public-export.momentai")
        File(exported.str("archivePath")).copyTo(output, overwrite = true)
    }
}
