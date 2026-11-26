import Flutter
import Foundation
import UIKit

private final class PlaybackEventStreamHandler: NSObject, FlutterStreamHandler {
  private let player: CommittedAudioPlayer

  init(player: CommittedAudioPlayer) {
    self.player = player
  }

  func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    player.setEventHandler { events($0) }
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    player.setEventHandler(nil)
    return nil
  }
}

final class PoCBridge: NSObject, FlutterStreamHandler, CameraProbeControllerDelegate {
  private let runtime = RecordingRuntime.shared
  private let recovery = RecoveryCoordinator()
  private let playback = CommittedAudioPlayer()
  private let exporter = SessionExporter()
  private let stage1Queue = DispatchQueue(
    label: "org.hohu.momentai.stage1.commit", qos: .userInitiated)
  private weak var presenter: UIViewController?
  private var eventSink: FlutterEventSink?
  private var pendingCameraResult: FlutterResult?
  private weak var activeCamera: CameraProbeController?
  private var playbackStreamHandler: PlaybackEventStreamHandler?

  init(messenger: FlutterBinaryMessenger) {
    super.init()

    let methodChannel = FlutterMethodChannel(
      name: "org.hohu.momentai.poc/methods",
      binaryMessenger: messenger
    )
    methodChannel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }

    let eventChannel = FlutterEventChannel(
      name: "org.hohu.momentai.poc/events",
      binaryMessenger: messenger
    )
    eventChannel.setStreamHandler(self)

    let playbackStreamHandler = PlaybackEventStreamHandler(player: playback)
    self.playbackStreamHandler = playbackStreamHandler
    let playbackEventChannel = FlutterEventChannel(
      name: "org.hohu.momentai.poc/playback_events",
      binaryMessenger: messenger
    )
    playbackEventChannel.setStreamHandler(playbackStreamHandler)

    runtime.setEventHandler { [weak self] event in
      self?.activeCamera?.recordingState = event["state"] as? String ?? "unknown"
      self?.eventSink?(event)
    }
  }

  func setPresenter(_ viewController: UIViewController?) {
    presenter = viewController
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  {
    eventSink = events
    runtime.snapshot { result in
      if case .success(let snapshot) = result { events(snapshot) }
    }
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "start":
      let arguments = call.arguments as? [String: Any]
      playback.stop { _ in
        self.runtime.start(title: arguments?["title"] as? String ?? "Stage 0 PoC") {
          self.complete($0, flutterResult: result)
        }
      }
    case "stop":
      runtime.stop { self.complete($0, flutterResult: result) }
    case "pauseRecording":
      runtime.pause { self.complete($0, flutterResult: result) }
    case "resumeRecording":
      runtime.resume { self.complete($0, flutterResult: result) }
    case "snapshot":
      runtime.snapshot { self.complete($0, flutterResult: result) }
    #if DEBUG && MOMENTAI_INTERNAL_TESTS
      case "injectAudioInterruptionForTest":
        let arguments = call.arguments as? [String: Any]
        runtime.injectAudioInterruptionForTest(
          durationMs: arguments?["durationMs"] as? Int ?? 3_000
        ) { self.complete($0, flutterResult: result) }
      case "runInterruptionStressTest":
        let arguments = call.arguments as? [String: Any]
        runtime.runInterruptionStressTest(
          count: arguments?["count"] as? Int ?? 100,
          durationMs: arguments?["durationMs"] as? Int ?? 500,
          settleMs: arguments?["settleMs"] as? Int ?? 250
        ) { self.complete($0, flutterResult: result) }
      case "injectLowStorageForTest":
        let arguments = call.arguments as? [String: Any]
        let simulated =
          (arguments?["simulatedAvailableBytes"] as? NSNumber)?.int64Value
          ?? 64 * 1_048_576
        runtime.injectLowStorageForTest(simulatedAvailableBytes: simulated) {
          self.complete($0, flutterResult: result)
        }
    #endif
    case "compatibilityReport":
      runtime.compatibilityReport { self.complete($0, flutterResult: result) }
    case "setASRMode":
      let arguments = call.arguments as? [String: Any]
      runtime.setASRMode(arguments?["mode"] as? String ?? "normal") {
        self.complete($0, flutterResult: result)
      }
    case "scanRecovery":
      do {
        let activePath = runtime.activeDirectoryPath()
        let candidates = recovery.scan(rootURL: try runtime.sessionRootURL()).filter {
          ($0["directory"] as? String) != activePath
        }
        result(candidates)
      } catch {
        result(flutterError(error))
      }
    case "recover":
      let arguments = call.arguments as? [String: Any]
      guard let path = arguments?["directory"] as? String else {
        result(
          FlutterError(code: "invalid_arguments", message: "directory is required", details: nil))
        return
      }
      stage1Queue.async {
        do {
          let recovered = try self.recovery.recover(directoryPath: path)
          DispatchQueue.main.async { result(recovered) }
        } catch {
          DispatchQueue.main.async { result(self.flutterError(error)) }
        }
      }
    case "committedChunks":
      let arguments = call.arguments as? [String: Any]
      guard let path = arguments?["directory"] as? String else {
        result(
          FlutterError(code: "invalid_arguments", message: "directory is required", details: nil))
        return
      }
      let afterSample = (arguments?["afterSample"] as? NSNumber)?.int64Value ?? 0
      stage1Queue.async {
        do {
          let store = try SessionStore(directoryURL: URL(fileURLWithPath: path), create: false)
          let chunks = try store.committedChunks(afterSample: afterSample)
          DispatchQueue.main.async { result(chunks) }
        } catch {
          DispatchQueue.main.async { result(self.flutterError(error)) }
        }
      }
    case "commitTranscriptSegment":
      let arguments = call.arguments as? [String: Any]
      guard let path = arguments?["directory"] as? String,
        let segment = arguments?["segment"] as? [String: Any]
      else {
        result(
          FlutterError(
            code: "invalid_arguments", message: "directory and segment are required", details: nil))
        return
      }
      runtime.commitTranscriptSegment(directoryPath: path, segment: segment) {
        self.complete($0, flutterResult: result)
      }
    case "commitStage1Event":
      let arguments = call.arguments as? [String: Any]
      guard let path = arguments?["directory"] as? String,
        let type = arguments?["type"] as? String,
        let sampleNumber = arguments?["sampleOffset"] as? NSNumber
      else {
        result(
          FlutterError(
            code: "invalid_arguments", message: "directory, type and sampleOffset are required",
            details: nil))
        return
      }
      runtime.commitStage1Event(
        directoryPath: path,
        type: type,
        sampleOffset: sampleNumber.int64Value,
        payload: arguments?["payload"] as? [String: Any] ?? [:]
      ) { self.complete($0, flutterResult: result) }
    case "timeline":
      let arguments = call.arguments as? [String: Any]
      guard let path = arguments?["directory"] as? String else {
        result(
          FlutterError(code: "invalid_arguments", message: "directory is required", details: nil))
        return
      }
      stage1Queue.async {
        do {
          let store = try SessionStore(directoryURL: URL(fileURLWithPath: path), create: false)
          let timeline = try store.timeline()
          DispatchQueue.main.async { result(timeline) }
        } catch {
          DispatchQueue.main.async { result(self.flutterError(error)) }
        }
      }
    case "exportSession":
      let arguments = call.arguments as? [String: Any]
      guard let path = arguments?["directory"] as? String else {
        result(
          FlutterError(code: "invalid_arguments", message: "directory is required", details: nil))
        return
      }
      guard runtime.activeDirectoryPath() != path else {
        result(
          FlutterError(
            code: "recording_active",
            message: "Stop recording before exporting the Session.",
            details: nil
          ))
        return
      }
      stage1Queue.async {
        do {
          let exported = try self.exporter.export(directoryPath: path)
          DispatchQueue.main.async { result(exported) }
        } catch {
          DispatchQueue.main.async { result(self.flutterError(error)) }
        }
      }
    case "shareExport":
      let arguments = call.arguments as? [String: Any]
      guard let path = arguments?["archivePath"] as? String else {
        result(
          FlutterError(code: "invalid_arguments", message: "archivePath is required", details: nil))
        return
      }
      shareExport(at: path, result: result)
    case "startPlayback":
      let arguments = call.arguments as? [String: Any]
      guard let path = arguments?["directory"] as? String,
        let sampleNumber = arguments?["sampleOffset"] as? NSNumber
      else {
        result(
          FlutterError(
            code: "invalid_arguments",
            message: "directory and sampleOffset are required",
            details: nil
          ))
        return
      }
      guard runtime.activeDirectoryPath() == nil else {
        result(
          FlutterError(
            code: "recording_active",
            message: "Stop recording before playing committed audio.",
            details: nil
          ))
        return
      }
      playback.play(
        directoryPath: path,
        sampleOffset: sampleNumber.int64Value,
        anchorID: arguments?["anchorId"] as? String ?? "",
        anchorType: arguments?["anchorType"] as? String ?? "timeline"
      ) { self.complete($0, flutterResult: result) }
    case "getPlaybackSound":
      playback.soundSettings { self.complete($0, flutterResult: result) }
    case "setPlaybackSound":
      let arguments = call.arguments as? [String: Any]
      playback.setSound(
        volume: (arguments?["volume"] as? NSNumber)?.floatValue ?? .nan,
        enhanced: arguments?["enhanced"] as? Bool ?? false
      ) { self.complete($0, flutterResult: result) }
    case "pausePlayback":
      playback.pause { self.complete($0, flutterResult: result) }
    case "resumePlayback":
      playback.resume { self.complete($0, flutterResult: result) }
    case "seekPlayback":
      let arguments = call.arguments as? [String: Any]
      guard let sampleNumber = arguments?["sampleOffset"] as? NSNumber else {
        result(
          FlutterError(
            code: "invalid_arguments",
            message: "sampleOffset is required",
            details: nil
          ))
        return
      }
      playback.seek(sampleOffset: sampleNumber.int64Value) {
        self.complete($0, flutterResult: result)
      }
    case "stopPlayback":
      playback.stop { self.complete($0, flutterResult: result) }
    case "addBookmark":
      runtime.addBookmark { self.complete($0, flutterResult: result) }
    case "addThought":
      let arguments = call.arguments as? [String: Any]
      guard let text = arguments?["text"] as? String else {
        result(FlutterError(code: "invalid_arguments", message: "text is required", details: nil))
        return
      }
      runtime.addThought(text: text) { self.complete($0, flutterResult: result) }
    case "openCamera":
      openCamera(result: result)
    #if DEBUG && MOMENTAI_INTERNAL_TESTS
      case "terminateForRecoveryTest":
        result(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
          abort()
        }
    #endif
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func openCamera(result: @escaping FlutterResult) {
    guard pendingCameraResult == nil else {
      result(
        FlutterError(code: "camera_busy", message: "Camera probe is already open.", details: nil))
      return
    }
    let viewController = CameraProbeController()
    viewController.delegate = self
    activeCamera = viewController
    viewController.modalPresentationStyle = .fullScreen
    pendingCameraResult = result

    let presentingController =
      presenter
      ?? UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap(\.windows)
      .first(where: { $0.isKeyWindow })?
      .rootViewController
    guard let presentingController else {
      pendingCameraResult = nil
      result(FlutterError(code: "no_presenter", message: "Unable to present camera.", details: nil))
      return
    }
    runtime.snapshot { snapshot in
      // Snapshot callbacks already arrive on main, in order with live recording events.
      if case .success(let payload) = snapshot {
        viewController.recordingState = payload["state"] as? String ?? "unknown"
      }
      presentingController.present(viewController, animated: true)
    }
  }

  private func shareExport(at path: String, result: @escaping FlutterResult) {
    let archiveURL = URL(fileURLWithPath: path)
    guard archiveURL.pathExtension.lowercased() == SessionExporter.archiveExtension,
      FileManager.default.fileExists(atPath: archiveURL.path)
    else {
      result(
        FlutterError(
          code: "invalid_export",
          message: "The .momentai export does not exist.",
          details: nil
        ))
      return
    }
    let root =
      presenter
      ?? UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap(\.windows)
      .first(where: { $0.isKeyWindow })?
      .rootViewController
    guard let root else {
      result(
        FlutterError(
          code: "no_presenter", message: "Unable to present export sharing.", details: nil))
      return
    }
    var presenting = root
    while let next = presenting.presentedViewController { presenting = next }
    let share = UIActivityViewController(activityItems: [archiveURL], applicationActivities: nil)
    if let popover = share.popoverPresentationController {
      popover.sourceView = presenting.view
      popover.sourceRect = CGRect(
        x: presenting.view.bounds.midX,
        y: presenting.view.bounds.midY,
        width: 1,
        height: 1
      )
      popover.permittedArrowDirections = []
    }
    presenting.present(share, animated: true) { result(["presented": true]) }
  }

  func cameraProbeController(
    _ controller: CameraProbeController,
    preparePhotoCapture completion: @escaping (Result<[String: Any], Error>) -> Void
  ) {
    runtime.beginPhotoCapture(completion: completion)
  }

  func cameraProbeController(
    _ controller: CameraProbeController,
    didCapture jpegData: Data,
    eventID: String,
    completion: @escaping (Result<[String: Any], Error>) -> Void
  ) {
    runtime.commitPhotoCapture(eventID: eventID, jpegData: jpegData, completion: completion)
  }

  func cameraProbeController(
    _ controller: CameraProbeController,
    didFailCapture eventID: String,
    error: Error,
    completion: @escaping () -> Void
  ) {
    runtime.failPhotoCapture(eventID: eventID, error: error, completion: completion)
  }

  func cameraProbeController(
    _ controller: CameraProbeController, didFinish results: [[String: Any]]
  ) {
    pendingCameraResult?([
      "photoCount": results.count,
      "photos": results,
      "firstMediaMs": results.first?["atMs"] ?? 0,
      "lastMediaMs": results.last?["atMs"] ?? 0,
    ])
    pendingCameraResult = nil
  }

  func cameraProbeController(_ controller: CameraProbeController, didFail error: Error) {
    pendingCameraResult?(flutterError(error))
    pendingCameraResult = nil
  }

  func cameraProbeControllerDidCancel(_ controller: CameraProbeController) {
    pendingCameraResult?([
      "photoCount": 0,
      "photos": [],
      "firstMediaMs": 0,
      "lastMediaMs": 0,
      "cancelled": true,
    ])
    pendingCameraResult = nil
  }

  private func complete(_ value: Result<[String: Any], Error>, flutterResult: FlutterResult?) {
    guard let flutterResult else { return }
    switch value {
    case .success(let payload): flutterResult(payload)
    case .failure(let error): flutterResult(self.flutterError(error))
    }
  }

  private func flutterError(_ error: Error) -> FlutterError {
    FlutterError(
      code: String(describing: type(of: error)),
      message: error.localizedDescription,
      details: nil
    )
  }
}
