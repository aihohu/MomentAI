import Foundation

enum RecoveryCoordinatorError: LocalizedError {
  case invalidState(String)

  var errorDescription: String? {
    switch self {
    case .invalidState(let state):
      return "Session in state \(state) is not eligible for recovery."
    }
  }
}

final class RecoveryCoordinator {
  private let fileManager = FileManager.default
  private let recoverableStates = Set([
    "preparing", "recording", "pausing", "paused", "resuming",
    "interrupted", "finalizing", "recovering",
  ])

  func scan(rootURL: URL) -> [[String: Any]] {
    guard
      let directories = try? fileManager.contentsOfDirectory(
        at: rootURL,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
      )
    else { return [] }

    return directories.compactMap { directory in
      guard let store = try? SessionStore(directoryURL: directory, create: false),
        let snapshot = try? store.snapshot(),
        let state = snapshot["state"] as? String,
        recoverableStates.contains(state)
      else {
        return nil
      }
      return recoveryPreview(directory: directory, snapshot: snapshot, store: store)
    }.sorted {
      ($0["startedAtWall"] as? String ?? "") > ($1["startedAtWall"] as? String ?? "")
    }
  }

  func recover(directoryPath: String) throws -> [String: Any] {
    let directory = URL(fileURLWithPath: directoryPath, isDirectory: true)
    let store = try SessionStore(directoryURL: directory, create: false)
    if let report = try store.recoveryReport() {
      // A persisted report proves this Session already entered the recovery
      // transaction. Re-running asset reconciliation is its idempotent repair
      // path for files that disappear after the first recovery.
      try reconcileCaptureAssets(directory: directory, store: store)
      return try result(store: store, report: report)
    }
    let snapshot = try store.snapshot()
    let state = snapshot["state"] as? String ?? "unknown"
    guard recoverableStates.contains(state) else {
      throw RecoveryCoordinatorError.invalidState(state)
    }

    // Claim recovery before touching assets. SessionStore rejects a concurrent
    // terminal transition, so a stale UI candidate cannot mutate that Session.
    try store.updateStatus("recovering")
    try store.closeOpenUserPause(
      sampleOffset: (snapshot["lastCommittedSample"] as? NSNumber)?.int64Value ?? 0,
      reason: "session_recovered"
    )
    try reconcileCaptureAssets(directory: directory, store: store)

    let audioDirectory = directory.appendingPathComponent("audio", isDirectory: true)
    let databaseChunks = try store.chunks()
    let files =
      (try? fileManager.contentsOfDirectory(
        at: audioDirectory,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
      )) ?? []

    let existingQuarantine = files.filter { $0.pathExtension == "quarantine" }
    var quarantined = existingQuarantine.count
    var discardedSamples = existingQuarantine.reduce(Int64(0)) { partial, file in
      partial + pcmSamples(at: file)
    }
    for file in files where file.pathExtension == "part" {
      discardedSamples += pcmSamples(at: file)
      let quarantine = file.appendingPathExtension("quarantine")
      try fileManager.moveItem(at: file, to: quarantine)
      quarantined += 1
    }

    let registeredPaths = Set(databaseChunks.values.map(\.path))
    for file in files where file.pathExtension == "pcm" {
      let relativePath = "audio/\(file.lastPathComponent)"
      guard !registeredPaths.contains(relativePath) else { continue }
      discardedSamples += pcmSamples(at: file)
      let quarantine = file.appendingPathExtension("quarantine")
      try fileManager.moveItem(at: file, to: quarantine)
      quarantined += 1
    }

    var contiguousSamples: Int64 = 0
    var index = 0
    var corruptChunks = 0
    while let chunk = databaseChunks[index] {
      let fileURL = directory.appendingPathComponent(chunk.path)
      guard let data = try? Data(contentsOf: fileURL),
        Int64(data.count) == chunk.byteCount,
        SessionStore.sha256(data) == chunk.sha256
      else {
        corruptChunks += 1
        break
      }
      contiguousSamples += chunk.sampleCount
      index += 1
    }

    corruptChunks = databaseChunks.values.filter { $0.index >= index }.count
    let corruptSamples = databaseChunks.values
      .filter { $0.index >= index }
      .reduce(Int64(0)) { $0 + $1.sampleCount }

    let probe = readProbe(directory: directory)
    let observedSamples = max(contiguousSamples, probe.observedSamples)
    let rpoSamples = max(
      max(0, observedSamples - contiguousSamples),
      max(discardedSamples, corruptSamples)
    )
    let rpoMs = Int64(Double(rpoSamples) / 16_000 * 1000)
    let hasGap = quarantined > 0 || corruptChunks > 0 || rpoSamples > 0
    let finalStatus = hasGap ? "completed_with_gaps" : "completed"

    let report = StoredRecoveryReport(
      status: finalStatus,
      lastCommittedSample: contiguousSamples,
      nextChunkIndex: index,
      observedSamples: observedSamples,
      discardedSamples: discardedSamples,
      rpoMs: rpoMs,
      quarantinedFiles: quarantined,
      corruptChunks: corruptChunks
    )
    try store.completeRecovery(report)
    store.checkpoint()
    return try result(store: store, report: report)
  }

  private func result(store: SessionStore, report: StoredRecoveryReport) throws -> [String: Any] {
    var snapshot = try store.snapshot()
    let persistedState = snapshot["state"] as? String
    snapshot["state"] =
      persistedState == "completed_with_gaps"
      ? "completed_with_gaps"
      : report.status
    snapshot["rpoMs"] = report.rpoMs
    snapshot["rpoPass"] = report.rpoMs <= 2_000
    snapshot["quarantinedFiles"] = report.quarantinedFiles
    snapshot["corruptChunks"] = report.corruptChunks
    snapshot["observedSamples"] = report.observedSamples
    snapshot["discardedSamples"] = report.discardedSamples
    let captureEvents = try store.timeline().filter { $0["kind"] as? String == "captureEvent" }
    snapshot["imageCommittedCount"] =
      captureEvents.filter {
        $0["type"] as? String == "image" && $0["captureState"] as? String == "committed"
      }.count
    snapshot["imageFailedCount"] =
      captureEvents.filter {
        $0["type"] as? String == "image" && $0["captureState"] as? String == "failed"
      }.count
    snapshot["capturePendingCount"] =
      captureEvents.filter {
        $0["captureState"] as? String == "pending"
      }.count
    return snapshot
  }

  private func reconcileCaptureAssets(directory: URL, store: SessionStore) throws {
    for asset in try store.captureAssets() where asset.type == "image" {
      let finalURL = directory.appendingPathComponent(asset.path)
      let partURL = finalURL.appendingPathExtension("part")

      if asset.captureState == "pending" || asset.assetState == "pending" {
        if fileManager.fileExists(atPath: finalURL.path) {
          do {
            let data = try Data(contentsOf: finalURL)
            guard isJPEG(data) else {
              try store.failCaptureEvent(
                eventID: asset.eventID,
                reason: "Pending image is not a complete JPEG.",
                assetState: "corrupt"
              )
              continue
            }
            _ = try store.commitImageCapture(
              eventID: asset.eventID,
              byteCount: Int64(data.count),
              sha256: SessionStore.sha256(data)
            )
          } catch {
            try store.failCaptureEvent(
              eventID: asset.eventID,
              reason: "Pending image recovery failed: \(error.localizedDescription)",
              assetState: "corrupt"
            )
          }
        } else if fileManager.fileExists(atPath: partURL.path) {
          try quarantine(partURL)
          try store.failCaptureEvent(
            eventID: asset.eventID,
            reason: "Incomplete image write was quarantined during recovery."
          )
        } else {
          try store.failCaptureEvent(
            eventID: asset.eventID,
            reason: "Pending image has no durable file.",
            assetState: "missing"
          )
        }
        continue
      }

      guard asset.captureState == "committed", asset.assetState == "committed" else { continue }
      guard fileManager.fileExists(atPath: finalURL.path) else {
        try store.invalidateCommittedCaptureEvent(
          eventID: asset.eventID,
          reason: "Committed image file is missing.",
          assetState: "missing"
        )
        continue
      }
      let data = try Data(contentsOf: finalURL)
      guard isJPEG(data),
        Int64(data.count) == asset.byteCount,
        SessionStore.sha256(data) == asset.sha256
      else {
        try store.invalidateCommittedCaptureEvent(
          eventID: asset.eventID,
          reason: "Committed image failed size, hash, or JPEG validation.",
          assetState: "corrupt"
        )
        continue
      }
    }
  }

  private func isJPEG(_ data: Data) -> Bool {
    data.count >= 4
      && data[data.startIndex] == 0xFF
      && data[data.startIndex + 1] == 0xD8
      && data[data.endIndex - 2] == 0xFF
      && data[data.endIndex - 1] == 0xD9
  }

  private func quarantine(_ fileURL: URL) throws {
    var quarantineURL = fileURL.appendingPathExtension("quarantine")
    if fileManager.fileExists(atPath: quarantineURL.path) {
      quarantineURL =
        fileURL
        .appendingPathExtension(UUID().uuidString.lowercased())
        .appendingPathExtension("quarantine")
    }
    try fileManager.moveItem(at: fileURL, to: quarantineURL)
  }

  private func pcmSamples(at file: URL) -> Int64 {
    let bytes = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    return Int64(bytes / MemoryLayout<Int16>.size)
  }

  private func recoveryPreview(
    directory: URL,
    snapshot: [String: Any],
    store: SessionStore
  ) -> [String: Any] {
    var preview = snapshot
    let committedSamples = snapshot["lastCommittedSample"] as? Int64 ?? 0
    let probe = readProbe(directory: directory)
    let observedSamples = max(committedSamples, probe.observedSamples)
    let audioDirectory = directory.appendingPathComponent("audio", isDirectory: true)
    let files =
      (try? fileManager.contentsOfDirectory(
        at: audioDirectory,
        includingPropertiesForKeys: [.fileSizeKey],
        options: [.skipsHiddenFiles]
      )) ?? []
    let registeredPaths = Set(((try? store.chunks()) ?? [:]).values.map(\.path))
    let discardedSamples = files.reduce(Int64(0)) { partial, file in
      let isPartialOrQuarantined =
        file.pathExtension == "part" || file.pathExtension == "quarantine"
      let isOrphanPCM =
        file.pathExtension == "pcm"
        && !registeredPaths.contains("audio/\(file.lastPathComponent)")
      return partial + ((isPartialOrQuarantined || isOrphanPCM) ? pcmSamples(at: file) : 0)
    }
    let rpoSamples = max(max(0, observedSamples - committedSamples), discardedSamples)
    let rpoMs = Int64(Double(rpoSamples) / 16_000 * 1000)
    preview["observedSamples"] = observedSamples
    preview["discardedSamples"] = discardedSamples
    preview["rpoMs"] = rpoMs
    preview["rpoPass"] = rpoMs <= 2_000
    preview["probeWallTime"] = probe.wallTime
    let captureEvents =
      (try? store.timeline())?.filter {
        $0["kind"] as? String == "captureEvent"
      } ?? []
    preview["imageCommittedCount"] =
      captureEvents.filter {
        $0["type"] as? String == "image" && $0["captureState"] as? String == "committed"
      }.count
    preview["imagePendingCount"] =
      captureEvents.filter {
        $0["type"] as? String == "image" && $0["captureState"] as? String == "pending"
      }.count
    return preview
  }

  private func readProbe(directory: URL) -> (observedSamples: Int64, wallTime: String) {
    let url = directory.appendingPathComponent("capture_highwater.probe.json")
    guard let data = try? Data(contentsOf: url),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return (0, "")
    }
    let observed = (object["observed_samples"] as? NSNumber)?.int64Value ?? 0
    let wallTime = object["wall_time"] as? String ?? ""
    return (observed, wallTime)
  }
}
