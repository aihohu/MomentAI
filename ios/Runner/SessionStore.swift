import CryptoKit
import Foundation
import SQLite3

enum SessionStoreError: LocalizedError {
  case sqlite(String)
  case invalidSession
  case invalidStateTransition(from: String, to: String)
  case invalidTitle(String)
  case invalidThought(String)

  var errorDescription: String? {
    switch self {
    case .sqlite(let message): return message
    case .invalidSession: return "Session metadata is missing or invalid."
    case .invalidStateTransition(let from, let to):
      return "Invalid Session state transition from \(from) to \(to)."
    case .invalidTitle(let message): return message
    case .invalidThought(let message): return message
    }
  }
}

struct StoredChunk {
  let index: Int
  let path: String
  let sampleCount: Int64
  let byteCount: Int64
  let sha256: String
}

struct StoredRecoveryReport {
  let status: String
  let lastCommittedSample: Int64
  let nextChunkIndex: Int
  let observedSamples: Int64
  let discardedSamples: Int64
  let rpoMs: Int64
  let quarantinedFiles: Int
  let corruptChunks: Int
}

struct ClockSnapshot {
  let sampleOffset: Int64
  let atMs: Int64
  let monotonicElapsedNs: UInt64
  let wallTime: String
  let clockEpochID: String
}

struct StoredCaptureAsset {
  let eventID: String
  let type: String
  let sampleOffset: Int64
  let captureState: String
  let blobID: String
  let path: String
  let assetState: String
  let byteCount: Int64
  let sha256: String
}

final class SessionStore {
  static let maximumTitleCharacters = 120
  static let maximumThoughtCharacters = 4_000

  let directoryURL: URL
  let databaseURL: URL
  let sessionID: String

  private var database: OpaquePointer?

  init(directoryURL: URL, create: Bool, title: String? = nil) throws {
    self.directoryURL = directoryURL
    databaseURL = directoryURL.appendingPathComponent("session.sqlite")
    sessionID = directoryURL.lastPathComponent

    if create {
      try FileManager.default.createDirectory(
        at: directoryURL.appendingPathComponent("audio"),
        withIntermediateDirectories: true
      )
      try FileManager.default.createDirectory(
        at: directoryURL.appendingPathComponent("assets"),
        withIntermediateDirectories: true
      )
    }

    let openFlags =
      create
      ? SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
      : SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
    guard
      sqlite3_open_v2(
        databaseURL.path,
        &database,
        openFlags,
        nil
      ) == SQLITE_OK
    else {
      throw SessionStoreError.sqlite(
        "Unable to open SQLite store at \(databaseURL.lastPathComponent).")
    }

    // Configure the native busy handler before any PRAGMA or schema access.
    // Recovery ASR writes and timeline reads use separate serial queues, so a
    // newly opened connection must wait for a short-lived writer instead of
    // surfacing SQLITE_BUSY to Flutter.
    guard sqlite3_busy_timeout(database, 5_000) == SQLITE_OK else {
      throw SessionStoreError.sqlite(lastError())
    }
    // Setting journal_mode is a database write. Avoid reissuing it for every
    // short-lived timeline connection once this Session is already in WAL.
    if try scalarText("PRAGMA journal_mode;").lowercased() != "wal" {
      try execute("PRAGMA journal_mode=WAL;")
    }
    try execute("PRAGMA synchronous=FULL;")
    try execute("PRAGMA foreign_keys=ON;")
    if create {
      try createSchema()
      try insertSession(title: title ?? "Stage 0 PoC")
    } else if try scalarInt64("SELECT COUNT(*) FROM session;") == 0 {
      throw SessionStoreError.invalidSession
    }
  }

  deinit {
    sqlite3_close(database)
  }

  func checkpoint() {
    sqlite3_wal_checkpoint_v2(database, nil, SQLITE_CHECKPOINT_FULL, nil, nil)
  }

  func updateStatus(_ status: String, stopped: Bool = false) throws {
    let sql =
      stopped
      ? """
      UPDATE session SET status = ?, stopped_at_wall = ?
      WHERE id = ?
        AND (status NOT IN ('completed', 'completed_with_gaps', 'failed_to_start') OR status = ?);
      """
      : """
      UPDATE session SET status = ?
      WHERE id = ?
        AND (status NOT IN ('completed', 'completed_with_gaps', 'failed_to_start') OR status = ?);
      """
    let statement = try prepare(sql)
    defer { sqlite3_finalize(statement) }
    bindText(status, at: 1, in: statement)
    if stopped {
      bindText(ISO8601DateFormatter().string(from: Date()), at: 2, in: statement)
      bindText(sessionID, at: 3, in: statement)
      bindText(status, at: 4, in: statement)
    } else {
      bindText(sessionID, at: 2, in: statement)
      bindText(status, at: 3, in: statement)
    }
    try stepDone(statement)
    guard sqlite3_changes(database) == 1 else {
      let currentStatus = try scalarText("SELECT status FROM session LIMIT 1;")
      throw SessionStoreError.invalidStateTransition(from: currentStatus, to: status)
    }
  }

  func rename(title rawTitle: String) throws -> [String: Any] {
    let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else {
      throw SessionStoreError.invalidTitle("Session title cannot be empty.")
    }
    guard title.count <= Self.maximumTitleCharacters else {
      throw SessionStoreError.invalidTitle(
        "Session title cannot exceed \(Self.maximumTitleCharacters) characters."
      )
    }

    try execute("BEGIN IMMEDIATE;")
    do {
      let statement = try prepare("UPDATE session SET title = ? WHERE id = ?;")
      defer { sqlite3_finalize(statement) }
      bindText(title, at: 1, in: statement)
      bindText(sessionID, at: 2, in: statement)
      try stepDone(statement)
      try execute("COMMIT;")
    } catch {
      try? execute("ROLLBACK;")
      throw error
    }
    checkpoint()
    return try productSummary()
  }

  func commitChunk(
    index: Int,
    relativePath: String,
    sampleCount: Int64,
    byteCount: Int64,
    sha256: String,
    lastCommittedSample: Int64
  ) throws {
    try execute("BEGIN IMMEDIATE;")
    do {
      let insert = try prepare(
        """
        INSERT OR REPLACE INTO chunks(chunk_index, path, sample_count, byte_count, sha256, committed_at_wall)
        VALUES (?, ?, ?, ?, ?, ?);
        """
      )
      bindInt64(Int64(index), at: 1, in: insert)
      bindText(relativePath, at: 2, in: insert)
      bindInt64(sampleCount, at: 3, in: insert)
      bindInt64(byteCount, at: 4, in: insert)
      bindText(sha256, at: 5, in: insert)
      bindText(ISO8601DateFormatter().string(from: Date()), at: 6, in: insert)
      try stepDone(insert)
      sqlite3_finalize(insert)

      let update = try prepare(
        "UPDATE session SET last_committed_sample = ?, next_chunk_index = ? WHERE id = ?;"
      )
      bindInt64(lastCommittedSample, at: 1, in: update)
      bindInt64(Int64(index + 1), at: 2, in: update)
      bindText(sessionID, at: 3, in: update)
      try stepDone(update)
      sqlite3_finalize(update)
      try execute("COMMIT;")
    } catch {
      try? execute("ROLLBACK;")
      throw error
    }
  }

  func insertEvent(type: String, sampleOffset: Int64, payload: [String: Any] = [:]) throws {
    try insertEventRecord(
      type: type,
      sampleOffset: sampleOffset,
      wallTime: ISO8601DateFormatter().string(from: Date()),
      payload: payload
    )
  }

  func beginUserPause(
    pauseID: String,
    sampleOffset: Int64,
    startedAt: Date,
    monotonicElapsedNs: UInt64
  ) throws {
    try execute("BEGIN IMMEDIATE;")
    do {
      let currentStatus = try scalarText("SELECT status FROM session LIMIT 1;")
      guard currentStatus == "recording" else {
        throw SessionStoreError.invalidStateTransition(from: currentStatus, to: "paused")
      }
      let update = try prepare(
        "UPDATE session SET status = 'paused' WHERE id = ? AND status = 'recording';")
      defer { sqlite3_finalize(update) }
      bindText(sessionID, at: 1, in: update)
      try stepDone(update)
      guard sqlite3_changes(database) == 1 else {
        throw SessionStoreError.invalidStateTransition(from: currentStatus, to: "paused")
      }
      try insertEventRecord(
        type: "user_pause_began",
        sampleOffset: sampleOffset,
        wallTime: ISO8601DateFormatter().string(from: startedAt),
        payload: [
          "schema_version": 1,
          "pause_id": pauseID,
          "started_at_unix_ms": Int64(startedAt.timeIntervalSince1970 * 1_000),
          "monotonic_elapsed_ns": Int64(clamping: monotonicElapsedNs),
        ]
      )
      try execute("COMMIT;")
    } catch {
      try? execute("ROLLBACK;")
      throw error
    }
  }

  func resumeUserPause(
    pauseID: String,
    sampleOffset: Int64,
    startedAt: Date,
    endedAt: Date,
    monotonicElapsedNs: UInt64
  ) throws {
    try execute("BEGIN IMMEDIATE;")
    do {
      let currentStatus = try scalarText("SELECT status FROM session LIMIT 1;")
      guard currentStatus == "paused" else {
        throw SessionStoreError.invalidStateTransition(from: currentStatus, to: "recording")
      }
      let update = try prepare(
        "UPDATE session SET status = 'recording' WHERE id = ? AND status = 'paused';")
      defer { sqlite3_finalize(update) }
      bindText(sessionID, at: 1, in: update)
      try stepDone(update)
      guard sqlite3_changes(database) == 1 else {
        throw SessionStoreError.invalidStateTransition(from: currentStatus, to: "recording")
      }
      try insertUserPauseEnded(
        pauseID: pauseID,
        sampleOffset: sampleOffset,
        startedAt: startedAt,
        endedAt: endedAt,
        monotonicElapsedNs: monotonicElapsedNs,
        reason: "resumed"
      )
      try execute("COMMIT;")
    } catch {
      try? execute("ROLLBACK;")
      throw error
    }
  }

  func closeOpenUserPause(
    sampleOffset: Int64,
    reason: String,
    endedAt: Date = Date()
  ) throws {
    try execute("BEGIN IMMEDIATE;")
    do {
      if let openPause = try latestOpenUserPause() {
        let lastMonotonicElapsedNs = try latestStoredMonotonicElapsedNs()
        try insertUserPauseEnded(
          pauseID: openPause.pauseID,
          sampleOffset: sampleOffset,
          startedAt: openPause.startedAt,
          endedAt: endedAt,
          monotonicElapsedNs: lastMonotonicElapsedNs == UInt64.max
            ? UInt64.max
            : lastMonotonicElapsedNs + 1,
          reason: reason
        )
      }
      try execute("COMMIT;")
    } catch {
      try? execute("ROLLBACK;")
      throw error
    }
  }

  private func insertUserPauseEnded(
    pauseID: String,
    sampleOffset: Int64,
    startedAt: Date,
    endedAt: Date,
    monotonicElapsedNs: UInt64,
    reason: String
  ) throws {
    let durationMs = max(0, Int64(endedAt.timeIntervalSince(startedAt) * 1_000))
    try insertEventRecord(
      type: "user_pause_ended",
      sampleOffset: sampleOffset,
      wallTime: ISO8601DateFormatter().string(from: endedAt),
      payload: [
        "schema_version": 1,
        "pause_id": pauseID,
        "duration_ms": durationMs,
        "end_reason": reason,
        "monotonic_elapsed_ns": Int64(clamping: monotonicElapsedNs),
      ]
    )
  }

  private func latestOpenUserPause() throws -> (pauseID: String, startedAt: Date)? {
    let statement = try prepare(
      """
      SELECT b.wall_time, b.payload_json
      FROM events b
      WHERE b.type = 'user_pause_began'
        AND b.seq > COALESCE((
          SELECT MAX(e.seq) FROM events e WHERE e.type = 'user_pause_ended'
        ), 0)
      ORDER BY b.seq DESC LIMIT 1;
      """
    )
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
    let startedAtRaw = columnText(statement, 0)
    let payloadData = columnText(statement, 1).data(using: .utf8) ?? Data()
    let payload = (try? JSONSerialization.jsonObject(with: payloadData)) as? [String: Any]
    guard let pauseID = payload?["pause_id"] as? String, !pauseID.isEmpty else {
      throw SessionStoreError.sqlite("Stored user pause metadata is invalid.")
    }
    let startedAt: Date?
    if let milliseconds = payload?["started_at_unix_ms"] as? NSNumber {
      startedAt = Date(timeIntervalSince1970: milliseconds.doubleValue / 1_000)
    } else {
      startedAt = ISO8601DateFormatter().date(from: startedAtRaw)
    }
    guard let startedAt else {
      throw SessionStoreError.sqlite("Stored user pause start time is invalid.")
    }
    return (pauseID, startedAt)
  }

  private func latestStoredMonotonicElapsedNs() throws -> UInt64 {
    var latest = UInt64(
      max(
        0,
        try scalarInt64(
          "SELECT COALESCE(MAX(monotonic_elapsed_ns), 0) FROM capture_events;"
        )))
    let statement = try prepare("SELECT payload_json FROM events ORDER BY seq;")
    defer { sqlite3_finalize(statement) }
    while sqlite3_step(statement) == SQLITE_ROW {
      let data = columnText(statement, 0).data(using: .utf8) ?? Data()
      let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
      guard let value = payload?["monotonic_elapsed_ns"] as? NSNumber else { continue }
      latest = max(latest, UInt64(max(0, value.int64Value)))
    }
    return latest
  }

  private func insertEventRecord(
    type: String,
    sampleOffset: Int64,
    wallTime: String,
    payload: [String: Any]
  ) throws {
    let payloadData = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    let payloadJSON = String(data: payloadData, encoding: .utf8) ?? "{}"
    let statement = try prepare(
      "INSERT INTO events(type, sample_offset, wall_time, payload_json) VALUES (?, ?, ?, ?);"
    )
    defer { sqlite3_finalize(statement) }
    bindText(type, at: 1, in: statement)
    bindInt64(sampleOffset, at: 2, in: statement)
    bindText(wallTime, at: 3, in: statement)
    bindText(payloadJSON, at: 4, in: statement)
    try stepDone(statement)
  }

  func beginImageCapture(
    eventID: String,
    blobID: String,
    relativePath: String,
    clock: ClockSnapshot
  ) throws -> [String: Any] {
    try execute("BEGIN IMMEDIATE;")
    do {
      let now = ISO8601DateFormatter().string(from: Date())
      let asset = try prepare(
        """
        INSERT INTO media_assets(
          blob_id, session_id, kind, state, path, mime_type, byte_count,
          sha256, created_at_wall, updated_at_wall
        ) VALUES (?, ?, 'image', 'pending', ?, 'image/jpeg', 0, '', ?, ?);
        """
      )
      bindText(blobID, at: 1, in: asset)
      bindText(sessionID, at: 2, in: asset)
      bindText(relativePath, at: 3, in: asset)
      bindText(now, at: 4, in: asset)
      bindText(now, at: 5, in: asset)
      try stepDone(asset)
      sqlite3_finalize(asset)

      let event = try prepare(
        """
        INSERT INTO capture_events(
          event_id, session_id, type, sample_offset, at_ms,
          monotonic_elapsed_ns, wall_time, clock_epoch_id, capture_state,
          asset_blob_id, manual_adjustment, payload_json, created_at_wall,
          updated_at_wall
        ) VALUES (?, ?, 'image', ?, ?, ?, ?, ?, 'pending', ?, 0, '{}', ?, ?);
        """
      )
      bindText(eventID, at: 1, in: event)
      bindText(sessionID, at: 2, in: event)
      bindInt64(clock.sampleOffset, at: 3, in: event)
      bindInt64(clock.atMs, at: 4, in: event)
      bindInt64(Int64(clamping: clock.monotonicElapsedNs), at: 5, in: event)
      bindText(clock.wallTime, at: 6, in: event)
      bindText(clock.clockEpochID, at: 7, in: event)
      bindText(blobID, at: 8, in: event)
      bindText(now, at: 9, in: event)
      bindText(now, at: 10, in: event)
      try stepDone(event)
      sqlite3_finalize(event)
      try execute("COMMIT;")
      return captureEventResult(
        eventID: eventID,
        type: "image",
        state: "pending",
        clock: clock,
        blobID: blobID,
        relativePath: relativePath
      )
    } catch {
      try? execute("ROLLBACK;")
      throw error
    }
  }

  func commitImageCapture(
    eventID: String,
    byteCount: Int64,
    sha256: String
  ) throws -> [String: Any] {
    guard let stored = try captureAsset(eventID: eventID), stored.type == "image" else {
      throw SessionStoreError.invalidSession
    }
    if stored.captureState == "committed", stored.assetState == "committed" {
      guard stored.byteCount == byteCount, stored.sha256 == sha256 else {
        throw SessionStoreError.sqlite("Committed image metadata changed for \(eventID).")
      }
      return try captureEvent(eventID: eventID)
    }
    guard stored.captureState == "pending", stored.assetState == "pending" else {
      throw SessionStoreError.sqlite("Image event \(eventID) is not pending.")
    }

    try execute("BEGIN IMMEDIATE;")
    do {
      let now = ISO8601DateFormatter().string(from: Date())
      let asset = try prepare(
        """
        UPDATE media_assets SET state = 'committed', byte_count = ?, sha256 = ?,
          updated_at_wall = ? WHERE blob_id = ? AND state = 'pending';
        """
      )
      bindInt64(byteCount, at: 1, in: asset)
      bindText(sha256, at: 2, in: asset)
      bindText(now, at: 3, in: asset)
      bindText(stored.blobID, at: 4, in: asset)
      try stepDone(asset)
      sqlite3_finalize(asset)

      let event = try prepare(
        """
        UPDATE capture_events SET capture_state = 'committed', updated_at_wall = ?
        WHERE event_id = ? AND capture_state = 'pending';
        """
      )
      bindText(now, at: 1, in: event)
      bindText(eventID, at: 2, in: event)
      try stepDone(event)
      sqlite3_finalize(event)
      try execute("COMMIT;")
      return try captureEvent(eventID: eventID)
    } catch {
      try? execute("ROLLBACK;")
      throw error
    }
  }

  func failCaptureEvent(eventID: String, reason: String, assetState: String = "failed") throws {
    let payloadData = try JSONSerialization.data(
      withJSONObject: ["error": reason],
      options: [.sortedKeys]
    )
    let payloadJSON = String(data: payloadData, encoding: .utf8) ?? "{}"
    try execute("BEGIN IMMEDIATE;")
    do {
      let now = ISO8601DateFormatter().string(from: Date())
      let asset = try prepare(
        """
        UPDATE media_assets SET state = ?, updated_at_wall = ?
        WHERE blob_id = (SELECT asset_blob_id FROM capture_events WHERE event_id = ?)
          AND state <> 'committed';
        """
      )
      bindText(assetState, at: 1, in: asset)
      bindText(now, at: 2, in: asset)
      bindText(eventID, at: 3, in: asset)
      try stepDone(asset)
      sqlite3_finalize(asset)

      let event = try prepare(
        """
        UPDATE capture_events SET capture_state = 'failed', payload_json = ?, updated_at_wall = ?
        WHERE event_id = ? AND capture_state <> 'committed';
        """
      )
      bindText(payloadJSON, at: 1, in: event)
      bindText(now, at: 2, in: event)
      bindText(eventID, at: 3, in: event)
      try stepDone(event)
      sqlite3_finalize(event)
      try execute("COMMIT;")
    } catch {
      try? execute("ROLLBACK;")
      throw error
    }
  }

  func invalidateCommittedCaptureEvent(
    eventID: String,
    reason: String,
    assetState: String
  ) throws {
    guard ["missing", "corrupt"].contains(assetState) else {
      throw SessionStoreError.sqlite("Invalid committed asset state: \(assetState).")
    }
    let payloadData = try JSONSerialization.data(
      withJSONObject: ["error": reason, "recoveryInvalidated": true],
      options: [.sortedKeys]
    )
    let payloadJSON = String(data: payloadData, encoding: .utf8) ?? "{}"
    try execute("BEGIN IMMEDIATE;")
    do {
      let now = ISO8601DateFormatter().string(from: Date())
      let asset = try prepare(
        """
        UPDATE media_assets SET state = ?, updated_at_wall = ?
        WHERE blob_id = (SELECT asset_blob_id FROM capture_events WHERE event_id = ?)
          AND state = 'committed';
        """
      )
      bindText(assetState, at: 1, in: asset)
      bindText(now, at: 2, in: asset)
      bindText(eventID, at: 3, in: asset)
      try stepDone(asset)
      sqlite3_finalize(asset)

      let event = try prepare(
        """
        UPDATE capture_events SET capture_state = 'failed', payload_json = ?, updated_at_wall = ?
        WHERE event_id = ? AND capture_state = 'committed';
        """
      )
      bindText(payloadJSON, at: 1, in: event)
      bindText(now, at: 2, in: event)
      bindText(eventID, at: 3, in: event)
      try stepDone(event)
      sqlite3_finalize(event)
      try execute("COMMIT;")
    } catch {
      try? execute("ROLLBACK;")
      throw error
    }
  }

  func commitBookmark(eventID: String, clock: ClockSnapshot) throws -> [String: Any] {
    let now = ISO8601DateFormatter().string(from: Date())
    let statement = try prepare(
      """
      INSERT INTO capture_events(
        event_id, session_id, type, sample_offset, at_ms,
        monotonic_elapsed_ns, wall_time, clock_epoch_id, capture_state,
        asset_blob_id, manual_adjustment, payload_json, created_at_wall,
        updated_at_wall
      ) VALUES (?, ?, 'bookmark', ?, ?, ?, ?, ?, 'committed', NULL, 0, '{}', ?, ?);
      """
    )
    defer { sqlite3_finalize(statement) }
    bindText(eventID, at: 1, in: statement)
    bindText(sessionID, at: 2, in: statement)
    bindInt64(clock.sampleOffset, at: 3, in: statement)
    bindInt64(clock.atMs, at: 4, in: statement)
    bindInt64(Int64(clamping: clock.monotonicElapsedNs), at: 5, in: statement)
    bindText(clock.wallTime, at: 6, in: statement)
    bindText(clock.clockEpochID, at: 7, in: statement)
    bindText(now, at: 8, in: statement)
    bindText(now, at: 9, in: statement)
    try stepDone(statement)
    return captureEventResult(
      eventID: eventID,
      type: "bookmark",
      state: "committed",
      clock: clock,
      blobID: nil,
      relativePath: nil
    )
  }

  func commitThought(
    eventID: String,
    text: String,
    clock: ClockSnapshot
  ) throws -> [String: Any] {
    let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !eventID.isEmpty,
      !normalized.isEmpty,
      normalized.count <= Self.maximumThoughtCharacters
    else {
      throw SessionStoreError.invalidThought(
        "Thought text must contain 1–\(Self.maximumThoughtCharacters) characters."
      )
    }
    let committedSample = try scalarInt64(
      "SELECT last_committed_sample FROM session LIMIT 1;"
    )
    guard clock.sampleOffset <= committedSample else {
      throw SessionStoreError.sqlite(
        "Thought anchor \(clock.sampleOffset) exceeds committed audio \(committedSample)."
      )
    }

    let payloadData = try JSONSerialization.data(
      withJSONObject: [
        "text": normalized,
        "source": "user_text",
      ],
      options: [.sortedKeys]
    )
    let payloadJSON = String(data: payloadData, encoding: .utf8) ?? "{}"
    try execute("BEGIN IMMEDIATE;")
    do {
      let now = ISO8601DateFormatter().string(from: Date())
      let statement = try prepare(
        """
        INSERT OR IGNORE INTO capture_events(
          event_id, session_id, type, sample_offset, at_ms,
          monotonic_elapsed_ns, wall_time, clock_epoch_id, capture_state,
          asset_blob_id, manual_adjustment, payload_json, created_at_wall,
          updated_at_wall
        ) VALUES (?, ?, 'thought', ?, ?, ?, ?, ?, 'committed', NULL, 0, ?, ?, ?);
        """
      )
      defer { sqlite3_finalize(statement) }
      bindText(eventID, at: 1, in: statement)
      bindText(sessionID, at: 2, in: statement)
      bindInt64(clock.sampleOffset, at: 3, in: statement)
      bindInt64(clock.atMs, at: 4, in: statement)
      bindInt64(Int64(clamping: clock.monotonicElapsedNs), at: 5, in: statement)
      bindText(clock.wallTime, at: 6, in: statement)
      bindText(clock.clockEpochID, at: 7, in: statement)
      bindText(payloadJSON, at: 8, in: statement)
      bindText(now, at: 9, in: statement)
      bindText(now, at: 10, in: statement)
      try stepDone(statement)

      let committed = try captureEvent(eventID: eventID)
      guard committed["type"] as? String == "thought",
        committed["captureState"] as? String == "committed",
        let storedPayload = committed["payload"] as? [String: Any],
        storedPayload["text"] as? String == normalized,
        storedPayload["source"] as? String == "user_text"
      else {
        throw SessionStoreError.sqlite("Thought idempotency conflict for \(eventID).")
      }
      try execute("COMMIT;")
      return committed
    } catch {
      try? execute("ROLLBACK;")
      throw error
    }
  }

  func captureAssets() throws -> [StoredCaptureAsset] {
    let statement = try prepare(
      """
      SELECT e.event_id, e.type, e.sample_offset, e.capture_state,
             a.blob_id, a.path, a.state, a.byte_count, a.sha256
      FROM capture_events e JOIN media_assets a ON a.blob_id = e.asset_blob_id
      ORDER BY e.seq;
      """
    )
    defer { sqlite3_finalize(statement) }
    var result: [StoredCaptureAsset] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      result.append(storedCaptureAsset(statement))
    }
    return result
  }

  func captureAsset(eventID: String) throws -> StoredCaptureAsset? {
    let statement = try prepare(
      """
      SELECT e.event_id, e.type, e.sample_offset, e.capture_state,
             a.blob_id, a.path, a.state, a.byte_count, a.sha256
      FROM capture_events e JOIN media_assets a ON a.blob_id = e.asset_blob_id
      WHERE e.event_id = ? LIMIT 1;
      """
    )
    defer { sqlite3_finalize(statement) }
    bindText(eventID, at: 1, in: statement)
    guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
    return storedCaptureAsset(statement)
  }

  func chunks() throws -> [Int: StoredChunk] {
    let statement = try prepare(
      "SELECT chunk_index, path, sample_count, byte_count, sha256 FROM chunks ORDER BY chunk_index;"
    )
    defer { sqlite3_finalize(statement) }
    var result: [Int: StoredChunk] = [:]
    while sqlite3_step(statement) == SQLITE_ROW {
      let index = Int(sqlite3_column_int64(statement, 0))
      result[index] = StoredChunk(
        index: index,
        path: columnText(statement, 1),
        sampleCount: sqlite3_column_int64(statement, 2),
        byteCount: sqlite3_column_int64(statement, 3),
        sha256: columnText(statement, 4)
      )
    }
    return result
  }

  func committedChunks(afterSample: Int64 = 0) throws -> [[String: Any]] {
    let ordered = try chunks().values.sorted { $0.index < $1.index }
    var startSample: Int64 = 0
    var result: [[String: Any]] = []
    for chunk in ordered {
      let endSample = startSample + chunk.sampleCount
      if endSample > afterSample {
        result.append([
          "sessionId": sessionID,
          "directory": directoryURL.path,
          "index": chunk.index,
          "path": directoryURL.appendingPathComponent(chunk.path).path,
          "startSample": startSample,
          "endSample": endSample,
          "sampleCount": chunk.sampleCount,
          "sampleRate": 16_000,
        ])
      }
      startSample = endSample
    }
    return result
  }

  func commitTranscriptSegment(_ segment: [String: Any]) throws -> [String: Any] {
    guard let segmentID = segment["segmentId"] as? String, !segmentID.isEmpty,
      let segmentSessionID = segment["sessionId"] as? String,
      segmentSessionID == sessionID,
      let startNumber = segment["startSample"] as? NSNumber,
      let endNumber = segment["endSample"] as? NSNumber,
      let text = segment["text"] as? String,
      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw SessionStoreError.invalidSession
    }

    let startSample = startNumber.int64Value
    let endSample = endNumber.int64Value
    let committedSample = try scalarInt64("SELECT last_committed_sample FROM session LIMIT 1;")
    guard startSample >= 0, endSample >= startSample, endSample <= committedSample else {
      throw SessionStoreError.sqlite(
        "Transcript range \(startSample)...\(endSample) exceeds committed audio \(committedSample)."
      )
    }

    let startMs = startSample * 1_000 / 16_000
    let endMs = endSample * 1_000 / 16_000
    let rawText = (segment["rawText"] as? String) ?? text
    let language = (segment["language"] as? String) ?? "zh"
    let source = (segment["source"] as? String) ?? "sherpa_onnx"
    let modelID = (segment["modelId"] as? String) ?? "unknown"
    let isFinal = (segment["isFinal"] as? Bool) ?? true
    let createdAt = ISO8601DateFormatter().string(from: Date())

    let statement = try prepare(
      """
      INSERT INTO transcript_segments(
        segment_id, session_id, start_sample, end_sample, start_ms, end_ms,
        text, raw_text, language, source, model_id, is_final, created_at_wall
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(segment_id) DO UPDATE SET
        text = excluded.text,
        is_final = MAX(transcript_segments.is_final, excluded.is_final)
      WHERE excluded.text <> '';
      """
    )
    defer { sqlite3_finalize(statement) }
    bindText(segmentID, at: 1, in: statement)
    bindText(sessionID, at: 2, in: statement)
    bindInt64(startSample, at: 3, in: statement)
    bindInt64(endSample, at: 4, in: statement)
    bindInt64(startMs, at: 5, in: statement)
    bindInt64(endMs, at: 6, in: statement)
    bindText(text, at: 7, in: statement)
    bindText(rawText, at: 8, in: statement)
    bindText(language, at: 9, in: statement)
    bindText(source, at: 10, in: statement)
    bindText(modelID, at: 11, in: statement)
    bindInt64(isFinal ? 1 : 0, at: 12, in: statement)
    bindText(createdAt, at: 13, in: statement)
    try stepDone(statement)

    return [
      "kind": "transcript",
      "segmentId": segmentID,
      "sessionId": sessionID,
      "sampleOffset": startSample,
      "startSample": startSample,
      "endSample": endSample,
      "startMs": startMs,
      "endMs": endMs,
      "text": text,
      "rawText": rawText,
      "language": language,
      "source": source,
      "modelId": modelID,
      "isFinal": isFinal,
      "wallTime": createdAt,
    ]
  }

  func timeline() throws -> [[String: Any]] {
    var items: [[String: Any]] = []

    let transcriptStatement = try prepare(
      """
      SELECT segment_id, start_sample, end_sample, start_ms, end_ms, text,
             raw_text, language, source, model_id, is_final, created_at_wall
      FROM transcript_segments ORDER BY start_sample, created_at_wall;
      """
    )
    defer { sqlite3_finalize(transcriptStatement) }
    while sqlite3_step(transcriptStatement) == SQLITE_ROW {
      items.append([
        "kind": "transcript",
        "segmentId": columnText(transcriptStatement, 0),
        "sessionId": sessionID,
        "sampleOffset": sqlite3_column_int64(transcriptStatement, 1),
        "startSample": sqlite3_column_int64(transcriptStatement, 1),
        "endSample": sqlite3_column_int64(transcriptStatement, 2),
        "startMs": sqlite3_column_int64(transcriptStatement, 3),
        "endMs": sqlite3_column_int64(transcriptStatement, 4),
        "text": columnText(transcriptStatement, 5),
        "rawText": columnText(transcriptStatement, 6),
        "language": columnText(transcriptStatement, 7),
        "source": columnText(transcriptStatement, 8),
        "modelId": columnText(transcriptStatement, 9),
        "isFinal": sqlite3_column_int64(transcriptStatement, 10) == 1,
        "wallTime": columnText(transcriptStatement, 11),
      ])
    }

    let captureStatement = try prepare(
      """
      SELECT e.seq, e.event_id, e.type, e.sample_offset, e.at_ms,
             e.monotonic_elapsed_ns, e.wall_time, e.clock_epoch_id,
             e.capture_state, COALESCE(a.blob_id, ''), COALESCE(a.path, ''),
             COALESCE(a.state, ''), COALESCE(a.mime_type, ''),
             COALESCE(a.byte_count, 0), COALESCE(a.sha256, ''), e.payload_json
      FROM capture_events e
      LEFT JOIN media_assets a ON a.blob_id = e.asset_blob_id
      ORDER BY e.seq;
      """
    )
    defer { sqlite3_finalize(captureStatement) }
    while sqlite3_step(captureStatement) == SQLITE_ROW {
      items.append(captureEventDictionary(captureStatement))
    }

    let eventStatement = try prepare(
      "SELECT seq, type, sample_offset, wall_time, payload_json FROM events ORDER BY seq;"
    )
    defer { sqlite3_finalize(eventStatement) }
    while sqlite3_step(eventStatement) == SQLITE_ROW {
      let payloadJSON = columnText(eventStatement, 4)
      let payloadData = payloadJSON.data(using: .utf8) ?? Data()
      let payload = (try? JSONSerialization.jsonObject(with: payloadData)) ?? [:]
      let payloadDictionary = payload as? [String: Any]
      items.append([
        "kind": "event",
        "sequence": sqlite3_column_int64(eventStatement, 0),
        "type": columnText(eventStatement, 1),
        "sampleOffset": sqlite3_column_int64(eventStatement, 2),
        "atMs": sqlite3_column_int64(eventStatement, 2) * 1_000 / 16_000,
        "monotonicElapsedNs": (payloadDictionary?["monotonic_elapsed_ns"] as? NSNumber)?.int64Value
          ?? 0,
        "wallTime": columnText(eventStatement, 3),
        "payload": payload,
      ])
    }

    return items.sorted {
      let lhsSample = ($0["sampleOffset"] as? NSNumber)?.int64Value ?? 0
      let rhsSample = ($1["sampleOffset"] as? NSNumber)?.int64Value ?? 0
      if lhsSample != rhsSample { return lhsSample < rhsSample }
      let lhsMonotonic = ($0["monotonicElapsedNs"] as? NSNumber)?.int64Value ?? 0
      let rhsMonotonic = ($1["monotonicElapsedNs"] as? NSNumber)?.int64Value ?? 0
      if lhsMonotonic != rhsMonotonic { return lhsMonotonic < rhsMonotonic }
      if ($0["kind"] as? String) != ($1["kind"] as? String) {
        return ($0["kind"] as? String) == "event"
      }
      let lhsSequence = ($0["sequence"] as? NSNumber)?.int64Value ?? 0
      let rhsSequence = ($1["sequence"] as? NSNumber)?.int64Value ?? 0
      return lhsSequence < rhsSequence
    }
  }

  func recoveryReport() throws -> StoredRecoveryReport? {
    let statement = try prepare(
      """
      SELECT status, last_committed_sample, next_chunk_index, observed_samples,
             discarded_samples, rpo_ms, quarantined_files, corrupt_chunks
      FROM recovery_report WHERE session_id = ? LIMIT 1;
      """
    )
    defer { sqlite3_finalize(statement) }
    bindText(sessionID, at: 1, in: statement)
    guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
    return StoredRecoveryReport(
      status: columnText(statement, 0),
      lastCommittedSample: sqlite3_column_int64(statement, 1),
      nextChunkIndex: Int(sqlite3_column_int64(statement, 2)),
      observedSamples: sqlite3_column_int64(statement, 3),
      discardedSamples: sqlite3_column_int64(statement, 4),
      rpoMs: sqlite3_column_int64(statement, 5),
      quarantinedFiles: Int(sqlite3_column_int64(statement, 6)),
      corruptChunks: Int(sqlite3_column_int64(statement, 7))
    )
  }

  func snapshot() throws -> [String: Any] {
    let statement = try prepare(
      """
      SELECT id, title, status, started_at_wall, COALESCE(stopped_at_wall, ''),
             sample_rate, last_committed_sample, next_chunk_index, recovery_count
      FROM session LIMIT 1;
      """
    )
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else {
      throw SessionStoreError.invalidSession
    }
    return [
      "sessionId": columnText(statement, 0),
      "title": columnText(statement, 1),
      "state": columnText(statement, 2),
      "startedAtWall": columnText(statement, 3),
      "stoppedAtWall": columnText(statement, 4),
      "sampleRate": sqlite3_column_int64(statement, 5),
      "lastCommittedSample": sqlite3_column_int64(statement, 6),
      "chunkCount": sqlite3_column_int64(statement, 7),
      "recoveryCount": sqlite3_column_int64(statement, 8),
      "directory": directoryURL.path,
    ]
  }

  func productSummary() throws -> [String: Any] {
    let snapshot = try snapshot()
    let persistedState = snapshot["state"] as? String ?? "unknown"
    let state = effectiveProductState(persistedState: persistedState)
    let sampleRate = max((snapshot["sampleRate"] as? NSNumber)?.int64Value ?? 16_000, 1)
    let durationSamples = (snapshot["lastCommittedSample"] as? NSNumber)?.int64Value ?? 0
    let transcriptCount = try scalarInt64(
      "SELECT COUNT(*) FROM transcript_segments WHERE is_final = 1;"
    )
    let imageCount = try scalarInt64(
      "SELECT COUNT(*) FROM capture_events WHERE type = 'image' AND capture_state = 'committed';"
    )
    let thoughtCount = try scalarInt64(
      "SELECT COUNT(*) FROM capture_events WHERE type = 'thought' AND capture_state = 'committed';"
    )
    let bookmarkCount = try scalarInt64(
      "SELECT COUNT(*) FROM capture_events WHERE type = 'bookmark' AND capture_state = 'committed';"
    )
    let exportAvailable =
      ["completed", "completed_with_gaps"].contains(state)
      && durationSamples > 0

    return [
      "sessionId": snapshot["sessionId"] ?? sessionID,
      "directory": directoryURL.path,
      "title": snapshot["title"] ?? "",
      "state": state,
      "persistedState": persistedState,
      "statusReconciledForDisplay": state != persistedState,
      "startedAtWall": snapshot["startedAtWall"] ?? "",
      "stoppedAtWall": snapshot["stoppedAtWall"] ?? "",
      "sampleRate": sampleRate,
      "durationSamples": durationSamples,
      "durationMs": durationSamples * 1_000 / sampleRate,
      "chunkCount": snapshot["chunkCount"] ?? 0,
      "transcriptCount": transcriptCount,
      "imageCount": imageCount,
      "thoughtCount": thoughtCount,
      "bookmarkCount": bookmarkCount,
      "recoveryCount": snapshot["recoveryCount"] ?? 0,
      "hasConfirmedGaps": state == "completed_with_gaps",
      "exportAvailable": exportAvailable,
    ]
  }

  func completeRecovery(_ report: StoredRecoveryReport) throws {
    try execute("BEGIN IMMEDIATE;")
    do {
      let currentStatus = try scalarText("SELECT status FROM session LIMIT 1;")
      guard currentStatus == "recovering" else {
        throw SessionStoreError.invalidStateTransition(
          from: currentStatus,
          to: report.status
        )
      }
      let now = ISO8601DateFormatter().string(from: Date())
      let insert = try prepare(
        """
        INSERT INTO recovery_report(
          session_id, status, last_committed_sample, next_chunk_index,
          observed_samples, discarded_samples, rpo_ms, quarantined_files,
          corrupt_chunks, completed_at_wall
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
      )
      bindText(sessionID, at: 1, in: insert)
      bindText(report.status, at: 2, in: insert)
      bindInt64(report.lastCommittedSample, at: 3, in: insert)
      bindInt64(Int64(report.nextChunkIndex), at: 4, in: insert)
      bindInt64(report.observedSamples, at: 5, in: insert)
      bindInt64(report.discardedSamples, at: 6, in: insert)
      bindInt64(report.rpoMs, at: 7, in: insert)
      bindInt64(Int64(report.quarantinedFiles), at: 8, in: insert)
      bindInt64(Int64(report.corruptChunks), at: 9, in: insert)
      bindText(now, at: 10, in: insert)
      try stepDone(insert)
      sqlite3_finalize(insert)

      let update = try prepare(
        """
        UPDATE session
        SET status = ?, last_committed_sample = ?, next_chunk_index = ?,
            recovery_count = 1, stopped_at_wall = ?
        WHERE id = ?;
        """
      )
      bindText(report.status, at: 1, in: update)
      bindInt64(report.lastCommittedSample, at: 2, in: update)
      bindInt64(Int64(report.nextChunkIndex), at: 3, in: update)
      bindText(now, at: 4, in: update)
      bindText(sessionID, at: 5, in: update)
      try stepDone(update)
      sqlite3_finalize(update)

      try insertEvent(
        type: "session_recovered",
        sampleOffset: report.lastCommittedSample,
        payload: [
          "rpoMs": report.rpoMs,
          "observedSamples": report.observedSamples,
          "discardedSamples": report.discardedSamples,
          "quarantinedFiles": report.quarantinedFiles,
          "corruptChunks": report.corruptChunks,
        ]
      )
      try execute("COMMIT;")
    } catch {
      try? execute("ROLLBACK;")
      throw error
    }
  }

  static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private func effectiveProductState(persistedState: String) -> String {
    guard persistedState == "completed" else { return persistedState }
    let probeURL = directoryURL.appendingPathComponent(Stage1S15Probe.enduranceFileName)
    guard let data = try? Data(contentsOf: probeURL),
      let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      payload["final_status"] as? String == "completed_with_gaps"
    else {
      return persistedState
    }
    return "completed_with_gaps"
  }

  private func createSchema() throws {
    try execute(
      """
      CREATE TABLE IF NOT EXISTS session(
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        status TEXT NOT NULL,
        started_at_wall TEXT NOT NULL,
        stopped_at_wall TEXT,
        sample_rate INTEGER NOT NULL,
        last_committed_sample INTEGER NOT NULL DEFAULT 0,
        next_chunk_index INTEGER NOT NULL DEFAULT 0,
        recovery_count INTEGER NOT NULL DEFAULT 0
      );
      CREATE TABLE IF NOT EXISTS chunks(
        chunk_index INTEGER PRIMARY KEY,
        path TEXT NOT NULL UNIQUE,
        sample_count INTEGER NOT NULL,
        byte_count INTEGER NOT NULL,
        sha256 TEXT NOT NULL,
        committed_at_wall TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS events(
        seq INTEGER PRIMARY KEY AUTOINCREMENT,
        type TEXT NOT NULL,
        sample_offset INTEGER NOT NULL,
        wall_time TEXT NOT NULL,
        payload_json TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS recovery_report(
        session_id TEXT PRIMARY KEY,
        status TEXT NOT NULL,
        last_committed_sample INTEGER NOT NULL,
        next_chunk_index INTEGER NOT NULL,
        observed_samples INTEGER NOT NULL,
        discarded_samples INTEGER NOT NULL,
        rpo_ms INTEGER NOT NULL,
        quarantined_files INTEGER NOT NULL,
        corrupt_chunks INTEGER NOT NULL,
        completed_at_wall TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS transcript_segments(
        segment_id TEXT PRIMARY KEY,
        session_id TEXT NOT NULL,
        start_sample INTEGER NOT NULL CHECK(start_sample >= 0),
        end_sample INTEGER NOT NULL CHECK(end_sample >= start_sample),
        start_ms INTEGER NOT NULL CHECK(start_ms = (start_sample * 1000 / 16000)),
        end_ms INTEGER NOT NULL CHECK(end_ms = (end_sample * 1000 / 16000)),
        text TEXT NOT NULL CHECK(length(trim(text)) > 0),
        raw_text TEXT NOT NULL,
        language TEXT NOT NULL,
        source TEXT NOT NULL,
        model_id TEXT NOT NULL,
        is_final INTEGER NOT NULL CHECK(is_final IN (0, 1)),
        created_at_wall TEXT NOT NULL,
        FOREIGN KEY(session_id) REFERENCES session(id)
      );
      CREATE TABLE IF NOT EXISTS media_assets(
        blob_id TEXT PRIMARY KEY,
        session_id TEXT NOT NULL,
        kind TEXT NOT NULL CHECK(kind IN ('image', 'voice_thought')),
        state TEXT NOT NULL CHECK(state IN ('pending', 'committed', 'failed', 'missing', 'corrupt', 'tombstoned')),
        path TEXT NOT NULL UNIQUE,
        mime_type TEXT NOT NULL,
        byte_count INTEGER NOT NULL DEFAULT 0 CHECK(byte_count >= 0),
        sha256 TEXT NOT NULL DEFAULT '',
        created_at_wall TEXT NOT NULL,
        updated_at_wall TEXT NOT NULL,
        FOREIGN KEY(session_id) REFERENCES session(id)
      );
      CREATE TABLE IF NOT EXISTS capture_events(
        seq INTEGER PRIMARY KEY AUTOINCREMENT,
        event_id TEXT NOT NULL UNIQUE,
        session_id TEXT NOT NULL,
        type TEXT NOT NULL CHECK(type IN ('image', 'thought', 'bookmark', 'voice_thought')),
        sample_offset INTEGER NOT NULL CHECK(sample_offset >= 0),
        at_ms INTEGER NOT NULL CHECK(at_ms = (sample_offset * 1000 / 16000)),
        monotonic_elapsed_ns INTEGER NOT NULL CHECK(monotonic_elapsed_ns >= 0),
        wall_time TEXT NOT NULL,
        clock_epoch_id TEXT NOT NULL,
        capture_state TEXT NOT NULL CHECK(capture_state IN ('pending', 'committed', 'failed', 'tombstoned')),
        asset_blob_id TEXT,
        display_after_segment TEXT,
        manual_adjustment INTEGER NOT NULL DEFAULT 0 CHECK(manual_adjustment IN (0, 1)),
        payload_json TEXT NOT NULL DEFAULT '{}',
        created_at_wall TEXT NOT NULL,
        updated_at_wall TEXT NOT NULL,
        FOREIGN KEY(session_id) REFERENCES session(id),
        FOREIGN KEY(asset_blob_id) REFERENCES media_assets(blob_id)
      );
      CREATE INDEX IF NOT EXISTS transcript_segments_timeline
      ON transcript_segments(start_sample, end_sample);
      CREATE INDEX IF NOT EXISTS capture_events_timeline
      ON capture_events(sample_offset, monotonic_elapsed_ns, seq);
      CREATE INDEX IF NOT EXISTS media_assets_session_state
      ON media_assets(session_id, state);
      """
    )
  }

  private func storedCaptureAsset(_ statement: OpaquePointer) -> StoredCaptureAsset {
    StoredCaptureAsset(
      eventID: columnText(statement, 0),
      type: columnText(statement, 1),
      sampleOffset: sqlite3_column_int64(statement, 2),
      captureState: columnText(statement, 3),
      blobID: columnText(statement, 4),
      path: columnText(statement, 5),
      assetState: columnText(statement, 6),
      byteCount: sqlite3_column_int64(statement, 7),
      sha256: columnText(statement, 8)
    )
  }

  private func captureEvent(eventID: String) throws -> [String: Any] {
    let statement = try prepare(
      """
      SELECT e.seq, e.event_id, e.type, e.sample_offset, e.at_ms,
             e.monotonic_elapsed_ns, e.wall_time, e.clock_epoch_id,
             e.capture_state, COALESCE(a.blob_id, ''), COALESCE(a.path, ''),
             COALESCE(a.state, ''), COALESCE(a.mime_type, ''),
             COALESCE(a.byte_count, 0), COALESCE(a.sha256, ''), e.payload_json
      FROM capture_events e
      LEFT JOIN media_assets a ON a.blob_id = e.asset_blob_id
      WHERE e.event_id = ? LIMIT 1;
      """
    )
    defer { sqlite3_finalize(statement) }
    bindText(eventID, at: 1, in: statement)
    guard sqlite3_step(statement) == SQLITE_ROW else {
      throw SessionStoreError.invalidSession
    }
    return captureEventDictionary(statement)
  }

  private func captureEventDictionary(_ statement: OpaquePointer) -> [String: Any] {
    let payloadJSON = columnText(statement, 15)
    let payloadData = payloadJSON.data(using: .utf8) ?? Data()
    var payload = (try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any]) ?? [:]
    let relativePath = columnText(statement, 10)
    let absolutePath =
      relativePath.isEmpty
      ? ""
      : directoryURL.appendingPathComponent(relativePath).path
    payload["eventId"] = columnText(statement, 1)
    payload["captureState"] = columnText(statement, 8)
    payload["blobId"] = columnText(statement, 9)
    payload["path"] = relativePath
    payload["assetPath"] = absolutePath
    payload["assetState"] = columnText(statement, 11)
    payload["mimeType"] = columnText(statement, 12)
    payload["byteCount"] = sqlite3_column_int64(statement, 13)
    payload["sha256"] = columnText(statement, 14)
    let type = columnText(statement, 2)
    var result: [String: Any] = [
      "kind": "captureEvent",
      "sequence": sqlite3_column_int64(statement, 0),
      "eventId": columnText(statement, 1),
      "type": type,
      "sampleOffset": sqlite3_column_int64(statement, 3),
      "atMs": sqlite3_column_int64(statement, 4),
      "monotonicElapsedNs": sqlite3_column_int64(statement, 5),
      "wallTime": columnText(statement, 6),
      "clockEpochId": columnText(statement, 7),
      "captureState": columnText(statement, 8),
      "assetPath": absolutePath,
      "payload": payload,
    ]
    if type == "thought", let text = payload["text"] as? String {
      result["text"] = text
    }
    return result
  }

  private func captureEventResult(
    eventID: String,
    type: String,
    state: String,
    clock: ClockSnapshot,
    blobID: String?,
    relativePath: String?
  ) -> [String: Any] {
    [
      "eventId": eventID,
      "type": type,
      "captureState": state,
      "sampleOffset": clock.sampleOffset,
      "atMs": clock.atMs,
      "monotonicElapsedNs": Int64(clamping: clock.monotonicElapsedNs),
      "wallTime": clock.wallTime,
      "clockEpochId": clock.clockEpochID,
      "blobId": blobID ?? "",
      "path": relativePath ?? "",
    ]
  }

  private func insertSession(title: String) throws {
    let statement = try prepare(
      """
      INSERT INTO session(id, title, status, started_at_wall, sample_rate)
      VALUES (?, ?, 'preparing', ?, 16000);
      """
    )
    defer { sqlite3_finalize(statement) }
    bindText(sessionID, at: 1, in: statement)
    bindText(title, at: 2, in: statement)
    bindText(ISO8601DateFormatter().string(from: Date()), at: 3, in: statement)
    try stepDone(statement)
  }

  private func execute(_ sql: String) throws {
    var errorPointer: UnsafeMutablePointer<Int8>?
    guard sqlite3_exec(database, sql, nil, nil, &errorPointer) == SQLITE_OK else {
      let message = errorPointer.map { String(cString: $0) } ?? lastError()
      sqlite3_free(errorPointer)
      throw SessionStoreError.sqlite(message)
    }
  }

  private func scalarInt64(_ sql: String) throws -> Int64 {
    let statement = try prepare(sql)
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
    return sqlite3_column_int64(statement, 0)
  }

  private func scalarText(_ sql: String) throws -> String {
    let statement = try prepare(sql)
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { return "" }
    return columnText(statement, 0)
  }

  private func prepare(_ sql: String) throws -> OpaquePointer {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else {
      throw SessionStoreError.sqlite(lastError())
    }
    return statement
  }

  private func bindText(_ value: String, at index: Int32, in statement: OpaquePointer) {
    sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
  }

  private func bindInt64(_ value: Int64, at index: Int32, in statement: OpaquePointer) {
    sqlite3_bind_int64(statement, index, value)
  }

  private func columnText(_ statement: OpaquePointer, _ index: Int32) -> String {
    guard let value = sqlite3_column_text(statement, index) else { return "" }
    return String(cString: value)
  }

  private func stepDone(_ statement: OpaquePointer) throws {
    guard sqlite3_step(statement) == SQLITE_DONE else {
      throw SessionStoreError.sqlite(lastError())
    }
  }

  private func lastError() -> String {
    guard let database, let message = sqlite3_errmsg(database) else {
      return "Unknown SQLite error."
    }
    return String(cString: message)
  }

  private var sqliteTransient: sqlite3_destructor_type {
    unsafeBitCast(-1, to: sqlite3_destructor_type.self)
  }
}
