import CoreFoundation
import Foundation
import ImageIO
import SQLite3

// Import is an offline materialization of the portable v1 export, NOT recovery.
// All writes target a new hidden staging directory until the final rename.
final class SessionImporter {
  private struct Pending {
    let token: String
    let job: URL
    let payload: URL
    let document: [String: Any]
    let archiveHash: String
    let archiveBytes: Int64
  }
  private let root: URL
  private let freeBytes: () throws -> Int64
  private let beforeCommit: () throws -> Void
  private var pending: Pending?
  private let fm = FileManager.default
  static let reserveBytes: Int64 = 512 * 1_048_576

  init(
    root: URL, freeBytes: (() throws -> Int64)? = nil,
    beforeCommit: @escaping () throws -> Void = {}
  ) {
    self.root = root
    self.freeBytes =
      freeBytes ?? {
        try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
          .volumeAvailableCapacityForImportantUsage ?? 0
      }
    self.beforeCommit = beforeCommit
  }

  func cancel() {
    if let pending { try? fm.removeItem(at: pending.job) }
    pending = nil
  }

  func prepare(archive: URL) throws -> [String: Any] {
    cancel()
    guard archive.pathExtension.lowercased() == "momentai" else {
      throw SessionImportError(NativeStrings.text("native_select_a_complete_momentai_recording_71"))
    }
    let values = try archive.resourceValues(forKeys: [
      .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
    ])
    let bytes = Int64(values.fileSize ?? 0)
    guard values.isRegularFile == true, values.isSymbolicLink != true,
      bytes > 0, bytes <= StoredZIPReader.maximumArchiveBytes
    else {
      throw SessionImportError(
        NativeStrings.text("native_unsupported_file_type_or_size_maximum_2_gib_139"))
    }
    // Snapshot + extracted payload + rebuilt session, plus metadata/SQLite headroom.
    try checkSpace(bytes * 3 + 64 * 1_048_576)
    let staging = root.appendingPathComponent(".Imports", isDirectory: true)
    if fm.fileExists(atPath: staging.path) { try fm.removeItem(at: staging) }
    let token = UUID().uuidString
    let job = staging.appendingPathComponent(token, isDirectory: true)
    try fm.createDirectory(at: job, withIntermediateDirectories: true)
    do {
      let local = job.appendingPathComponent("source.momentai")
      try boundedCopy(archive, to: local, bytes: bytes)
      let reader = try StoredZIPReader(url: local)
      guard let manifestEntry = reader.entries.first(where: { $0.path == "manifest.json" }),
        manifestEntry.size <= 2 * 1_024 * 1_024
      else {
        throw SessionImportError(NativeStrings.text("native_a_valid_manifest_is_missing_140"))
      }
      let manifest = try object(reader.data(manifestEntry))
      guard try number(manifest, "schemaVersion") == 1,
        manifest["format"] as? String == "org.hohu.momentai.archive",
        manifest["archiveFormat"] as? String == "zip-store",
        let files = manifest["files"] as? [[String: Any]]
      else { throw SessionImportError(NativeStrings.text("native_unsupported_archive_version_72")) }
      let payload = job.appendingPathComponent("payload", isDirectory: true)
      let artifacts = try reader.extract(to: payload)
      var declared = Set<String>()
      for file in files {
        let path = try string(file, "path")
        guard path != "manifest.json", declared.insert(path).inserted,
          let actual = artifacts[path], try number(file, "byteCount") == actual.bytes,
          try string(file, "sha256") == actual.sha256
        else {
          throw SessionImportError(
            NativeStrings.text("native_manifest_file_size_or_sha_256_verification_failed_141"))
        }
      }
      guard declared == Set(artifacts.keys).subtracting(["manifest.json"]) else {
        throw SessionImportError(
          NativeStrings.text("native_the_manifest_has_missing_or_extra_files_75"))
      }
      let document = try object(Data(contentsOf: payload.appendingPathComponent("session.json")))
      try validate(document, manifest: manifest, artifacts: artifacts, payload: payload)
      let archiveHash = try SessionExporter.sha256File(local)
      pending = Pending(
        token: token, job: job, payload: payload, document: document,
        archiveHash: archiveHash, archiveBytes: bytes)
      let session = document["session"] as! [String: Any]
      let sessionID = session["sessionId"] as! String
      return [
        "token": token, "sessionId": sessionID, "title": session["title"]!,
        "startedAtWall": session["startedAtWall"]!, "stoppedAtWall": session["stoppedAtWall"]!,
        "durationSamples": session["lastCommittedSample"]!, "archiveBytes": bytes,
        "timelineItemCount": (document["timeline"] as! [[String: Any]]).count,
        "hasConfirmedGaps": session["state"] as? String == "completed_with_gaps",
        "conflict": fm.fileExists(atPath: root.appendingPathComponent(sessionID).path),
      ]
    } catch {
      try? fm.removeItem(at: job)
      throw error
    }
  }

  func commit(token: String, asCopy: Bool) throws -> [String: Any] {
    guard let job = pending, job.token == token else {
      throw SessionImportError(
        NativeStrings.text("native_the_import_preview_has_expired_select_the_file_again_76"))
    }
    let source = job.document["session"] as! [String: Any]
    let sourceID = source["sessionId"] as! String
    let sessionID =
      asCopy
      ? "session_import_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))" : sourceID
    let destination = root.appendingPathComponent(sessionID, isDirectory: true)
    guard !fm.fileExists(atPath: destination.path) else {
      throw SessionImportError(
        NativeStrings.text(
          "native_a_recording_with_this_id_already_exists_import_a_copy_to_preserve_77"))
    }
    do {
      try checkSpace(job.archiveBytes + 64 * 1_048_576)
      let stagedSession = job.job.appendingPathComponent(sessionID, isDirectory: true)
      try materialize(job: job, directory: stagedSession, sessionID: sessionID, asCopy: asCopy)
      // All SQLite handles have closed; validate the same read/playback contracts used by the app.
      var summary: [String: Any] = try autoreleasepool {
        let store = try SessionStore(directoryURL: stagedSession, create: false)
        _ = try CommittedAudioManifest(store: store)
        return try store.productSummary()
      }
      try beforeCommit()
      try checkSpace(0)
      guard !fm.fileExists(atPath: destination.path) else {
        throw SessionImportError(
          NativeStrings.text("native_recording_id_conflict_import_it_again_as_a_copy_142"))
      }
      // Same-volume directory rename is the visibility/commit point. Never overwrite.
      try fm.moveItem(at: stagedSession, to: destination)
      summary["directory"] = destination.path
      summary["importedFromSessionId"] = sourceID
      cancel()
      return summary
    } catch {
      cancel()
      throw error
    }
  }

  private func checkSpace(_ required: Int64) throws {
    guard try freeBytes() >= required + Self.reserveBytes else {
      throw SessionImportError(
        NativeStrings.text(
          "native_not_enough_storage_for_import_staging_and_reconstruction_plus_512_143"))
    }
  }

  private func boundedCopy(_ source: URL, to destination: URL, bytes: Int64) throws {
    let input = try FileHandle(forReadingFrom: source)
    defer { try? input.close() }
    guard fm.createFile(atPath: destination.path, contents: nil) else {
      throw SessionImportError(
        NativeStrings.text("native_could_not_create_the_import_snapshot_144"))
    }
    let output = try FileHandle(forWritingTo: destination)
    defer { try? output.close() }
    var remaining = bytes
    while remaining > 0 {
      let data = try input.importRead(Int(min(256 * 1_024, remaining))) ?? Data()
      guard !data.isEmpty else {
        throw SessionImportError(
          NativeStrings.text("native_the_source_file_changed_while_being_read_145"))
      }
      try output.importWrite(data)
      remaining -= Int64(data.count)
    }
    guard (try input.importRead(1) ?? Data()).isEmpty else {
      throw SessionImportError(NativeStrings.text("native_the_source_file_size_changed_146"))
    }
    try output.synchronize()
  }

  private func validate(
    _ doc: [String: Any], manifest: [String: Any],
    artifacts: [String: (bytes: Int, sha256: String)], payload: URL
  ) throws {
    guard try number(doc, "schemaVersion") == 1,
      doc["format"] as? String == "org.hohu.momentai.session-export",
      let session = doc["session"] as? [String: Any], let audio = doc["audio"] as? [String: Any],
      let timeline = doc["timeline"] as? [[String: Any]], timeline.count <= 100_000,
      let images = doc["images"] as? [[String: Any]]
    else {
      throw SessionImportError(NativeStrings.text("native_invalid_recording_data_structure_147"))
    }
    guard
      Set(["manifest.json", "session.json", "session.md", "timeline.jsonl", "audio/session.wav"])
        .isSubset(of: Set(artifacts.keys))
    else {
      throw SessionImportError(NativeStrings.text("native_required_archive_files_are_missing_148"))
    }
    let id = try string(session, "sessionId")
    let allowed = CharacterSet(
      charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
    guard id.hasPrefix("session_"), id.count <= 160,
      id.unicodeScalars.allSatisfy({ allowed.contains($0) }),
      id == manifest["sessionId"] as? String,
      ["completed", "completed_with_gaps"].contains(try string(session, "state")),
      try string(session, "title").count <= 120,
      let started = date(try string(session, "startedAtWall")),
      let stopped = date(try string(session, "stoppedAtWall")), stopped >= started,
      try number(session, "sampleRate") == 16_000
    else {
      throw SessionImportError(
        NativeStrings.text("native_invalid_session_identity_final_state_or_timestamps_149"))
    }
    let samples = try number(session, "lastCommittedSample")
    guard samples > 0, samples <= StoredZIPReader.maximumArchiveBytes / 2,
      try number(session, "chunkCount") > 0, try number(session, "recoveryCount") >= 0,
      audio["path"] as? String == "audio/session.wav", audio["codec"] as? String == "pcm_s16le",
      try number(audio, "sampleRate") == 16_000, try number(audio, "channels") == 1,
      try number(audio, "bitsPerSample") == 16, try number(audio, "sampleCount") == samples,
      try number(audio, "durationMs") == samples * 1_000 / 16_000,
      let wav = artifacts["audio/session.wav"], Int64(wav.bytes) == samples * 2 + 44,
      try number(audio, "byteCount") == wav.bytes, audio["sha256"] as? String == wav.sha256
    else {
      throw SessionImportError(
        NativeStrings.text(
          "native_audio_samples_committed_position_duration_or_hash_do_not_match_150"))
    }
    let input = try FileHandle(forReadingFrom: payload.appendingPathComponent("audio/session.wav"))
    defer { try? input.close() }
    let header = try input.importRead(44) ?? Data()
    guard header.count == 44, String(decoding: header[0..<4], as: UTF8.self) == "RIFF",
      header.zipUInt32(4) == wav.bytes - 8,
      String(decoding: header[8..<16], as: UTF8.self) == "WAVEfmt ", header.zipUInt32(16) == 16,
      header.zipUInt16(20) == 1, header.zipUInt16(22) == 1, header.zipUInt32(24) == 16_000,
      header.zipUInt32(28) == 32_000, header.zipUInt16(32) == 2, header.zipUInt16(34) == 16,
      String(decoding: header[36..<40], as: UTF8.self) == "data",
      header.zipUInt32(40) == samples * 2
    else {
      throw SessionImportError(
        NativeStrings.text("native_the_wav_header_does_not_match_the_pcm_format_151"))
    }
    var identities = Set<String>()
    var imageItems: [String: [String: Any]] = [:]
    for item in timeline {
      let sample = try number(item, "sampleOffset")
      guard sample <= samples else {
        throw SessionImportError(
          NativeStrings.text("native_timeline_anchors_exceed_committed_audio_152"))
      }
      let kind = try string(item, "kind")
      switch kind {
      case "transcript":
        let segmentID = try string(item, "segmentId")
        let end = try number(item, "endSample")
        guard identities.insert("t:\(segmentID)").inserted, item["sessionId"] as? String == id,
          try number(item, "startSample") == sample, end > sample, end <= samples,
          try number(item, "startMs") == sample * 1_000 / 16_000,
          try number(item, "endMs") == end * 1_000 / 16_000,
          item["isFinal"] as? Bool == true
        else {
          throw SessionImportError(
            NativeStrings.text(
              "native_duplicate_or_unfinished_transcript_or_invalid_sample_anchors_153"))
        }
        _ = try string(item, "text")
        if let live = item["liveText"] as? String, live != item["text"] as? String {
          throw SessionImportError(
            NativeStrings.text("native_the_original_transcript_layer_does_not_match_154"))
        }
      case "captureEvent":
        let eventID = try string(item, "eventId")
        let type = try string(item, "type")
        let state = try string(item, "captureState")
        guard identities.insert("c:\(eventID)").inserted,
          identities.insert("cs:\(try number(item, "sequence"))").inserted,
          ["image", "thought", "bookmark"].contains(type),
          ["committed", "failed", "tombstoned"].contains(state),
          try number(item, "atMs") == sample * 1_000 / 16_000,
          let info = item["payload"] as? [String: Any]
        else {
          throw SessionImportError(
            NativeStrings.text("native_duplicate_unfinished_or_unsupported_capture_events_155"))
        }
        _ = try number(item, "monotonicElapsedNs")
        if type == "image" && state == "committed" { imageItems[eventID] = item }
        if type == "thought" && state == "committed" {
          guard try string(info, "text") == item["text"] as? String else {
            throw SessionImportError(NativeStrings.text("native_thought_text_does_not_match_156"))
          }
        }
      case "event":
        guard identities.insert("e:\(try number(item, "sequence"))").inserted,
          try number(item, "atMs") == sample * 1_000 / 16_000,
          item["payload"] is [String: Any]
        else {
          throw SessionImportError(
            NativeStrings.text("native_duplicate_or_invalid_historical_events_157"))
        }
        _ = try string(item, "type")
      default: throw SessionImportError(NativeStrings.text("native_unsupported_timeline_type_81"))
      }
    }
    let transcriptRanges = timeline.filter { $0["kind"] as? String == "transcript" }
      .sorted {
        ($0["startSample"] as! NSNumber).int64Value < ($1["startSample"] as! NSNumber).int64Value
      }
    var lastEnd: Int64 = 0
    for item in transcriptRanges {
      let start = try number(item, "startSample")
      guard start >= lastEnd else {
        throw SessionImportError(
          NativeStrings.text(
            "native_transcript_sample_ranges_overlap_the_recording_cannot_be_safely_i_158"))
      }
      lastEnd = try number(item, "endSample")
    }
    var imagePaths = Set<String>()
    var imageIDs = Set<String>()
    for image in images {
      let eventID = try string(image, "eventId")
      let path = try string(image, "path")
      guard imageIDs.insert(eventID).inserted, imagePaths.insert(path).inserted,
        path.hasPrefix("images/"), let artifact = artifacts[path], let item = imageItems[eventID],
        let info = item["payload"] as? [String: Any],
        item["mediaPath"] as? String == path, info["path"] as? String == path,
        info["assetState"] as? String == "committed",
        try number(image, "sampleOffset") == number(item, "sampleOffset"),
        try number(image, "byteCount") == artifact.bytes,
        try number(info, "byteCount") == artifact.bytes,
        image["sha256"] as? String == artifact.sha256, info["sha256"] as? String == artifact.sha256
      else {
        throw SessionImportError(
          NativeStrings.text("native_invalid_image_timeline_association_or_hash_159"))
      }
      guard
        let imageSource = CGImageSourceCreateWithURL(
          payload.appendingPathComponent(path) as CFURL,
          [kCGImageSourceShouldCache: false] as CFDictionary),
        CGImageSourceGetType(imageSource) as String? == "public.jpeg",
        CGImageSourceGetCount(imageSource) == 1,
        let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any],
        let width = properties[kCGImagePropertyPixelWidth as String] as? NSNumber,
        let height = properties[kCGImagePropertyPixelHeight as String] as? NSNumber,
        width.int64Value > 0, height.int64Value > 0, width.int64Value <= 20_000,
        height.int64Value <= 20_000,
        width.int64Value * height.int64Value <= 50_000_000
      else {
        throw SessionImportError(
          NativeStrings.text("native_the_image_is_damaged_or_exceeds_the_maximum_size_of_50_mp_160")
        )
      }
    }
    guard imageIDs == Set(imageItems.keys),
      imagePaths == Set(artifacts.keys.filter { $0.hasPrefix("images/") })
    else {
      throw SessionImportError(
        NativeStrings.text("native_images_are_missing_or_have_no_associated_files_161"))
    }
    let lines = try String(
      contentsOf: payload.appendingPathComponent("timeline.jsonl"), encoding: .utf8
    ).split(separator: "\n")
    guard lines.count == timeline.count else {
      throw SessionImportError(
        NativeStrings.text("native_json_and_jsonl_timeline_counts_do_not_match_162"))
    }
    for (index, line) in lines.enumerated() {
      let row = try object(Data(line.utf8))
      guard try number(row, "schemaVersion") == 1, row["sessionId"] as? String == id,
        try number(row, "index") == index, let item = row["item"] as? [String: Any],
        NSDictionary(dictionary: item).isEqual(to: timeline[index])
      else {
        throw SessionImportError(
          NativeStrings.text("native_json_and_jsonl_timeline_content_do_not_match_163"))
      }
    }
    try validateCanonical(doc, timeline: timeline, samples: samples)
    if let raw = doc["extensions"] {
      guard let extensions = raw as? [String: Any],
        Set(extensions.keys).isSubset(of: [SpeakerTextContract.capability])
      else {
        throw SessionImportError(
          NativeStrings.text(
            "native_the_archive_contains_unsupported_extensions_update_the_app_before_164"))
      }
    }
    let capabilities = doc["capabilities"] as? [String] ?? []
    guard
      Set(capabilities).isSubset(of: [
        "canonicalTextV1", "timelineTextLayersV1", SpeakerTextContract.capability,
      ])
    else {
      throw SessionImportError(
        NativeStrings.text(
          "native_the_archive_requires_capabilities_unsupported_by_this_version_165"))
    }
    let extensionValue = (doc["extensions"] as? [String: Any])?[SpeakerTextContract.capability]
    guard (extensionValue != nil) == capabilities.contains(SpeakerTextContract.capability) else {
      throw SessionImportError(
        NativeStrings.text("native_speaker_extension_declarations_do_not_match_166"))
    }
    if let extensionValue {
      guard let ext = extensionValue as? [String: Any], try number(ext, "schemaVersion") == 1,
        ext["sourceAudioSha256"] as? String == wav.sha256,
        let speakers = ext["document"] as? [String: Any],
        let projection = ext["textProjection"] as? [String: Any],
        let canonical = doc["canonicalText"] as? [String: Any]
      else {
        throw SessionImportError(
          NativeStrings.text("native_invalid_speaker_extension_version_or_audio_source_167"))
      }
      try SpeakerTextContract.validate(speakers, sessionID: id, samples: samples)
      let expected = try SpeakerTextContract.projection(canonical: canonical, document: speakers)
      guard NSDictionary(dictionary: projection).isEqual(to: expected) else {
        throw SessionImportError(
          NativeStrings.text(
            "native_speaker_text_does_not_match_the_original_segments_or_user_edits_168"))
      }
    }
  }

  private func validateCanonical(_ doc: [String: Any], timeline: [[String: Any]], samples: Int64)
    throws
  {
    guard let canonical = doc["canonicalText"] as? [String: Any] else {
      // Original v1 pre-S2.6 bundles carry live text only.
      guard !timeline.contains(where: { $0["textLayer"] as? String == "refined" }) else {
        throw SessionImportError(
          NativeStrings.text("native_the_refinement_source_declaration_is_missing_169"))
      }
      return
    }
    let transcripts = timeline.filter { $0["kind"] as? String == "transcript" }
    guard try number(canonical, "schemaVersion") == 1,
      canonical["format"] as? String == "org.hohu.momentai.canonical-text",
      try number(canonical, "sourceAudioSamples") == samples,
      try number(canonical, "sampleRate") == 16_000,
      try canonical["sourceTimelineFingerprint"] as? String
        == SessionExporter.sourceTimelineFingerprint(timeline),
      let segments = canonical["segments"] as? [[String: Any]], segments.count == transcripts.count,
      try number(canonical, "segmentCount") == transcripts.count,
      canonical["fullText"] is String
    else {
      throw SessionImportError(
        NativeStrings.text("native_invalid_source_fingerprint_or_segment_mapping_170"))
    }
    let status = try string(canonical, "status")
    guard ["ready", "partial", "live", "stale", "failed"].contains(status) else {
      throw SessionImportError(NativeStrings.text("native_unsupported_text_layer_state_171"))
    }
    let refined = status == "ready" || status == "partial"
    guard canonical["defaultTextLayer"] as? String == (refined ? "refined" : "live"),
      try !refined || (number(canonical, "composerVersion") == 4)
    else {
      throw SessionImportError(NativeStrings.text("native_unsupported_refinement_composer_172"))
    }
    var refinedCount = 0
    var fallbackCount = 0
    for (segment, item) in zip(segments, transcripts) {
      let layer = item["textLayer"] as? String ?? "live"
      guard segment["segmentId"] as? String == item["segmentId"] as? String,
        try number(segment, "startSample") == number(item, "startSample"),
        try number(segment, "endSample") == number(item, "endSample"),
        segment["liveText"] as? String == item["text"] as? String,
        segment["text"] as? String == item["displayText"] as? String,
        segment["textLayer"] as? String == layer
      else {
        throw SessionImportError(
          NativeStrings.text("native_refined_segments_do_not_match_the_original_transcript_173"))
      }
      if layer == "refined" && refined {
        guard try string(item, "refinedText") == item["displayText"] as? String,
          item["refinedText"] as? String == segment["refinedText"] as? String
        else {
          throw SessionImportError(
            NativeStrings.text("native_invalid_refined_text_association_174"))
        }
        refinedCount += 1
      } else {
        guard layer == (refined ? "fallback" : "live"),
          item["displayText"] as? String == item["text"] as? String
        else {
          throw SessionImportError(NativeStrings.text("native_invalid_fallback_text_layer_175"))
        }
        if refined { fallbackCount += 1 }
      }
    }
    guard try number(canonical, "refinedSegmentCount") == refinedCount,
      try number(canonical, "fallbackSegmentCount") == fallbackCount,
      status != "ready" || fallbackCount == 0,
      status != "partial" || fallbackCount > 0
    else {
      throw SessionImportError(
        NativeStrings.text("native_refinement_counts_or_state_do_not_match_176"))
    }
  }

  private func materialize(job: Pending, directory: URL, sessionID: String, asCopy: Bool) throws {
    let source = job.document["session"] as! [String: Any]
    let timeline = job.document["timeline"] as! [[String: Any]]
    // Reuse the frozen schema, not its recording/recovery state machine.
    try autoreleasepool {
      _ = try SessionStore(directoryURL: directory, create: true, title: source["title"] as? String)
    }
    let db = try ImportDatabase(directory.appendingPathComponent("session.sqlite"))
    try db.run("PRAGMA foreign_keys=ON;")
    try db.run("BEGIN IMMEDIATE;")
    let title = source["title"] as! String
    try db.run(
      "UPDATE session SET title=?,status=?,started_at_wall=?,stopped_at_wall=?,last_committed_sample=?,recovery_count=? WHERE id=?;",
      [
        asCopy ? String(title.prefix(112)) + NativeStrings.text("export_copy") : title,
        source["state"]!,
        source["startedAtWall"]!,
        source["stoppedAtWall"]!, source["lastCommittedSample"]!, source["recoveryCount"]!,
        sessionID,
      ])
    let audio = try FileHandle(
      forReadingFrom: job.payload.appendingPathComponent("audio/session.wav"))
    defer { try? audio.close() }
    try audio.seek(toOffset: 44)
    var index = 0
    while let data = try audio.importRead(960_000), !data.isEmpty {
      let relative = String(format: "audio/chunk_%06d.pcm", index)
      try data.write(to: directory.appendingPathComponent(relative), options: .atomic)
      try db.run(
        "INSERT INTO chunks VALUES(?,?,?,?,?,?);",
        [
          index, relative, data.count / 2, data.count, SessionStore.sha256(data),
          source["stoppedAtWall"]!,
        ])
      index += 1
    }
    try db.run("UPDATE session SET next_chunk_index=? WHERE id=?;", [index, sessionID])
    for image in job.document["images"] as! [[String: Any]] {
      let path = image["path"] as! String
      let destination = directory.appendingPathComponent(path)
      try fm.createDirectory(
        at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
      try fm.copyItem(at: job.payload.appendingPathComponent(path), to: destination)
    }
    for item in timeline {
      let sample = item["sampleOffset"]!
      let wall = item["wallTime"] as? String ?? source["startedAtWall"] as! String
      switch item["kind"] as! String {
      case "transcript":
        try db.run(
          "INSERT INTO transcript_segments VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?);",
          [
            item["segmentId"]!, sessionID, sample, item["endSample"]!, item["startMs"]!,
            item["endMs"]!,
            item["text"]!, item["rawText"] as? String ?? item["text"]!,
            item["language"] as? String ?? "",
            item["source"] as? String ?? "import", item["modelId"] as? String ?? "unknown", 1, wall,
          ])
      case "captureEvent":
        var info = item["payload"] as! [String: Any]
        info.removeValue(forKey: "assetPath")
        info.removeValue(forKey: "path")
        let hasImage =
          item["type"] as? String == "image" && item["captureState"] as? String == "committed"
        let blob: Any = hasImage ? "import_\(item["eventId"]!)" : NSNull()
        if hasImage {
          try db.run(
            "INSERT INTO media_assets VALUES(?,?,?,?,?,?,?,?,?,?);",
            [
              blob, sessionID, "image", "committed", item["mediaPath"]!, "image/jpeg",
              info["byteCount"]!, info["sha256"]!, wall, wall,
            ])
        }
        try db.run(
          "INSERT INTO capture_events(seq,event_id,session_id,type,sample_offset,at_ms,monotonic_elapsed_ns,wall_time,clock_epoch_id,capture_state,asset_blob_id,payload_json,created_at_wall,updated_at_wall) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?);",
          [
            item["sequence"]!, item["eventId"]!, sessionID, item["type"]!, sample, item["atMs"]!,
            item["monotonicElapsedNs"]!, wall, item["clockEpochId"] as? String ?? "import",
            item["captureState"]!, blob, try jsonString(info), wall, wall,
          ])
      default:
        try db.run(
          "INSERT INTO events(seq,type,sample_offset,wall_time,payload_json) VALUES(?,?,?,?,?);",
          [item["sequence"]!, item["type"]!, sample, wall, try jsonString(item["payload"]!)])
      }
    }
    try db.run("COMMIT;")
    try db.checkIntegrity()
    try db.close()
    if let ext = (job.document["extensions"] as? [String: Any])?[SpeakerTextContract.capability]
      as? [String: Any],
      var speakers = ext["document"] as? [String: Any]
    {
      speakers["sessionId"] = sessionID
      let store = try SessionStore(directoryURL: directory, create: false)
      speakers["sourceChunkFingerprint"] = try SpeakerTextContract.localFingerprint(
        store: store, destination: root.appendingPathComponent(sessionID, isDirectory: true))
      try SpeakerTextContract.validate(
        speakers, sessionID: sessionID,
        samples: (source["lastCommittedSample"] as! NSNumber).int64Value)
      try JSONSerialization.data(withJSONObject: speakers, options: [.sortedKeys]).write(
        to: directory.appendingPathComponent(SpeakerTextContract.fileName), options: .atomic)
    }
    if let canonical = job.document["canonicalText"] as? [String: Any],
      ["ready", "partial"].contains(canonical["status"] as? String ?? "")
    {
      let projection: [[String: Any]] = timeline.filter { $0["kind"] as? String == "transcript" }
        .map {
          [
            "segmentId": $0["segmentId"]!, "startSample": $0["startSample"]!,
            "endSample": $0["endSample"]!,
            "refinedText": $0["displayText"]!, "fallback": $0["textLayer"] as? String != "refined",
          ]
        }
      let refinement: [String: Any] = [
        "schemaVersion": 4, "status": "ready", "sessionId": sessionID,
        "modelId": canonical["modelId"] as? String ?? "import", "fullText": canonical["fullText"]!,
        "sourceAudioSamples": source["lastCommittedSample"]!, "sampleRate": 16_000,
        "createdAt": canonical["createdAt"] as? String ?? "", "composerVersion": 4,
        "sourceTimelineFingerprint": canonical["sourceTimelineFingerprint"]!,
        "timelineProjection": projection,
        "segments": [], "canonicalTokens": [], "imported": true,
      ]
      try JSONSerialization.data(withJSONObject: refinement, options: [.sortedKeys]).write(
        to: directory.appendingPathComponent("full_text_refinement.json"), options: .atomic)
    }
    let provenance: [String: Any] = [
      "schemaVersion": 1, "sourceSessionId": source["sessionId"]!,
      "sourceArchiveSha256": job.archiveHash,
      "importedAt": ISO8601DateFormatter().string(from: Date()),
      "sourceChunkCount": source["chunkCount"]!, "materializedChunkCount": index,
      "mode": "portable-export-v1", "note": "从连续 WAV 重建；不是原设备 SQLite、Chunk 日志或 ASR 任务恢复。",
    ]
    try JSONSerialization.data(withJSONObject: provenance, options: [.sortedKeys]).write(
      to: directory.appendingPathComponent("import_provenance.json"), options: .atomic)
  }

  private func object(_ data: Data) throws -> [String: Any] {
    guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw SessionImportError(NativeStrings.text("native_json_is_not_an_object_178"))
    }
    return value
  }
  private func string(_ object: [String: Any], _ key: String) throws -> String {
    guard let value = object[key] as? String,
      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      value.utf8.count <= 1_048_576
    else {
      throw SessionImportError(
        NativeStrings.text("native_invalid_text_field_179", String(describing: key)))
    }
    return value
  }
  private func number(_ object: [String: Any], _ key: String) throws -> Int64 {
    guard let value = object[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
      value.doubleValue.isFinite, value.doubleValue >= 0,
      value.doubleValue <= 9_007_199_254_740_991,
      value.doubleValue == Double(value.int64Value)
    else {
      throw SessionImportError(
        NativeStrings.text("native_invalid_integer_metadata_180", String(describing: key)))
    }
    return value.int64Value
  }
  private func date(_ string: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    if let date = formatter.date(from: string) { return date }
    formatter.formatOptions.insert(.withFractionalSeconds)
    return formatter.date(from: string)
  }
  private func jsonString(_ object: Any) throws -> String {
    String(
      decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
      as: UTF8.self)
  }
}

private final class ImportDatabase {
  private var db: OpaquePointer?
  init(_ url: URL) throws {
    guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
      throw SessionImportError(NativeStrings.text("native_could_not_open_the_staging_database_181"))
    }
  }
  deinit { sqlite3_close(db) }
  func run(_ sql: String, _ values: [Any] = []) throws {
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
      throw SessionImportError(NativeStrings.text("native_could_not_prepare_the_import_sql_182"))
    }
    defer { sqlite3_finalize(stmt) }
    for (offset, value) in values.enumerated() {
      let index = Int32(offset + 1)
      let result: Int32
      if let text = value as? String {
        result = sqlite3_bind_text(
          stmt, index, text, Int32(text.utf8.count),
          unsafeBitCast(-1, to: sqlite3_destructor_type.self))
      } else if let number = value as? NSNumber {
        result = sqlite3_bind_int64(stmt, index, number.int64Value)
      } else if value is NSNull {
        result = sqlite3_bind_null(stmt, index)
      } else {
        throw SessionImportError(NativeStrings.text("native_invalid_import_field_type_183"))
      }
      guard result == SQLITE_OK else {
        throw SessionImportError(NativeStrings.text("native_could_not_bind_import_fields_184"))
      }
    }
    guard sqlite3_step(stmt) == SQLITE_DONE else {
      throw SessionImportError(
        NativeStrings.text("native_imported_data_violates_database_constraints_185"))
    }
  }
  func checkIntegrity() throws {
    for sql in ["PRAGMA integrity_check;", "PRAGMA foreign_key_check;"] {
      var stmt: OpaquePointer?
      guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
        throw SessionImportError(NativeStrings.text("native_could_not_run_database_validation_186"))
      }
      defer { sqlite3_finalize(stmt) }
      let result = sqlite3_step(stmt)
      if sql.contains("integrity") {
        guard result == SQLITE_ROW, let text = sqlite3_column_text(stmt, 0),
          String(cString: text) == "ok"
        else {
          throw SessionImportError(
            NativeStrings.text("native_import_database_integrity_verification_failed_187"))
        }
      } else if result != SQLITE_DONE {
        throw SessionImportError(
          NativeStrings.text("native_import_database_relationship_verification_failed_188"))
      }
    }
  }
  func close() throws {
    guard sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil) == SQLITE_OK,
      sqlite3_close(db) == SQLITE_OK
    else {
      throw SessionImportError(
        NativeStrings.text("native_the_staging_database_could_not_be_safely_closed_189"))
    }
    db = nil
  }
}
