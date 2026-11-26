import Darwin
import Foundation
import UIKit

final class Stage1S15Probe {
  static let enduranceFileName = "stage1_s1_5_endurance_probe.json"
  static let interruptionFileName = "stage1_s1_5_interruption_probe.json"
  static let storageFileName = "stage1_s1_5_storage_probe.json"
  static let compatibilityFileName = "stage1_s1_5_compatibility.json"
  static let enduranceTargetMs: Int64 = 3 * 60 * 60 * 1_000

  private let queue = DispatchQueue(label: "org.hohu.momentai.stage1.s1-5-probe", qos: .utility)
  private let fileManager: FileManager
  private let now: () -> Date
  private let uptimeNanoseconds: () -> UInt64

  private var directoryURL: URL?
  private var startedAt: Date?
  private var startedUptimeNs: UInt64 = 0
  private var lastWriteUptimeNs: UInt64 = 0
  private var latestSamples: Int64 = 0
  private var latestState = "idle"
  private var finalStatus: String?
  private var finalRpoMs: Int64?
  private var initialApplicationState = "unknown"
  private var initialProtectedDataAvailable = true
  private var backgroundCount = 0
  private var foregroundCount = 0
  private var protectedDataUnavailableCount = 0
  private var protectedDataAvailableCount = 0
  private var backgroundStartedUptimeNs: UInt64?
  private var protectedDataUnavailableStartedUptimeNs: UInt64?
  private var backgroundDurationNs: UInt64 = 0
  private var protectedDataUnavailableDurationNs: UInt64 = 0
  private var lifecycleEvents: [[String: Any]] = []
  private var interruptionProbe: [String: Any] = [:]
  private var storageProbe: [String: Any] = [:]

  init(
    fileManager: FileManager = .default,
    now: @escaping () -> Date = Date.init,
    uptimeNanoseconds: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
  ) {
    self.fileManager = fileManager
    self.now = now
    self.uptimeNanoseconds = uptimeNanoseconds
  }

  func start(
    directoryURL: URL,
    samples: Int64,
    applicationState: String,
    protectedDataAvailable: Bool
  ) {
    queue.sync {
      self.directoryURL = directoryURL
      startedAt = now()
      startedUptimeNs = uptimeNanoseconds()
      lastWriteUptimeNs = startedUptimeNs
      latestSamples = samples
      latestState = "recording"
      finalStatus = nil
      finalRpoMs = nil
      initialApplicationState = applicationState
      initialProtectedDataAvailable = protectedDataAvailable
      backgroundCount = applicationState == "background" ? 1 : 0
      foregroundCount = applicationState == "active" ? 1 : 0
      protectedDataUnavailableCount = protectedDataAvailable ? 0 : 1
      protectedDataAvailableCount = protectedDataAvailable ? 1 : 0
      backgroundStartedUptimeNs = applicationState == "background" ? startedUptimeNs : nil
      protectedDataUnavailableStartedUptimeNs = protectedDataAvailable ? nil : startedUptimeNs
      backgroundDurationNs = 0
      protectedDataUnavailableDurationNs = 0
      lifecycleEvents = [
        [
          "type": "probe_started",
          "sample_offset": samples,
          "wall_time": iso8601(now()),
          "uptime_ns": Int64(clamping: startedUptimeNs),
        ]
      ]
      interruptionProbe = [:]
      storageProbe = [:]
      writeEnduranceLocked()
      writeJSONLocked(
        Self.compatibilityReport(storageURL: directoryURL), fileName: Self.compatibilityFileName)
    }
  }

  func noteProgress(samples: Int64, state: String) {
    queue.async {
      guard self.directoryURL != nil else { return }
      self.latestSamples = max(self.latestSamples, samples)
      self.latestState = state
      let currentUptime = self.uptimeNanoseconds()
      if currentUptime >= self.lastWriteUptimeNs + 60_000_000_000 {
        self.lastWriteUptimeNs = currentUptime
        self.writeEnduranceLocked()
      }
    }
  }

  func noteLifecycle(type: String, samples: Int64) {
    queue.async {
      guard self.directoryURL != nil else { return }
      let currentUptime = self.uptimeNanoseconds()
      self.latestSamples = max(self.latestSamples, samples)
      switch type {
      case "application_background":
        self.backgroundCount += 1
        self.backgroundStartedUptimeNs = self.backgroundStartedUptimeNs ?? currentUptime
      case "application_foreground":
        self.foregroundCount += 1
        if let began = self.backgroundStartedUptimeNs, currentUptime >= began {
          self.backgroundDurationNs += currentUptime - began
        }
        self.backgroundStartedUptimeNs = nil
      case "protected_data_unavailable":
        self.protectedDataUnavailableCount += 1
        self.protectedDataUnavailableStartedUptimeNs =
          self.protectedDataUnavailableStartedUptimeNs ?? currentUptime
      case "protected_data_available":
        self.protectedDataAvailableCount += 1
        if let began = self.protectedDataUnavailableStartedUptimeNs, currentUptime >= began {
          self.protectedDataUnavailableDurationNs += currentUptime - began
        }
        self.protectedDataUnavailableStartedUptimeNs = nil
      default:
        break
      }
      self.lifecycleEvents.append([
        "type": type,
        "sample_offset": samples,
        "wall_time": self.iso8601(self.now()),
        "uptime_ns": Int64(clamping: currentUptime),
      ])
      if self.lifecycleEvents.count > 256 {
        self.lifecycleEvents.removeFirst(self.lifecycleEvents.count - 256)
      }
      self.lastWriteUptimeNs = currentUptime
      self.writeEnduranceLocked()
    }
  }

  func finish(samples: Int64, state: String, rpoMs: Int64) {
    queue.sync {
      guard directoryURL != nil else { return }
      let currentUptime = uptimeNanoseconds()
      latestSamples = max(latestSamples, samples)
      latestState = state
      finalStatus = state
      finalRpoMs = rpoMs
      closeOpenIntervalsLocked(at: currentUptime)
      lifecycleEvents.append([
        "type": "probe_finished",
        "sample_offset": samples,
        "wall_time": iso8601(now()),
        "uptime_ns": Int64(clamping: currentUptime),
      ])
      writeEnduranceLocked()
    }
  }

  func noteInterruptionStress(_ payload: [String: Any]) {
    queue.async {
      guard self.directoryURL != nil else { return }
      self.interruptionProbe = payload
      self.writeJSONLocked(payload, fileName: Self.interruptionFileName)
    }
  }

  func noteStorageTest(_ payload: [String: Any]) {
    queue.sync {
      guard directoryURL != nil else { return }
      storageProbe = payload
      writeJSONLocked(payload, fileName: Self.storageFileName)
    }
  }

  func snapshot() -> [String: Any] {
    queue.sync { snapshotLocked() }
  }

  static func hasSufficientStorage(availableBytes: Int64, minimumBytes: Int64) -> Bool {
    availableBytes >= minimumBytes
  }

  static func availableStorageBytes(at url: URL) -> Int64 {
    let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
    return values?.volumeAvailableCapacityForImportantUsage ?? 0
  }

  static func compatibilityReport(storageURL: URL) -> [String: Any] {
    let process = ProcessInfo.processInfo
    let device = UIDevice.current
    let app = Bundle.main
    return [
      "schema_version": 1,
      "generated_at": ISO8601DateFormatter().string(from: Date()),
      "hardware_identifier": hardwareIdentifier(),
      "device_name": device.name,
      "device_model": device.model,
      "system_name": device.systemName,
      "system_version": device.systemVersion,
      "operating_system_version": process.operatingSystemVersionString,
      "processor_count": process.processorCount,
      "active_processor_count": process.activeProcessorCount,
      "physical_memory_bytes": Int64(clamping: process.physicalMemory),
      "thermal_state": thermalStateName(process.thermalState),
      "low_power_mode": process.isLowPowerModeEnabled,
      "available_storage_bytes": availableStorageBytes(at: storageURL),
      "architecture": architectureName(),
      "preferred_languages": Locale.preferredLanguages,
      "app_version": app.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        ?? "",
      "app_build": app.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
      "minimum_os_version": app.object(forInfoDictionaryKey: "MinimumOSVersion") as? String ?? "",
    ]
  }

  private func snapshotLocked() -> [String: Any] {
    guard startedAt != nil else {
      return [
        "active": false,
        "target_ms": Self.enduranceTargetMs,
      ]
    }
    let currentUptime = uptimeNanoseconds()
    let elapsedNs = currentUptime >= startedUptimeNs ? currentUptime - startedUptimeNs : 0
    let backgroundNs = intervalDurationLocked(
      accumulated: backgroundDurationNs,
      openStart: backgroundStartedUptimeNs,
      current: currentUptime
    )
    let protectedNs = intervalDurationLocked(
      accumulated: protectedDataUnavailableDurationNs,
      openStart: protectedDataUnavailableStartedUptimeNs,
      current: currentUptime
    )
    var result: [String: Any] = [
      "schema_version": 1,
      "active": finalStatus == nil,
      "started_at": iso8601(startedAt!),
      "elapsed_ms": Int64(elapsedNs / 1_000_000),
      "target_ms": Self.enduranceTargetMs,
      "target_reached": elapsedNs / 1_000_000 >= UInt64(Self.enduranceTargetMs),
      "latest_samples": latestSamples,
      "latest_state": latestState,
      "initial_application_state": initialApplicationState,
      "initial_protected_data_available": initialProtectedDataAvailable,
      "background_count": backgroundCount,
      "foreground_count": foregroundCount,
      "background_duration_ms": Int64(backgroundNs / 1_000_000),
      "protected_data_unavailable_count": protectedDataUnavailableCount,
      "protected_data_available_count": protectedDataAvailableCount,
      "protected_data_unavailable_duration_ms": Int64(protectedNs / 1_000_000),
      "lifecycle_events": lifecycleEvents,
    ]
    if let finalStatus { result["final_status"] = finalStatus }
    if let finalRpoMs { result["final_rpo_ms"] = finalRpoMs }
    if !interruptionProbe.isEmpty { result["interruption_stress"] = interruptionProbe }
    if !storageProbe.isEmpty { result["storage_test"] = storageProbe }
    return result
  }

  private func closeOpenIntervalsLocked(at currentUptime: UInt64) {
    if let began = backgroundStartedUptimeNs, currentUptime >= began {
      backgroundDurationNs += currentUptime - began
    }
    backgroundStartedUptimeNs = nil
    if let began = protectedDataUnavailableStartedUptimeNs, currentUptime >= began {
      protectedDataUnavailableDurationNs += currentUptime - began
    }
    protectedDataUnavailableStartedUptimeNs = nil
  }

  private func intervalDurationLocked(
    accumulated: UInt64,
    openStart: UInt64?,
    current: UInt64
  ) -> UInt64 {
    guard let openStart, current >= openStart else { return accumulated }
    return accumulated + current - openStart
  }

  private func writeEnduranceLocked() {
    writeJSONLocked(snapshotLocked(), fileName: Self.enduranceFileName)
  }

  private func writeJSONLocked(_ value: [String: Any], fileName: String) {
    guard let directoryURL,
      JSONSerialization.isValidJSONObject(value),
      let data = try? JSONSerialization.data(
        withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    else { return }
    try? data.write(to: directoryURL.appendingPathComponent(fileName), options: [.atomic])
  }

  private func iso8601(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
  }

  private static func hardwareIdentifier() -> String {
    var size: size_t = 0
    guard sysctlbyname("hw.machine", nil, &size, nil, 0) == 0 else { return "unknown" }
    var value = [CChar](repeating: 0, count: size)
    guard sysctlbyname("hw.machine", &value, &size, nil, 0) == 0 else { return "unknown" }
    return String(cString: value)
  }

  private static func architectureName() -> String {
    #if arch(arm64)
      return "arm64"
    #elseif arch(x86_64)
      return "x86_64"
    #else
      return "unknown"
    #endif
  }

  private static func thermalStateName(_ state: ProcessInfo.ThermalState) -> String {
    switch state {
    case .nominal: return "nominal"
    case .fair: return "fair"
    case .serious: return "serious"
    case .critical: return "critical"
    @unknown default: return "unknown"
    }
  }
}
