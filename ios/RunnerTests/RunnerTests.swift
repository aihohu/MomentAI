import AVFoundation
import Foundation
import SQLite3
import UIKit
import XCTest

@testable import Runner

final class RunnerTests: XCTestCase {
  private var rootURL: URL!

  func testSpeechRuntimeLoadsWithTtsDisabled() throws {
    let handle = try XCTUnwrap(dlopen("SherpaOnnxC.framework/SherpaOnnxC", RTLD_NOW))
    defer { dlclose(handle) }
    typealias Version = @convention(c) () -> UnsafePointer<CChar>?
    let versionSymbol = try XCTUnwrap(dlsym(handle, "SherpaOnnxGetVersionStr"))
    let version = unsafeBitCast(versionSymbol, to: Version.self)
    XCTAssertEqual(String(cString: try XCTUnwrap(version())), "1.13.5")

    // The no-TTS C API stub accepts a null config and must return null.
    typealias CreateTts = @convention(c) (UnsafeRawPointer?) -> UnsafeRawPointer?
    let ttsSymbol = try XCTUnwrap(dlsym(handle, "SherpaOnnxCreateOfflineTts"))
    let createTts = unsafeBitCast(ttsSymbol, to: CreateTts.self)
    XCTAssertNil(createTts(nil))
    for name in [
      "SherpaOnnxCreateOnlineRecognizer",
      "SherpaOnnxCreateOfflineRecognizer",
      "SherpaOnnxCreateOfflineSpeakerDiarization",
    ] {
      XCTAssertNotNil(dlsym(handle, name), "Missing speech API: \(name)")
    }
  }

  override func setUpWithError() throws {
    rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("MomentAI-Tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: rootURL)
  }

  func testRecoveryComputesRPOAndIsIdempotent() throws {
    let sessionURL = rootURL.appendingPathComponent("session_test", isDirectory: true)
    let store = try SessionStore(directoryURL: sessionURL, create: true, title: "Recovery test")
    try store.updateStatus("recording")

    let audio = Data(repeating: 0x2A, count: 32_000)
    let chunkURL = sessionURL.appendingPathComponent("audio/chunk_000000.pcm")
    try audio.write(to: chunkURL)
    try store.commitChunk(
      index: 0,
      relativePath: "audio/chunk_000000.pcm",
      sampleCount: 16_000,
      byteCount: Int64(audio.count),
      sha256: SessionStore.sha256(audio),
      lastCommittedSample: 16_000
    )
    try writeProbe(observedSamples: 24_000, to: sessionURL)

    let coordinator = RecoveryCoordinator()
    let first = try coordinator.recover(directoryPath: sessionURL.path)
    XCTAssertEqual(first["state"] as? String, "completed_with_gaps")
    XCTAssertEqual((first["rpoMs"] as? NSNumber)?.intValue, 500)
    XCTAssertEqual(first["rpoPass"] as? Bool, true)

    let second = try coordinator.recover(directoryPath: sessionURL.path)
    XCTAssertEqual(second["state"] as? String, "completed_with_gaps")
    XCTAssertEqual((second["lastCommittedSample"] as? NSNumber)?.int64Value, 16_000)
    XCTAssertEqual((second["rpoMs"] as? NSNumber)?.intValue, 500)
    XCTAssertEqual(first["quarantinedFiles"] as? Int, second["quarantinedFiles"] as? Int)
    XCTAssertEqual(first["corruptChunks"] as? Int, second["corruptChunks"] as? Int)
    XCTAssertEqual(first["discardedSamples"] as? Int64, second["discardedSamples"] as? Int64)
    let snapshot = try SessionStore(directoryURL: sessionURL, create: false).snapshot()
    XCTAssertEqual((snapshot["recoveryCount"] as? NSNumber)?.intValue, 1)
  }

  func testUserPauseFactsKeepOneSampleAnchorAndResumeAtomically() throws {
    let sessionURL = rootURL.appendingPathComponent("session_pause", isDirectory: true)
    let store = try SessionStore(directoryURL: sessionURL, create: true, title: "Pause test")
    try store.updateStatus("recording")
    let startedAt = Date(timeIntervalSince1970: 1_788_196_923.125)
    let endedAt = startedAt.addingTimeInterval(2.5)
    let sample: Int64 = 42_731

    try store.beginUserPause(
      pauseID: "pause_exact",
      sampleOffset: sample,
      startedAt: startedAt,
      monotonicElapsedNs: 10_000
    )
    XCTAssertEqual(try store.snapshot()["state"] as? String, "paused")
    _ = try store.commitBookmark(
      eventID: "bookmark_during_pause",
      clock: ClockSnapshot(
        sampleOffset: sample,
        atMs: sample * 1_000 / 16_000,
        monotonicElapsedNs: 20_000,
        wallTime: ISO8601DateFormatter().string(from: startedAt.addingTimeInterval(1)),
        clockEpochID: "clock_pause"
      )
    )

    try store.resumeUserPause(
      pauseID: "pause_exact",
      sampleOffset: sample,
      startedAt: startedAt,
      endedAt: endedAt,
      monotonicElapsedNs: 2_510_000_000
    )
    XCTAssertEqual(try store.snapshot()["state"] as? String, "recording")

    let facts = try store.timeline().filter {
      ($0["type"] as? String)?.hasPrefix("user_pause_") == true
    }
    XCTAssertEqual(facts.count, 2)
    XCTAssertEqual(
      Set(facts.compactMap { ($0["sampleOffset"] as? NSNumber)?.int64Value }),
      Set([sample])
    )
    let began = try XCTUnwrap(facts.first { $0["type"] as? String == "user_pause_began" })
    let beganPayload = try XCTUnwrap(began["payload"] as? [String: Any])
    XCTAssertEqual(beganPayload["pause_id"] as? String, "pause_exact")
    XCTAssertEqual((beganPayload["started_at_unix_ms"] as? NSNumber)?.int64Value, 1_788_196_923_125)
    let ended = try XCTUnwrap(facts.first { $0["type"] as? String == "user_pause_ended" })
    let endedPayload = try XCTUnwrap(ended["payload"] as? [String: Any])
    XCTAssertEqual(endedPayload["pause_id"] as? String, "pause_exact")
    XCTAssertEqual((endedPayload["duration_ms"] as? NSNumber)?.int64Value, 2_500)
    XCTAssertEqual(endedPayload["end_reason"] as? String, "resumed")
    XCTAssertEqual(
      try store.timeline()
        .filter {
          ["user_pause_began", "bookmark", "user_pause_ended"].contains($0["type"] as? String ?? "")
        }
        .map { $0["type"] as? String },
      ["user_pause_began", "bookmark", "user_pause_ended"]
    )
    XCTAssertThrowsError(
      try store.resumeUserPause(
        pauseID: "pause_exact",
        sampleOffset: sample,
        startedAt: startedAt,
        endedAt: endedAt,
        monotonicElapsedNs: 2_510_000_000
      )
    )
    XCTAssertEqual(
      try store.timeline().filter { $0["type"] as? String == "user_pause_ended" }.count,
      1
    )
  }

  func testPausedSessionRecoveryClosesPauseWithoutInventingAGap() throws {
    let sessionURL = rootURL.appendingPathComponent("session_paused_recovery", isDirectory: true)
    let store = try SessionStore(directoryURL: sessionURL, create: true, title: "Paused recovery")
    try store.updateStatus("recording")
    let audio = Data(repeating: 0x35, count: 32_000)
    let chunkURL = sessionURL.appendingPathComponent("audio/chunk_000000.pcm")
    try audio.write(to: chunkURL)
    try store.commitChunk(
      index: 0,
      relativePath: "audio/chunk_000000.pcm",
      sampleCount: 16_000,
      byteCount: Int64(audio.count),
      sha256: SessionStore.sha256(audio),
      lastCommittedSample: 16_000
    )
    try store.beginUserPause(
      pauseID: "pause_recovery",
      sampleOffset: 16_000,
      startedAt: Date().addingTimeInterval(-1),
      monotonicElapsedNs: 99
    )

    let coordinator = RecoveryCoordinator()
    let candidates = coordinator.scan(rootURL: rootURL)
    XCTAssertEqual(candidates.count, 1)
    XCTAssertEqual(candidates.first?["state"] as? String, "paused")

    let first = try coordinator.recover(directoryPath: sessionURL.path)
    XCTAssertEqual(first["state"] as? String, "completed")
    XCTAssertEqual((first["lastCommittedSample"] as? NSNumber)?.int64Value, 16_000)
    XCTAssertEqual((first["rpoMs"] as? NSNumber)?.int64Value, 0)
    let facts = try store.timeline().filter {
      ($0["type"] as? String)?.hasPrefix("user_pause_") == true
    }
    XCTAssertEqual(facts.count, 2)
    XCTAssertEqual(
      Set(facts.compactMap { ($0["sampleOffset"] as? NSNumber)?.int64Value }),
      Set([16_000])
    )
    let ended = try XCTUnwrap(facts.first { $0["type"] as? String == "user_pause_ended" })
    let payload = try XCTUnwrap(ended["payload"] as? [String: Any])
    XCTAssertEqual(payload["pause_id"] as? String, "pause_recovery")
    XCTAssertEqual(payload["end_reason"] as? String, "session_recovered")

    let second = try coordinator.recover(directoryPath: sessionURL.path)
    XCTAssertEqual(second["state"] as? String, "completed")
    XCTAssertEqual(
      try store.timeline().filter { $0["type"] as? String == "user_pause_ended" }.count,
      1
    )
  }

  func testPortableImportRoundTripsAudioTextImagesAndExactSamples() throws {
    let fixture = try transferFixture(refined: true, gaps: true)
    let destination = rootURL.appendingPathComponent("Imported")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let importer = SessionImporter(root: destination, freeBytes: { 10_000_000_000 })
    let preview = try importer.prepare(archive: fixture.archive)
    XCTAssertEqual(preview["conflict"] as? Bool, false)
    XCTAssertEqual(preview["hasConfirmedGaps"] as? Bool, true)
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: destination.path), [".Imports"])
    let result = try importer.commit(token: preview["token"] as! String, asCopy: false)
    let imported = URL(fileURLWithPath: result["directory"] as! String)
    let store = try SessionStore(directoryURL: imported, create: false)
    let original = try SessionStore(directoryURL: fixture.source, create: false).snapshot()
    let snapshot = try store.snapshot()
    XCTAssertEqual(snapshot["startedAtWall"] as? String, original["startedAtWall"] as? String)
    XCTAssertEqual(snapshot["stoppedAtWall"] as? String, original["stoppedAtWall"] as? String)
    XCTAssertEqual(snapshot["state"] as? String, "completed_with_gaps")
    XCTAssertEqual((snapshot["lastCommittedSample"] as? NSNumber)?.int64Value, 480_111)
    XCTAssertEqual((snapshot["chunkCount"] as? NSNumber)?.intValue, 2)
    var audio = Data()
    for chunk in try store.chunks().values.sorted(by: { $0.index < $1.index }) {
      let bytes = try Data(contentsOf: imported.appendingPathComponent(chunk.path))
      XCTAssertEqual(SessionStore.sha256(bytes), chunk.sha256)
      audio.append(bytes)
    }
    XCTAssertEqual(audio, fixture.pcm)
    let timeline = try store.timeline()
    XCTAssertEqual(
      (timeline.first(where: { $0["segmentId"] as? String == "seg_second" })?["sampleOffset"]
        as? NSNumber)?.int64Value, 16_053)
    XCTAssertEqual(
      timeline.first(where: { $0["segmentId"] as? String == "seg_second" })?["text"] as? String,
      "原文二。")
    XCTAssertEqual((try store.productSummary()["imageCount"] as? NSNumber)?.intValue, 1)
    XCTAssertEqual((try store.productSummary()["thoughtCount"] as? NSNumber)?.intValue, 1)
    let manifest = try CommittedAudioManifest(store: store)
    XCTAssertEqual(manifest.location(for: 480_001)?.offsetInChunk, 1)
    let refined = try transferObject(
      Data(contentsOf: imported.appendingPathComponent("full_text_refinement.json")))
    XCTAssertEqual(refined["sessionId"] as? String, store.sessionID)
    XCTAssertEqual(refined["fullText"] as? String, "精修一。\n\n精修二。")
    XCTAssertEqual(
      refined["sourceTimelineFingerprint"] as? String,
      try SessionExporter.sourceTimelineFingerprint(timeline))
    let reexport = try SessionExporter().export(directoryPath: imported.path)
    XCTAssertEqual(reexport["canonicalTextStatus"] as? String, "ready")
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: imported.appendingPathComponent("import_provenance.json").path))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: imported.appendingPathComponent("asr_progress.json").path))
    XCTAssertThrowsError(try importer.commit(token: preview["token"] as! String, asCopy: false))
  }

  func testPortableImportConflictOnlyAllowsIndependentCopy() throws {
    let fixture = try transferFixture(refined: true)
    let before = try SessionExporter.sha256File(
      fixture.source.appendingPathComponent("session.sqlite"))
    let importer = SessionImporter(root: rootURL, freeBytes: { 10_000_000_000 })
    let preview = try importer.prepare(archive: fixture.archive)
    XCTAssertEqual(preview["conflict"] as? Bool, true)
    XCTAssertThrowsError(try importer.commit(token: preview["token"] as! String, asCopy: false))
    let result = try importer.commit(token: preview["token"] as! String, asCopy: true)
    XCTAssertNotEqual(result["sessionId"] as? String, fixture.source.lastPathComponent)
    XCTAssertTrue((result["title"] as! String).contains(NativeStrings.text("export_copy")))
    XCTAssertEqual(
      try SessionExporter.sha256File(fixture.source.appendingPathComponent("session.sqlite")),
      before)
    let repo = ProductSessionRepository(
      rootURLProvider: { self.rootURL }, activeDirectoryProvider: { nil })
    XCTAssertEqual(
      try repo.session(sessionID: result["sessionId"] as! String)["importedFromSessionId"]
        as? String, fixture.source.lastPathComponent)
  }

  func testPortableImportUsesCheckedSnapshotAndRechecksSpaceAtCommit() throws {
    let fixture = try transferFixture()
    let destination = rootURL.appendingPathComponent("Imported")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    var space: Int64 = 10_000_000_000
    let importer = SessionImporter(root: destination, freeBytes: { space })
    var preview = try importer.prepare(archive: fixture.archive)
    space = 1
    XCTAssertThrowsError(try importer.commit(token: preview["token"] as! String, asCopy: false))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: destination.appendingPathComponent(fixture.source.lastPathComponent).path))
    space = 10_000_000_000
    preview = try importer.prepare(archive: fixture.archive)
    try Data("source changed after preview".utf8).write(to: fixture.archive)
    let result = try importer.commit(token: preview["token"] as! String, asCopy: false)
    XCTAssertEqual((result["durationSamples"] as? NSNumber)?.int64Value, 480_111)
  }

  func testSharingPreservesReconciledGapWarningWithoutChangingSessionState() throws {
    let fixture = try transferFixture()
    try JSONSerialization.data(withJSONObject: ["final_status": "completed_with_gaps"]).write(
      to: fixture.source.appendingPathComponent(Stage1S15Probe.enduranceFileName))
    let exporter = SessionExporter()
    let text = try exporter.exportShare(directoryPath: fixture.source.path, format: "text")
    XCTAssertTrue(
      try String(contentsOf: text, encoding: .utf8).contains(NativeStrings.text("export_gaps")))
    let result = try SessionExporter(now: { Date().addingTimeInterval(1) }).export(
      directoryPath: fixture.source.path)
    let doc = try transferObject(
      Data(contentsOf: URL(fileURLWithPath: result["jsonPath"] as! String)))
    XCTAssertEqual((doc["session"] as? [String: Any])?["state"] as? String, "completed_with_gaps")
    XCTAssertEqual(
      try SessionStore(directoryURL: fixture.source, create: false).snapshot()["state"] as? String,
      "completed")
  }

  func testPortableImportSpaceCancellationAndCommitFailureLeaveNoSession() throws {
    let fixture = try transferFixture()
    let destination = rootURL.appendingPathComponent("Imported")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    XCTAssertThrowsError(
      try SessionImporter(root: destination, freeBytes: { 1 }).prepare(archive: fixture.archive))
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
    let importer = SessionImporter(
      root: destination, freeBytes: { 10_000_000_000 },
      beforeCommit: { throw SessionImportError("injected commit failure") })
    var preview = try importer.prepare(archive: fixture.archive)
    importer.cancel()
    XCTAssertThrowsError(try importer.commit(token: preview["token"] as! String, asCopy: false))
    preview = try importer.prepare(archive: fixture.archive)
    XCTAssertThrowsError(try importer.commit(token: preview["token"] as! String, asCopy: false))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: destination.appendingPathComponent(fixture.source.lastPathComponent).path))
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(
        atPath: destination.appendingPathComponent(".Imports").path), [])
  }

  func testPortableImportRejectsTraversalDuplicatesCompressionLinksAndTruncation() throws {
    let fixture = try transferFixture()
    let files = try transferFiles(fixture.archive)
    let safeNames = files.keys.sorted()
    for badPath in [
      "../session.json", "/session.json", "images/../escape.jpg", "images\\escape.jpg",
      "images/%2e%2e.jpg", "images/.jpg", "session.sqlite",
    ] {
      var entries = safeNames.map { ($0, files[$0]!) }
      entries.append((badPath, Data([1])))
      let url = try transferZIP(entries)
      XCTAssertThrowsError(try StoredZIPReader(url: url), badPath)
    }
    var duplicates = safeNames.map { ($0, files[$0]!) }
    duplicates.append(("session.json", files["session.json"]!))
    XCTAssertThrowsError(try StoredZIPReader(url: transferZIP(duplicates)))
    let zip = try Data(contentsOf: fixture.archive)
    let central = Int(zip.zipUInt32(zip.count - 6))
    for (offset, value) in [
      (8, UInt8(8)), (6, 1), (central + 10, 8), (central + 38, 1), (central + 42, 1),
    ] {
      var changed = zip
      changed[offset] = value
      let url = rootURL.appendingPathComponent("bad_\(offset).momentai")
      try changed.write(to: url)
      XCTAssertThrowsError(try StoredZIPReader(url: url))
    }
    let truncated = rootURL.appendingPathComponent("truncated.momentai")
    try zip.dropLast().write(to: truncated)
    XCTAssertThrowsError(try StoredZIPReader(url: truncated))
    // Repackaging must not clear the required UTF-8 flags in both headers.
    var noncanonical = zip
    noncanonical[7] = 0
    noncanonical[central + 9] = 0
    let noncanonicalURL = rootURL.appendingPathComponent("noncanonical.momentai")
    try noncanonical.write(to: noncanonicalURL)
    XCTAssertThrowsError(try StoredZIPReader(url: noncanonicalURL))
  }

  func testPortableImportRejectsHashJSONLAnchorsAndRefinementMismatch() throws {
    let fixture = try transferFixture(refined: true)
    let destination = rootURL.appendingPathComponent("Imported")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    for corruption in [
      "hash", "jsonl", "sample", "refinement", "pending", "duplicate", "wav", "extra", "state",
    ] {
      var files = try transferFiles(fixture.archive)
      var document = try transferObject(files["session.json"]!)
      var timeline = document["timeline"] as! [[String: Any]]
      switch corruption {
      case "hash": files["session.md"] = Data("tampered".utf8)
      case "jsonl": files["timeline.jsonl"] = Data()
      case "sample":
        let i = timeline.firstIndex { $0["kind"] as? String == "transcript" }!
        timeline[i]["endSample"] = 999_999
      case "refinement":
        var canonical = document["canonicalText"] as! [String: Any]
        canonical["sourceTimelineFingerprint"] = "sha256:wrong"
        document["canonicalText"] = canonical
      case "pending":
        let i = timeline.firstIndex { $0["kind"] as? String == "captureEvent" }!
        timeline[i]["captureState"] = "pending"
      case "duplicate": timeline.append(timeline[0])
      case "wav": files["audio/session.wav"]![24] = 0
      case "state":
        var session = document["session"] as! [String: Any]
        session["state"] = "recording"
        document["session"] = session
      default: files["images/orphan.jpg"] = Data([1, 2])
      }
      document["timeline"] = timeline
      files["session.json"] = try JSONSerialization.data(withJSONObject: document)
      if corruption != "jsonl" {
        var jsonl = Data()
        for (index, item) in timeline.enumerated() {
          jsonl.append(
            try JSONSerialization.data(withJSONObject: [
              "schemaVersion": 1, "sessionId": fixture.source.lastPathComponent, "index": index,
              "item": item,
            ]))
          jsonl.append(10)
        }
        files["timeline.jsonl"] = jsonl
      }
      if corruption != "hash" { try transferRefreshManifest(&files) }
      let archive = try transferZIP(files.keys.sorted().map { ($0, files[$0]!) })
      XCTAssertThrowsError(
        try SessionImporter(root: destination, freeBytes: { 10_000_000_000 }).prepare(
          archive: archive), corruption)
      XCTAssertFalse(
        FileManager.default.fileExists(
          atPath: destination.appendingPathComponent(fixture.source.lastPathComponent).path))
    }
  }

  func testStandaloneSharesUseCanonicalTextAndUnchangedPCMWithoutFullArchive() throws {
    let fixture = try transferFixture(refined: true, gaps: true)
    let exporter = SessionExporter()
    let before = try SessionExporter.sha256File(
      fixture.source.appendingPathComponent("session.sqlite"))
    let textURL = try exporter.exportShare(directoryPath: fixture.source.path, format: "text")
    let text = try String(contentsOf: textURL, encoding: .utf8)
    XCTAssertTrue(text.contains("精修一。\n\n精修二。"))
    XCTAssertTrue(text.contains(NativeStrings.text("export_gaps")))
    XCTAssertTrue(text.contains("导入随想"))
    XCTAssertFalse(text.contains("原文二。"))
    let md = try exporter.exportShare(directoryPath: fixture.source.path, format: "markdown")
    XCTAssertTrue(try String(contentsOf: md, encoding: .utf8).hasPrefix("# "))
    let audio = try exporter.exportShare(directoryPath: fixture.source.path, format: "audio")
    XCTAssertEqual(try Data(contentsOf: audio).dropFirst(44), fixture.pcm)
    XCTAssertEqual(
      try SessionExporter.sha256File(fixture.source.appendingPathComponent("session.sqlite")),
      before)
    XCTAssertThrowsError(
      try exporter.exportShare(directoryPath: fixture.source.path, format: "unknown"))
    try FileManager.default.removeItem(
      at: fixture.source.appendingPathComponent("full_text_refinement.json"))
    let live = try exporter.exportShare(directoryPath: fixture.source.path, format: "text")
    XCTAssertTrue(try String(contentsOf: live, encoding: .utf8).contains("原文二。"))
  }

  @MainActor
  func testTextShareUsesTXTFileURLForBothPlaceholderAndFinalPayload() throws {
    let fixture = try transferFixture(refined: true, gaps: true)
    let url = try SessionExporter().exportShare(directoryPath: fixture.source.path, format: "text")
    let source = SessionTextFileActivityItem(url: url)
    let controller = UIActivityViewController(activityItems: [source], applicationActivities: nil)
    XCTAssertTrue(url.isFileURL)
    XCTAssertEqual(url.pathExtension, "txt")
    XCTAssertEqual(source.activityViewControllerPlaceholderItem(controller) as? URL, url)
    let destinations: [UIActivity.ActivityType?] = [
      nil, .copyToPasteboard, .mail, UIActivity.ActivityType("third.party.share"),
    ]
    for destination in destinations {
      let item = source.activityViewController(controller, itemForActivityType: destination)
      XCTAssertEqual(item as? URL, url)
      XCTAssertFalse(item is String)
      XCTAssertEqual(
        source.activityViewController(controller, dataTypeIdentifierForActivityType: destination),
        "public.plain-text")
    }
    XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("精修二。"))
  }

  func testCopyTextMatchesCanonicalTXTAndCleansOnlyItsTemporaryFile() throws {
    let fixture = try transferFixture(refined: true, gaps: true)
    let exporter = SessionExporter()
    let url = try exporter.exportShare(directoryPath: fixture.source.path, format: "text")
    let exports = url.deletingLastPathComponent()
    let filesBefore = try FileManager.default.contentsOfDirectory(atPath: exports.path).sorted()
    let database = fixture.source.appendingPathComponent("session.sqlite")
    let before = try SessionExporter.sha256File(database)
    let text = try exporter.readShareText(directoryPath: fixture.source.path)
    XCTAssertEqual(text, try String(contentsOf: url, encoding: .utf8))
    XCTAssertTrue(text.contains("精修二。"))
    XCTAssertTrue(text.contains(NativeStrings.text("export_gaps")))
    XCTAssertTrue(text.contains("导入随想"))
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: exports.path).sorted(), filesBefore)
    XCTAssertEqual(try SessionExporter.sha256File(database), before)
    try FileManager.default.removeItem(
      at: fixture.source.appendingPathComponent("full_text_refinement.json"))
    let live = try exporter.readShareText(directoryPath: fixture.source.path)
    XCTAssertTrue(live.contains("原文二。"))
    XCTAssertFalse(live.contains("精修二。"))
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: exports.path).sorted(), filesBefore)
  }

  func testCopyTextRejectsUnfinishedSessionWithoutCreatingFiles() throws {
    let source = rootURL.appendingPathComponent("session_copy_active")
    let store = try SessionStore(directoryURL: source, create: true, title: "Active copy test")
    try store.updateStatus("recording")
    store.checkpoint()
    let filesBefore = try FileManager.default.contentsOfDirectory(atPath: rootURL.path).sorted()
    XCTAssertThrowsError(try SessionExporter().readShareText(directoryPath: source.path)) { error in
      guard case SessionExportError.invalidState(let state) = error else {
        return XCTFail("Expected invalid state, got \(error)")
      }
      XCTAssertEqual(state, "recording")
    }
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: rootURL.path).sorted(), filesBefore)
    XCTAssertEqual(try store.snapshot()["state"] as? String, "recording")
  }

  func testReadingParagraphsMatchTXTAndCopyWithoutChangingSource() throws {
    let fixture = try transferFixture(refined: true, gaps: true)
    let exporter = SessionExporter()
    let refinement = fixture.source.appendingPathComponent("full_text_refinement.json")
    let before = try Data(contentsOf: refinement)
    let reading = "第一段。\n\n第二段。"
    let file = try exporter.exportShare(
      directoryPath: fixture.source.path, format: "text", readingText: reading)
    let copied = try exporter.readShareText(
      directoryPath: fixture.source.path, readingText: reading)
    XCTAssertEqual(copied, try String(contentsOf: file, encoding: .utf8))
    XCTAssertTrue(copied.contains(reading))
    XCTAssertTrue(copied.contains(NativeStrings.text("export_gaps")))
    XCTAssertTrue(copied.contains("导入随想"))
    XCTAssertEqual(try Data(contentsOf: refinement), before)
  }

  private func m2Fixture(_ name: String) throws -> URL {
    try XCTUnwrap(
      Bundle(for: RunnerTests.self).url(forResource: name, withExtension: nil, subdirectory: "m2"))
  }

  func testRetiredArchiveExtensionIsRejectedBeforeImport() throws {
    let archive = rootURL.appendingPathComponent("retired.tracenote")
    try FileManager.default.copyItem(at: m2Fixture("speaker-v1.momentai"), to: archive)
    let destination = rootURL.appendingPathComponent("destination")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let importer = SessionImporter(root: destination, freeBytes: { 10_000_000_000 })
    XCTAssertThrowsError(try importer.prepare(archive: archive))
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
  }

  func testAndroidProducedArchivesImportAndReexportWithMediaAndSpeakerHistory() throws {
    for name in ["android-media-v1.momentai", "android-speaker-v1.momentai"] {
      let destination = rootURL.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
      let importer = SessionImporter(root: destination, freeBytes: { 10_000_000_000 })
      let preview = try importer.prepare(archive: m2Fixture(name))
      let result = try importer.commit(token: preview["token"] as! String, asCopy: true)
      let directory = URL(fileURLWithPath: result["directory"] as! String)
      let exported = try SessionExporter().export(directoryPath: directory.path)
      let doc = try transferObject(
        Data(contentsOf: URL(fileURLWithPath: exported["jsonPath"] as! String)))
      let canonical = doc["canonicalText"] as! [String: Any]
      if name == "android-media-v1.momentai" {
        XCTAssertEqual((doc["images"] as! [Any]).count, 1)
        XCTAssertEqual(
          (doc["session"] as! [String: Any])["state"] as? String, "completed_with_gaps")
        XCTAssertEqual(canonical["fullText"] as? String, "精修连续全文。")
        XCTAssertEqual(canonical["status"] as? String, "ready")
        let timeline = doc["timeline"] as! [[String: Any]]
        XCTAssertEqual(timeline.filter { $0["kind"] as? String == "captureEvent" }.count, 3)
        XCTAssertEqual(
          timeline.first { $0["kind"] as? String == "transcript" }?["text"] as? String,
          "实时 / 引号\"与表情😀")
      } else {
        let golden = try transferObject(Data(contentsOf: m2Fixture("speaker-text-v1.json")))
        let ext =
          (doc["extensions"] as! [String: Any])[SpeakerTextContract.capability] as! [String: Any]
        XCTAssertTrue(
          NSDictionary(dictionary: ext["textProjection"] as! [String: Any]).isEqual(
            to: golden["expected"] as! [String: Any]))
        let speaker = ext["document"] as! [String: Any]
        XCTAssertEqual((speaker["labelEdits"] as! [String: Any])["revision"] as? Int, 2)
      }
      // Public synthetic output only, retained for Android's reverse-direction test.
      let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      let output = cache.appendingPathComponent("ios-return-" + name)
      try? FileManager.default.removeItem(at: output)
      try FileManager.default.copyItem(
        at: URL(fileURLWithPath: exported["archivePath"] as! String), to: output)
    }
  }

  func testM2SharedSpeakerProjectionGoldenAndCanonicalV1RemainCompatible() throws {
    let fixture = try transferObject(Data(contentsOf: m2Fixture("speaker-text-v1.json")))
    let doc = fixture["document"] as! [String: Any]
    let canonical = fixture["canonical"] as! [String: Any]
    try SpeakerTextContract.validate(doc, sessionID: "session_public_m2", samples: 64_000)
    let projection = try SpeakerTextContract.projection(canonical: canonical, document: doc)
    XCTAssertTrue(
      NSDictionary(dictionary: projection).isEqual(to: fixture["expected"] as! [String: Any]))
    XCTAssertNil(canonical["speakerVersion"])
    let rendered = SpeakerTextContract.rendered(projection)
    for label in ["林[主持]", "多人轮流", "有重叠", "归属不确定", "说话人未确定"] {
      XCTAssertTrue(rendered.contains(label))
    }
  }

  func testM2PublicArchivesImportWithoutModelsAndRejectInvalidOnesAtomically() throws {
    for file in ["legacy-v1.momentai", "speaker-v1.momentai"] {
      let destination = rootURL.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
      let importer = SessionImporter(root: destination, freeBytes: { 10_000_000_000 })
      let preview = try importer.prepare(archive: m2Fixture(file))
      let result = try importer.commit(token: preview["token"] as! String, asCopy: true)
      let imported = URL(fileURLWithPath: result["directory"] as! String)
      let store = try SessionStore(directoryURL: imported, create: false)
      let doc = try SpeakerTextContract.load(store: store, directory: imported, samples: 64_000)
      if file.hasPrefix("legacy") {
        XCTAssertNil(doc)
      } else {
        let doc = try XCTUnwrap(doc)
        XCTAssertEqual(doc["sessionId"] as? String, result["sessionId"] as? String)
        XCTAssertEqual(
          doc["sourceChunkFingerprint"] as? String,
          try SpeakerTextContract.localFingerprint(store: store))
        XCTAssertEqual((doc["segments"] as? [[String: Any]])?.count, 4)
        XCTAssertEqual((doc["labelEdits"] as? [String: Any])?["revision"] as? Int, 2)
        let reexport = try SessionExporter().export(directoryPath: imported.path)
        let exported = try transferObject(
          Data(contentsOf: URL(fileURLWithPath: reexport["jsonPath"] as! String)))
        let ext =
          (exported["extensions"] as! [String: Any])[SpeakerTextContract.capability]
          as! [String: Any]
        let golden = try transferObject(Data(contentsOf: m2Fixture("speaker-text-v1.json")))
        XCTAssertTrue(
          NSDictionary(dictionary: ext["textProjection"] as! [String: Any]).isEqual(
            to: golden["expected"] as! [String: Any]))
        for format in ["text", "markdown"] {
          let text = try String(
            contentsOf: SessionExporter().exportShare(directoryPath: imported.path, format: format),
            encoding: .utf8)
          XCTAssertTrue(text.contains("多人轮流"))
          XCTAssertTrue(text.contains("有重叠"))
          XCTAssertTrue(text.contains("林[主持]"))
          XCTAssertTrue(text.contains("不是逐字对齐"))
        }
      }
    }
    for file in [
      "invalid-compression.momentai", "invalid-extra-entry.momentai",
      "invalid-speaker-extension.momentai",
    ] {
      let destination = rootURL.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
      let importer = SessionImporter(root: destination, freeBytes: { 10_000_000_000 })
      XCTAssertThrowsError(try importer.prepare(archive: m2Fixture(file)), file)
      XCTAssertTrue(
        try FileManager.default.contentsOfDirectory(atPath: destination.path).allSatisfy {
          $0 == ".Imports"
        })
    }
  }

  func testSpeakerAlgorithmV5ExportsAndImportsWithoutLosingLabels() throws {
    let destination = rootURL.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let importer = SessionImporter(root: destination, freeBytes: { 10_000_000_000 })
    let preview = try importer.prepare(archive: m2Fixture("speaker-v1.momentai"))
    let result = try importer.commit(token: preview["token"] as! String, asCopy: true)
    let imported = URL(fileURLWithPath: result["directory"] as! String)
    let store = try SessionStore(directoryURL: imported, create: false)
    var doc = try XCTUnwrap(
      SpeakerTextContract.load(store: store, directory: imported, samples: 64_000))
    doc["algorithmVersion"] = 5
    try JSONSerialization.data(withJSONObject: doc).write(
      to: imported.appendingPathComponent(SpeakerTextContract.fileName), options: .atomic)
    let exported = try SessionExporter().export(directoryPath: imported.path)
    let secondPreview = try importer.prepare(
      archive: URL(fileURLWithPath: exported["archivePath"] as! String))
    let copied = try importer.commit(token: secondPreview["token"] as! String, asCopy: true)
    let copiedURL = URL(fileURLWithPath: copied["directory"] as! String)
    let copiedStore = try SessionStore(directoryURL: copiedURL, create: false)
    let reloaded = try XCTUnwrap(
      SpeakerTextContract.load(store: copiedStore, directory: copiedURL, samples: 64_000))
    XCTAssertEqual(reloaded["algorithmVersion"] as? Int, 5)
    XCTAssertTrue(
      NSArray(array: reloaded["segments"] as! [Any]).isEqual(to: doc["segments"] as! [Any]))
    XCTAssertTrue(
      NSDictionary(dictionary: reloaded["labelEdits"] as! [String: Any]).isEqual(
        to: doc["labelEdits"] as! [String: Any]))
    doc["algorithmVersion"] = 6
    XCTAssertThrowsError(
      try SpeakerTextContract.validate(doc, sessionID: store.sessionID, samples: 64_000))
  }

  func testM2ExtensionCorruptionAndUnknownCapabilitiesNeverSilentlyLoseSpeakerEdits() throws {
    let original = try transferFiles(m2Fixture("speaker-v1.momentai"))
    for corruption in [
      "audioHash", "identity", "projection", "revision", "overlapMerge", "history",
      "unknownExtension", "version", "missingDeclaration",
    ] {
      var files = original
      var doc = try transferObject(files["session.json"]!)
      var extensions = doc["extensions"] as! [String: Any]
      var ext = extensions[SpeakerTextContract.capability] as! [String: Any]
      var speaker = ext["document"] as! [String: Any]
      switch corruption {
      case "audioHash": ext["sourceAudioSha256"] = String(repeating: "0", count: 64)
      case "identity": speaker["sessionId"] = "session_wrong"
      case "projection": ext["textProjection"] = [:]
      case "version": ext["schemaVersion"] = 2
      case "missingDeclaration": doc["capabilities"] = ["canonicalTextV1"]
      case "unknownExtension": extensions["futureRequiredExtension"] = [:]
      default:
        var edits = speaker["labelEdits"] as! [String: Any]
        if corruption == "revision" {
          edits["revision"] = true
        } else {
          let bad: [String: Any] = [
            "names": [String: String](), "mergedInto": ["speaker_2": "speaker_4"],
          ]
          edits[corruption == "history" ? "history" : "current"] =
            corruption == "history" ? [bad] : bad as Any
        }
        speaker["labelEdits"] = edits
      }
      ext["document"] = speaker
      extensions[SpeakerTextContract.capability] = ext
      doc["extensions"] = extensions
      files["session.json"] = try JSONSerialization.data(withJSONObject: doc)
      try transferRefreshManifest(&files)
      let archive = try transferZIP(files.keys.sorted().map { ($0, files[$0]!) })
      let destination = rootURL.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
      XCTAssertThrowsError(
        try SessionImporter(root: destination, freeBytes: { 10_000_000_000 }).prepare(
          archive: archive), corruption)
      XCTAssertTrue(
        try FileManager.default.contentsOfDirectory(atPath: destination.path).allSatisfy {
          $0 == ".Imports"
        })
    }
  }

  private func transferFixture(refined: Bool = false, gaps: Bool = false) throws -> (
    source: URL, archive: URL, pcm: Data
  ) {
    let source = rootURL.appendingPathComponent("session_transfer_fixture")
    let store = try SessionStore(directoryURL: source, create: true, title: "分享导入测试")
    let pcm = Data((0..<960_222).map { UInt8($0 % 251) })
    try pcm.write(to: source.appendingPathComponent("audio/chunk_000000.pcm"))
    try store.commitChunk(
      index: 0, relativePath: "audio/chunk_000000.pcm", sampleCount: 480_111,
      byteCount: Int64(pcm.count), sha256: SessionStore.sha256(pcm), lastCommittedSample: 480_111)
    for (id, start, end, text) in [
      ("seg_first", 0, 16_000, "原文一。"), ("seg_second", 16_053, 480_111, "原文二。"),
    ] {
      _ = try store.commitTranscriptSegment([
        "segmentId": id, "sessionId": store.sessionID, "startSample": start, "endSample": end,
        "text": text, "isFinal": true,
      ])
    }
    let clock = ClockSnapshot(
      sampleOffset: 16_053, atMs: 1_003, monotonicElapsedNs: 1_003_312_500,
      wallTime: "2026-08-31T00:00:00Z", clockEpochID: "clock_fixture")
    _ = try store.commitThought(eventID: "thought_fixture", text: "导入随想", clock: clock)
    _ = try store.beginImageCapture(
      eventID: "image_fixture", blobID: "blob_fixture", relativePath: "assets/image.jpg",
      clock: clock)
    let image = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).jpegData(
      withCompressionQuality: 0.8
    ) { context in
      UIColor.red.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
    }
    try image.write(to: source.appendingPathComponent("assets/image.jpg"))
    _ = try store.commitImageCapture(
      eventID: "image_fixture", byteCount: Int64(image.count), sha256: SessionStore.sha256(image))
    try store.updateStatus(gaps ? "completed_with_gaps" : "completed", stopped: true)
    if refined {
      let timeline = try store.timeline()
      let payload: [String: Any] = [
        "schemaVersion": 4, "composerVersion": 4, "status": "ready", "sessionId": store.sessionID,
        "sourceAudioSamples": 480_111, "sampleRate": 16_000, "modelId": "sensevoice-test",
        "createdAt": "2026-08-31T00:00:00Z",
        "fullText": "精修一。\n\n精修二。",
        "sourceTimelineFingerprint": try SessionExporter.sourceTimelineFingerprint(timeline),
        "timelineProjection": [
          [
            "segmentId": "seg_first", "startSample": 0, "endSample": 16_000, "refinedText": "精修一。",
            "fallback": false,
          ],
          [
            "segmentId": "seg_second", "startSample": 16_053, "endSample": 480_111,
            "refinedText": "精修二。", "fallback": false,
          ],
        ],
      ]
      try JSONSerialization.data(withJSONObject: payload).write(
        to: source.appendingPathComponent("full_text_refinement.json"))
    }
    store.checkpoint()
    let result = try SessionExporter().export(directoryPath: source.path)
    return (source, URL(fileURLWithPath: result["archivePath"] as! String), pcm)
  }

  private func transferObject(_ data: Data) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }
  private func transferFiles(_ archive: URL) throws -> [String: Data] {
    let reader = try StoredZIPReader(url: archive)
    return try Dictionary(
      uniqueKeysWithValues: reader.entries.map { ($0.path, try reader.data($0)) })
  }
  private func transferRefreshManifest(_ files: inout [String: Data]) throws {
    var manifest = try transferObject(files["manifest.json"]!)
    manifest["files"] = files.keys.filter { $0 != "manifest.json" }.sorted().map { path in
      ["path": path, "byteCount": files[path]!.count, "sha256": SessionStore.sha256(files[path]!)]
        as [String: Any]
    }
    files["manifest.json"] = try JSONSerialization.data(withJSONObject: manifest)
  }
  private func transferZIP(_ files: [(String, Data)]) throws -> URL {
    func u16(_ value: Int) -> Data { Data([UInt8(value & 255), UInt8((value >> 8) & 255)]) }
    func u32(_ value: UInt32) -> Data { u16(Int(value & 65535)) + u16(Int(value >> 16)) }
    var output = Data()
    var central = Data()
    for (name, data) in files {
      let path = Data(name.utf8)
      let size = u32(UInt32(data.count))
      let crc = u32(StoredZIPReader.crc32(data))
      let offset = output.count
      output += u32(0x0403_4b50) + u16(20) + u16(0x800) + u16(0) + u16(0) + u16(0x21)
      output += crc + size + size + u16(path.count) + u16(0) + path + data
      central += u32(0x0201_4b50) + u16(20) + u16(20) + u16(0x800) + u16(0) + u16(0) + u16(0x21)
      for part in [
        crc, size, size, u16(path.count), u16(0), u16(0), u16(0), u16(0), u32(0),
        u32(UInt32(offset)), path,
      ] {
        central.append(part)
      }
    }
    let offset = output.count
    output += central
    output +=
      u32(0x0605_4b50) + u16(0) + u16(0) + u16(files.count) + u16(files.count)
      + u32(UInt32(central.count)) + u32(UInt32(offset)) + u16(0)
    let url = rootURL.appendingPathComponent("test_\(UUID().uuidString).momentai")
    try output.write(to: url)
    return url
  }

  func testRecoveryRejectsNormallyCompletedSessionWithoutMutation() throws {
    let sessionURL = rootURL.appendingPathComponent("session_completed", isDirectory: true)
    let store = try SessionStore(directoryURL: sessionURL, create: true, title: "Completed")
    try store.updateStatus("recording")
    try store.updateStatus("completed", stopped: true)

    XCTAssertThrowsError(try RecoveryCoordinator().recover(directoryPath: sessionURL.path)) {
      guard case RecoveryCoordinatorError.invalidState("completed") = $0 else {
        return XCTFail("Unexpected error: \($0)")
      }
    }

    let reopened = try SessionStore(directoryURL: sessionURL, create: false)
    XCTAssertEqual(try reopened.snapshot()["state"] as? String, "completed")
    XCTAssertNil(try reopened.recoveryReport())
    XCTAssertFalse(
      try reopened.timeline().contains {
        $0["type"] as? String == "session_recovered"
      })
  }

  func testStoreNeverDowngradesCompletedWithGapsDuringRecovery() throws {
    let sessionURL = rootURL.appendingPathComponent("session_gaps", isDirectory: true)
    let store = try SessionStore(directoryURL: sessionURL, create: true, title: "Has gaps")
    try store.updateStatus("recording")
    try store.updateStatus("completed_with_gaps", stopped: true)
    let report = StoredRecoveryReport(
      status: "completed",
      lastCommittedSample: 0,
      nextChunkIndex: 0,
      observedSamples: 0,
      discardedSamples: 0,
      rpoMs: 0,
      quarantinedFiles: 0,
      corruptChunks: 0
    )

    XCTAssertThrowsError(try store.updateStatus("recovering"))
    XCTAssertThrowsError(try store.completeRecovery(report))
    XCTAssertEqual(try store.snapshot()["state"] as? String, "completed_with_gaps")
    XCTAssertNil(try store.recoveryReport())
  }

  func testCameraZoomUsesDeviceRangeAndConsistentRelativeTravel() {
    for limits: (CGFloat, CGFloat) in [(0.5, 40), (1, 120), (1, 1)] {
      let scale = CameraZoomScale(minimum: limits.0, maximum: limits.1)
      XCTAssertEqual(scale.factor(-10), limits.0)
      XCTAssertEqual(scale.factor(scale.span + 10), limits.1)
      XCTAssertEqual(scale.factor(scale.position(limits.1)), limits.1, accuracy: 0.0001)
    }
    let scale = CameraZoomScale(minimum: 0.5, maximum: 40)
    XCTAssertEqual(
      scale.position(2) - scale.position(1), scale.position(40) - scale.position(20),
      accuracy: 0.0001)
    XCTAssertEqual(scale.factor(scale.position(17.3)), 17.3, accuracy: 0.0001)
  }

  @MainActor
  func testCameraZoomFullRangeFitsOneDragAcrossControlWidths() {
    let dial = CameraZoomDial()
    for width: CGFloat in [236, 260, 369] {
      dial.frame = CGRect(x: 0, y: 0, width: width, height: 84)
      for maximum: CGFloat in [1, 40, 120] {
        dial.configure(minimum: 0.5, maximum: maximum)
        var selected: CGFloat = 0
        dial.onValueChanged = { selected = $0 }
        dial.selectZoom(at: 0)
        XCTAssertEqual(selected, 0.5)
        dial.selectZoom(at: width / 2)
        XCTAssertEqual(selected, sqrt(0.5 * maximum), accuracy: 0.0001)
        dial.selectZoom(at: width)
        XCTAssertEqual(selected, maximum)
        dial.selectZoom(at: -100)
        XCTAssertEqual(selected, 0.5)
      }
    }
  }

  @MainActor
  func testCameraControlsKeepReturnAndShutterReachableAcrossOrientations() {
    let controls = CameraControlsView()
    controls.configureZoom(minimum: 0.5, maximum: 40)
    controls.updateZoom(1)
    controls.status.text =
      NativeStrings.text("camera_recording_continues") + "\n"
      + NativeStrings.text("camera_saved_count", "1")
    for size in [CGSize(width: 393, height: 852), CGSize(width: 852, height: 393)] {
      controls.frame = CGRect(origin: .zero, size: size)
      controls.setNeedsLayout()
      controls.layoutIfNeeded()
      XCTAssertGreaterThanOrEqual(controls.back.bounds.height, 48)
      XCTAssertGreaterThanOrEqual(controls.back.bounds.width, 48)
      let shutter = controls.shutter.convert(controls.shutter.bounds, to: controls)
      XCTAssertTrue(controls.bounds.contains(shutter))
      XCTAssertFalse(controls.preview.frame.intersects(shutter))
      XCTAssertFalse(controls.back.frame.intersects(controls.preview.frame))
      XCTAssertGreaterThan(controls.preview.bounds.width, 200)
      XCTAssertGreaterThan(controls.preview.bounds.height, 200)
      let image = UIGraphicsImageRenderer(size: size).image { context in
        controls.layer.render(in: context.cgContext)
      }
      let attachment = XCTAttachment(image: image)
      attachment.name =
        size.width > size.height ? "Camera landscape controls" : "Camera portrait controls"
      attachment.lifetime = .keepAlways
      add(attachment)
    }
  }

  func testCameraReportsOnlyActiveRecordingAsContinuing() {
    XCTAssertEqual(
      CameraProbeController.recordingStatusKey("recording"), "camera_recording_continues")
    XCTAssertEqual(CameraProbeController.recordingStatusKey("paused"), "camera_recording_paused")
    for state in ["interrupted", "finalizing", "completed", "failed", "unknown"] {
      XCTAssertEqual(CameraProbeController.recordingStatusKey(state), "camera_recording_check")
    }
  }

  func testCameraLifecycleWaitsForPreviewAndHonorsEarlyStop() {
    let lifecycle = CameraSessionLifecycleGate()
    XCTAssertTrue(lifecycle.beginConfiguration())
    XCTAssertFalse(lifecycle.beginConfiguration())
    XCTAssertFalse(lifecycle.consumeStartPermission())

    lifecycle.markConfigurationCommitted()
    XCTAssertFalse(lifecycle.consumeStartPermission())
    lifecycle.markPreviewAttached()
    XCTAssertTrue(lifecycle.consumeStartPermission())
    XCTAssertFalse(lifecycle.consumeStartPermission())
    XCTAssertTrue(lifecycle.requestStop())
    XCTAssertFalse(lifecycle.consumeStartPermission())

    let dismissedBeforePreview = CameraSessionLifecycleGate()
    XCTAssertTrue(dismissedBeforePreview.beginConfiguration())
    XCTAssertFalse(dismissedBeforePreview.requestStop())
    dismissedBeforePreview.markConfigurationCommitted()
    dismissedBeforePreview.markPreviewAttached()
    XCTAssertFalse(dismissedBeforePreview.consumeStartPermission())
  }

  func testExistingStoreWaitsForShortLivedWriterLock() throws {
    let sessionURL = rootURL.appendingPathComponent("session_busy", isDirectory: true)
    _ = try SessionStore(directoryURL: sessionURL, create: true, title: "Busy timeout test")

    var lockingDatabase: OpaquePointer?
    XCTAssertEqual(
      sqlite3_open_v2(
        sessionURL.appendingPathComponent("session.sqlite").path,
        &lockingDatabase,
        SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
        nil
      ),
      SQLITE_OK
    )
    let database = try XCTUnwrap(lockingDatabase)
    defer { sqlite3_close(database) }
    XCTAssertEqual(sqlite3_exec(database, "BEGIN IMMEDIATE;", nil, nil, nil), SQLITE_OK)

    let lockReleased = expectation(description: "writer lock released")
    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.15) {
      sqlite3_exec(database, "COMMIT;", nil, nil, nil)
      lockReleased.fulfill()
    }

    let reopened = try SessionStore(directoryURL: sessionURL, create: false)
    XCTAssertNoThrow(try reopened.timeline())
    wait(for: [lockReleased], timeout: 2)
  }

  func testRecoveryQuarantinesPartAndUnregisteredFinalChunk() throws {
    let sessionURL = rootURL.appendingPathComponent("session_orphans", isDirectory: true)
    let store = try SessionStore(directoryURL: sessionURL, create: true, title: "Orphan test")
    try store.updateStatus("recording")

    let partURL = sessionURL.appendingPathComponent("audio/chunk_000000.pcm.part")
    let orphanURL = sessionURL.appendingPathComponent("audio/chunk_000001.pcm")
    try Data(repeating: 1, count: 10).write(to: partURL)
    try Data(repeating: 2, count: 10).write(to: orphanURL)

    let result = try RecoveryCoordinator().recover(directoryPath: sessionURL.path)
    XCTAssertEqual(result["state"] as? String, "completed_with_gaps")
    XCTAssertEqual((result["quarantinedFiles"] as? NSNumber)?.intValue, 2)
    XCTAssertEqual((result["discardedSamples"] as? NSNumber)?.int64Value, 10)
    XCTAssertEqual((result["rpoMs"] as? NSNumber)?.int64Value, 0)
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: partURL.appendingPathExtension("quarantine").path))
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: orphanURL.appendingPathExtension("quarantine").path))

    let second = try RecoveryCoordinator().recover(directoryPath: sessionURL.path)
    XCTAssertEqual((second["quarantinedFiles"] as? NSNumber)?.intValue, 2)
    XCTAssertEqual((second["discardedSamples"] as? NSNumber)?.int64Value, 10)
  }

  func testRecoveryUsesDiscardedPCMForConservativeRPO() throws {
    let sessionURL = rootURL.appendingPathComponent("session_discarded", isDirectory: true)
    let store = try SessionStore(directoryURL: sessionURL, create: true, title: "Discarded test")
    try store.updateStatus("recording")
    let partURL = sessionURL.appendingPathComponent("audio/chunk_000000.pcm.part")
    try Data(repeating: 7, count: 32_000).write(to: partURL)

    let result = try RecoveryCoordinator().recover(directoryPath: sessionURL.path)
    XCTAssertEqual((result["discardedSamples"] as? NSNumber)?.int64Value, 16_000)
    XCTAssertEqual((result["rpoMs"] as? NSNumber)?.int64Value, 1_000)
    XCTAssertEqual(result["rpoPass"] as? Bool, true)
  }

  func testTranscriptSegmentUsesCommittedSampleClockAndAppearsOnTimeline() throws {
    let sessionURL = rootURL.appendingPathComponent("session_transcript", isDirectory: true)
    let store = try SessionStore(directoryURL: sessionURL, create: true, title: "Transcript test")
    let audio = Data(repeating: 0x00, count: 64_000)
    let chunkURL = sessionURL.appendingPathComponent("audio/chunk_000000.pcm")
    try audio.write(to: chunkURL)
    try store.commitChunk(
      index: 0,
      relativePath: "audio/chunk_000000.pcm",
      sampleCount: 32_000,
      byteCount: Int64(audio.count),
      sha256: SessionStore.sha256(audio),
      lastCommittedSample: 32_000
    )

    let committed = try store.commitTranscriptSegment([
      "segmentId": "seg_000001",
      "sessionId": store.sessionID,
      "startSample": 8_000,
      "endSample": 24_000,
      "text": "这是一段真实转写。",
      "rawText": "这是一段真实转写",
      "language": "zh",
      "source": "sherpa_onnx",
      "modelId": "test-model",
      "isFinal": true,
    ])
    XCTAssertEqual((committed["startMs"] as? NSNumber)?.intValue, 500)
    XCTAssertEqual((committed["endMs"] as? NSNumber)?.intValue, 1_500)

    let chunks = try store.committedChunks()
    XCTAssertEqual(chunks.count, 1)
    XCTAssertEqual((chunks[0]["startSample"] as? NSNumber)?.int64Value, 0)
    XCTAssertEqual((chunks[0]["endSample"] as? NSNumber)?.int64Value, 32_000)

    let timeline = try store.timeline()
    XCTAssertEqual(timeline.count, 1)
    XCTAssertEqual(timeline[0]["kind"] as? String, "transcript")
    XCTAssertEqual(timeline[0]["text"] as? String, "这是一段真实转写。")

    XCTAssertThrowsError(
      try store.commitTranscriptSegment([
        "segmentId": "seg_out_of_range",
        "sessionId": store.sessionID,
        "startSample": 24_000,
        "endSample": 48_000,
        "text": "越界",
      ])
    )
  }

  func testImageAndBookmarkUseAtomicCaptureTimeline() throws {
    let sessionURL = rootURL.appendingPathComponent("session_capture", isDirectory: true)
    let store = try SessionStore(directoryURL: sessionURL, create: true, title: "Capture test")
    let imageClock = ClockSnapshot(
      sampleOffset: 8_000,
      atMs: 500,
      monotonicElapsedNs: 10,
      wallTime: "2026-08-15T12:00:00Z",
      clockEpochID: "clock_test"
    )
    let pending = try store.beginImageCapture(
      eventID: "evt_image",
      blobID: "blob_image",
      relativePath: "assets/blob_image.jpg",
      clock: imageClock
    )
    XCTAssertEqual(pending["captureState"] as? String, "pending")
    XCTAssertEqual((pending["sampleOffset"] as? NSNumber)?.int64Value, 8_000)

    let jpeg = Data([0xFF, 0xD8, 0x01, 0x02, 0xFF, 0xD9])
    try jpeg.write(to: sessionURL.appendingPathComponent("assets/blob_image.jpg"))
    let committed = try store.commitImageCapture(
      eventID: "evt_image",
      byteCount: Int64(jpeg.count),
      sha256: SessionStore.sha256(jpeg)
    )
    XCTAssertEqual(committed["captureState"] as? String, "committed")

    let bookmark = try store.commitBookmark(
      eventID: "evt_bookmark",
      clock: ClockSnapshot(
        sampleOffset: 8_000,
        atMs: 500,
        monotonicElapsedNs: 20,
        wallTime: "2026-08-15T12:00:00Z",
        clockEpochID: "clock_test"
      )
    )
    XCTAssertEqual(bookmark["captureState"] as? String, "committed")

    let timeline = try store.timeline()
    XCTAssertEqual(timeline.count, 2)
    XCTAssertEqual(timeline[0]["eventId"] as? String, "evt_image")
    XCTAssertEqual(timeline[1]["eventId"] as? String, "evt_bookmark")
    XCTAssertEqual((timeline[0]["atMs"] as? NSNumber)?.int64Value, 500)
    let asset = try XCTUnwrap(store.captureAsset(eventID: "evt_image"))
    XCTAssertEqual(asset.assetState, "committed")
    XCTAssertEqual(asset.byteCount, Int64(jpeg.count))
    XCTAssertEqual(asset.sha256, SessionStore.sha256(jpeg))
  }

  func testTextThoughtUsesDurableAtomicAnchorAndIsIdempotent() throws {
    let sessionURL = rootURL.appendingPathComponent("session_thought", isDirectory: true)
    let store = try SessionStore(directoryURL: sessionURL, create: true, title: "Thought test")
    let audio = Data(repeating: 0x31, count: 32_000)
    let chunkURL = sessionURL.appendingPathComponent("audio/chunk_000000.pcm")
    try audio.write(to: chunkURL)
    try store.commitChunk(
      index: 0,
      relativePath: "audio/chunk_000000.pcm",
      sampleCount: 16_000,
      byteCount: Int64(audio.count),
      sha256: SessionStore.sha256(audio),
      lastCommittedSample: 16_000
    )
    let clock = ClockSnapshot(
      sampleOffset: 16_000,
      atMs: 1_000,
      monotonicElapsedNs: 42,
      wallTime: "2026-08-16T00:00:00Z",
      clockEpochID: "clock_thought"
    )

    let first = try store.commitThought(
      eventID: "evt_thought",
      text: "  这是我的现场判断。\n下一步验证它。  ",
      clock: clock
    )
    XCTAssertEqual(first["type"] as? String, "thought")
    XCTAssertEqual(first["captureState"] as? String, "committed")
    XCTAssertEqual(first["text"] as? String, "这是我的现场判断。\n下一步验证它。")
    XCTAssertEqual((first["sampleOffset"] as? NSNumber)?.int64Value, 16_000)
    let payload = try XCTUnwrap(first["payload"] as? [String: Any])
    XCTAssertEqual(payload["source"] as? String, "user_text")
    XCTAssertEqual(payload["assetPath"] as? String, "")

    let second = try store.commitThought(
      eventID: "evt_thought",
      text: "这是我的现场判断。\n下一步验证它。",
      clock: clock
    )
    XCTAssertEqual(second["eventId"] as? String, "evt_thought")
    XCTAssertEqual(try store.timeline().filter { $0["type"] as? String == "thought" }.count, 1)

    XCTAssertThrowsError(
      try store.commitThought(eventID: "evt_thought", text: "冲突文本", clock: clock)
    )
    XCTAssertThrowsError(
      try store.commitThought(eventID: "evt_empty", text: "  \n ", clock: clock)
    )
    XCTAssertThrowsError(
      try store.commitThought(
        eventID: "evt_beyond_audio",
        text: "锚点不能超过耐久音频",
        clock: ClockSnapshot(
          sampleOffset: 16_001,
          atMs: 1_000,
          monotonicElapsedNs: 43,
          wallTime: "2026-08-16T00:00:01Z",
          clockEpochID: "clock_thought"
        )
      )
    )
  }

  func testPlaybackManifestMapsExactSamplesAcrossCommittedChunks() throws {
    let sessionURL = rootURL.appendingPathComponent("session_playback", isDirectory: true)
    let store = try SessionStore(directoryURL: sessionURL, create: true, title: "Playback test")
    let sampleCounts: [Int64] = [16_000, 8_000, 12_000]
    var highWater: Int64 = 0
    for (index, sampleCount) in sampleCounts.enumerated() {
      let data = Data(repeating: UInt8(index + 1), count: Int(sampleCount * 2))
      let relativePath = String(format: "audio/chunk_%06d.pcm", index)
      try data.write(to: sessionURL.appendingPathComponent(relativePath))
      highWater += sampleCount
      try store.commitChunk(
        index: index,
        relativePath: relativePath,
        sampleCount: sampleCount,
        byteCount: Int64(data.count),
        sha256: SessionStore.sha256(data),
        lastCommittedSample: highWater
      )
    }
    try store.updateStatus("completed", stopped: true)

    let manifest = try CommittedAudioManifest(store: store)
    XCTAssertEqual(manifest.sessionID, "session_playback")
    XCTAssertEqual(manifest.sampleRate, 16_000)
    XCTAssertEqual(manifest.durationSamples, 36_000)
    XCTAssertEqual(manifest.chunks.count, 3)
    XCTAssertEqual(manifest.location(for: 0)?.chunkIndex, 0)
    XCTAssertEqual(manifest.location(for: 15_999)?.offsetInChunk, 15_999)
    XCTAssertEqual(manifest.location(for: 16_000)?.chunkIndex, 1)
    XCTAssertEqual(manifest.location(for: 16_000)?.offsetInChunk, 0)
    XCTAssertEqual(manifest.location(for: 20_000)?.offsetInChunk, 4_000)
    XCTAssertEqual(manifest.location(for: 24_000)?.chunkIndex, 2)
    XCTAssertEqual(manifest.location(for: 35_999)?.offsetInChunk, 11_999)
    XCTAssertNil(manifest.location(for: 36_000))
    XCTAssertEqual(manifest.clampedSample(-1), 0)
    XCTAssertEqual(manifest.clampedSample(40_000), 36_000)
  }

  func testPlaybackLoudnessProfileRaisesQuietSpeechWithoutBoostingSilenceOrLoudAudio() {
    func pcm(_ amplitude: Int16, frames: Int = 16000) -> Data {
      var values = (0..<frames).map { ($0 % 2 == 0 ? amplitude : -amplitude).littleEndian }
      return values.withUnsafeMutableBytes { Data($0) }
    }
    var quiet = PlaybackLoudnessProfile()
    quiet.addPCM16(pcm(128))
    XCTAssertEqual(quiet.gain, 25.6, accuracy: 0.001)
    var loud = PlaybackLoudnessProfile()
    loud.addPCM16(pcm(8000))
    XCTAssertEqual(loud.gain, 1)
    var silence = PlaybackLoudnessProfile()
    silence.addPCM16(pcm(0))
    silence.addPCM16(pcm(10))
    XCTAssertEqual(silence.gain, 1)
    var bounded = PlaybackLoudnessProfile()
    bounded.addPCM16(pcm(40))
    XCTAssertEqual(bounded.gain, 31.6227766, accuracy: 0.001)
    let processor = PlaybackSignalProcessor()
    processor.compensationGain = quiet.gain
    processor.configure(volume: 1, enhanced: true)
    for _ in 0..<320 { _ = processor.processPCM16(0) }
    XCTAssertEqual(processor.processPCM16(128), 0.1, accuracy: 0.001)
    XCTAssertLessThanOrEqual(processor.processPCM16(Int16.max), 0.999)
    processor.configure(volume: 1, enhanced: false)
    for _ in 0..<320 { _ = processor.processPCM16(0) }
    XCTAssertEqual(processor.processPCM16(128), 128.0 / 32768, accuracy: 0.000001)
  }

  func testPlaybackSignalProcessorAddsGainAndSoftLimitsPeaks() {
    let processor = PlaybackSignalProcessor()
    processor.compensationGain = 2
    XCTAssertEqual(processor.processPCM16(16_384), 0.5)
    XCTAssertEqual(processor.processPCM16(Int16.min), -1)
    processor.configure(volume: 1, enhanced: true)
    for _ in 0..<320 { _ = processor.processPCM16(0) }
    XCTAssertEqual(processor.gainDB, 6.0206, accuracy: 0.001)
    XCTAssertEqual(processor.processPCM16(2_048), 0.125, accuracy: 0.0001)
    XCTAssertEqual(processor.processPCM16(-2_048), -0.125, accuracy: 0.0001)
    XCTAssertLessThanOrEqual(processor.processPCM16(Int16.max), 0.999)
    XCTAssertGreaterThanOrEqual(processor.processPCM16(Int16.min), -0.999)
  }

  func testPlaybackSoundTransitionsAreSmoothAndMuteIsExact() {
    let processor = PlaybackSignalProcessor()
    processor.compensationGain = 2
    processor.configure(volume: 0, enhanced: false)
    var previous: Float = 0.5
    for _ in 0..<320 {
      let next = processor.processPCM16(16_384)
      XCTAssertLessThanOrEqual(next, previous)
      XCTAssertLessThanOrEqual(abs(next - previous), 0.002)
      previous = next
    }
    XCTAssertEqual(processor.processPCM16(Int16.max), 0)
    processor.configure(volume: 0.5, enhanced: true)
    for _ in 0..<320 { _ = processor.processPCM16(0) }
    XCTAssertEqual(processor.processPCM16(2_048), 0.0625, accuracy: 0.0001)
    processor.configure(volume: 1, enhanced: false)
    for _ in 0..<320 { _ = processor.processPCM16(0) }
    XCTAssertEqual(processor.processPCM16(Int16.min), -1)
  }

  func testPlaybackSoundPreferencesPersistAndRejectInvalidValues() throws {
    let suite = "playback-test-" + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(0.6, forKey: "playbackVolume")
    defaults.set(false, forKey: "playbackEnhanced")
    let player = CommittedAudioPlayer(soundDefaults: defaults)
    let initial = expectation(description: "automatic level defaults on and keeps volume")
    player.soundSettings { result in
      if case .success(let settings) = result {
        XCTAssertEqual(settings["enhanced"] as? Bool, true)
        XCTAssertEqual((settings["volume"] as? NSNumber)?.floatValue ?? 0, 0.6, accuracy: 0.0001)
      } else {
        XCTFail("Settings unavailable")
      }
      initial.fulfill()
    }
    wait(for: [initial], timeout: 5)
    let saved = expectation(description: "save sound settings while idle")
    player.setSound(volume: 0.35, enhanced: true) { result in
      if case .failure(let error) = result { XCTFail("Save failed: \(error)") }
      saved.fulfill()
    }
    wait(for: [saved], timeout: 5)
    let invalid = expectation(description: "reject invalid volume")
    player.setSound(volume: .nan, enhanced: false) { result in
      if case .success = result { XCTFail("Invalid volume was accepted") }
      invalid.fulfill()
    }
    wait(for: [invalid], timeout: 5)
    let reloaded = expectation(description: "reload persisted sound")
    let replacement = CommittedAudioPlayer(soundDefaults: defaults)
    replacement.soundSettings { result in
      guard case .success(let settings) = result else {
        XCTFail("Read failed")
        reloaded.fulfill()
        return
      }
      XCTAssertEqual((settings["volume"] as? NSNumber)?.floatValue ?? 0, 0.35, accuracy: 0.0001)
      XCTAssertEqual(settings["enhanced"] as? Bool, true)
      reloaded.fulfill()
    }
    wait(for: [reloaded], timeout: 5)
  }

  func testPlaybackPositionDoesNotRegressWhileResumeRenderTimeCatchesUp() {
    let pausedSample: Int64 = 1_355_840

    XCTAssertEqual(
      PlaybackPositionResolver.resolve(
        baseSample: 0,
        renderedElapsedSamples: 1_355_200,
        reportedSampleFloor: pausedSample,
        durationSamples: 2_289_463
      ),
      pausedSample
    )
    XCTAssertEqual(
      PlaybackPositionResolver.resolve(
        baseSample: 0,
        renderedElapsedSamples: 1_356_480,
        reportedSampleFloor: pausedSample,
        durationSamples: 2_289_463
      ),
      1_356_480
    )
    XCTAssertEqual(
      PlaybackPositionResolver.resolve(
        baseSample: 640_000,
        renderedElapsedSamples: 0,
        reportedSampleFloor: 640_000,
        durationSamples: 2_289_463
      ),
      640_000
    )
  }

  func testPlaybackInterruptionsPreservePositionAndRequireExplicitResume() throws {
    let sessionURL = rootURL.appendingPathComponent("session_interruptions", isDirectory: true)
    let store = try SessionStore(directoryURL: sessionURL, create: true, title: "Interruptions")
    let data = Data(repeating: 0, count: 16_000 * 30 * 2)
    let path = "audio/chunk_000000.pcm"
    try data.write(to: sessionURL.appendingPathComponent(path))
    try store.commitChunk(
      index: 0, relativePath: path, sampleCount: 480_000,
      byteCount: Int64(data.count), sha256: SessionStore.sha256(data),
      lastCommittedSample: 480_000)
    try store.updateStatus("completed", stopped: true)
    let center = NotificationCenter()
    let player = CommittedAudioPlayer(notificationCenter: center)
    var latest: [String: Any] = [:]
    player.setEventHandler { latest = $0 }

    func command(_ operation: (@escaping CommittedAudioPlayer.Completion) -> Void) throws
      -> [String: Any]
    {
      let done = expectation(description: "playback command")
      var result: Result<[String: Any], Error>?
      operation {
        result = $0
        done.fulfill()
      }
      wait(for: [done], timeout: 15)
      return try XCTUnwrap(result).get()
    }
    func post(_ name: Notification.Name, info: [AnyHashable: Any] = [:]) throws {
      center.post(name: name, object: nil, userInfo: info)
      // A command on the same queue also waits for the preceding event delivery.
      _ = try command { player.soundSettings(completion: $0) }
    }
    defer { player.stop { _ in } }
    _ = try command {
      player.play(
        directoryPath: sessionURL.path, sampleOffset: 32_000,
        anchorID: "anchor", anchorType: "transcript", completion: $0)
    }
    try post(
      AVAudioSession.routeChangeNotification,
      info: [
        AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.newDeviceAvailable
          .rawValue
      ])
    XCTAssertEqual(latest["state"] as? String, "playing")
    try post(
      AVAudioSession.interruptionNotification,
      info: [
        AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue
      ])
    XCTAssertEqual(latest["state"] as? String, "paused")
    let position = try XCTUnwrap((latest["positionSample"] as? NSNumber)?.int64Value)
    XCTAssertGreaterThanOrEqual(position, 32_000)
    try post(
      AVAudioSession.interruptionNotification,
      info: [
        AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
        AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume
          .rawValue,
      ])
    XCTAssertEqual(latest["state"] as? String, "paused")
    let resumed = try command { player.resume(completion: $0) }
    XCTAssertEqual(resumed["state"] as? String, "playing")
    XCTAssertGreaterThanOrEqual((resumed["positionSample"] as? NSNumber)?.int64Value ?? 0, position)
    try post(
      AVAudioSession.routeChangeNotification,
      info: [
        AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable
          .rawValue
      ])
    XCTAssertEqual(latest["state"] as? String, "paused")
    let sought = try command { player.seek(sampleOffset: 16_000, completion: $0) }
    XCTAssertEqual(sought["state"] as? String, "paused")
    XCTAssertEqual((sought["positionSample"] as? NSNumber)?.int64Value, 16_000)
    _ = try command { player.resume(completion: $0) }
    try post(AVAudioSession.mediaServicesWereResetNotification)
    XCTAssertEqual(latest["state"] as? String, "paused")
    XCTAssertEqual((try command { player.resume(completion: $0) })["state"] as? String, "playing")
    _ = try command { player.stop(completion: $0) }
    try post(
      AVAudioSession.interruptionNotification,
      info: [
        AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue
      ])
    XCTAssertEqual(latest["state"] as? String, "idle")
  }

  func testCommittedAudioPlayerStartsWithDeviceOutputFormat() throws {
    let sessionURL = rootURL.appendingPathComponent("session_engine_playback", isDirectory: true)
    let store = try SessionStore(directoryURL: sessionURL, create: true, title: "Engine playback")
    var samples: Int64 = 0
    for (index, count) in [16_000, 16_000, 7_311].enumerated() {
      let data = Data(repeating: 0, count: count * 2)
      let relativePath = String(format: "audio/chunk_%06d.pcm", index)
      try data.write(to: sessionURL.appendingPathComponent(relativePath))
      samples += Int64(count)
      try store.commitChunk(
        index: index, relativePath: relativePath, sampleCount: Int64(count),
        byteCount: Int64(data.count), sha256: SessionStore.sha256(data),
        lastCommittedSample: samples)
    }
    try store.updateStatus("completed", stopped: true)

    let suite = "playback-engine-test-" + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let player = CommittedAudioPlayer(soundDefaults: defaults)
    let started = expectation(description: "playback engine starts")
    var startResult: Result<[String: Any], Error>?
    player.play(
      directoryPath: sessionURL.path,
      sampleOffset: 1_000,
      anchorID: "test_anchor",
      anchorType: "transcript"
    ) {
      startResult = $0
      started.fulfill()
    }
    // A freshly cloned iOS Simulator may take several seconds to provision its
    // first audio route even though the same engine starts immediately afterward.
    wait(for: [started], timeout: 15)
    let snapshot = try XCTUnwrap(startResult).get()
    XCTAssertEqual(snapshot["state"] as? String, "playing")
    XCTAssertEqual((snapshot["positionSample"] as? NSNumber)?.int64Value, 1_000)
    XCTAssertEqual(AVAudioSession.sharedInstance().category, .playback)
    XCTAssertEqual(AVAudioSession.sharedInstance().mode, .default)
    XCTAssertNotNil(snapshot["outputPortType"])
    XCTAssertNotNil(snapshot["outputVolume"])
    XCTAssertEqual(
      (snapshot["signalGainDb"] as? NSNumber)?.doubleValue ?? 0,
      0,
      accuracy: 0.001
    )
    XCTAssertEqual(
      (snapshot["limiterThreshold"] as? NSNumber)?.floatValue ?? 0,
      PlaybackSignalProcessor.limiterThreshold,
      accuracy: 0.001
    )

    let paused = expectation(description: "playback engine pauses")
    var pauseResult: Result<[String: Any], Error>?
    player.pause {
      pauseResult = $0
      paused.fulfill()
    }
    wait(for: [paused], timeout: 5)
    let pauseSnapshot = try XCTUnwrap(pauseResult).get()
    let pausedSample = try XCTUnwrap(
      (pauseSnapshot["positionSample"] as? NSNumber)?.int64Value
    )

    let resumed = expectation(description: "playback engine resumes")
    var resumeResult: Result<[String: Any], Error>?
    player.resume {
      resumeResult = $0
      resumed.fulfill()
    }
    wait(for: [resumed], timeout: 5)
    let resumeSnapshot = try XCTUnwrap(resumeResult).get()
    let resumedSample = try XCTUnwrap(
      (resumeSnapshot["positionSample"] as? NSNumber)?.int64Value
    )
    XCTAssertGreaterThanOrEqual(resumedSample, pausedSample)

    let completed = expectation(description: "all short slices reach the end")
    let expectedSamples = samples
    var reachedEnd = false
    player.setEventHandler { snapshot in
      if snapshot["state"] as? String == "completed" && !reachedEnd {
        reachedEnd = true
        XCTAssertEqual((snapshot["positionSample"] as? NSNumber)?.int64Value, expectedSamples)
        completed.fulfill()
      }
    }
    wait(for: [completed], timeout: 5)
    player.setEventHandler(nil)

    let stopped = expectation(description: "playback engine stops")
    player.stop { result in
      switch result {
      case .success:
        break
      case .failure(let error):
        XCTFail("Playback stop failed: \(error.localizedDescription)")
      }
      stopped.fulfill()
    }
    wait(for: [stopped], timeout: 5)
  }

  func testRecoveryFinalizesOrRejectsPendingImagesAndDetectsMissingCommittedFile() throws {
    let sessionURL = rootURL.appendingPathComponent("session_image_recovery", isDirectory: true)
    let store = try SessionStore(directoryURL: sessionURL, create: true, title: "Image recovery")
    try store.updateStatus("recording")
    let clock = ClockSnapshot(
      sampleOffset: 0,
      atMs: 0,
      monotonicElapsedNs: 1,
      wallTime: "2026-08-15T12:00:00Z",
      clockEpochID: "clock_recovery"
    )
    _ = try store.beginImageCapture(
      eventID: "evt_durable",
      blobID: "blob_durable",
      relativePath: "assets/blob_durable.jpg",
      clock: clock
    )
    _ = try store.beginImageCapture(
      eventID: "evt_partial",
      blobID: "blob_partial",
      relativePath: "assets/blob_partial.jpg",
      clock: clock
    )
    let jpeg = Data([0xFF, 0xD8, 0x11, 0x22, 0xFF, 0xD9])
    let durableURL = sessionURL.appendingPathComponent("assets/blob_durable.jpg")
    let partialURL = sessionURL.appendingPathComponent("assets/blob_partial.jpg.part")
    try jpeg.write(to: durableURL)
    try Data([0xFF, 0xD8]).write(to: partialURL)

    let coordinator = RecoveryCoordinator()
    let first = try coordinator.recover(directoryPath: sessionURL.path)
    XCTAssertEqual((first["imageCommittedCount"] as? NSNumber)?.intValue, 1)
    XCTAssertEqual((first["imageFailedCount"] as? NSNumber)?.intValue, 1)
    XCTAssertEqual((first["capturePendingCount"] as? NSNumber)?.intValue, 0)
    XCTAssertTrue(fileManagerExists(partialURL.appendingPathExtension("quarantine")))

    try FileManager.default.removeItem(at: durableURL)
    let second = try coordinator.recover(directoryPath: sessionURL.path)
    XCTAssertEqual((second["imageCommittedCount"] as? NSNumber)?.intValue, 0)
    XCTAssertEqual((second["imageFailedCount"] as? NSNumber)?.intValue, 2)
    let invalidated = try XCTUnwrap(
      SessionStore(directoryURL: sessionURL, create: false)
        .captureAsset(eventID: "evt_durable")
    )
    XCTAssertEqual(invalidated.captureState, "failed")
    XCTAssertEqual(invalidated.assetState, "missing")
  }

  func testSessionExporterCreatesPortableIntegrityCheckedBundle() throws {
    let sessionURL = rootURL.appendingPathComponent("session_export", isDirectory: true)
    let store = try SessionStore(directoryURL: sessionURL, create: true, title: "Export test")
    let audio = Data((0..<32_000).map { UInt8($0 % 251) })
    let chunkURL = sessionURL.appendingPathComponent("audio/chunk_000000.pcm")
    try audio.write(to: chunkURL)
    try store.commitChunk(
      index: 0,
      relativePath: "audio/chunk_000000.pcm",
      sampleCount: 16_000,
      byteCount: Int64(audio.count),
      sha256: SessionStore.sha256(audio),
      lastCommittedSample: 16_000
    )
    _ = try store.commitTranscriptSegment([
      "segmentId": "seg_export",
      "sessionId": store.sessionID,
      "startSample": 0,
      "endSample": 8_000,
      "text": "导出中的真实转写。",
      "rawText": "导出中的真实转写",
      "language": "zh",
      "source": "sherpa_onnx",
      "modelId": "test-model",
      "isFinal": true,
    ])
    let imageClock = ClockSnapshot(
      sampleOffset: 4_000,
      atMs: 250,
      monotonicElapsedNs: 10,
      wallTime: "2026-08-16T00:00:00Z",
      clockEpochID: "clock_export"
    )
    _ = try store.beginImageCapture(
      eventID: "evt_image_export",
      blobID: "blob_image_export",
      relativePath: "assets/blob_image_export.jpg",
      clock: imageClock
    )
    let jpeg = Data([0xFF, 0xD8, 0x10, 0x20, 0x30, 0xFF, 0xD9])
    try jpeg.write(to: sessionURL.appendingPathComponent("assets/blob_image_export.jpg"))
    _ = try store.commitImageCapture(
      eventID: "evt_image_export",
      byteCount: Int64(jpeg.count),
      sha256: SessionStore.sha256(jpeg)
    )
    _ = try store.commitBookmark(
      eventID: "evt_bookmark_export",
      clock: ClockSnapshot(
        sampleOffset: 8_000,
        atMs: 500,
        monotonicElapsedNs: 20,
        wallTime: "2026-08-16T00:00:01Z",
        clockEpochID: "clock_export"
      )
    )
    _ = try store.commitThought(
      eventID: "evt_thought_export",
      text: "导出文字随想",
      clock: ClockSnapshot(
        sampleOffset: 12_000,
        atMs: 750,
        monotonicElapsedNs: 30,
        wallTime: "2026-08-16T00:00:02Z",
        clockEpochID: "clock_export"
      )
    )
    try store.updateStatus("completed", stopped: true)

    let originalAudioHash = SessionStore.sha256(audio)
    let fixedDate = Date(timeIntervalSince1970: 1_787_000_000)
    let result = try SessionExporter(now: { fixedDate }).export(directoryPath: sessionURL.path)
    XCTAssertEqual(result["sessionId"] as? String, "session_export")
    XCTAssertEqual((result["audioSamples"] as? NSNumber)?.int64Value, 16_000)
    XCTAssertEqual((result["durationMs"] as? NSNumber)?.int64Value, 1_000)
    XCTAssertEqual((result["timelineItemCount"] as? NSNumber)?.intValue, 4)
    XCTAssertEqual((result["transcriptCount"] as? NSNumber)?.intValue, 1)
    XCTAssertEqual(result["canonicalTextStatus"] as? String, "live")
    XCTAssertEqual(result["canonicalTextLayer"] as? String, "live")
    XCTAssertEqual((result["refinedTranscriptCount"] as? NSNumber)?.intValue, 0)
    XCTAssertEqual((result["fallbackTranscriptCount"] as? NSNumber)?.intValue, 0)
    XCTAssertEqual((result["imageCount"] as? NSNumber)?.intValue, 1)
    XCTAssertEqual((result["payloadFileCount"] as? NSNumber)?.intValue, 5)

    let wavURL = URL(fileURLWithPath: try XCTUnwrap(result["audioPath"] as? String))
    let wav = try Data(contentsOf: wavURL)
    XCTAssertEqual(wav.count, 32_044)
    XCTAssertEqual(String(data: wav.prefix(4), encoding: .ascii), "RIFF")
    XCTAssertEqual(String(data: wav[8..<12], encoding: .ascii), "WAVE")
    XCTAssertEqual(wav.suffix(audio.count), audio)

    let jsonURL = URL(fileURLWithPath: try XCTUnwrap(result["jsonPath"] as? String))
    let jsonData = try Data(contentsOf: jsonURL)
    let document = try XCTUnwrap(
      JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
    )
    XCTAssertEqual((document["schemaVersion"] as? NSNumber)?.intValue, 1)
    XCTAssertEqual((document["timeline"] as? [[String: Any]])?.count, 4)
    let liveTimeline = try XCTUnwrap(document["timeline"] as? [[String: Any]])
    let liveTranscript = try XCTUnwrap(
      liveTimeline.first { $0["kind"] as? String == "transcript" }
    )
    XCTAssertEqual(liveTranscript["text"] as? String, "导出中的真实转写。")
    XCTAssertEqual(liveTranscript["liveText"] as? String, "导出中的真实转写。")
    XCTAssertEqual(liveTranscript["displayText"] as? String, "导出中的真实转写。")
    XCTAssertEqual(liveTranscript["textLayer"] as? String, "live")
    XCTAssertTrue(liveTranscript["refinedText"] is NSNull)
    let liveCanonicalText = try XCTUnwrap(document["canonicalText"] as? [String: Any])
    XCTAssertEqual(liveCanonicalText["format"] as? String, "org.hohu.momentai.canonical-text")
    XCTAssertEqual(liveCanonicalText["status"] as? String, "live")
    XCTAssertEqual((liveCanonicalText["segmentCount"] as? NSNumber)?.intValue, 1)
    XCTAssertFalse(String(data: jsonData, encoding: .utf8)?.contains(sessionURL.path) ?? true)

    let jsonlURL = URL(fileURLWithPath: try XCTUnwrap(result["jsonlPath"] as? String))
    let jsonl = try String(contentsOf: jsonlURL, encoding: .utf8)
      .split(separator: "\n")
    XCTAssertEqual(jsonl.count, 4)
    XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(jsonl[0].utf8)))

    let archiveURL = URL(fileURLWithPath: try XCTUnwrap(result["archivePath"] as? String))
    let archive = try Data(contentsOf: archiveURL)
    XCTAssertEqual(Array(archive.prefix(4)), [0x50, 0x4B, 0x03, 0x04])
    XCTAssertTrue(String(decoding: archive, as: UTF8.self).contains("manifest.json"))
    XCTAssertEqual(try SessionExporter.sha256File(chunkURL), originalAudioHash)
    XCTAssertTrue(fileManagerExists(sessionURL.appendingPathComponent("stage1_export_probe.json")))
  }

  func testSessionExporterAddsNonDestructiveRefinedAndCanonicalText() throws {
    let sessionURL = rootURL.appendingPathComponent("session_export_refined", isDirectory: true)
    let store = try SessionStore(directoryURL: sessionURL, create: true, title: "Refined export")
    let audio = Data(repeating: 0x31, count: 32_000)
    let chunkURL = sessionURL.appendingPathComponent("audio/chunk_000000.pcm")
    try audio.write(to: chunkURL)
    try store.commitChunk(
      index: 0,
      relativePath: "audio/chunk_000000.pcm",
      sampleCount: 16_000,
      byteCount: Int64(audio.count),
      sha256: SessionStore.sha256(audio),
      lastCommittedSample: 16_000
    )
    for (segmentID, startSample, endSample, text) in [
      ("seg_refined_1", 0, 8_000, "第一段实时原文。"),
      ("seg_refined_2", 8_000, 16_000, "第二段实时原文。"),
    ] {
      _ = try store.commitTranscriptSegment([
        "segmentId": segmentID,
        "sessionId": store.sessionID,
        "startSample": startSample,
        "endSample": endSample,
        "text": text,
        "rawText": "raw-\(segmentID)",
        "isFinal": true,
      ])
    }
    try store.updateStatus("completed", stopped: true)
    let sourceTimeline = try store.timeline()
    let fingerprint = try SessionExporter.sourceTimelineFingerprint(sourceTimeline)
    XCTAssertEqual(
      fingerprint,
      "sha256:1ce27d71c1510ba44e2f6180d66068504f646cd4487a4545b5b3961b5fc2e0aa"
    )
    let refinement: [String: Any] = [
      "schemaVersion": 4,
      "status": "ready",
      "sessionId": store.sessionID,
      "modelId": "sensevoice-test",
      "fullText": "第一段精修文字。第二段实时原文。",
      "sourceAudioSamples": 16_000,
      "sampleRate": 16_000,
      "createdAt": "2026-08-30T08:00:00Z",
      "sourceTimelineFingerprint": fingerprint,
      "composerVersion": 4,
      "timelineProjection": [
        [
          "segmentId": "seg_refined_1",
          "startSample": 0,
          "endSample": 8_000,
          "refinedText": "第一段精修文字。",
          "fallback": false,
        ],
        [
          "segmentId": "seg_refined_2",
          "startSample": 8_000,
          "endSample": 16_000,
          "refinedText": "第二段实时原文。",
          "fallback": true,
        ],
      ],
    ]
    let refinementData = try JSONSerialization.data(
      withJSONObject: refinement,
      options: [.sortedKeys]
    )
    try refinementData.write(
      to: sessionURL.appendingPathComponent("full_text_refinement.json"),
      options: .atomic
    )

    let result = try SessionExporter(
      now: { Date(timeIntervalSince1970: 1_787_000_100) }
    ).export(directoryPath: sessionURL.path)
    XCTAssertEqual(result["canonicalTextStatus"] as? String, "partial")
    XCTAssertEqual(result["canonicalTextLayer"] as? String, "refined")
    XCTAssertEqual((result["refinedTranscriptCount"] as? NSNumber)?.intValue, 1)
    XCTAssertEqual((result["fallbackTranscriptCount"] as? NSNumber)?.intValue, 1)

    let document = try XCTUnwrap(
      JSONSerialization.jsonObject(
        with: Data(contentsOf: URL(fileURLWithPath: try XCTUnwrap(result["jsonPath"] as? String)))
      ) as? [String: Any]
    )
    let timeline = try XCTUnwrap(document["timeline"] as? [[String: Any]])
      .filter { $0["kind"] as? String == "transcript" }
    XCTAssertEqual(timeline.count, 2)
    XCTAssertEqual(timeline[0]["text"] as? String, "第一段实时原文。")
    XCTAssertEqual(timeline[0]["rawText"] as? String, "raw-seg_refined_1")
    XCTAssertEqual(timeline[0]["refinedText"] as? String, "第一段精修文字。")
    XCTAssertEqual(timeline[0]["displayText"] as? String, "第一段精修文字。")
    XCTAssertEqual(timeline[0]["textLayer"] as? String, "refined")
    XCTAssertEqual(timeline[1]["text"] as? String, "第二段实时原文。")
    XCTAssertTrue(timeline[1]["refinedText"] is NSNull)
    XCTAssertEqual(timeline[1]["displayText"] as? String, "第二段实时原文。")
    XCTAssertEqual(timeline[1]["textLayer"] as? String, "fallback")

    let canonicalText = try XCTUnwrap(document["canonicalText"] as? [String: Any])
    XCTAssertEqual(canonicalText["status"] as? String, "partial")
    XCTAssertEqual(canonicalText["defaultTextLayer"] as? String, "refined")
    XCTAssertEqual(canonicalText["fullText"] as? String, "第一段精修文字。第二段实时原文。")
    let canonicalSegments = try XCTUnwrap(canonicalText["segments"] as? [[String: Any]])
    XCTAssertEqual((canonicalSegments[0]["startSample"] as? NSNumber)?.int64Value, 0)
    XCTAssertEqual((canonicalSegments[1]["endSample"] as? NSNumber)?.int64Value, 16_000)
    XCTAssertEqual(canonicalSegments[0]["textLayer"] as? String, "refined")
    XCTAssertEqual(canonicalSegments[1]["textLayer"] as? String, "fallback")

    let markdown = try String(
      contentsOf: URL(fileURLWithPath: try XCTUnwrap(result["markdownPath"] as? String)),
      encoding: .utf8
    )
    XCTAssertTrue(markdown.contains("第一段精修文字。"))
    XCTAssertFalse(markdown.contains("第一段实时原文。"))
    XCTAssertTrue(markdown.contains("第二段实时原文。"))
    XCTAssertTrue(markdown.contains(NativeStrings.text("export_refined_partial", "1")))

    let unchanged = try store.timeline().filter { $0["kind"] as? String == "transcript" }
    XCTAssertEqual(unchanged[0]["text"] as? String, "第一段实时原文。")
    XCTAssertNil(unchanged[0]["refinedText"])
  }

  func testSessionExporterFallsBackForStaleAndFailedRefinement() throws {
    for (suffix, payloadStatus, expectedStatus) in [
      ("stale", "ready", "stale"),
      ("failed", "failed", "failed"),
    ] {
      let sessionURL = rootURL.appendingPathComponent("session_export_\(suffix)", isDirectory: true)
      let store = try SessionStore(directoryURL: sessionURL, create: true, title: suffix)
      let audio = Data(repeating: 0x41, count: 32_000)
      let chunkURL = sessionURL.appendingPathComponent("audio/chunk_000000.pcm")
      try audio.write(to: chunkURL)
      try store.commitChunk(
        index: 0,
        relativePath: "audio/chunk_000000.pcm",
        sampleCount: 16_000,
        byteCount: Int64(audio.count),
        sha256: SessionStore.sha256(audio),
        lastCommittedSample: 16_000
      )
      _ = try store.commitTranscriptSegment([
        "segmentId": "seg_\(suffix)",
        "sessionId": store.sessionID,
        "startSample": 0,
        "endSample": 16_000,
        "text": "\(suffix)-live-text",
        "rawText": "\(suffix)-raw-text",
        "isFinal": true,
      ])
      try store.updateStatus("completed", stopped: true)
      let refinement: [String: Any] = [
        "schemaVersion": 4,
        "status": payloadStatus,
        "sessionId": store.sessionID,
        "modelId": "stale-model",
        "fullText": "must-not-export-refined",
        "sourceAudioSamples": 16_000,
        "sampleRate": 16_000,
        "sourceTimelineFingerprint": "sha256:not-current",
        "composerVersion": 4,
        "timelineProjection": [
          [
            "segmentId": "seg_\(suffix)",
            "startSample": 0,
            "endSample": 16_000,
            "refinedText": "must-not-export-refined",
            "fallback": false,
          ]
        ],
      ]
      try JSONSerialization.data(withJSONObject: refinement).write(
        to: sessionURL.appendingPathComponent("full_text_refinement.json"),
        options: .atomic
      )
      let result = try SessionExporter(
        now: { Date(timeIntervalSince1970: 1_787_000_200) }
      ).export(directoryPath: sessionURL.path)
      XCTAssertEqual(result["canonicalTextStatus"] as? String, expectedStatus)
      XCTAssertEqual(result["canonicalTextLayer"] as? String, "live")
      XCTAssertEqual((result["refinedTranscriptCount"] as? NSNumber)?.intValue, 0)
      let document = try XCTUnwrap(
        JSONSerialization.jsonObject(
          with: Data(contentsOf: URL(fileURLWithPath: try XCTUnwrap(result["jsonPath"] as? String)))
        ) as? [String: Any]
      )
      let canonicalText = try XCTUnwrap(document["canonicalText"] as? [String: Any])
      XCTAssertEqual(canonicalText["status"] as? String, expectedStatus)
      XCTAssertEqual(canonicalText["defaultTextLayer"] as? String, "live")
      XCTAssertEqual(canonicalText["fullText"] as? String, "\(suffix)-live-text")
      let transcript = try XCTUnwrap(
        (document["timeline"] as? [[String: Any]])?.first {
          $0["kind"] as? String == "transcript"
        }
      )
      XCTAssertEqual(transcript["text"] as? String, "\(suffix)-live-text")
      XCTAssertEqual(transcript["displayText"] as? String, "\(suffix)-live-text")
      XCTAssertEqual(transcript["textLayer"] as? String, "live")
      XCTAssertTrue(transcript["refinedText"] is NSNull)
      let markdown = try String(
        contentsOf: URL(fileURLWithPath: try XCTUnwrap(result["markdownPath"] as? String)),
        encoding: .utf8
      )
      XCTAssertTrue(markdown.contains("\(suffix)-live-text"))
      XCTAssertFalse(markdown.contains("must-not-export-refined"))
    }
  }

  func testSessionExporterRejectsActiveAndTamperedSessions() throws {
    let sessionURL = rootURL.appendingPathComponent("session_export_reject", isDirectory: true)
    let store = try SessionStore(directoryURL: sessionURL, create: true, title: "Reject export")
    let audio = Data(repeating: 0x42, count: 32_000)
    let chunkURL = sessionURL.appendingPathComponent("audio/chunk_000000.pcm")
    try audio.write(to: chunkURL)
    try store.commitChunk(
      index: 0,
      relativePath: "audio/chunk_000000.pcm",
      sampleCount: 16_000,
      byteCount: Int64(audio.count),
      sha256: SessionStore.sha256(audio),
      lastCommittedSample: 16_000
    )
    try store.updateStatus("recording")
    XCTAssertThrowsError(try SessionExporter().export(directoryPath: sessionURL.path))

    try store.updateStatus("completed", stopped: true)
    try Data(repeating: 0x43, count: 32_000).write(to: chunkURL)
    XCTAssertThrowsError(try SessionExporter().export(directoryPath: sessionURL.path))
  }

  func testProductSessionRepositoryListsRenamesCountsAndDeletes() throws {
    let sessionURL = rootURL.appendingPathComponent("session_product_complete", isDirectory: true)
    var store: SessionStore? = try SessionStore(
      directoryURL: sessionURL,
      create: true,
      title: "现场访谈"
    )
    let audio = Data(repeating: 0x21, count: 32_000)
    let chunkURL = sessionURL.appendingPathComponent("audio/chunk_000000.pcm")
    try audio.write(to: chunkURL)
    try store?.commitChunk(
      index: 0,
      relativePath: "audio/chunk_000000.pcm",
      sampleCount: 16_000,
      byteCount: Int64(audio.count),
      sha256: SessionStore.sha256(audio),
      lastCommittedSample: 16_000
    )
    _ = try store?.commitTranscriptSegment([
      "segmentId": "seg_product",
      "sessionId": "session_product_complete",
      "startSample": 0,
      "endSample": 8_000,
      "text": "产品数据层测试",
      "isFinal": true,
    ])
    _ = try store?.commitBookmark(
      eventID: "evt_product_bookmark",
      clock: ClockSnapshot(
        sampleOffset: 8_000,
        atMs: 500,
        monotonicElapsedNs: 1,
        wallTime: "2026-08-17T12:00:00Z",
        clockEpochID: "clock_product"
      )
    )
    try store?.updateStatus("completed", stopped: true)
    store = nil

    let invalidURL = rootURL.appendingPathComponent("session_invalid", isDirectory: true)
    try FileManager.default.createDirectory(at: invalidURL, withIntermediateDirectories: true)
    let repository = ProductSessionRepository(
      rootURLProvider: { self.rootURL },
      activeDirectoryProvider: { nil }
    )

    let listed = try repository.listSessions()
    XCTAssertEqual(listed.count, 1)
    XCTAssertEqual(listed[0]["title"] as? String, "现场访谈")
    XCTAssertEqual((listed[0]["durationMs"] as? NSNumber)?.int64Value, 1_000)
    XCTAssertEqual((listed[0]["transcriptCount"] as? NSNumber)?.int64Value, 1)
    XCTAssertEqual((listed[0]["bookmarkCount"] as? NSNumber)?.int64Value, 1)
    XCTAssertEqual(listed[0]["exportAvailable"] as? Bool, true)

    let renamed = try repository.rename(
      sessionID: "session_product_complete",
      title: "  重新命名的访谈  "
    )
    XCTAssertEqual(renamed["title"] as? String, "重新命名的访谈")
    XCTAssertThrowsError(
      try repository.rename(sessionID: "session_product_complete", title: "   ")
    )

    let exportRoot = rootURL.appendingPathComponent("Exports", isDirectory: true)
    let exportURL = exportRoot.appendingPathComponent(
      "session_product_complete_20260817.momentai"
    )
    try FileManager.default.createDirectory(at: exportRoot, withIntermediateDirectories: true)
    try Data([1, 2, 3]).write(to: exportURL)
    let storage = try repository.storageOverview()
    XCTAssertEqual((storage["sessionCount"] as? NSNumber)?.intValue, 1)
    XCTAssertGreaterThan((storage["appUsedBytes"] as? NSNumber)?.int64Value ?? 0, 0)

    try repository.delete(sessionID: "session_product_complete")
    XCTAssertFalse(FileManager.default.fileExists(atPath: sessionURL.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: exportURL.path))
    XCTAssertTrue(try repository.listSessions().isEmpty)
  }

  func testProductSessionRepositoryRejectsActiveAndEscapingSessions() throws {
    let sessionURL = rootURL.appendingPathComponent("session_product_active", isDirectory: true)
    let store = try SessionStore(directoryURL: sessionURL, create: true, title: "Active")
    try store.updateStatus("recording")
    let repository = ProductSessionRepository(
      rootURLProvider: { self.rootURL },
      activeDirectoryProvider: { sessionURL.path }
    )

    XCTAssertThrowsError(try repository.delete(sessionID: "session_product_active"))
    XCTAssertThrowsError(
      try repository.rename(sessionID: "session_product_active", title: "Should fail")
    )
    XCTAssertThrowsError(try repository.session(sessionID: "../session_product_active"))
    XCTAssertTrue(FileManager.default.fileExists(atPath: sessionURL.path))
  }

  func testProductSummaryPreservesHistoricalGapEvidenceWithoutMutatingStore() throws {
    let sessionURL = rootURL.appendingPathComponent("session_historical_gap", isDirectory: true)
    let store = try SessionStore(directoryURL: sessionURL, create: true, title: "Historical gap")
    try store.updateStatus("recording")
    try store.updateStatus("completed", stopped: true)
    let probe = try JSONSerialization.data(withJSONObject: [
      "schema_version": 1,
      "final_status": "completed_with_gaps",
      "final_rpo_ms": 0,
    ])
    try probe.write(
      to: sessionURL.appendingPathComponent(Stage1S15Probe.enduranceFileName),
      options: .atomic
    )

    let summary = try store.productSummary()
    XCTAssertEqual(summary["state"] as? String, "completed_with_gaps")
    XCTAssertEqual(summary["persistedState"] as? String, "completed")
    XCTAssertEqual(summary["statusReconciledForDisplay"] as? Bool, true)
    XCTAssertEqual(summary["hasConfirmedGaps"] as? Bool, true)
    XCTAssertEqual(try store.snapshot()["state"] as? String, "completed")
  }

  func testS15StorageThresholdIsDeterministic() {
    let minimum: Int64 = 512 * 1_048_576
    XCTAssertFalse(
      Stage1S15Probe.hasSufficientStorage(
        availableBytes: minimum - 1,
        minimumBytes: minimum
      )
    )
    XCTAssertTrue(
      Stage1S15Probe.hasSufficientStorage(
        availableBytes: minimum,
        minimumBytes: minimum
      )
    )
  }

  func testS15ProbePersistsLifecycleAndFinalHighWater() throws {
    let sessionURL = rootURL.appendingPathComponent("session_s15_probe", isDirectory: true)
    try FileManager.default.createDirectory(at: sessionURL, withIntermediateDirectories: true)
    let probe = Stage1S15Probe()
    probe.start(
      directoryURL: sessionURL,
      samples: 0,
      applicationState: "active",
      protectedDataAvailable: true
    )
    probe.noteLifecycle(type: "application_background", samples: 16_000)
    probe.noteLifecycle(type: "protected_data_unavailable", samples: 16_000)
    probe.noteProgress(samples: 32_000, state: "recording")
    _ = probe.snapshot()
    probe.noteLifecycle(type: "protected_data_available", samples: 32_000)
    probe.noteLifecycle(type: "application_foreground", samples: 32_000)
    _ = probe.snapshot()
    probe.finish(samples: 32_000, state: "completed", rpoMs: 0)

    let data = try Data(
      contentsOf: sessionURL.appendingPathComponent(Stage1S15Probe.enduranceFileName)
    )
    let document = try XCTUnwrap(
      JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    XCTAssertEqual(document["active"] as? Bool, false)
    XCTAssertEqual(document["final_status"] as? String, "completed")
    XCTAssertEqual((document["latest_samples"] as? NSNumber)?.int64Value, 32_000)
    XCTAssertEqual((document["final_rpo_ms"] as? NSNumber)?.int64Value, 0)
    XCTAssertEqual((document["background_count"] as? NSNumber)?.intValue, 1)
    XCTAssertEqual(
      (document["protected_data_unavailable_count"] as? NSNumber)?.intValue,
      1
    )
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: sessionURL.appendingPathComponent(Stage1S15Probe.compatibilityFileName).path
      )
    )
  }

  func testReleaseFacingBundleMetadataUsesProductLanguage() throws {
    let info = Bundle(for: AppDelegate.self).infoDictionary
    XCTAssertEqual(info?["CFBundleDisplayName"] as? String, "MomentAI")

    let microphone = try XCTUnwrap(
      info?["NSMicrophoneUsageDescription"] as? String
    )
    let camera = try XCTUnwrap(info?["NSCameraUsageDescription"] as? String)
    XCTAssertTrue(microphone.contains("主动开始"))
    XCTAssertTrue(microphone.contains("只保存在本机"))
    XCTAssertTrue(camera.contains("对应录音时刻"))
    for engineeringTerm in ["Stage", "PoC", "RPO", "Chunk", "sample"] {
      XCTAssertFalse(microphone.localizedCaseInsensitiveContains(engineeringTerm))
      XCTAssertFalse(camera.localizedCaseInsensitiveContains(engineeringTerm))
    }
  }

  func testProductOverviewReportsBundledLightweightModel() {
    XCTAssertEqual(
      ProductSessionRepositoryBridge.modelID,
      "sherpa-onnx-streaming-zipformer-zh-14M-2023-02-23"
    )
  }

  private func writeProbe(observedSamples: Int64, to directory: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: [
      "observed_samples": observedSamples,
      "sample_rate": 16_000,
      "wall_time": "2026-08-12T00:00:00Z",
      "instrumentation_only": true,
    ])
    try data.write(to: directory.appendingPathComponent("capture_highwater.probe.json"))
  }

  private func fileManagerExists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path)
  }
}
