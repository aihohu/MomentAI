import AVFoundation
import Darwin
import Foundation
import UIKit

enum RecordingRuntimeError: LocalizedError {
  case busy
  case microphoneDenied
  case invalidInputFormat
  case noActiveSession
  case insufficientStorage(Int64)
  case interruptionStressAlreadyRunning
  case interruptionStressCancelled

  var errorDescription: String? {
    switch self {
    case .busy: return "A recording session is already active."
    case .microphoneDenied: return "Microphone permission was not granted."
    case .invalidInputFormat: return "The microphone did not provide a usable PCM format."
    case .noActiveSession: return "No recording session is active."
    case .insufficientStorage(let bytes):
      return "Only \(bytes / 1_048_576) MB is available; at least 512 MB is required for this PoC."
    case .interruptionStressAlreadyRunning:
      return "An interruption stress test is already running."
    case .interruptionStressCancelled:
      return "The interruption stress test was cancelled before all cycles completed."
    }
  }
}

private final class InterruptionStressRun {
  let runID = "interruptions_\(UUID().uuidString.lowercased())"
  let target: Int
  let durationMs: Int
  let settleMs: Int
  let startedAt = Date()
  let startSample: Int64
  let completion: (Result<[String: Any], Error>) -> Void
  var completed = 0
  var totalGapMs: Int64 = 0
  var maximumRestartAttempts = 0

  init(
    target: Int,
    durationMs: Int,
    settleMs: Int,
    startSample: Int64,
    completion: @escaping (Result<[String: Any], Error>) -> Void
  ) {
    self.target = target
    self.durationMs = durationMs
    self.settleMs = settleMs
    self.startSample = startSample
    self.completion = completion
  }
}

final class RecordingRuntime {
  typealias EventHandler = ([String: Any]) -> Void

  static let shared = RecordingRuntime()

  private let audioEngine = AVAudioEngine()
  private let persistenceQueue = DispatchQueue(
    label: "org.hohu.momentai.poc.persistence", qos: .userInitiated)
  private let probeQueue = DispatchQueue(
    label: "org.hohu.momentai.poc.capture-probe", qos: .utility)
  private let stateQueue = DispatchQueue(label: "org.hohu.momentai.poc.runtime")
  private let asrProbe = BoundedASRProbe()
  private let stage1S15Probe = Stage1S15Probe()
  private let fileManager = FileManager.default

  private let logicalSampleRate: Double = 16_000
  private let chunkDurationSamples: Int64 = 16_000
  private let captureProbeIntervalSamples: Int64 = 16_000
  private let minimumFreeBytes: Int64 = 512 * 1_048_576
  private let storageCheckIntervalChunks = 15
  private let maximumInterruptionRestartAttempts = 3

  private var store: SessionStore?
  private var sessionDirectory: URL?
  private var converter: AVAudioConverter?
  private var logicalFormat: AVAudioFormat?
  private var chunkBuffer = Data()
  private var chunkSampleCount: Int64 = 0
  private var capturedSamples: Int64 = 0
  private var committedSamples: Int64 = 0
  private var nextChunkIndex = 0
  private var lastProbeSample: Int64 = 0
  private var state = "idle"
  private var interruptionStartedAt: Date?
  private var sessionHasGaps = false
  private var activeCaptureID: UUID?
  private var persistenceCaptureID: UUID?
  // Read and written only on persistenceQueue. It lets an active paused
  // Session keep accepting anchored events without accepting microphone PCM.
  private var acceptingAudio = false
  private var tapInstalled = false
  private var eventHandler: EventHandler?
  private var clockEpochID = ""
  private var clockEpochStartedUptimeNs: UInt64 = 0
  private var interruptionStress: InterruptionStressRun?
  private var userPauseID: String?
  private var userPauseStartedAt: Date?
  private var userPauseCount = 0
  private var totalUserPausedMs: Int64 = 0

  private init() {
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleInterruption(_:)),
      name: AVAudioSession.interruptionNotification,
      object: AVAudioSession.sharedInstance()
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleApplicationLifecycle(_:)),
      name: UIApplication.didEnterBackgroundNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleApplicationLifecycle(_:)),
      name: UIApplication.willEnterForegroundNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleApplicationLifecycle(_:)),
      name: UIApplication.protectedDataWillBecomeUnavailableNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleApplicationLifecycle(_:)),
      name: UIApplication.protectedDataDidBecomeAvailableNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleRouteChange(_:)),
      name: AVAudioSession.routeChangeNotification,
      object: AVAudioSession.sharedInstance()
    )
  }

  func setEventHandler(_ handler: EventHandler?) {
    stateQueue.sync { eventHandler = handler }
  }

  func start(title: String, completion: @escaping (Result<[String: Any], Error>) -> Void) {
    let initialApplicationState = Self.applicationStateName(UIApplication.shared.applicationState)
    let initialProtectedDataAvailable = UIApplication.shared.isProtectedDataAvailable
    stateQueue.async {
      guard self.state == "idle" || self.state == "completed" || self.state == "completed_with_gaps"
      else {
        DispatchQueue.main.async { completion(.failure(RecordingRuntimeError.busy)) }
        return
      }
      let previousState = self.state
      self.state = "authorizing"

      self.requestMicrophonePermission { granted in
        guard granted else {
          self.stateQueue.async {
            self.state = previousState
            DispatchQueue.main.async {
              completion(.failure(RecordingRuntimeError.microphoneDenied))
            }
          }
          return
        }

        self.stateQueue.async {
          do {
            self.cleanupEngine()
            self.persistenceQueue.sync {
              self.persistenceCaptureID = nil
            }
            self.store = nil
            self.sessionDirectory = nil
            try self.ensureStorageCapacity()
            let directory = try self.makeSessionDirectory()
            let store = try SessionStore(directoryURL: directory, create: true, title: title)
            self.store = store
            self.sessionDirectory = directory
            self.chunkBuffer.removeAll(keepingCapacity: true)
            self.chunkSampleCount = 0
            self.capturedSamples = 0
            self.committedSamples = 0
            self.nextChunkIndex = 0
            self.lastProbeSample = 0
            self.sessionHasGaps = false
            self.clockEpochID = "clock_\(UUID().uuidString.lowercased())"
            self.clockEpochStartedUptimeNs = DispatchTime.now().uptimeNanoseconds
            self.asrProbe.reset()
            self.interruptionStress = nil
            self.userPauseID = nil
            self.userPauseStartedAt = nil
            self.userPauseCount = 0
            self.totalUserPausedMs = 0
            self.state = "preparing"
            let captureID = UUID()
            self.activeCaptureID = captureID
            self.persistenceQueue.sync {
              self.persistenceCaptureID = captureID
              self.acceptingAudio = true
            }

            try self.configureAudioSession()
            try self.installTapAndStartEngine(captureID: captureID)
            self.state = "recording"
            try store.updateStatus("recording")
            try store.insertEvent(type: "session_started", sampleOffset: 0)
            self.stage1S15Probe.start(
              directoryURL: directory,
              samples: 0,
              applicationState: initialApplicationState,
              protectedDataAvailable: initialProtectedDataAvailable
            )
            self.emitState()
            let snapshot = try self.snapshotLocked()
            DispatchQueue.main.async { completion(.success(snapshot)) }
          } catch {
            self.cleanupEngine()
            self.persistenceQueue.sync {
              self.persistenceCaptureID = nil
              self.acceptingAudio = false
            }
            try? self.store?.insertEvent(
              type: "session_start_failed",
              sampleOffset: 0,
              payload: ["error": error.localizedDescription]
            )
            try? self.store?.updateStatus("failed_to_start", stopped: true)
            self.store?.checkpoint()
            self.state = "idle"
            self.store = nil
            self.sessionDirectory = nil
            DispatchQueue.main.async { completion(.failure(error)) }
          }
        }
      }
    }
  }

  func stop(completion: @escaping (Result<[String: Any], Error>) -> Void) {
    stateQueue.async {
      guard self.store != nil, ["recording", "interrupted", "paused"].contains(self.state) else {
        DispatchQueue.main.async { completion(.failure(RecordingRuntimeError.noActiveSession)) }
        return
      }
      let stoppedWhilePaused = self.state == "paused"
      let finalStatus = self.sessionHasGaps ? "completed_with_gaps" : "completed"
      self.cancelInterruptionStressIfNeeded()
      self.state = "finalizing"
      try? self.store?.updateStatus("finalizing")
      self.cleanupEngine()
      self.emitState(extra: ["event": "finalizing"])

      self.persistenceQueue.async {
        self.acceptingAudio = false
        self.persistenceCaptureID = nil
        do {
          try self.commitPendingChunk()
          if stoppedWhilePaused {
            try self.store?.closeOpenUserPause(
              sampleOffset: self.committedSamples,
              reason: "session_stopped"
            )
          }
          try self.insertASREvent(type: "stage0_asr_probe_stop_snapshot")
          try self.store?.insertEvent(type: "session_stopped", sampleOffset: self.committedSamples)
          try self.store?.updateStatus(finalStatus, stopped: true)
          self.store?.checkpoint()
          let finalRpoMs = Int64(
            Double(max(0, self.capturedSamples - self.committedSamples)) / self.logicalSampleRate
              * 1000)
          self.stage1S15Probe.finish(
            samples: self.committedSamples,
            state: finalStatus,
            rpoMs: finalRpoMs
          )
          self.stateQueue.async {
            self.state = finalStatus
            self.interruptionStartedAt = nil
            if let startedAt = self.userPauseStartedAt {
              self.totalUserPausedMs += max(
                0,
                Int64(Date().timeIntervalSince(startedAt) * 1_000)
              )
            }
            self.userPauseID = nil
            self.userPauseStartedAt = nil
            try? AVAudioSession.sharedInstance().setActive(
              false, options: [.notifyOthersOnDeactivation])
            self.emitState(extra: ["event": "session_stopped"])
            do {
              let snapshot = try self.snapshotLocked()
              DispatchQueue.main.async { completion(.success(snapshot)) }
            } catch {
              DispatchQueue.main.async { completion(.failure(error)) }
            }
          }
        } catch {
          self.stateQueue.async {
            self.state = "completed_with_gaps"
            try? self.store?.updateStatus("completed_with_gaps", stopped: true)
            self.store?.checkpoint()
            self.interruptionStartedAt = nil
            self.userPauseID = nil
            self.userPauseStartedAt = nil
            try? AVAudioSession.sharedInstance().setActive(
              false, options: [.notifyOthersOnDeactivation])
            self.emitState(extra: ["error": error.localizedDescription])
            DispatchQueue.main.async { completion(.failure(error)) }
          }
        }
      }
    }
  }

  func pause(completion: @escaping (Result<[String: Any], Error>) -> Void) {
    stateQueue.async {
      guard self.state == "recording",
        let captureID = self.activeCaptureID,
        self.store != nil
      else {
        DispatchQueue.main.async { completion(.failure(RecordingRuntimeError.noActiveSession)) }
        return
      }
      guard self.interruptionStress == nil else {
        DispatchQueue.main.async {
          completion(.failure(RecordingRuntimeError.interruptionStressAlreadyRunning))
        }
        return
      }

      let pauseID = "pause_\(UUID().uuidString.lowercased())"
      let startedAt = Date()
      self.userPauseID = pauseID
      self.userPauseStartedAt = startedAt
      self.state = "pausing"
      self.cleanupEngine(invalidateCapture: false)
      self.emitState(extra: ["event": "user_pause_committing"])

      self.persistenceQueue.async {
        do {
          // This task runs after every microphone callback already queued before
          // the tap was removed, so the final tail is durable before paused is.
          try self.commitPendingChunk()
          self.acceptingAudio = false
          let clock = self.snapshotClockOnPersistenceQueue()
          try self.store?.beginUserPause(
            pauseID: pauseID,
            sampleOffset: self.committedSamples,
            startedAt: startedAt,
            monotonicElapsedNs: clock.monotonicElapsedNs
          )
          self.stateQueue.async {
            guard self.activeCaptureID == captureID, self.state == "pausing" else { return }
            self.capturedSamples = max(self.capturedSamples, self.committedSamples)
            self.userPauseCount += 1
            self.state = "paused"
            try? AVAudioSession.sharedInstance().setActive(
              false,
              options: [.notifyOthersOnDeactivation]
            )
            self.emitState(extra: [
              "event": "user_pause_began",
              "pauseId": pauseID,
            ])
            do {
              let snapshot = try self.snapshotLocked()
              DispatchQueue.main.async { completion(.success(snapshot)) }
            } catch {
              DispatchQueue.main.async { completion(.failure(error)) }
            }
          }
        } catch {
          self.acceptingAudio = false
          self.stateQueue.async {
            self.finalizeAfterCaptureFailure(
              error: error,
              eventType: "user_pause_failed",
              payload: ["pauseId": pauseID],
              completion: completion
            )
          }
        }
      }
    }
  }

  func resume(completion: @escaping (Result<[String: Any], Error>) -> Void) {
    stateQueue.async {
      guard self.state == "paused",
        let captureID = self.activeCaptureID,
        let pauseID = self.userPauseID,
        let startedAt = self.userPauseStartedAt,
        self.store != nil
      else {
        DispatchQueue.main.async { completion(.failure(RecordingRuntimeError.noActiveSession)) }
        return
      }

      self.state = "resuming"
      self.emitState(extra: ["event": "user_resume_starting"])
      do {
        try self.configureAudioSession()
        try self.installTapAndStartEngine(captureID: captureID)
      } catch {
        self.cleanupEngine(invalidateCapture: false)
        try? AVAudioSession.sharedInstance().setActive(
          false,
          options: [.notifyOthersOnDeactivation]
        )
        self.state = "paused"
        self.emitState(extra: [
          "event": "user_resume_failed",
          "error": error.localizedDescription,
        ])
        DispatchQueue.main.async { completion(.failure(error)) }
        return
      }

      let endedAt = Date()
      self.persistenceQueue.async {
        do {
          let clock = self.snapshotClockOnPersistenceQueue()
          try self.store?.resumeUserPause(
            pauseID: pauseID,
            sampleOffset: self.committedSamples,
            startedAt: startedAt,
            endedAt: endedAt,
            monotonicElapsedNs: clock.monotonicElapsedNs
          )
          // Microphone callbacks queued before this boundary are intentionally
          // ignored; PCM is accepted only after the resume fact is durable.
          self.acceptingAudio = true
          self.stateQueue.async {
            guard self.activeCaptureID == captureID, self.state == "resuming" else { return }
            let durationMs = max(
              0,
              Int64(endedAt.timeIntervalSince(startedAt) * 1_000)
            )
            self.totalUserPausedMs += durationMs
            self.userPauseID = nil
            self.userPauseStartedAt = nil
            self.state = "recording"
            self.emitState(extra: [
              "event": "user_pause_ended",
              "pauseId": pauseID,
              "pauseDurationMs": durationMs,
            ])
            do {
              let snapshot = try self.snapshotLocked()
              DispatchQueue.main.async { completion(.success(snapshot)) }
            } catch {
              DispatchQueue.main.async { completion(.failure(error)) }
            }
          }
        } catch {
          self.acceptingAudio = false
          self.stateQueue.async {
            self.cleanupEngine(invalidateCapture: false)
            try? AVAudioSession.sharedInstance().setActive(
              false,
              options: [.notifyOthersOnDeactivation]
            )
            self.state = "paused"
            self.emitState(extra: [
              "event": "user_resume_failed",
              "error": error.localizedDescription,
            ])
            DispatchQueue.main.async { completion(.failure(error)) }
          }
        }
      }
    }
  }

  func injectAudioInterruptionForTest(
    durationMs: Int,
    completion: @escaping (Result<[String: Any], Error>) -> Void
  ) {
    stateQueue.async {
      guard self.state == "recording", let captureID = self.activeCaptureID else {
        DispatchQueue.main.async { completion(.failure(RecordingRuntimeError.noActiveSession)) }
        return
      }

      let clampedDurationMs = min(max(durationMs, 500), 10_000)
      self.interruptionStartedAt = Date()
      self.sessionHasGaps = true
      self.state = "interrupted"
      self.cleanupEngine(invalidateCapture: false)
      try? self.store?.updateStatus("interrupted")
      try? self.store?.insertEvent(
        type: "audio_interruption_began",
        sampleOffset: self.capturedSamples,
        payload: [
          "injected": true,
          "requestedDurationMs": clampedDurationMs,
        ]
      )
      self.emitState(extra: [
        "event": "interruption_began",
        "injected": true,
        "requestedDurationMs": clampedDurationMs,
      ])
      DispatchQueue.main.async {
        completion(
          .success([
            "accepted": true,
            "durationMs": clampedDurationMs,
          ]))
      }

      self.stateQueue.asyncAfter(deadline: .now() + .milliseconds(clampedDurationMs)) {
        guard self.state == "interrupted", self.activeCaptureID == captureID else { return }
        let gapMs = Int64(Date().timeIntervalSince(self.interruptionStartedAt ?? Date()) * 1000)
        self.restartAfterInterruption(
          gapMs: gapMs,
          optionsValue: AVAudioSession.InterruptionOptions.shouldResume.rawValue,
          attempt: 1,
          injected: true
        )
      }
    }
  }

  func runInterruptionStressTest(
    count: Int,
    durationMs: Int,
    settleMs: Int,
    completion: @escaping (Result<[String: Any], Error>) -> Void
  ) {
    stateQueue.async {
      guard self.state == "recording" else {
        DispatchQueue.main.async { completion(.failure(RecordingRuntimeError.noActiveSession)) }
        return
      }
      guard self.interruptionStress == nil else {
        DispatchQueue.main.async {
          completion(.failure(RecordingRuntimeError.interruptionStressAlreadyRunning))
        }
        return
      }
      let run = InterruptionStressRun(
        target: min(max(count, 1), 100),
        durationMs: min(max(durationMs, 500), 10_000),
        settleMs: min(max(settleMs, 100), 5_000),
        startSample: self.capturedSamples,
        completion: completion
      )
      self.interruptionStress = run
      let payload = self.interruptionStressPayload(run: run, status: "running")
      self.stage1S15Probe.noteInterruptionStress(payload)
      try? self.store?.insertEvent(
        type: "stage1_interruption_stress_started",
        sampleOffset: self.capturedSamples,
        payload: payload
      )
      self.emitState(extra: ["event": "interruption_stress_started"])
      self.stateQueue.asyncAfter(deadline: .now() + .milliseconds(250)) {
        self.runNextStressInterruption(runID: run.runID)
      }
    }
  }

  func injectLowStorageForTest(
    simulatedAvailableBytes: Int64,
    completion: @escaping (Result<[String: Any], Error>) -> Void
  ) {
    stateQueue.async {
      guard self.state == "recording", let directory = self.sessionDirectory else {
        DispatchQueue.main.async { completion(.failure(RecordingRuntimeError.noActiveSession)) }
        return
      }
      let simulated = min(max(simulatedAvailableBytes, 0), self.minimumFreeBytes - 1)
      let actual = Stage1S15Probe.availableStorageBytes(at: directory)
      let detectedAt = ISO8601DateFormatter().string(from: Date())
      let payload: [String: Any] = [
        "schema_version": 1,
        "status": "triggered",
        "injected": true,
        "detected_at": detectedAt,
        "actual_available_bytes": actual,
        "simulated_available_bytes": simulated,
        "minimum_required_bytes": self.minimumFreeBytes,
        "sample_offset": self.capturedSamples,
      ]
      self.stage1S15Probe.noteStorageTest(payload)
      try? self.store?.insertEvent(
        type: "storage_pressure_detected",
        sampleOffset: self.capturedSamples,
        payload: payload
      )
      self.finalizeAfterCaptureFailure(
        error: RecordingRuntimeError.insufficientStorage(simulated),
        eventType: "storage_pressure_controlled_stop",
        payload: payload,
        surfaceOriginalError: false,
        completion: completion
      )
    }
  }

  func compatibilityReport(completion: @escaping (Result<[String: Any], Error>) -> Void) {
    do {
      let report = Stage1S15Probe.compatibilityReport(storageURL: try sessionRootURL())
      DispatchQueue.main.async { completion(.success(report)) }
    } catch {
      DispatchQueue.main.async { completion(.failure(error)) }
    }
  }

  func snapshotClock(completion: @escaping (Result<[String: Any], Error>) -> Void) {
    persistenceQueue.async {
      guard self.persistenceCaptureID != nil else {
        DispatchQueue.main.async { completion(.failure(RecordingRuntimeError.noActiveSession)) }
        return
      }
      let clock = self.snapshotClockOnPersistenceQueue()
      DispatchQueue.main.async { completion(.success(self.clockPayload(clock))) }
    }
  }

  func beginPhotoCapture(completion: @escaping (Result<[String: Any], Error>) -> Void) {
    persistenceQueue.async {
      guard self.persistenceCaptureID != nil,
        let store = self.store
      else {
        DispatchQueue.main.async { completion(.failure(RecordingRuntimeError.noActiveSession)) }
        return
      }
      let clock = self.snapshotClockOnPersistenceQueue()
      let eventID = "evt_\(UUID().uuidString.lowercased())"
      let blobID = "blob_image_\(UUID().uuidString.lowercased())"
      let relativePath = "assets/\(blobID).jpg"
      do {
        let pending = try store.beginImageCapture(
          eventID: eventID,
          blobID: blobID,
          relativePath: relativePath,
          clock: clock
        )
        self.emitState(extra: [
          "event": "image_pending",
          "captureEvent": pending,
        ])
        DispatchQueue.main.async { completion(.success(pending)) }
      } catch {
        DispatchQueue.main.async { completion(.failure(error)) }
      }
    }
  }

  func commitPhotoCapture(
    eventID: String,
    jpegData: Data,
    completion: @escaping (Result<[String: Any], Error>) -> Void
  ) {
    persistenceQueue.async {
      guard self.persistenceCaptureID != nil,
        let store = self.store,
        let directory = self.sessionDirectory
      else {
        DispatchQueue.main.async { completion(.failure(RecordingRuntimeError.noActiveSession)) }
        return
      }
      do {
        guard let asset = try store.captureAsset(eventID: eventID) else {
          throw SessionStoreError.invalidSession
        }
        let finalURL = directory.appendingPathComponent(asset.path)
        if asset.captureState != "committed" || asset.assetState != "committed" {
          try self.writeDurableAsset(jpegData, to: finalURL)
        }
        let committed = try store.commitImageCapture(
          eventID: eventID,
          byteCount: Int64(jpegData.count),
          sha256: SessionStore.sha256(jpegData)
        )
        self.emitState(extra: [
          "event": "image",
          "captureEvent": committed,
        ])
        DispatchQueue.main.async { completion(.success(committed)) }
      } catch {
        DispatchQueue.main.async { completion(.failure(error)) }
      }
    }
  }

  func failPhotoCapture(
    eventID: String,
    error: Error,
    completion: @escaping () -> Void
  ) {
    persistenceQueue.async {
      var recovered = false
      if let store = self.store,
        let directory = self.sessionDirectory,
        let asset = try? store.captureAsset(eventID: eventID)
      {
        let finalURL = directory.appendingPathComponent(asset.path)
        let partURL = finalURL.appendingPathExtension("part")
        if asset.captureState == "committed", asset.assetState == "committed" {
          recovered = true
        } else if asset.captureState == "pending",
          let data = try? Data(contentsOf: finalURL),
          self.isCompleteJPEG(data),
          let committed = try? store.commitImageCapture(
            eventID: eventID,
            byteCount: Int64(data.count),
            sha256: SessionStore.sha256(data)
          )
        {
          recovered = true
          self.emitState(extra: [
            "event": "image",
            "captureEvent": committed,
            "recoveredAfterError": error.localizedDescription,
          ])
        } else {
          if self.fileManager.fileExists(atPath: finalURL.path) {
            try? self.quarantineAssetFile(finalURL)
          }
          if self.fileManager.fileExists(atPath: partURL.path) {
            try? self.quarantineAssetFile(partURL)
          }
          try? store.failCaptureEvent(eventID: eventID, reason: error.localizedDescription)
        }
      } else if let store = self.store {
        try? store.failCaptureEvent(eventID: eventID, reason: error.localizedDescription)
      }
      if !recovered {
        self.emitState(extra: [
          "event": "image_failed",
          "captureEventId": eventID,
          "error": error.localizedDescription,
        ])
      }
      DispatchQueue.main.async { completion() }
    }
  }

  func addBookmark(completion: @escaping (Result<[String: Any], Error>) -> Void) {
    persistenceQueue.async {
      guard self.persistenceCaptureID != nil,
        let store = self.store
      else {
        DispatchQueue.main.async { completion(.failure(RecordingRuntimeError.noActiveSession)) }
        return
      }
      let clock = self.snapshotClockOnPersistenceQueue()
      let eventID = "evt_\(UUID().uuidString.lowercased())"
      do {
        let bookmark = try store.commitBookmark(eventID: eventID, clock: clock)
        self.emitState(extra: [
          "event": "bookmark",
          "captureEvent": bookmark,
        ])
        DispatchQueue.main.async { completion(.success(bookmark)) }
      } catch {
        DispatchQueue.main.async { completion(.failure(error)) }
      }
    }
  }

  func addThought(
    text: String,
    completion: @escaping (Result<[String: Any], Error>) -> Void
  ) {
    persistenceQueue.async {
      guard self.persistenceCaptureID != nil,
        let store = self.store
      else {
        DispatchQueue.main.async { completion(.failure(RecordingRuntimeError.noActiveSession)) }
        return
      }
      do {
        // A committed Thought must never point past durable audio. Sealing the
        // current tail first makes the text event and its media anchor a
        // one-way atomic boundary: audio may exist without the Thought after a
        // crash, but a committed Thought always has durable audio beneath it.
        try self.commitPendingChunk()
        let clock = self.snapshotClockOnPersistenceQueue()
        let eventID = "evt_\(UUID().uuidString.lowercased())"
        let thought = try store.commitThought(
          eventID: eventID,
          text: text,
          clock: clock
        )
        self.emitState(extra: [
          "event": "thought",
          "captureEvent": thought,
        ])
        DispatchQueue.main.async { completion(.success(thought)) }
      } catch {
        DispatchQueue.main.async { completion(.failure(error)) }
      }
    }
  }

  func setASRMode(
    _ mode: String,
    completion: @escaping (Result<[String: Any], Error>) -> Void
  ) {
    stateQueue.async {
      guard self.store != nil else {
        DispatchQueue.main.async { completion(.failure(RecordingRuntimeError.noActiveSession)) }
        return
      }
      let previousMode = self.asrProbe.snapshot()["mode"] as? String ?? "normal"
      self.asrProbe.setMode(mode)
      let sampleOffset = self.capturedSamples
      self.persistenceQueue.async {
        do {
          var metrics = self.asrProbe.snapshot()
          metrics["fromMode"] = previousMode
          metrics["toMode"] = mode
          try self.store?.insertEvent(
            type: "asr_mode_changed",
            sampleOffset: sampleOffset,
            payload: metrics
          )
          self.emitState(extra: ["event": "asr_mode_changed"])
          DispatchQueue.main.async { completion(.success(metrics)) }
        } catch {
          DispatchQueue.main.async { completion(.failure(error)) }
        }
      }
    }
  }

  func commitTranscriptSegment(
    directoryPath: String,
    segment: [String: Any],
    completion: @escaping (Result<[String: Any], Error>) -> Void
  ) {
    persistenceQueue.async {
      do {
        let store: SessionStore
        if self.sessionDirectory?.path == directoryPath, let activeStore = self.store {
          store = activeStore
        } else {
          store = try SessionStore(
            directoryURL: URL(fileURLWithPath: directoryPath, isDirectory: true),
            create: false
          )
        }
        let committed = try store.commitTranscriptSegment(segment)
        DispatchQueue.main.async { completion(.success(committed)) }
      } catch {
        DispatchQueue.main.async { completion(.failure(error)) }
      }
    }
  }

  func commitStage1Event(
    directoryPath: String,
    type: String,
    sampleOffset: Int64,
    payload: [String: Any],
    completion: @escaping (Result<[String: Any], Error>) -> Void
  ) {
    persistenceQueue.async {
      do {
        let store: SessionStore
        if self.sessionDirectory?.path == directoryPath, let activeStore = self.store {
          store = activeStore
        } else {
          store = try SessionStore(
            directoryURL: URL(fileURLWithPath: directoryPath, isDirectory: true),
            create: false
          )
        }
        try store.insertEvent(type: type, sampleOffset: sampleOffset, payload: payload)
        DispatchQueue.main.async {
          completion(
            .success([
              "type": type,
              "sampleOffset": sampleOffset,
            ]))
        }
      } catch {
        DispatchQueue.main.async { completion(.failure(error)) }
      }
    }
  }

  func snapshot(completion: @escaping (Result<[String: Any], Error>) -> Void) {
    stateQueue.async {
      do {
        let snapshot = try self.snapshotLocked()
        DispatchQueue.main.async { completion(.success(snapshot)) }
      } catch {
        DispatchQueue.main.async { completion(.failure(error)) }
      }
    }
  }

  func sessionRootURL() throws -> URL {
    let applicationSupport = try fileManager.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    let root = applicationSupport.appendingPathComponent("MomentAI/Sessions", isDirectory: true)
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  func activeDirectoryPath() -> String? {
    stateQueue.sync {
      guard
        [
          "preparing", "recording", "pausing", "paused", "resuming",
          "interrupted", "finalizing",
        ].contains(state)
      else { return nil }
      return sessionDirectory?.path
    }
  }

  private func requestMicrophonePermission(_ completion: @escaping (Bool) -> Void) {
    if #available(iOS 17.0, *) {
      AVAudioApplication.requestRecordPermission(completionHandler: completion)
    } else {
      AVAudioSession.sharedInstance().requestRecordPermission(completion)
    }
  }

  private func configureAudioSession() throws {
    let audioSession = AVAudioSession.sharedInstance()
    try audioSession.setCategory(.record, mode: .default, options: [.allowBluetoothHFP])
    try audioSession.setPreferredSampleRate(48_000)
    try audioSession.setPreferredIOBufferDuration(0.02)
    try audioSession.setActive(true)
  }

  private func installTapAndStartEngine(captureID: UUID) throws {
    let input = audioEngine.inputNode
    let inputFormat = input.inputFormat(forBus: 0)
    guard inputFormat.sampleRate > 0,
      inputFormat.channelCount > 0,
      let target = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: logicalSampleRate,
        channels: 1,
        interleaved: true
      ),
      let converter = AVAudioConverter(from: inputFormat, to: target)
    else {
      throw RecordingRuntimeError.invalidInputFormat
    }
    logicalFormat = target
    self.converter = converter

    guard !tapInstalled else {
      throw RecordingRuntimeError.busy
    }
    input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
      self?.handleAudio(buffer, converter: converter, logicalFormat: target, captureID: captureID)
    }
    tapInstalled = true
    audioEngine.prepare()
    try audioEngine.start()
  }

  private func handleAudio(
    _ buffer: AVAudioPCMBuffer,
    converter: AVAudioConverter,
    logicalFormat: AVAudioFormat,
    captureID: UUID
  ) {
    let ratio = logicalFormat.sampleRate / buffer.format.sampleRate
    let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio)) + 32
    guard let output = AVAudioPCMBuffer(pcmFormat: logicalFormat, frameCapacity: capacity) else {
      return
    }

    var provided = false
    var conversionError: NSError?
    let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
      guard !provided else {
        inputStatus.pointee = .noDataNow
        return nil
      }
      provided = true
      inputStatus.pointee = .haveData
      return buffer
    }
    guard conversionError == nil, status != .error, output.frameLength > 0 else { return }

    let audioBuffer = output.audioBufferList.pointee.mBuffers
    guard let bytes = audioBuffer.mData else { return }
    let data = Data(bytes: bytes, count: Int(audioBuffer.mDataByteSize))
    let samples = Int64(output.frameLength)

    persistenceQueue.async { [weak self] in
      guard let self,
        self.persistenceCaptureID == captureID,
        self.acceptingAudio
      else { return }
      self.asrProbe.enqueue(output)
      self.chunkBuffer.append(data)
      self.chunkSampleCount += samples
      let observedSamples = self.committedSamples + self.chunkSampleCount
      if observedSamples - self.lastProbeSample >= self.captureProbeIntervalSamples {
        self.lastProbeSample = observedSamples
        self.writeCaptureProbe(observedSamples: observedSamples)
      }
      self.stateQueue.async { self.capturedSamples += samples }
      if self.chunkSampleCount >= self.chunkDurationSamples {
        do {
          try self.commitPendingChunk()
          if self.detectRealStoragePressureAfterCommit() {
            return
          }
          self.emitState()
        } catch {
          self.persistenceCaptureID = nil
          self.stateQueue.async {
            self.finalizeAfterCaptureFailure(
              error: error,
              eventType: "audio_persistence_failed",
              payload: [:]
            )
          }
        }
      }
    }
  }

  private func commitPendingChunk() throws {
    guard !chunkBuffer.isEmpty, chunkSampleCount > 0,
      let store,
      let sessionDirectory
    else { return }

    let index = nextChunkIndex
    let fileName = String(format: "chunk_%06d.pcm", index)
    let relativePath = "audio/\(fileName)"
    let audioDirectory = sessionDirectory.appendingPathComponent("audio", isDirectory: true)
    let partURL = audioDirectory.appendingPathComponent(fileName + ".part")
    let finalURL = audioDirectory.appendingPathComponent(fileName)
    let data = chunkBuffer
    let samples = chunkSampleCount

    fileManager.createFile(atPath: partURL.path, contents: nil)
    let handle = try FileHandle(forWritingTo: partURL)
    handle.write(data)
    try handle.synchronize()
    handle.closeFile()
    if fileManager.fileExists(atPath: finalURL.path) {
      try fileManager.removeItem(at: finalURL)
    }
    try fileManager.moveItem(at: partURL, to: finalURL)
    let directoryDescriptor = open(audioDirectory.path, O_RDONLY)
    if directoryDescriptor >= 0 {
      _ = fsync(directoryDescriptor)
      close(directoryDescriptor)
    }

    let startSample = committedSamples
    let newCommittedSamples = committedSamples + samples
    try store.commitChunk(
      index: index,
      relativePath: relativePath,
      sampleCount: samples,
      byteCount: Int64(data.count),
      sha256: SessionStore.sha256(data),
      lastCommittedSample: newCommittedSamples
    )
    committedSamples = newCommittedSamples
    nextChunkIndex += 1
    chunkBuffer.removeAll(keepingCapacity: true)
    chunkSampleCount = 0
    stage1S15Probe.noteProgress(samples: newCommittedSamples, state: "recording")
    emitState(extra: [
      "event": "chunk_committed",
      "chunk": [
        "sessionId": store.sessionID,
        "directory": sessionDirectory.path,
        "index": index,
        "path": finalURL.path,
        "startSample": startSample,
        "endSample": newCommittedSamples,
        "sampleCount": samples,
        "sampleRate": Int(logicalSampleRate),
      ],
    ])
  }

  private func snapshotClockOnPersistenceQueue() -> ClockSnapshot {
    let sampleOffset = committedSamples + chunkSampleCount
    let nowUptimeNs = DispatchTime.now().uptimeNanoseconds
    let elapsedNs =
      nowUptimeNs >= clockEpochStartedUptimeNs
      ? nowUptimeNs - clockEpochStartedUptimeNs
      : 0
    return ClockSnapshot(
      sampleOffset: sampleOffset,
      atMs: sampleOffset * 1_000 / Int64(logicalSampleRate),
      monotonicElapsedNs: elapsedNs,
      wallTime: ISO8601DateFormatter().string(from: Date()),
      clockEpochID: clockEpochID
    )
  }

  private func clockPayload(_ clock: ClockSnapshot) -> [String: Any] {
    [
      "sampleOffset": clock.sampleOffset,
      "atMs": clock.atMs,
      "monotonicElapsedNs": Int64(clamping: clock.monotonicElapsedNs),
      "wallTime": clock.wallTime,
      "clockEpochId": clock.clockEpochID,
    ]
  }

  private func writeDurableAsset(_ data: Data, to finalURL: URL) throws {
    let directoryURL = finalURL.deletingLastPathComponent()
    try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

    if fileManager.fileExists(atPath: finalURL.path) {
      let existing = try Data(contentsOf: finalURL)
      guard existing == data else {
        throw SessionStoreError.sqlite(
          "Pending image path already contains different bytes: \(finalURL.lastPathComponent)."
        )
      }
      return
    }

    let partURL = finalURL.appendingPathExtension("part")
    if fileManager.fileExists(atPath: partURL.path) {
      try fileManager.removeItem(at: partURL)
    }
    guard fileManager.createFile(atPath: partURL.path, contents: nil) else {
      throw CocoaError(.fileWriteUnknown)
    }
    let handle = try FileHandle(forWritingTo: partURL)
    do {
      handle.write(data)
      try handle.synchronize()
      handle.closeFile()
    } catch {
      handle.closeFile()
      throw error
    }
    try fileManager.moveItem(at: partURL, to: finalURL)

    let directoryDescriptor = open(directoryURL.path, O_RDONLY)
    guard directoryDescriptor >= 0 else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    defer { close(directoryDescriptor) }
    guard fsync(directoryDescriptor) == 0 else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
  }

  private func isCompleteJPEG(_ data: Data) -> Bool {
    data.count >= 4
      && data[data.startIndex] == 0xFF
      && data[data.startIndex + 1] == 0xD8
      && data[data.endIndex - 2] == 0xFF
      && data[data.endIndex - 1] == 0xD9
  }

  private func quarantineAssetFile(_ fileURL: URL) throws {
    var quarantineURL = fileURL.appendingPathExtension("quarantine")
    if fileManager.fileExists(atPath: quarantineURL.path) {
      quarantineURL =
        fileURL
        .appendingPathExtension(UUID().uuidString.lowercased())
        .appendingPathExtension("quarantine")
    }
    try fileManager.moveItem(at: fileURL, to: quarantineURL)
  }

  private func insertASREvent(type: String) throws {
    var payload = asrProbe.snapshot()
    payload["legacySyntheticProbe"] = true
    payload["finality"] = "snapshot_before_async_drain"
    try store?.insertEvent(
      type: type,
      sampleOffset: committedSamples,
      payload: payload
    )
  }

  private func writeCaptureProbe(observedSamples: Int64) {
    guard let sessionDirectory else { return }
    probeQueue.async {
      let probe: [String: Any] = [
        "observed_samples": observedSamples,
        "sample_rate": Int(self.logicalSampleRate),
        "wall_time": ISO8601DateFormatter().string(from: Date()),
        "instrumentation_only": true,
      ]
      guard let data = try? JSONSerialization.data(withJSONObject: probe, options: [.sortedKeys])
      else { return }
      let url = sessionDirectory.appendingPathComponent("capture_highwater.probe.json")
      try? data.write(to: url, options: [.atomic])
    }
  }

  private func snapshotLocked() throws -> [String: Any] {
    var snapshot: [String: Any] = [
      "state": state,
      "sampleRate": Int(logicalSampleRate),
      "capturedSamples": capturedSamples,
      "lastCommittedSample": committedSamples,
      "capturedMs": Int64(Double(capturedSamples) / logicalSampleRate * 1000),
      "committedMs": Int64(Double(committedSamples) / logicalSampleRate * 1000),
      "rpoMs": Int64(Double(max(0, capturedSamples - committedSamples)) / logicalSampleRate * 1000),
      "chunkCount": nextChunkIndex,
      "userPauseCount": userPauseCount,
      "totalUserPausedMs": totalUserPausedMs,
      "currentUserPauseMs": userPauseStartedAt.map {
        max(0, Int64(Date().timeIntervalSince($0) * 1_000))
      } ?? 0,
      "asr": asrProbe.snapshot(),
      "s15": stage1S15Probe.snapshot(),
    ]
    if let interruptionStress {
      snapshot["interruptionStress"] = interruptionStressPayload(
        run: interruptionStress,
        status: "running"
      )
    }
    if let store {
      snapshot.merge(try store.snapshot()) { current, new in
        if current is NSNumber && new is NSNumber { return current }
        return new
      }
      snapshot["state"] = state
    }
    return snapshot
  }

  private func emitState(extra: [String: Any] = [:]) {
    stateQueue.async {
      var payload = (try? self.snapshotLocked()) ?? ["state": self.state]
      payload.merge(extra) { _, new in new }
      guard let handler = self.eventHandler else { return }
      DispatchQueue.main.async { handler(payload) }
    }
  }

  private func ensureStorageCapacity() throws {
    let root = try sessionRootURL()
    let available = Stage1S15Probe.availableStorageBytes(at: root)
    guard
      Stage1S15Probe.hasSufficientStorage(
        availableBytes: available,
        minimumBytes: minimumFreeBytes
      )
    else {
      throw RecordingRuntimeError.insufficientStorage(available)
    }
  }

  private func detectRealStoragePressureAfterCommit() -> Bool {
    guard nextChunkIndex > 0,
      nextChunkIndex % storageCheckIntervalChunks == 0,
      let directory = sessionDirectory
    else { return false }
    let available = Stage1S15Probe.availableStorageBytes(at: directory)
    guard
      !Stage1S15Probe.hasSufficientStorage(
        availableBytes: available,
        minimumBytes: minimumFreeBytes
      )
    else { return false }
    let payload: [String: Any] = [
      "schema_version": 1,
      "status": "triggered",
      "injected": false,
      "detected_at": ISO8601DateFormatter().string(from: Date()),
      "actual_available_bytes": available,
      "simulated_available_bytes": available,
      "minimum_required_bytes": minimumFreeBytes,
      "sample_offset": committedSamples,
    ]
    stage1S15Probe.noteStorageTest(payload)
    try? store?.insertEvent(
      type: "storage_pressure_detected",
      sampleOffset: committedSamples,
      payload: payload
    )
    persistenceCaptureID = nil
    stateQueue.async {
      self.finalizeAfterCaptureFailure(
        error: RecordingRuntimeError.insufficientStorage(available),
        eventType: "storage_pressure_controlled_stop",
        payload: payload,
        surfaceOriginalError: false
      )
    }
    return true
  }

  private func makeSessionDirectory() throws -> URL {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd_HHmmss"
    let id = "session_\(formatter.string(from: Date()))_\(UUID().uuidString.prefix(8))"
    return try sessionRootURL().appendingPathComponent(id, isDirectory: true)
  }

  private func cleanupEngine(invalidateCapture: Bool = true) {
    if tapInstalled {
      audioEngine.inputNode.removeTap(onBus: 0)
      tapInstalled = false
    }
    audioEngine.stop()
    converter = nil
    logicalFormat = nil
    if invalidateCapture {
      activeCaptureID = nil
    }
  }

  @objc private func handleInterruption(_ notification: Notification) {
    guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
      let type = AVAudioSession.InterruptionType(rawValue: rawType)
    else { return }
    stateQueue.async {
      switch type {
      case .began:
        guard self.state == "recording" else { return }
        self.interruptionStartedAt = Date()
        self.sessionHasGaps = true
        self.state = "interrupted"
        try? self.store?.updateStatus("interrupted")
        try? self.store?.insertEvent(
          type: "audio_interruption_began", sampleOffset: self.capturedSamples)
        self.emitState(extra: ["event": "interruption_began"])
      case .ended:
        guard self.state == "interrupted" else { return }
        let gapMs = Int64((Date().timeIntervalSince(self.interruptionStartedAt ?? Date())) * 1000)
        let optionsValue =
          (notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0
        self.restartAfterInterruption(gapMs: gapMs, optionsValue: optionsValue, attempt: 1)
      @unknown default:
        break
      }
    }
  }

  @objc private func handleApplicationLifecycle(_ notification: Notification) {
    let type: String
    switch notification.name {
    case UIApplication.didEnterBackgroundNotification:
      type = "application_background"
    case UIApplication.willEnterForegroundNotification:
      type = "application_foreground"
    case UIApplication.protectedDataWillBecomeUnavailableNotification:
      type = "protected_data_unavailable"
    case UIApplication.protectedDataDidBecomeAvailableNotification:
      type = "protected_data_available"
    default:
      return
    }
    stateQueue.async {
      guard
        [
          "preparing", "recording", "pausing", "paused", "resuming",
          "interrupted", "finalizing",
        ].contains(self.state)
      else { return }
      let sampleOffset = self.capturedSamples
      self.stage1S15Probe.noteLifecycle(type: type, samples: sampleOffset)
      self.persistenceQueue.async {
        guard self.store != nil else { return }
        try? self.store?.insertEvent(
          type: "stage1_s1_5_\(type)",
          sampleOffset: sampleOffset
        )
      }
      self.emitState(extra: ["event": "s1_5_\(type)"])
    }
  }

  @objc private func handleRouteChange(_ notification: Notification) {
    guard let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
    else { return }
    stateQueue.async {
      guard
        [
          "preparing", "recording", "pausing", "paused", "resuming",
          "interrupted", "finalizing",
        ].contains(self.state)
      else { return }
      try? self.store?.insertEvent(
        type: "audio_route_changed",
        sampleOffset: self.capturedSamples,
        payload: ["reason": reasonValue]
      )
      self.emitState(extra: ["event": "route_changed", "routeReason": reasonValue])
    }
  }

  private func restartAfterInterruption(
    gapMs: Int64,
    optionsValue: UInt,
    attempt: Int,
    injected: Bool = false,
    stressRunID: String? = nil
  ) {
    guard state == "interrupted", let captureID = activeCaptureID else { return }
    do {
      cleanupEngine(invalidateCapture: false)
      try configureAudioSession()
      try installTapAndStartEngine(captureID: captureID)
      state = "recording"
      interruptionStartedAt = nil
      try store?.updateStatus("recording")
      var interruptionPayload: [String: Any] = [
        "gapMs": gapMs,
        "restartAttempts": attempt,
        "options": optionsValue,
        "injected": injected,
      ]
      if let stressRunID { interruptionPayload["stressRunId"] = stressRunID }
      try store?.insertEvent(
        type: "audio_interruption_ended",
        sampleOffset: capturedSamples,
        payload: interruptionPayload
      )
      emitState(extra: [
        "event": "interruption_ended",
        "gapMs": gapMs,
        "injected": injected,
      ])
      if let stressRunID {
        handleStressInterruptionRecovered(
          runID: stressRunID,
          gapMs: gapMs,
          restartAttempts: attempt
        )
      }
    } catch {
      cleanupEngine(invalidateCapture: false)
      if attempt < maximumInterruptionRestartAttempts {
        try? store?.insertEvent(
          type: "audio_interruption_restart_retry",
          sampleOffset: capturedSamples,
          payload: [
            "attempt": attempt,
            "error": error.localizedDescription,
            "gapMs": gapMs,
            "options": optionsValue,
          ]
        )
        emitState(extra: [
          "event": "interruption_restart_retry",
          "restartAttempt": attempt,
        ])
        stateQueue.asyncAfter(deadline: .now() + .milliseconds(500)) {
          self.restartAfterInterruption(
            gapMs: gapMs,
            optionsValue: optionsValue,
            attempt: attempt + 1,
            injected: injected,
            stressRunID: stressRunID
          )
        }
      } else {
        if let stressRunID {
          failInterruptionStress(
            runID: stressRunID,
            error: error,
            gapMs: gapMs,
            restartAttempts: attempt
          )
        }
        finalizeAfterCaptureFailure(
          error: error,
          eventType: "audio_interruption_recovery_failed",
          payload: [
            "gapMs": gapMs,
            "restartAttempts": attempt,
            "options": optionsValue,
          ]
        )
      }
    }
  }

  private func finalizeAfterCaptureFailure(
    error: Error,
    eventType: String,
    payload: [String: Any],
    surfaceOriginalError: Bool = true,
    completion: ((Result<[String: Any], Error>) -> Void)? = nil
  ) {
    guard store != nil, state != "finalizing" else { return }
    let errorDescription = error.localizedDescription
    sessionHasGaps = true
    state = "finalizing"
    try? store?.updateStatus("finalizing")
    cleanupEngine()
    emitState(extra: [
      "event": "finalizing_after_error",
      "error": errorDescription,
    ])

    persistenceQueue.async {
      self.acceptingAudio = false
      self.persistenceCaptureID = nil
      var finalizationError: Error?
      do {
        try self.commitPendingChunk()
        try self.insertASREvent(type: "asr_probe_final")
      } catch {
        finalizationError = error
      }

      var eventPayload = payload
      eventPayload["error"] = errorDescription
      if let finalizationError {
        eventPayload["finalizationError"] = finalizationError.localizedDescription
      }
      try? self.store?.insertEvent(
        type: eventType,
        sampleOffset: self.committedSamples,
        payload: eventPayload
      )
      try? self.store?.updateStatus("completed_with_gaps", stopped: true)
      self.store?.checkpoint()
      let finalRpoMs = Int64(
        Double(max(0, self.capturedSamples - self.committedSamples)) / self.logicalSampleRate * 1000
      )
      if eventType == "storage_pressure_controlled_stop" {
        var storagePayload = eventPayload
        storagePayload["status"] = finalizationError == nil ? "completed" : "finalization_failed"
        storagePayload["final_sample"] = self.committedSamples
        storagePayload["final_rpo_ms"] = finalRpoMs
        self.stage1S15Probe.noteStorageTest(storagePayload)
      }
      self.stage1S15Probe.finish(
        samples: self.committedSamples,
        state: "completed_with_gaps",
        rpoMs: finalRpoMs
      )

      self.stateQueue.async {
        self.state = "completed_with_gaps"
        self.interruptionStartedAt = nil
        self.userPauseID = nil
        self.userPauseStartedAt = nil
        try? AVAudioSession.sharedInstance().setActive(
          false, options: [.notifyOthersOnDeactivation])
        var emitted: [String: Any] = ["event": eventType]
        if let finalizationError {
          emitted["error"] = finalizationError.localizedDescription
        } else if surfaceOriginalError {
          emitted["error"] = errorDescription
        }
        self.emitState(extra: emitted)
        guard let completion else { return }
        do {
          let snapshot = try self.snapshotLocked()
          DispatchQueue.main.async { completion(.success(snapshot)) }
        } catch {
          DispatchQueue.main.async { completion(.failure(error)) }
        }
      }
    }
  }

  private func runNextStressInterruption(runID: String) {
    guard let run = interruptionStress,
      run.runID == runID,
      state == "recording",
      let captureID = activeCaptureID
    else { return }
    let cycle = run.completed + 1
    interruptionStartedAt = Date()
    sessionHasGaps = true
    state = "interrupted"
    cleanupEngine(invalidateCapture: false)
    try? store?.updateStatus("interrupted")
    try? store?.insertEvent(
      type: "audio_interruption_began",
      sampleOffset: capturedSamples,
      payload: [
        "injected": true,
        "stressRunId": runID,
        "cycle": cycle,
        "requestedDurationMs": run.durationMs,
      ]
    )
    emitState(extra: [
      "event": "interruption_began",
      "injected": true,
      "stressCycle": cycle,
      "stressTarget": run.target,
    ])
    stateQueue.asyncAfter(deadline: .now() + .milliseconds(run.durationMs)) {
      guard self.state == "interrupted",
        self.activeCaptureID == captureID,
        self.interruptionStress?.runID == runID
      else { return }
      let gapMs = Int64(Date().timeIntervalSince(self.interruptionStartedAt ?? Date()) * 1000)
      self.restartAfterInterruption(
        gapMs: gapMs,
        optionsValue: AVAudioSession.InterruptionOptions.shouldResume.rawValue,
        attempt: 1,
        injected: true,
        stressRunID: runID
      )
    }
  }

  private func handleStressInterruptionRecovered(
    runID: String,
    gapMs: Int64,
    restartAttempts: Int
  ) {
    guard let run = interruptionStress, run.runID == runID else { return }
    run.completed += 1
    run.totalGapMs += gapMs
    run.maximumRestartAttempts = max(run.maximumRestartAttempts, restartAttempts)
    if run.completed >= run.target {
      let payload = interruptionStressPayload(run: run, status: "completed")
      stage1S15Probe.noteInterruptionStress(payload)
      try? store?.insertEvent(
        type: "stage1_interruption_stress_completed",
        sampleOffset: capturedSamples,
        payload: payload
      )
      interruptionStress = nil
      emitState(extra: [
        "event": "interruption_stress_completed",
        "interruptionStress": payload,
      ])
      DispatchQueue.main.async { run.completion(.success(payload)) }
      return
    }
    let payload = interruptionStressPayload(run: run, status: "running")
    stage1S15Probe.noteInterruptionStress(payload)
    emitState(extra: [
      "event": "interruption_stress_progress",
      "interruptionStress": payload,
    ])
    stateQueue.asyncAfter(deadline: .now() + .milliseconds(run.settleMs)) {
      self.runNextStressInterruption(runID: runID)
    }
  }

  private func failInterruptionStress(
    runID: String,
    error: Error,
    gapMs: Int64,
    restartAttempts: Int
  ) {
    guard let run = interruptionStress, run.runID == runID else { return }
    var payload = interruptionStressPayload(run: run, status: "failed")
    payload["error"] = error.localizedDescription
    payload["failed_gap_ms"] = gapMs
    payload["failed_restart_attempts"] = restartAttempts
    stage1S15Probe.noteInterruptionStress(payload)
    try? store?.insertEvent(
      type: "stage1_interruption_stress_failed",
      sampleOffset: capturedSamples,
      payload: payload
    )
    interruptionStress = nil
    DispatchQueue.main.async { run.completion(.failure(error)) }
  }

  private func cancelInterruptionStressIfNeeded() {
    guard let run = interruptionStress else { return }
    let payload = interruptionStressPayload(run: run, status: "cancelled")
    stage1S15Probe.noteInterruptionStress(payload)
    try? store?.insertEvent(
      type: "stage1_interruption_stress_cancelled",
      sampleOffset: capturedSamples,
      payload: payload
    )
    interruptionStress = nil
    DispatchQueue.main.async {
      run.completion(.failure(RecordingRuntimeError.interruptionStressCancelled))
    }
  }

  private func interruptionStressPayload(
    run: InterruptionStressRun,
    status: String
  ) -> [String: Any] {
    [
      "schema_version": 1,
      "run_id": run.runID,
      "status": status,
      "target_count": run.target,
      "completed_count": run.completed,
      "duration_ms": run.durationMs,
      "settle_ms": run.settleMs,
      "started_at": ISO8601DateFormatter().string(from: run.startedAt),
      "start_sample": run.startSample,
      "latest_sample": capturedSamples,
      "total_gap_ms": run.totalGapMs,
      "maximum_restart_attempts": run.maximumRestartAttempts,
    ]
  }

  private static func applicationStateName(_ state: UIApplication.State) -> String {
    switch state {
    case .active: return "active"
    case .inactive: return "inactive"
    case .background: return "background"
    @unknown default: return "unknown"
    }
  }
}
