import AVFoundation
import Foundation

enum ASRProbeMode: String {
  case normal
  case slow
  case failed
  case disabled
}

final class BoundedASRProbe {
  private let queue = DispatchQueue(label: "org.hohu.momentai.poc.asr", qos: .utility)
  private let lock = NSLock()
  private let capacity = 4

  private var mode: ASRProbeMode = .normal
  private var pendingCount = 0
  private var processedSamples: Int64 = 0
  private var droppedBuffers: Int64 = 0
  private var droppedSamples: Int64 = 0
  private var failedSamples: Int64 = 0
  private var generation: Int64 = 0

  func reset() {
    lock.lock()
    generation += 1
    mode = .normal
    pendingCount = 0
    processedSamples = 0
    droppedBuffers = 0
    droppedSamples = 0
    failedSamples = 0
    lock.unlock()
  }

  func setMode(_ rawValue: String) {
    lock.lock()
    mode = ASRProbeMode(rawValue: rawValue) ?? .normal
    lock.unlock()
  }

  func enqueue(_ buffer: AVAudioPCMBuffer) {
    let frameCount = Int64(buffer.frameLength)
    lock.lock()
    let currentMode = mode
    let currentGeneration = generation
    guard currentMode != .disabled else {
      lock.unlock()
      return
    }
    guard pendingCount < capacity else {
      droppedBuffers += 1
      droppedSamples += frameCount
      lock.unlock()
      return
    }
    pendingCount += 1
    lock.unlock()

    queue.async { [weak self] in
      guard let self else { return }
      switch currentMode {
      case .normal:
        usleep(20_000)
      case .slow:
        usleep(1_500_000)
      case .failed:
        usleep(10_000)
      case .disabled:
        break
      }

      self.lock.lock()
      guard self.generation == currentGeneration else {
        self.lock.unlock()
        return
      }
      self.pendingCount = max(0, self.pendingCount - 1)
      if currentMode == .failed {
        self.failedSamples += frameCount
      } else {
        self.processedSamples += frameCount
      }
      self.lock.unlock()
    }
  }

  func snapshot() -> [String: Any] {
    lock.lock()
    defer { lock.unlock() }
    return [
      "mode": mode.rawValue,
      "queueDepth": pendingCount,
      "queueCapacity": capacity,
      "processedSamples": processedSamples,
      "droppedBuffers": droppedBuffers,
      "droppedSamples": droppedSamples,
      "failedSamples": failedSamples,
    ]
  }
}
