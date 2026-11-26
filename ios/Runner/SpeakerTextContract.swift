import CoreFoundation
import CryptoKit
import Foundation

/// Portable speaker extension v1; canonical-text v1 stays byte-for-byte semantic compatible.
enum SpeakerTextContract {
  static let capability = "speakerDiarizationV1"
  static let fileName = "speaker_diarization.json"
  static let notice = "说话人按整段音频估计，不是逐字对齐；多人、重叠或归属不确定的段落不能确定每句话由谁说。"

  static func integer(_ map: [String: Any], _ key: String) throws -> Int64 {
    guard let n = map[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
      n.doubleValue.isFinite, n.doubleValue >= 0, n.doubleValue <= 9_007_199_254_740_991,
      n.doubleValue == Double(n.int64Value)
    else { throw SessionImportError("说话人整数字段无效：\(key)") }
    return n.int64Value
  }

  static func validate(_ doc: [String: Any], sessionID: String, samples: Int64) throws {
    guard try integer(doc, "schemaVersion") == 1, doc["status"] as? String == "ready",
      doc["sessionId"] as? String == sessionID,
      let model = doc["modelId"] as? String, !model.isEmpty, model.utf8.count <= 1024,
      doc["createdAt"] is String,
      try integer(doc, "sampleRate") == 16_000,
      try integer(doc, "sourceAudioSamples") == samples, samples > 0,
      let fingerprint = doc["sourceChunkFingerprint"] as? String,
      fingerprint.range(of: "^sha256:[0-9a-f]{64}$", options: .regularExpression) != nil,
      let segments = doc["segments"] as? [[String: Any]], segments.count <= 100_000
    else { throw SessionImportError("说话人结果来源或版本无效。") }
    let algorithm = try integer(
      doc.merging(["algorithmVersion": doc["algorithmVersion"] ?? 1]) { _, b in b },
      "algorithmVersion")
    guard (1...5).contains(algorithm) else { throw SessionImportError("说话人算法版本不受支持。") }
    for key in ["processingMs", "peakRssBytes", "windowCount"] { _ = try integer(doc, key) }
    guard let rtf = doc["realTimeFactor"] as? NSNumber,
      CFGetTypeID(rtf) != CFBooleanGetTypeID(), rtf.doubleValue.isFinite, rtf.doubleValue >= 0
    else { throw SessionImportError("说话人性能元数据无效。") }
    if let requested = doc["requestedSpeakerCount"], !(requested is NSNull) {
      guard try (1...12).contains(integer(doc, "requestedSpeakerCount")) else {
        throw SessionImportError("说话人数设置无效。")
      }
    }
    for s in segments {
      guard let id = s["speakerId"] as? String, id.utf8.count <= 80,
        id.range(of: "^speaker_[1-9][0-9]*$", options: .regularExpression) != nil,
        try integer(s, "startSample") < integer(s, "endSample"),
        try integer(s, "endSample") <= samples
      else { throw SessionImportError("说话人 sample 范围无效。") }
    }
    var states = [[String: Any]]()
    if let edits = doc["labelEdits"] {
      guard let edits = edits as? [String: Any], try integer(edits, "schemaVersion") == 1,
        let current = edits["current"] as? [String: Any],
        let history = edits["history"] as? [[String: Any]], history.count <= 20,
        try integer(edits, "revision") >= history.count
      else { throw SessionImportError("说话人修改历史无效。") }
      states = [current] + history
    }
    for state in states { try validateLabels(state, segments: segments) }
    if doc["speakerCount"] != nil {
      let labels = currentLabels(doc)
      let merged = labels["mergedInto"] as? [String: String] ?? [:]
      let ids = Set(
        segments.map { merged[$0["speakerId"] as! String] ?? ($0["speakerId"] as! String) })
      guard try integer(doc, "speakerCount") == ids.count else {
        throw SessionImportError("有效说话人数不一致。")
      }
    }
  }

  private static func validateLabels(_ state: [String: Any], segments: [[String: Any]]) throws {
    guard let names = state["names"] as? [String: String],
      let merged = state["mergedInto"] as? [String: String]
    else { throw SessionImportError("说话人名称或合并结构无效。") }
    let rawIDs = Set(segments.map { $0["speakerId"] as! String })
    for (a, b) in merged {
      guard rawIDs.contains(a), rawIDs.contains(b), a != b, merged[b] == nil else {
        throw SessionImportError("说话人合并引用无效。")
      }
    }
    let active = Set(rawIDs.map { merged[$0] ?? $0 })
    for (id, name) in names {
      guard active.contains(id), !name.isEmpty,
        name == name.trimmingCharacters(in: .whitespacesAndNewlines),
        name.unicodeScalars.count <= 40,
        !name.unicodeScalars.contains(where: {
          $0.value < 32 || $0.value == 127 || $0.value == 0x2028 || $0.value == 0x2029
        })
      else { throw SessionImportError("说话人名称无效。") }
    }
    guard Set(active.map { names[$0] ?? defaultName($0) }).count == active.count else {
      throw SessionImportError("说话人显示名称重复。")
    }
    // Check every historical state too: undo must never reveal an invalid merge.
    var activeEnds: [String: [String: Int64]] = [:]
    for s in segments.sorted(by: {
      ($0["startSample"] as! NSNumber).int64Value < ($1["startSample"] as! NSNumber).int64Value
    }) {
      let raw = s["speakerId"] as! String
      let effective = merged[raw] ?? raw
      let start = (s["startSample"] as! NSNumber).int64Value
      let end = (s["endSample"] as! NSNumber).int64Value
      var group = activeEnds[effective] ?? [:]
      guard !group.contains(where: { $0.key != raw && $0.value > start }) else {
        throw SessionImportError("不能合并同时发言的说话人。")
      }
      group[raw] = max(group[raw] ?? 0, end)
      activeEnds[effective] = group
    }
  }

  static func currentLabels(_ doc: [String: Any]) -> [String: Any] {
    (doc["labelEdits"] as? [String: Any])?["current"] as? [String: Any] ?? [:]
  }
  static func defaultName(_ id: String) -> String { "说话人 \(id.dropFirst(8))" }
  static func encoded(_ value: Any) throws -> String {
    String(
      decoding: try JSONSerialization.data(
        withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes]), as: UTF8.self
    )
  }
  static func hash(_ string: String) -> String {
    "sha256:" + SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
  }
  static func version(_ doc: [String: Any]) throws -> String {
    let labels = currentLabels(doc)
    func pairs(_ key: String) -> [[String]] {
      let map = labels[key] as? [String: String] ?? [:]
      return map.keys.sorted().map { [$0, map[$0]!] }
    }
    return try hash(
      encoded([
        1, doc["modelId"]!, doc["algorithmVersion"] ?? 1, doc["createdAt"]!,
        (doc["labelEdits"] as? [String: Any])?["revision"] ?? 0,
        (doc["segments"] as! [[String: Any]]).map {
          [$0["speakerId"]!, $0["startSample"]!, $0["endSample"]!]
        },
        pairs("names"), pairs("mergedInto"),
      ]))
  }

  static func projection(canonical: [String: Any], document: [String: Any]) throws -> [String: Any]
  {
    let labels = currentLabels(document)
    let names = labels["names"] as? [String: String] ?? [:]
    let merged = labels["mergedInto"] as? [String: String] ?? [:]
    let raw = (document["segments"] as! [[String: Any]]).sorted {
      ($0["startSample"] as! NSNumber).int64Value < ($1["startSample"] as! NSNumber).int64Value
    }
    let textRows = canonical["segments"] as! [[String: Any]]
    var next = 0
    var activeRaw: [[String: Any]] = []
    let projected = textRows.sorted {
      ($0["startSample"] as! NSNumber).int64Value < ($1["startSample"] as! NSNumber).int64Value
    }.map { text -> [String: Any] in
      let start = (text["startSample"] as! NSNumber).int64Value
      let end = (text["endSample"] as! NSNumber).int64Value
      var clips: [(id: String, start: Int64, end: Int64)] = []
      var durations: [String: Int64] = [:]
      activeRaw.removeAll { ($0["endSample"] as! NSNumber).int64Value <= start }
      while next < raw.count && (raw[next]["startSample"] as! NSNumber).int64Value < end {
        if (raw[next]["endSample"] as! NSNumber).int64Value > start { activeRaw.append(raw[next]) }
        next += 1
      }
      for s in activeRaw {
        let a = max(start, (s["startSample"] as! NSNumber).int64Value)
        let b = min(end, (s["endSample"] as! NSNumber).int64Value)
        if b <= a { continue }
        let id = merged[s["speakerId"] as! String] ?? (s["speakerId"] as! String)
        clips.append((id, a, b))
        durations[id, default: 0] += b - a
      }
      clips.sort { $0.start < $1.start }
      var active: [String: Int64] = [:]
      var covered: Int64 = 0
      var cursor = start
      var overlap = false
      for s in clips {
        if active.contains(where: { $0.key != s.id && $0.value > s.start }) { overlap = true }
        active[s.id] = max(active[s.id] ?? 0, s.end)
        let a = max(cursor, s.start)
        let b = max(a, s.end)
        covered += b - a
        cursor = b
      }
      let ids = durations.keys.sorted {
        durations[$0] == durations[$1] ? $0 < $1 : durations[$0]! > durations[$1]!
      }
      let displayNames = ids.map { names[$0] ?? defaultName($0) }
      let state =
        ids.isEmpty
        ? "unattributed"
        : overlap
          ? "overlap"
          : ids.count > 1 ? "multiple" : covered * 5 >= (end - start) * 4 ? "single" : "uncertain"
      let joined = displayNames.joined(separator: "、")
      let label: String
      switch state {
      case "single": label = joined
      case "multiple": label = "多人轮流：\(joined)"
      case "overlap": label = "多人 · 有重叠：\(joined)"
      case "uncertain": label = "归属不确定：\(joined)"
      default: label = "说话人未确定"
      }
      return [
        "segmentId": text["segmentId"]!, "startSample": start, "endSample": end,
        "text": text["text"]!, "textLayer": text["textLayer"]!, "speakerIds": ids,
        "displayNames": displayNames, "attribution": state, "coveredSamples": covered,
        "label": label,
      ]
    }
    let byID = Dictionary(uniqueKeysWithValues: projected.map { ($0["segmentId"] as! String, $0) })
    let rows = textRows.map { byID[$0["segmentId"] as! String]! }
    let textVersion = try hash(
      encoded([
        1, canonical["status"]!, canonical["defaultTextLayer"]!,
        canonical["modelId"]!, canonical["sourceTimelineFingerprint"]!, canonical["fullText"]!,
        (canonical["segments"] as! [[String: Any]]).map {
          [$0["segmentId"]!, $0["startSample"]!, $0["endSample"]!, $0["text"]!, $0["textLayer"]!]
        },
      ]))
    return [
      "schemaVersion": 1, "format": "org.hohu.momentai.speaker-text",
      "speakerVersion": try version(document), "textVersion": textVersion,
      "sourceTimelineFingerprint": canonical["sourceTimelineFingerprint"]!, "notice": notice,
      "fullText": canonical["fullText"]!, "segments": rows,
    ]
  }

  static func localFingerprint(store: SessionStore, destination: URL? = nil) throws -> String {
    let chunks = try store.committedChunks()
    let total = (chunks.last?["endSample"] as? NSNumber)?.int64Value ?? 0
    let types = Set([
      "audio_interruption_began", "audio_interruption_ended", "user_pause_began",
      "user_pause_ended",
    ])
    let boundaries = Set(
      try store.timeline().filter { types.contains($0["type"] as? String ?? "") }
        .compactMap { ($0["sampleOffset"] as? NSNumber)?.int64Value }.filter {
          $0 > 0 && $0 < total
        }
    ).sorted()
    let rows = try chunks.map { c -> String in
      var path = c["path"] as! String
      if let destination {
        path =
          destination.appendingPathComponent(
            "audio/" + URL(fileURLWithPath: path).lastPathComponent
          ).path
      }
      return
        "{\"index\":\(c["index"]!),\"path\":\(try encoded(path)),\"startSample\":\(c["startSample"]!),\"endSample\":\(c["endSample"]!),\"fileStartSample\":\(c["startSample"]!),\"sampleRate\":16000}"
    }
    return try hash(
      "{\"chunks\":[\(rows.joined(separator: ","))],\"boundaries\":\(encoded(boundaries))}")
  }

  static func load(store: SessionStore, directory: URL, samples: Int64) throws -> [String: Any]? {
    let file = directory.appendingPathComponent(fileName)
    guard FileManager.default.fileExists(atPath: file.path) else {
      if FileManager.default.fileExists(atPath: file.path + ".backup") {
        throw SessionImportError("说话人修改正在保存或等待恢复，请重新打开记录后导出。")
      }
      return nil
    }
    let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard size <= StoredZIPReader.maximumMetadataBytes,
      let doc = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
    else { throw SessionImportError("说话人结果文件损坏或过大。") }
    if doc["status"] as? String == "failed" { return nil }
    try validate(doc, sessionID: store.sessionID, samples: samples)
    guard try doc["sourceChunkFingerprint"] as? String == localFingerprint(store: store) else {
      throw SessionImportError("说话人结果已过期，请重新分析后再导出。")
    }
    return doc
  }

  static func rendered(_ projection: [String: Any]) -> String {
    let rows = projection["segments"] as! [[String: Any]]
    let paragraphs = rows.map { "[\($0["label"]!)] \($0["text"]!)" }.joined(separator: "\n\n")
    let raw = rows.map { $0["text"] as! String }.joined(separator: "\n\n")
    let full = projection["fullText"] as! String
    // Preserve continuous composition when it differs from the anchored text.
    let prefix = raw == full ? "" : "连续全文\n\n\(full)\n\n按段说话人\n\n"
    return "\(notice)\n\n\(prefix)\(paragraphs)"
  }
}
