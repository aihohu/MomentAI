import CryptoKit
import Foundation

enum SessionExportError: LocalizedError {
  case invalidState(String)
  case invalidChunk(String)
  case invalidAsset(String)
  case invalidArchive(String)

  var errorDescription: String? {
    switch self {
    case .invalidState(let state):
      return "Only completed Sessions can be exported (current state: \(state))."
    case .invalidChunk(let message), .invalidAsset(let message), .invalidArchive(let message):
      return message
    }
  }
}

private struct ExportArtifact {
  let path: String
  let url: URL
  let byteCount: Int64
  let sha256: String

  var dictionary: [String: Any] {
    ["path": path, "byteCount": byteCount, "sha256": sha256]
  }
}

private struct ExportedImage {
  let eventID: String
  let sampleOffset: Int64
  let path: String
  let byteCount: Int64
  let sha256: String

  var dictionary: [String: Any] {
    [
      "eventId": eventID,
      "sampleOffset": sampleOffset,
      "atMs": sampleOffset * 1_000 / 16_000,
      "path": path,
      "mimeType": "image/jpeg",
      "byteCount": byteCount,
      "sha256": sha256,
    ]
  }
}

private struct ExportTimelineSource {
  let segmentID: String
  let startSample: Int64
  let endSample: Int64
  let text: String
}

private struct ExportTextProjection {
  let timeline: [[String: Any]]
  let canonicalText: [String: Any]
  let status: String
  let defaultTextLayer: String
  let refinedTranscriptCount: Int
  let fallbackTranscriptCount: Int
}

final class SessionExporter {
  static let schemaVersion = 1
  static let canonicalTextSchemaVersion = 1
  static let refinedFullTextSchemaVersion = 4
  static let refinedTimelineComposerVersion = 4
  static let archiveExtension = "momentai"

  private let fileManager: FileManager
  private let now: () -> Date

  init(fileManager: FileManager = .default, now: @escaping () -> Date = Date.init) {
    self.fileManager = fileManager
    self.now = now
  }

  // Standalone shares do not assemble/copy the full audio-and-image archive.
  // Source metadata uses the same validation as .momentai export. TXT can
  // receive the shared Flutter reading layout without rewriting stored text.
  func readShareText(directoryPath: String, readingText: String? = nil) throws -> String {
    let url = try exportShare(
      directoryPath: directoryPath, format: "text", readingText: readingText)
    defer { try? fileManager.removeItem(at: url) }
    return try String(contentsOf: url, encoding: .utf8)
  }

  func exportShare(directoryPath: String, format: String, readingText: String? = nil) throws -> URL
  {
    guard ["text", "markdown", "audio"].contains(format) else {
      throw SessionExportError.invalidArchive(
        NativeStrings.text("native_unsupported_sharing_format_67"))
    }
    let sessionURL = URL(fileURLWithPath: directoryPath, isDirectory: true)
    let store = try SessionStore(directoryURL: sessionURL, create: false)
    var snapshot = try store.snapshot()
    snapshot["state"] = try store.productSummary()["state"]
    let state = snapshot["state"] as? String ?? "unknown"
    guard ["completed", "completed_with_gaps"].contains(state) else {
      throw SessionExportError.invalidState(state)
    }
    let root = sessionURL.deletingLastPathComponent().appendingPathComponent("Exports")
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    let ext = format == "audio" ? "wav" : format == "markdown" ? "md" : "txt"
    let url = root.appendingPathComponent(
      "\(safeName(store.sessionID))_\(UUID().uuidString).\(ext)")
    let partial = root.appendingPathComponent(".\(url.lastPathComponent).part")
    defer { try? fileManager.removeItem(at: partial) }
    let samples = (snapshot["lastCommittedSample"] as? NSNumber)?.int64Value ?? 0
    let free =
      try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
      .volumeAvailableCapacityForImportantUsage ?? 0
    guard free >= (format == "audio" ? samples * 2 + 44 : 16 * 1_048_576) + 512 * 1_048_576 else {
      throw SessionExportError.invalidArchive(
        NativeStrings.text("native_not_enough_storage_leave_at_least_512_mib_free_and_try_again_65")
      )
    }
    if format == "audio" {
      _ = try writeWAV(
        chunks: validatedChunks(store: store, snapshot: snapshot), sessionURL: sessionURL,
        to: partial)
    } else {
      let projection = try exportTextProjection(
        sessionURL: sessionURL, sessionID: store.sessionID, timeline: store.timeline(),
        sourceAudioSamples: samples, sampleRate: 16_000
      )
      let title = snapshot["title"] as? String ?? NativeStrings.text("native_momentai_45")
      let speakers = try SpeakerTextContract.load(
        store: store, directory: sessionURL, samples: samples)
      let speakerText = try speakers.map {
        try SpeakerTextContract.projection(canonical: projection.canonicalText, document: $0)
      }
      let isMarkdown = format == "markdown"
      var lines = [
        isMarkdown ? "# \(escapeMarkdown(title))" : title, "",
        NativeStrings.text("export_source", markdownTextLayer(projection.canonicalText)),
      ]
      if state == "completed_with_gaps" { lines.append(NativeStrings.text("export_gaps")) }
      let body =
        (format == "text" ? readingText : nil)
        ?? speakerText.map(SpeakerTextContract.rendered)
        ?? (projection.canonicalText["fullText"] as? String ?? "")
      lines += ["", body]
      let thoughts = projection.timeline.filter {
        $0["type"] as? String == "thought" && $0["captureState"] as? String == "committed"
      }
      if !thoughts.isEmpty {
        lines += [
          "",
          isMarkdown
            ? NativeStrings.text("export_thoughts_heading")
            : NativeStrings.text("export_thought_event"),
        ]
        for item in thoughts {
          let sample = (item["sampleOffset"] as? NSNumber)?.int64Value ?? 0
          lines += [
            "",
            "[\(timeLabel(milliseconds: sample * 1_000 / 16_000))] \(item["text"] as? String ?? "")",
          ]
        }
      }
      try (lines.joined(separator: "\n") + "\n").write(
        to: partial, atomically: true, encoding: .utf8)
    }
    try fileManager.moveItem(at: partial, to: url)
    return url
  }

  func export(directoryPath: String) throws -> [String: Any] {
    let sessionURL = URL(fileURLWithPath: directoryPath, isDirectory: true)
    let store = try SessionStore(directoryURL: sessionURL, create: false)
    var snapshot = try store.snapshot()
    snapshot["state"] = try store.productSummary()["state"]
    let state = snapshot["state"] as? String ?? "unknown"
    guard state == "completed" || state == "completed_with_gaps" else {
      throw SessionExportError.invalidState(state)
    }

    let sessionID = store.sessionID
    let exportedAt = ISO8601DateFormatter().string(from: now())
    let jobName = "\(safeName(sessionID))_\(timestamp(now()))"
    let exportRoot = sessionURL.deletingLastPathComponent()
      .appendingPathComponent("Exports", isDirectory: true)
    let partialBundleURL = exportRoot.appendingPathComponent(".\(jobName).part", isDirectory: true)
    let bundleURL = exportRoot.appendingPathComponent(jobName, isDirectory: true)
    let partialArchiveURL = exportRoot.appendingPathComponent(".\(jobName).momentai.part")
    let archiveURL = exportRoot.appendingPathComponent("\(jobName).momentai")

    try fileManager.createDirectory(at: exportRoot, withIntermediateDirectories: true)
    try? fileManager.removeItem(at: partialBundleURL)
    try? fileManager.removeItem(at: partialArchiveURL)

    do {
      try fileManager.createDirectory(
        at: partialBundleURL.appendingPathComponent("audio", isDirectory: true),
        withIntermediateDirectories: true
      )
      try fileManager.createDirectory(
        at: partialBundleURL.appendingPathComponent("images", isDirectory: true),
        withIntermediateDirectories: true
      )

      let chunks = try validatedChunks(store: store, snapshot: snapshot)
      let audioURL = partialBundleURL.appendingPathComponent("audio/session.wav")
      let audioSamples = try writeWAV(chunks: chunks, sessionURL: sessionURL, to: audioURL)
      let audioArtifact = try artifact(path: "audio/session.wav", url: audioURL)

      let exportedImages = try copyImages(
        from: store,
        sessionURL: sessionURL,
        bundleURL: partialBundleURL
      )
      let imagePaths = Dictionary(
        uniqueKeysWithValues: exportedImages.map { ($0.eventID, $0.path) }
      )
      let sourceTimeline = try store.timeline().map {
        canonicalTimelineItem($0, imagePaths: imagePaths)
      }
      let textProjection = try exportTextProjection(
        sessionURL: sessionURL,
        sessionID: sessionID,
        timeline: sourceTimeline,
        sourceAudioSamples: audioSamples,
        sampleRate: (snapshot["sampleRate"] as? NSNumber)?.intValue ?? 16_000
      )
      let timeline = textProjection.timeline

      var session = snapshot
      session.removeValue(forKey: "directory")
      let audio: [String: Any] = [
        "path": audioArtifact.path,
        "mimeType": "audio/wav",
        "codec": "pcm_s16le",
        "sampleRate": snapshot["sampleRate"] ?? 16_000,
        "channels": 1,
        "bitsPerSample": 16,
        "sampleCount": audioSamples,
        "durationMs": audioSamples * 1_000 / 16_000,
        "byteCount": audioArtifact.byteCount,
        "sha256": audioArtifact.sha256,
      ]
      let speakerDocument = try SpeakerTextContract.load(
        store: store, directory: sessionURL, samples: audioSamples)
      let speakerText = try speakerDocument.map {
        try SpeakerTextContract.projection(canonical: textProjection.canonicalText, document: $0)
      }
      var sessionDocument: [String: Any] = [
        "schemaVersion": Self.schemaVersion,
        "format": "org.hohu.momentai.session-export",
        "capabilities": ["canonicalTextV1", "timelineTextLayersV1"],
        "exportedAt": exportedAt,
        "session": session,
        "audio": audio,
        "images": exportedImages.map(\.dictionary),
        "timeline": timeline,
        "canonicalText": textProjection.canonicalText,
      ]
      if let speakerDocument, let speakerText {
        sessionDocument["capabilities"] = [
          "canonicalTextV1", "timelineTextLayersV1", SpeakerTextContract.capability,
        ]
        sessionDocument["extensions"] = [
          SpeakerTextContract.capability: [
            "schemaVersion": 1, "sourceAudioSha256": audioArtifact.sha256,
            "document": speakerDocument, "textProjection": speakerText,
          ]
        ]
      }

      let jsonURL = partialBundleURL.appendingPathComponent("session.json")
      try writeJSON(sessionDocument, to: jsonURL, pretty: true)
      let jsonArtifact = try artifact(path: "session.json", url: jsonURL)

      let jsonlURL = partialBundleURL.appendingPathComponent("timeline.jsonl")
      try writeJSONL(timeline, sessionID: sessionID, to: jsonlURL)
      let jsonlArtifact = try artifact(path: "timeline.jsonl", url: jsonlURL)

      let markdownURL = partialBundleURL.appendingPathComponent("session.md")
      try markdown(
        snapshot: snapshot,
        audio: audio,
        timeline: timeline,
        canonicalText: textProjection.canonicalText,
        speakerText: speakerText,
        exportedAt: exportedAt
      ).write(to: markdownURL, atomically: true, encoding: .utf8)
      let markdownArtifact = try artifact(path: "session.md", url: markdownURL)

      var payloadArtifacts = [markdownArtifact, jsonArtifact, jsonlArtifact, audioArtifact]
      for image in exportedImages {
        payloadArtifacts.append(
          ExportArtifact(
            path: image.path,
            url: partialBundleURL.appendingPathComponent(image.path),
            byteCount: image.byteCount,
            sha256: image.sha256
          )
        )
      }
      payloadArtifacts.sort { $0.path < $1.path }

      let manifest: [String: Any] = [
        "schemaVersion": Self.schemaVersion,
        "format": "org.hohu.momentai.archive",
        "archiveFormat": "zip-store",
        "sessionId": sessionID,
        "exportedAt": exportedAt,
        "files": payloadArtifacts.map(\.dictionary),
      ]
      let manifestURL = partialBundleURL.appendingPathComponent("manifest.json")
      try writeJSON(manifest, to: manifestURL, pretty: true)
      let manifestArtifact = try artifact(path: "manifest.json", url: manifestURL)
      let archiveArtifacts = (payloadArtifacts + [manifestArtifact]).sorted { $0.path < $1.path }

      try StoredZIPWriter().write(artifacts: archiveArtifacts, to: partialArchiveURL)
      let partialArchiveArtifact = try artifact(
        path: archiveURL.lastPathComponent, url: partialArchiveURL)

      guard !fileManager.fileExists(atPath: bundleURL.path),
        !fileManager.fileExists(atPath: archiveURL.path)
      else {
        throw SessionExportError.invalidArchive(
          "An export with the same identifier already exists.")
      }
      try fileManager.moveItem(at: partialBundleURL, to: bundleURL)
      do {
        try fileManager.moveItem(at: partialArchiveURL, to: archiveURL)
      } catch {
        try? fileManager.removeItem(at: bundleURL)
        throw error
      }

      let result: [String: Any] = [
        "schemaVersion": Self.schemaVersion,
        "sessionId": sessionID,
        "exportId": jobName,
        "directory": bundleURL.path,
        "archivePath": archiveURL.path,
        "markdownPath": bundleURL.appendingPathComponent("session.md").path,
        "jsonPath": bundleURL.appendingPathComponent("session.json").path,
        "jsonlPath": bundleURL.appendingPathComponent("timeline.jsonl").path,
        "audioPath": bundleURL.appendingPathComponent("audio/session.wav").path,
        "manifestPath": bundleURL.appendingPathComponent("manifest.json").path,
        "audioSamples": audioSamples,
        "durationMs": audioSamples * 1_000 / 16_000,
        "timelineItemCount": timeline.count,
        "transcriptCount": timeline.filter { $0["kind"] as? String == "transcript" }.count,
        "canonicalTextStatus": textProjection.status,
        "canonicalTextLayer": textProjection.defaultTextLayer,
        "refinedTranscriptCount": textProjection.refinedTranscriptCount,
        "fallbackTranscriptCount": textProjection.fallbackTranscriptCount,
        "imageCount": exportedImages.count,
        "payloadFileCount": payloadArtifacts.count,
        "archiveByteCount": partialArchiveArtifact.byteCount,
        "archiveSha256": partialArchiveArtifact.sha256,
        "sourceDatabaseSha256": try Self.sha256File(store.databaseURL),
        "exportedAt": exportedAt,
      ]
      try writeJSON(
        [
          "schemaVersion": Self.schemaVersion,
          "event": "stage1_export_completed",
          "result": result,
        ],
        to: sessionURL.appendingPathComponent("stage1_export_probe.json"),
        pretty: true
      )
      return result
    } catch {
      try? fileManager.removeItem(at: partialBundleURL)
      try? fileManager.removeItem(at: partialArchiveURL)
      throw error
    }
  }

  private func validatedChunks(
    store: SessionStore,
    snapshot: [String: Any]
  ) throws -> [StoredChunk] {
    let chunks = try store.chunks().values.sorted { $0.index < $1.index }
    guard !chunks.isEmpty else {
      throw SessionExportError.invalidChunk("The Session has no committed audio chunks.")
    }
    var totalSamples: Int64 = 0
    for (expectedIndex, chunk) in chunks.enumerated() {
      guard chunk.index == expectedIndex else {
        throw SessionExportError.invalidChunk(
          "Committed chunk sequence is not contiguous at index \(expectedIndex)."
        )
      }
      guard chunk.sampleCount >= 0,
        chunk.byteCount == chunk.sampleCount * 2
      else {
        throw SessionExportError.invalidChunk(
          "Chunk \(chunk.index) has invalid PCM length metadata.")
      }
      guard isSafeRelativePath(chunk.path) else {
        throw SessionExportError.invalidChunk("Chunk \(chunk.index) has an unsafe relative path.")
      }
      let url = store.directoryURL.appendingPathComponent(chunk.path)
      let size = try fileSize(url)
      guard size == chunk.byteCount else {
        throw SessionExportError.invalidChunk(
          "Chunk \(chunk.index) byte count does not match SQLite.")
      }
      guard try Self.sha256File(url) == chunk.sha256 else {
        throw SessionExportError.invalidChunk("Chunk \(chunk.index) SHA-256 does not match SQLite.")
      }
      totalSamples += chunk.sampleCount
    }
    let committed = (snapshot["lastCommittedSample"] as? NSNumber)?.int64Value ?? -1
    guard totalSamples == committed else {
      throw SessionExportError.invalidChunk(
        "Committed audio samples \(totalSamples) do not match Session high-water \(committed)."
      )
    }
    return chunks
  }

  private func writeWAV(
    chunks: [StoredChunk],
    sessionURL: URL,
    to outputURL: URL
  ) throws -> Int64 {
    let samples = chunks.reduce(Int64(0)) { $0 + $1.sampleCount }
    let pcmBytes = samples * 2
    guard pcmBytes <= Int64(UInt32.max) - 36 else {
      throw SessionExportError.invalidChunk("The Session is too large for a standard PCM WAV file.")
    }
    guard fileManager.createFile(atPath: outputURL.path, contents: nil) else {
      throw SessionExportError.invalidArchive("Unable to create WAV at \(outputURL.path).")
    }
    let output = try FileHandle(forWritingTo: outputURL)
    defer { output.closeFile() }
    output.write(wavHeader(pcmByteCount: UInt32(pcmBytes)))
    for chunk in chunks {
      let input = try FileHandle(forReadingFrom: sessionURL.appendingPathComponent(chunk.path))
      defer { input.closeFile() }
      while true {
        let data = input.readData(ofLength: 256 * 1_024)
        if data.isEmpty { break }
        output.write(data)
      }
    }
    output.synchronizeFile()
    return samples
  }

  private func copyImages(
    from store: SessionStore,
    sessionURL: URL,
    bundleURL: URL
  ) throws -> [ExportedImage] {
    var result: [ExportedImage] = []
    for asset in try store.captureAssets() where asset.type == "image" {
      guard asset.captureState == "committed", asset.assetState == "committed" else { continue }
      guard isSafeRelativePath(asset.path) else {
        throw SessionExportError.invalidAsset(
          "Committed image \(asset.eventID) has an unsafe path.")
      }
      let sourceURL = sessionURL.appendingPathComponent(asset.path)
      guard try fileSize(sourceURL) == asset.byteCount,
        try Self.sha256File(sourceURL) == asset.sha256
      else {
        throw SessionExportError.invalidAsset(
          "Committed image \(asset.eventID) does not match its SQLite integrity metadata."
        )
      }
      let relativePath = "images/\(safeName(asset.eventID)).jpg"
      let destinationURL = bundleURL.appendingPathComponent(relativePath)
      try fileManager.copyItem(at: sourceURL, to: destinationURL)
      result.append(
        ExportedImage(
          eventID: asset.eventID,
          sampleOffset: asset.sampleOffset,
          path: relativePath,
          byteCount: asset.byteCount,
          sha256: asset.sha256
        )
      )
    }
    return result.sorted {
      $0.sampleOffset == $1.sampleOffset
        ? $0.eventID < $1.eventID : $0.sampleOffset < $1.sampleOffset
    }
  }

  private func canonicalTimelineItem(
    _ raw: [String: Any],
    imagePaths: [String: String]
  ) -> [String: Any] {
    var item = raw
    item.removeValue(forKey: "assetPath")
    let eventID = item["eventId"] as? String ?? ""
    if let imagePath = imagePaths[eventID] {
      item["mediaPath"] = imagePath
    }
    if var payload = item["payload"] as? [String: Any] {
      payload.removeValue(forKey: "assetPath")
      if let imagePath = imagePaths[eventID] { payload["path"] = imagePath }
      item["payload"] = payload
    }
    return item
  }

  private func exportTextProjection(
    sessionURL: URL,
    sessionID: String,
    timeline: [[String: Any]],
    sourceAudioSamples: Int64,
    sampleRate: Int
  ) throws -> ExportTextProjection {
    let sources = Self.timelineSources(timeline)
    let fingerprint = try Self.sourceTimelineFingerprint(sources)
    let refinementURL = sessionURL.appendingPathComponent("full_text_refinement.json")
    guard fileManager.fileExists(atPath: refinementURL.path) else {
      return liveTextProjection(
        timeline: timeline,
        status: "live",
        fingerprint: fingerprint,
        sourceAudioSamples: sourceAudioSamples,
        sampleRate: sampleRate
      )
    }

    let payload: [String: Any]
    do {
      let data = try Data(contentsOf: refinementURL)
      guard let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw SessionExportError.invalidArchive("Refinement payload is not a JSON object.")
      }
      payload = decoded
    } catch {
      return liveTextProjection(
        timeline: timeline,
        status: "failed",
        fingerprint: fingerprint,
        sourceAudioSamples: sourceAudioSamples,
        sampleRate: sampleRate
      )
    }

    let persistedStatus = payload["status"] as? String ?? ""
    if persistedStatus == "failed" {
      return liveTextProjection(
        timeline: timeline,
        status: "failed",
        fingerprint: fingerprint,
        sourceAudioSamples: sourceAudioSamples,
        sampleRate: sampleRate
      )
    }
    guard persistedStatus == "ready" else {
      return liveTextProjection(
        timeline: timeline,
        status: "live",
        fingerprint: fingerprint,
        sourceAudioSamples: sourceAudioSamples,
        sampleRate: sampleRate
      )
    }

    let schemaVersion = (payload["schemaVersion"] as? NSNumber)?.intValue ?? 0
    let composerVersion = (payload["composerVersion"] as? NSNumber)?.intValue ?? 0
    let refinedSamples = (payload["sourceAudioSamples"] as? NSNumber)?.int64Value ?? -1
    let refinedSampleRate = (payload["sampleRate"] as? NSNumber)?.intValue ?? -1
    guard schemaVersion == Self.refinedFullTextSchemaVersion,
      composerVersion == Self.refinedTimelineComposerVersion,
      payload["sessionId"] as? String == sessionID,
      refinedSamples == sourceAudioSamples,
      refinedSampleRate == sampleRate,
      payload["sourceTimelineFingerprint"] as? String == fingerprint,
      let rawProjection = payload["timelineProjection"] as? [[String: Any]]
    else {
      return liveTextProjection(
        timeline: timeline,
        status: "stale",
        fingerprint: fingerprint,
        sourceAudioSamples: sourceAudioSamples,
        sampleRate: sampleRate
      )
    }

    let sourceByID = Dictionary(uniqueKeysWithValues: sources.map { ($0.segmentID, $0) })
    var refinedTextByID: [String: String] = [:]
    var projectedIDs = Set<String>()
    for entry in rawProjection {
      guard let segmentID = entry["segmentId"] as? String,
        let source = sourceByID[segmentID],
        projectedIDs.insert(segmentID).inserted,
        (entry["startSample"] as? NSNumber)?.int64Value == source.startSample,
        (entry["endSample"] as? NSNumber)?.int64Value == source.endSample
      else {
        return liveTextProjection(
          timeline: timeline,
          status: "stale",
          fingerprint: fingerprint,
          sourceAudioSamples: sourceAudioSamples,
          sampleRate: sampleRate
        )
      }
      let refinedText = entry["refinedText"] as? String ?? ""
      let fallback = entry["fallback"] as? Bool ?? false
      if fallback || refinedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        continue
      } else {
        refinedTextByID[segmentID] = refinedText
      }
    }
    let enrichedTimeline = timeline.map { raw -> [String: Any] in
      guard raw["kind"] as? String == "transcript" else { return raw }
      var item = raw
      let segmentID = item["segmentId"] as? String ?? ""
      let liveText = item["text"] as? String ?? ""
      item["liveText"] = liveText
      if let refinedText = refinedTextByID[segmentID] {
        item["refinedText"] = refinedText
        item["displayText"] = refinedText
        item["textLayer"] = "refined"
      } else {
        item["refinedText"] = NSNull()
        item["displayText"] = liveText
        item["textLayer"] = "fallback"
      }
      return item
    }
    let fallbackCount = sources.count - refinedTextByID.count
    let status = fallbackCount == 0 ? "ready" : "partial"
    let segments = canonicalTextSegments(enrichedTimeline)
    let persistedFullText = (payload["fullText"] as? String ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let fullText =
      persistedFullText.isEmpty
      ? segments.compactMap { $0["text"] as? String }.joined(separator: "\n\n")
      : persistedFullText
    let canonicalText: [String: Any] = [
      "schemaVersion": Self.canonicalTextSchemaVersion,
      "format": "org.hohu.momentai.canonical-text",
      "status": status,
      "defaultTextLayer": "refined",
      "modelId": payload["modelId"] as? String ?? "",
      "composerVersion": composerVersion,
      "sourceTimelineFingerprint": fingerprint,
      "sourceAudioSamples": sourceAudioSamples,
      "sampleRate": sampleRate,
      "createdAt": payload["createdAt"] as? String ?? "",
      "fullText": fullText,
      "segmentCount": segments.count,
      "refinedSegmentCount": refinedTextByID.count,
      "fallbackSegmentCount": fallbackCount,
      "segments": segments,
    ]
    return ExportTextProjection(
      timeline: enrichedTimeline,
      canonicalText: canonicalText,
      status: status,
      defaultTextLayer: "refined",
      refinedTranscriptCount: refinedTextByID.count,
      fallbackTranscriptCount: fallbackCount
    )
  }

  private func liveTextProjection(
    timeline: [[String: Any]],
    status: String,
    fingerprint: String,
    sourceAudioSamples: Int64,
    sampleRate: Int
  ) -> ExportTextProjection {
    let enrichedTimeline = timeline.map { raw -> [String: Any] in
      guard raw["kind"] as? String == "transcript" else { return raw }
      var item = raw
      let liveText = item["text"] as? String ?? ""
      item["liveText"] = liveText
      item["refinedText"] = NSNull()
      item["displayText"] = liveText
      item["textLayer"] = "live"
      return item
    }
    let segments = canonicalTextSegments(enrichedTimeline)
    let fullText = segments.compactMap { $0["text"] as? String }.joined(separator: "\n\n")
    let canonicalText: [String: Any] = [
      "schemaVersion": Self.canonicalTextSchemaVersion,
      "format": "org.hohu.momentai.canonical-text",
      "status": status,
      "defaultTextLayer": "live",
      "modelId": "",
      "composerVersion": 0,
      "sourceTimelineFingerprint": fingerprint,
      "sourceAudioSamples": sourceAudioSamples,
      "sampleRate": sampleRate,
      "createdAt": "",
      "fullText": fullText,
      "segmentCount": segments.count,
      "refinedSegmentCount": 0,
      "fallbackSegmentCount": 0,
      "segments": segments,
    ]
    return ExportTextProjection(
      timeline: enrichedTimeline,
      canonicalText: canonicalText,
      status: status,
      defaultTextLayer: "live",
      refinedTranscriptCount: 0,
      fallbackTranscriptCount: 0
    )
  }

  private func canonicalTextSegments(_ timeline: [[String: Any]]) -> [[String: Any]] {
    timeline.compactMap { item in
      guard item["kind"] as? String == "transcript" else { return nil }
      return [
        "segmentId": item["segmentId"] as? String ?? "",
        "startSample": (item["startSample"] as? NSNumber)?.int64Value ?? 0,
        "endSample": (item["endSample"] as? NSNumber)?.int64Value ?? 0,
        "startMs": (item["startMs"] as? NSNumber)?.int64Value ?? 0,
        "endMs": (item["endMs"] as? NSNumber)?.int64Value ?? 0,
        "text": item["displayText"] as? String ?? item["text"] as? String ?? "",
        "liveText": item["liveText"] as? String ?? item["text"] as? String ?? "",
        "rawText": item["rawText"] as? String ?? item["text"] as? String ?? "",
        "refinedText": item["refinedText"] ?? NSNull(),
        "textLayer": item["textLayer"] as? String ?? "live",
      ]
    }
  }

  static func sourceTimelineFingerprint(_ timeline: [[String: Any]]) throws -> String {
    try sourceTimelineFingerprint(timelineSources(timeline))
  }

  private static func timelineSources(_ timeline: [[String: Any]]) -> [ExportTimelineSource] {
    timeline.compactMap { item in
      guard item["kind"] as? String == "transcript",
        let segmentID = item["segmentId"] as? String,
        !segmentID.isEmpty,
        let startSample = (item["startSample"] as? NSNumber)?.int64Value,
        let endSample = (item["endSample"] as? NSNumber)?.int64Value,
        endSample > startSample,
        let text = item["text"] as? String,
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else {
        return nil
      }
      return ExportTimelineSource(
        segmentID: segmentID,
        startSample: startSample,
        endSample: endSample,
        text: text
      )
    }.sorted {
      if $0.startSample != $1.startSample { return $0.startSample < $1.startSample }
      if $0.endSample != $1.endSample { return $0.endSample < $1.endSample }
      return $0.segmentID < $1.segmentID
    }
  }

  private static func sourceTimelineFingerprint(
    _ sources: [ExportTimelineSource]
  ) throws -> String {
    var rows: [String] = []
    rows.reserveCapacity(sources.count)
    for source in sources {
      rows.append(
        "{\"segmentId\":\(try jsonString(source.segmentID)),"
          + "\"startSample\":\(source.startSample),"
          + "\"endSample\":\(source.endSample),"
          + "\"text\":\(try jsonString(source.text))}"
      )
    }
    let canonical = "[\(rows.joined(separator: ","))]"
    let digest = SHA256.hash(data: Data(canonical.utf8))
    return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
  }

  private static func jsonString(_ value: String) throws -> String {
    let data = try JSONSerialization.data(
      withJSONObject: [value],
      options: [.withoutEscapingSlashes]
    )
    guard let encoded = String(data: data, encoding: .utf8), encoded.count >= 2 else {
      throw SessionExportError.invalidArchive("Unable to encode canonical text fingerprint.")
    }
    return String(encoded.dropFirst().dropLast())
  }

  private func markdown(
    snapshot: [String: Any],
    audio: [String: Any],
    timeline: [[String: Any]],
    canonicalText: [String: Any],
    speakerText: [String: Any]? = nil,
    exportedAt: String
  ) -> String {
    let title = snapshot["title"] as? String ?? NativeStrings.text("export_recording")
    let sessionID = snapshot["sessionId"] as? String ?? ""
    let durationMs = ((audio["durationMs"] as? NSNumber)?.int64Value ?? 0)
    var lines = [
      "# \(escapeMarkdown(title))",
      "",
      "- Session: `\(sessionID)`",
      NativeStrings.text("export_status", snapshot["state"] as? String ?? "unknown"),
      NativeStrings.text("export_started", snapshot["startedAtWall"] as? String ?? ""),
      NativeStrings.text("export_ended", snapshot["stoppedAtWall"] as? String ?? ""),
      NativeStrings.text("export_duration", timeLabel(milliseconds: durationMs)),
      NativeStrings.text("export_exported", exportedAt),
      NativeStrings.text("export_layer", markdownTextLayer(canonicalText)),
      "",
      NativeStrings.text("export_audio_link"),
      "",
      NativeStrings.text("export_timeline"),
      "",
    ]
    if let speakerText {
      lines += [SpeakerTextContract.notice, ""]
      // Full continuous text is kept when its composition differs from segments.
      let rows = speakerText["segments"] as! [[String: Any]]
      if rows.map({ $0["text"] as! String }).joined(separator: "\n\n") != canonicalText["fullText"]
        as? String
      {
        lines += [canonicalText["fullText"] as? String ?? "", ""]
      }
    }
    let speakerRows = Dictionary(
      uniqueKeysWithValues: ((speakerText?["segments"] as? [[String: Any]]) ?? []).map {
        ($0["segmentId"] as! String, $0)
      })
    for item in timeline {
      let sample = (item["sampleOffset"] as? NSNumber)?.int64Value ?? 0
      let atMs =
        (item["atMs"] as? NSNumber)?.int64Value
        ?? (item["startMs"] as? NSNumber)?.int64Value
        ?? sample * 1_000 / 16_000
      let kind = item["kind"] as? String ?? "event"
      let type = item["type"] as? String ?? kind
      lines.append(
        "### \(timeLabel(milliseconds: atMs)) · \(markdownLabel(kind: kind, type: type))")
      lines.append("")
      lines.append("<!-- sample_offset: \(sample) -->")
      if let label = speakerRows[item["segmentId"] as? String ?? ""]?["label"] as? String {
        lines += ["", "[\(escapeMarkdown(label))]"]
      }
      let text =
        kind == "transcript"
        ? item["displayText"] as? String
        : item["text"] as? String
      if let text, !text.isEmpty {
        lines.append("")
        if type == "thought" {
          lines.append(
            contentsOf: text.split(separator: "\n", omittingEmptySubsequences: false)
              .map { "> \($0)" })
        } else {
          lines.append(text)
        }
      }
      if let mediaPath = item["mediaPath"] as? String {
        lines.append("")
        lines.append("![\(escapeMarkdown(type))](\(mediaPath))")
      }
      lines.append("")
    }
    return lines.joined(separator: "\n") + "\n"
  }

  private func writeJSON(_ value: Any, to url: URL, pretty: Bool) throws {
    var options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
    if pretty { options.insert(.prettyPrinted) }
    let data = try JSONSerialization.data(withJSONObject: value, options: options)
    try data.write(to: url, options: .atomic)
  }

  private func writeJSONL(
    _ timeline: [[String: Any]],
    sessionID: String,
    to url: URL
  ) throws {
    guard fileManager.createFile(atPath: url.path, contents: nil) else {
      throw SessionExportError.invalidArchive("Unable to create JSONL at \(url.path).")
    }
    let output = try FileHandle(forWritingTo: url)
    defer { output.closeFile() }
    for (index, item) in timeline.enumerated() {
      let row: [String: Any] = [
        "schemaVersion": Self.schemaVersion,
        "sessionId": sessionID,
        "index": index,
        "item": item,
      ]
      var data = try JSONSerialization.data(
        withJSONObject: row,
        options: [.sortedKeys, .withoutEscapingSlashes]
      )
      data.append(0x0A)
      output.write(data)
    }
    output.synchronizeFile()
  }

  private func artifact(path: String, url: URL) throws -> ExportArtifact {
    ExportArtifact(
      path: path,
      url: url,
      byteCount: try fileSize(url),
      sha256: try Self.sha256File(url)
    )
  }

  private func fileSize(_ url: URL) throws -> Int64 {
    let attributes = try fileManager.attributesOfItem(atPath: url.path)
    return (attributes[.size] as? NSNumber)?.int64Value ?? -1
  }

  private func wavHeader(pcmByteCount: UInt32) -> Data {
    var data = Data("RIFF".utf8)
    data.appendLittleEndian(UInt32(36) + pcmByteCount)
    data.append(Data("WAVEfmt ".utf8))
    data.appendLittleEndian(UInt32(16))
    data.appendLittleEndian(UInt16(1))
    data.appendLittleEndian(UInt16(1))
    data.appendLittleEndian(UInt32(16_000))
    data.appendLittleEndian(UInt32(32_000))
    data.appendLittleEndian(UInt16(2))
    data.appendLittleEndian(UInt16(16))
    data.append(Data("data".utf8))
    data.appendLittleEndian(pcmByteCount)
    return data
  }

  private func safeName(_ value: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
    let scalars = value.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "_" }
    let result = String(scalars)
    return result.isEmpty ? "session" : result
  }

  private func isSafeRelativePath(_ value: String) -> Bool {
    !value.isEmpty && !value.hasPrefix("/") && !value.contains("\\")
      && !value.split(separator: "/", omittingEmptySubsequences: false).contains("..")
  }

  private func timestamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyyMMdd_HHmmss_SSS"
    return formatter.string(from: date)
  }

  private func timeLabel(milliseconds: Int64) -> String {
    let hours = milliseconds / 3_600_000
    let minutes = (milliseconds / 60_000) % 60
    let seconds = (milliseconds / 1_000) % 60
    let millis = milliseconds % 1_000
    return String(format: "%02lld:%02lld:%02lld.%03lld", hours, minutes, seconds, millis)
  }

  private func markdownLabel(kind: String, type: String) -> String {
    if kind == "transcript" { return "Transcript" }
    switch type {
    case "thought": return NativeStrings.text("export_thought_event")
    case "bookmark": return NativeStrings.text("export_bookmark_event")
    case "image": return NativeStrings.text("export_photo")
    case "user_pause_began": return NativeStrings.text("export_pause")
    case "user_pause_ended": return NativeStrings.text("export_resume")
    default: return NativeStrings.text("export_event", escapeMarkdown(type))
    }
  }

  private func markdownTextLayer(_ canonicalText: [String: Any]) -> String {
    let status = canonicalText["status"] as? String ?? "live"
    let fallbackCount = (canonicalText["fallbackSegmentCount"] as? NSNumber)?.intValue ?? 0
    switch status {
    case "ready": return NativeStrings.text("export_refined_ready")
    case "partial": return NativeStrings.text("export_refined_partial", String(fallbackCount))
    case "stale": return NativeStrings.text("export_refined_stale")
    case "failed": return NativeStrings.text("export_refined_failed")
    default: return NativeStrings.text("export_live")
    }
  }

  private func escapeMarkdown(_ value: String) -> String {
    value
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "[", with: "\\[")
      .replacingOccurrences(of: "]", with: "\\]")
  }

  static func sha256File(_ url: URL) throws -> String {
    let input = try FileHandle(forReadingFrom: url)
    defer { input.closeFile() }
    var hasher = SHA256()
    while true {
      let data = input.readData(ofLength: 256 * 1_024)
      if data.isEmpty { break }
      hasher.update(data: data)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }
}

private struct ZIPCentralEntry {
  let pathData: Data
  let crc32: UInt32
  let size: UInt32
  let localOffset: UInt32
}

private final class StoredZIPWriter {
  func write(artifacts: [ExportArtifact], to url: URL) throws {
    guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
      throw SessionExportError.invalidArchive("Unable to create archive at \(url.path).")
    }
    let output = try FileHandle(forWritingTo: url)
    defer { output.closeFile() }
    var offset: UInt64 = 0
    var centralEntries: [ZIPCentralEntry] = []

    for artifact in artifacts {
      guard artifact.byteCount >= 0, artifact.byteCount <= Int64(UInt32.max) else {
        throw SessionExportError.invalidArchive(
          "Archive entry \(artifact.path) exceeds ZIP32 limits.")
      }
      let pathData = Data(artifact.path.utf8)
      guard pathData.count <= Int(UInt16.max), offset <= UInt64(UInt32.max) else {
        throw SessionExportError.invalidArchive("Archive metadata exceeds ZIP32 limits.")
      }
      let crc = try crc32(artifact.url)
      let size = UInt32(artifact.byteCount)
      let localOffset = UInt32(offset)
      var header = Data()
      header.appendLittleEndian(UInt32(0x0403_4B50))
      header.appendLittleEndian(UInt16(20))
      header.appendLittleEndian(UInt16(0x0800))
      header.appendLittleEndian(UInt16(0))
      header.appendLittleEndian(UInt16(0))
      header.appendLittleEndian(UInt16(0x0021))
      header.appendLittleEndian(crc)
      header.appendLittleEndian(size)
      header.appendLittleEndian(size)
      header.appendLittleEndian(UInt16(pathData.count))
      header.appendLittleEndian(UInt16(0))
      header.append(pathData)
      output.write(header)
      offset += UInt64(header.count)

      let input = try FileHandle(forReadingFrom: artifact.url)
      defer { input.closeFile() }
      while true {
        let data = input.readData(ofLength: 256 * 1_024)
        if data.isEmpty { break }
        output.write(data)
        offset += UInt64(data.count)
      }
      centralEntries.append(
        ZIPCentralEntry(pathData: pathData, crc32: crc, size: size, localOffset: localOffset)
      )
    }

    guard centralEntries.count <= Int(UInt16.max), offset <= UInt64(UInt32.max) else {
      throw SessionExportError.invalidArchive("Archive exceeds ZIP32 limits.")
    }
    let centralOffset = UInt32(offset)
    for entry in centralEntries {
      var header = Data()
      header.appendLittleEndian(UInt32(0x0201_4B50))
      header.appendLittleEndian(UInt16(20))
      header.appendLittleEndian(UInt16(20))
      header.appendLittleEndian(UInt16(0x0800))
      header.appendLittleEndian(UInt16(0))
      header.appendLittleEndian(UInt16(0))
      header.appendLittleEndian(UInt16(0x0021))
      header.appendLittleEndian(entry.crc32)
      header.appendLittleEndian(entry.size)
      header.appendLittleEndian(entry.size)
      header.appendLittleEndian(UInt16(entry.pathData.count))
      header.appendLittleEndian(UInt16(0))
      header.appendLittleEndian(UInt16(0))
      header.appendLittleEndian(UInt16(0))
      header.appendLittleEndian(UInt16(0))
      header.appendLittleEndian(UInt32(0))
      header.appendLittleEndian(entry.localOffset)
      header.append(entry.pathData)
      output.write(header)
      offset += UInt64(header.count)
    }
    let centralSize = UInt32(offset - UInt64(centralOffset))
    var end = Data()
    end.appendLittleEndian(UInt32(0x0605_4B50))
    end.appendLittleEndian(UInt16(0))
    end.appendLittleEndian(UInt16(0))
    end.appendLittleEndian(UInt16(centralEntries.count))
    end.appendLittleEndian(UInt16(centralEntries.count))
    end.appendLittleEndian(centralSize)
    end.appendLittleEndian(centralOffset)
    end.appendLittleEndian(UInt16(0))
    output.write(end)
    output.synchronizeFile()
  }

  private func crc32(_ url: URL) throws -> UInt32 {
    let input = try FileHandle(forReadingFrom: url)
    defer { input.closeFile() }
    var crc = UInt32.max
    while true {
      let data = input.readData(ofLength: 256 * 1_024)
      if data.isEmpty { break }
      for byte in data {
        let index = Int((crc ^ UInt32(byte)) & 0xFF)
        crc = Self.crcTable[index] ^ (crc >> 8)
      }
    }
    return crc ^ UInt32.max
  }

  private static let crcTable: [UInt32] = (0..<256).map { value in
    var crc = UInt32(value)
    for _ in 0..<8 {
      crc = (crc & 1) == 1 ? (0xEDB8_8320 ^ (crc >> 1)) : (crc >> 1)
    }
    return crc
  }
}

extension Data {
  fileprivate mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
    var littleEndian = value.littleEndian
    Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
  }
}
