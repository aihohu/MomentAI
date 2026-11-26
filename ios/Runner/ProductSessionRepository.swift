import AVFoundation
import Flutter
import Foundation
import UIKit

enum ProductSessionRepositoryError: LocalizedError {
  case invalidSessionID
  case sessionNotFound(String)
  case sessionActive
  case sessionBusy(String)

  var errorDescription: String? {
    switch self {
    case .invalidSessionID:
      return "Session id is invalid."
    case .sessionNotFound(let sessionID):
      return "Session \(sessionID) was not found."
    case .sessionActive:
      return "The active Session cannot be changed or deleted."
    case .sessionBusy(let state):
      return "Session cannot be deleted while it is \(state)."
    }
  }
}

final class ProductSessionRepository {
  static let minimumFreeBytes: Int64 = 512 * 1_048_576

  private let fileManager: FileManager
  private let rootURLProvider: () throws -> URL
  private let activeDirectoryProvider: () -> String?

  init(
    fileManager: FileManager = .default,
    rootURLProvider: @escaping () throws -> URL,
    activeDirectoryProvider: @escaping () -> String?
  ) {
    self.fileManager = fileManager
    self.rootURLProvider = rootURLProvider
    self.activeDirectoryProvider = activeDirectoryProvider
  }

  func listSessions() throws -> [[String: Any]] {
    let rootURL = try rootURLProvider()
    let children = try fileManager.contentsOfDirectory(
      at: rootURL,
      includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles]
    )

    var summaries: [[String: Any]] = []
    for child in children {
      guard child.lastPathComponent.hasPrefix("session_") else { continue }
      guard let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
        values.isDirectory == true,
        values.isSymbolicLink != true,
        fileManager.fileExists(
          atPath: child.appendingPathComponent("session.sqlite").path
        )
      else {
        continue
      }
      do {
        summaries.append(
          try summary(at: child)
        )
      } catch SessionStoreError.invalidSession {
        continue
      } catch {
        // A real Session that is temporarily locked or unreadable must not
        // silently disappear from the product list. Let Flutter retain its
        // last good cache and offer a retry instead of returning partial data.
        throw error
      }
    }
    return summaries.sorted { lhs, rhs in
      let lhsStarted = lhs["startedAtWall"] as? String ?? ""
      let rhsStarted = rhs["startedAtWall"] as? String ?? ""
      if lhsStarted != rhsStarted { return lhsStarted > rhsStarted }
      return (lhs["sessionId"] as? String ?? "") > (rhs["sessionId"] as? String ?? "")
    }
  }

  func session(sessionID: String) throws -> [String: Any] {
    let url = try sessionURL(sessionID: sessionID)
    return try summary(at: url)
  }

  func rename(sessionID: String, title: String) throws -> [String: Any] {
    let url = try sessionURL(sessionID: sessionID)
    try ensureSessionMutable(url)
    _ = try SessionStore(directoryURL: url, create: false).rename(title: title)
    return try summary(at: url)
  }

  private func summary(at url: URL) throws -> [String: Any] {
    var value = try SessionStore(directoryURL: url, create: false).productSummary()
    let provenanceURL = url.appendingPathComponent("import_provenance.json")
    if let size = try? provenanceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
      size < 64 * 1_024,
      let data = try? Data(contentsOf: provenanceURL),
      let provenance = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    {
      value["importedFromSessionId"] = provenance["sourceSessionId"]
    }
    return value
  }

  func delete(sessionID: String) throws {
    let url = try sessionURL(sessionID: sessionID)
    try ensureSessionMutable(url)

    try removeExports(sessionID: sessionID, rootURL: url.deletingLastPathComponent())
    try fileManager.removeItem(at: url)
  }

  private func ensureSessionMutable(_ url: URL) throws {
    if let activePath = activeDirectoryProvider(),
      URL(fileURLWithPath: activePath).standardizedFileURL.path == url.standardizedFileURL.path
    {
      throw ProductSessionRepositoryError.sessionActive
    }

    let state: String
    do {
      let summary = try SessionStore(directoryURL: url, create: false).productSummary()
      state = summary["state"] as? String ?? "unknown"
    }
    if [
      "authorizing", "preparing", "recording", "pausing", "paused",
      "resuming", "interrupted", "finalizing", "recovering",
    ]
    .contains(state) {
      throw ProductSessionRepositoryError.sessionBusy(state)
    }
  }

  func storageOverview() throws -> [String: Any] {
    let rootURL = try rootURLProvider()
    var appUsedBytes: Int64 = 0
    let keys: Set<URLResourceKey> = [
      .isRegularFileKey,
      .fileAllocatedSizeKey,
      .totalFileAllocatedSizeKey,
    ]
    if let enumerator = fileManager.enumerator(
      at: rootURL,
      includingPropertiesForKeys: Array(keys),
      options: [],
      errorHandler: { _, _ in true }
    ) {
      for case let fileURL as URL in enumerator {
        guard let values = try? fileURL.resourceValues(forKeys: keys),
          values.isRegularFile == true
        else {
          continue
        }
        appUsedBytes += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
      }
    }

    let volumeValues = try rootURL.resourceValues(forKeys: [
      .volumeAvailableCapacityForImportantUsageKey,
      .volumeTotalCapacityKey,
    ])
    let availableBytes = volumeValues.volumeAvailableCapacityForImportantUsage ?? 0
    let totalBytes = Int64(volumeValues.volumeTotalCapacity ?? 0)
    return [
      "appUsedBytes": appUsedBytes,
      "availableBytes": availableBytes,
      "totalBytes": totalBytes,
      "minimumRequiredBytes": Self.minimumFreeBytes,
      "canStartRecording": availableBytes >= Self.minimumFreeBytes,
      "sessionCount": try sessionDirectoryCount(rootURL: rootURL),
    ]
  }

  private func sessionDirectoryCount(rootURL: URL) throws -> Int {
    try fileManager.contentsOfDirectory(
      at: rootURL,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles]
    ).filter { child in
      guard child.lastPathComponent.hasPrefix("session_") else { return false }
      guard let values = try? child.resourceValues(forKeys: [.isDirectoryKey]),
        values.isDirectory == true
      else {
        return false
      }
      return fileManager.fileExists(
        atPath: child.appendingPathComponent("session.sqlite").path
      )
    }.count
  }

  private func sessionURL(sessionID: String) throws -> URL {
    guard !sessionID.isEmpty,
      sessionID == URL(fileURLWithPath: sessionID).lastPathComponent,
      sessionID.hasPrefix("session_"),
      !sessionID.contains("/")
    else {
      throw ProductSessionRepositoryError.invalidSessionID
    }

    let rootURL = try rootURLProvider().standardizedFileURL.resolvingSymlinksInPath()
    let candidate = rootURL.appendingPathComponent(sessionID, isDirectory: true)
      .standardizedFileURL.resolvingSymlinksInPath()
    guard candidate.deletingLastPathComponent().path == rootURL.path,
      fileManager.fileExists(
        atPath: candidate.appendingPathComponent("session.sqlite").path
      )
    else {
      throw ProductSessionRepositoryError.sessionNotFound(sessionID)
    }
    return candidate
  }

  private func removeExports(sessionID: String, rootURL: URL) throws {
    let exportRoot = rootURL.appendingPathComponent("Exports", isDirectory: true)
    guard fileManager.fileExists(atPath: exportRoot.path) else { return }
    let exports = try fileManager.contentsOfDirectory(
      at: exportRoot,
      includingPropertiesForKeys: nil,
      options: []
    )
    for export in exports {
      let name = export.lastPathComponent
      if name.hasPrefix("\(sessionID)_") || name.hasPrefix(".\(sessionID)_") {
        try fileManager.removeItem(at: export)
      }
    }
  }
}

final class ProductSessionRepositoryBridge {
  static let modelID = "sherpa-onnx-streaming-zipformer-zh-14M-2023-02-23"

  private let repository: ProductSessionRepository
  private var permissionRequestActive = false
  private let queue = DispatchQueue(
    label: "org.hohu.momentai.product.session-repository",
    qos: .userInitiated
  )

  init(messenger: FlutterBinaryMessenger, runtime: RecordingRuntime = .shared) {
    repository = ProductSessionRepository(
      rootURLProvider: { try runtime.sessionRootURL() },
      activeDirectoryProvider: { runtime.activeDirectoryPath() }
    )
    let channel = FlutterMethodChannel(
      name: "org.hohu.momentai.product/session_repository",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    if call.method == "requestPermission" {
      DispatchQueue.main.async {
        self.requestPermission(call, result: result)
      }
      return
    }
    if call.method == "openSystemSettings" {
      DispatchQueue.main.async {
        guard let url = URL(string: UIApplication.openSettingsURLString) else {
          result(
            FlutterError(
              code: "SystemSettingsError",
              message: "Unable to create the iOS Settings URL.",
              details: nil
            ))
          return
        }
        UIApplication.shared.open(url, options: [:]) { opened in
          if opened {
            result(nil)
          } else {
            result(
              FlutterError(
                code: "SystemSettingsError",
                message: "iOS Settings could not be opened.",
                details: nil
              ))
          }
        }
      }
      return
    }
    queue.async {
      do {
        let value: Any?
        switch call.method {
        case "listSessions":
          value = try self.repository.listSessions()
        case "getSession":
          value = try self.repository.session(sessionID: try self.sessionID(call))
        case "renameSession":
          let arguments = call.arguments as? [String: Any]
          guard let title = arguments?["title"] as? String else {
            throw ProductSessionRepositoryError.invalidSessionID
          }
          value = try self.repository.rename(
            sessionID: try self.sessionID(call),
            title: title
          )
        case "deleteSession":
          try self.repository.delete(sessionID: try self.sessionID(call))
          value = nil
        case "storageOverview":
          value = try self.repository.storageOverview()
        case "systemOverview":
          value = Self.systemOverview()
        default:
          DispatchQueue.main.async { result(FlutterMethodNotImplemented) }
          return
        }
        DispatchQueue.main.async { result(value) }
      } catch {
        DispatchQueue.main.async {
          result(
            FlutterError(
              code: "SessionRepositoryError",
              message: error.localizedDescription,
              details: nil
            ))
        }
      }
    }
  }

  private static func systemOverview() -> [String: Any] {
    let bundle = Bundle.main
    return [
      "microphonePermission": microphonePermission(),
      "cameraPermission": cameraPermission(),
      "appVersion": bundle.object(
        forInfoDictionaryKey: "CFBundleShortVersionString"
      ) as? String ?? "",
      "buildNumber": bundle.object(
        forInfoDictionaryKey: "CFBundleVersion"
      ) as? String ?? "",
      "modelId": modelID,
    ]
  }

  private func requestPermission(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let arguments = call.arguments as? [String: Any]
    guard let permission = arguments?["permission"] as? String,
      ["microphone", "camera"].contains(permission)
    else {
      result(FlutterError(code: "invalid_permission", message: "Unknown permission.", details: nil))
      return
    }
    guard !permissionRequestActive else {
      result(
        FlutterError(
          code: "permission_busy", message: "A permission request is already active.", details: nil)
      )
      return
    }
    let status = permission == "microphone" ? Self.microphonePermission() : Self.cameraPermission()
    guard status == "not_determined" else {
      result(nil)
      return
    }
    permissionRequestActive = true
    let completion: (Bool) -> Void = { _ in
      DispatchQueue.main.async {
        self.permissionRequestActive = false
        result(nil)
      }
    }
    if permission == "camera" {
      AVCaptureDevice.requestAccess(for: .video, completionHandler: completion)
    } else if #available(iOS 17.0, *) {
      AVAudioApplication.requestRecordPermission(completionHandler: completion)
    } else {
      AVAudioSession.sharedInstance().requestRecordPermission(completion)
    }
  }

  private static func microphonePermission() -> String {
    if #available(iOS 17.0, *) {
      switch AVAudioApplication.shared.recordPermission {
      case .granted: return "authorized"
      case .denied: return "denied"
      case .undetermined: return "not_determined"
      @unknown default: return "unknown"
      }
    }
    switch AVAudioSession.sharedInstance().recordPermission {
    case .granted: return "authorized"
    case .denied: return "denied"
    case .undetermined: return "not_determined"
    @unknown default: return "unknown"
    }
  }

  private static func cameraPermission() -> String {
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized: return "authorized"
    case .denied: return "denied"
    case .restricted: return "restricted"
    case .notDetermined: return "not_determined"
    @unknown default: return "unknown"
    }
  }

  private func sessionID(_ call: FlutterMethodCall) throws -> String {
    guard let arguments = call.arguments as? [String: Any],
      let sessionID = arguments["sessionId"] as? String
    else {
      throw ProductSessionRepositoryError.invalidSessionID
    }
    return sessionID
  }
}
