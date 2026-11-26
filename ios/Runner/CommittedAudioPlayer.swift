import AVFoundation
import Foundation

enum CommittedAudioPlayerError: LocalizedError {
  case invalidSession(String)
  case invalidState(String)
  case invalidAudio(String)

  var errorDescription: String? {
    switch self {
    case .invalidSession(let message),
      .invalidState(let message),
      .invalidAudio(let message):
      return message
    }
  }
}

/// Recording-wide analysis prevents gain from pumping between words or pauses.
struct PlaybackLoudnessProfile {
  private var levels: [Double] = []

  mutating func addPCM16(_ data: Data) {
    data.withUnsafeBytes { bytes in
      let samples = bytes.bindMemory(to: Int16.self)
      var offset = 0
      while offset < samples.count {
        let end = min(offset + 1600, samples.count)
        let count = end - offset
        var energy = 0.0
        for index in offset..<end {
          let value = Double(Int16(littleEndian: samples[index])) / 32_768
          energy += value * value
        }
        let rms = sqrt(energy / Double(count))
        // Ignore near-silence below -60 dBFS and windows shorter than 50 ms.
        if count >= 800 && rms >= 0.001 { levels.append(rms) }
        offset = end
      }
    }
  }

  var gain: Float {
    guard levels.count >= 5 else { return 1 }
    let sorted = levels.sorted()
    let reference = sorted[max(0, Int(ceil(Double(sorted.count) * 0.9)) - 1)]
    // Target -20 dBFS active-window RMS, with at most +30 dB of compensation.
    return Float(min(max(0.1 / reference, 1), 31.6227766))
  }
}

final class PlaybackSignalProcessor {
  var gainDB: Double { enhanced ? 20 * log10(Double(compensationGain)) : 0 }
  var compensationGain: Float = 1
  static let limiterThreshold: Float = 0.90
  private(set) var volume: Float = 1
  private(set) var enhanced = false
  private var currentVolume: Float = 1
  private var mix: Float = 0
  private var remaining = 0

  func configure(volume: Float, enhanced: Bool) {
    precondition(volume.isFinite && (0...1).contains(volume))
    self.volume = volume
    self.enhanced = enhanced
    remaining = 320
  }

  func reset() {
    currentVolume = 0
    mix = enhanced ? 1 : 0
    remaining = 320
  }

  func processPCM16(_ sample: Int16) -> Float {
    if remaining > 0 {
      currentVolume += (volume - currentVolume) / Float(remaining)
      mix += ((enhanced ? 1 : 0) - mix) / Float(remaining)
      remaining -= 1
    }
    let original = Float(sample) / 32_768
    let amplified = original * compensationGain
    let magnitude = abs(amplified)
    let limited: Float
    if magnitude <= Self.limiterThreshold {
      limited = amplified
    } else {
      let peak = min(
        0.9 + 0.1 * (1 - Float(Foundation.exp(Double(-(magnitude - 0.9) / 0.1)))), 0.999)
      limited = amplified < 0 ? -peak : peak
    }
    return (original + mix * (limited - original)) * currentVolume
  }
}

enum PlaybackPositionResolver {
  static func resolve(
    baseSample: Int64,
    renderedElapsedSamples: Int64,
    reportedSampleFloor: Int64,
    durationSamples: Int64
  ) -> Int64 {
    let renderedSample = max(baseSample, baseSample + renderedElapsedSamples)
    return min(durationSamples, max(reportedSampleFloor, renderedSample))
  }
}

struct PlaybackChunkDescriptor {
  let index: Int
  let url: URL
  let startSample: Int64
  let endSample: Int64
  let byteCount: Int64
}

struct PlaybackLocation {
  let chunkIndex: Int
  let offsetInChunk: Int64
}

struct CommittedAudioManifest {
  let sessionID: String
  let directoryURL: URL
  let sampleRate: Double
  let durationSamples: Int64
  let chunks: [PlaybackChunkDescriptor]

  init(store: SessionStore) throws {
    let snapshot = try store.snapshot()
    let status = snapshot["state"] as? String ?? ""
    guard ["completed", "completed_with_gaps"].contains(status) else {
      throw CommittedAudioPlayerError.invalidSession(
        "Only completed Sessions can be played; current state is \(status)."
      )
    }
    let sampleRate = (snapshot["sampleRate"] as? NSNumber)?.doubleValue ?? 0
    let highWater = (snapshot["lastCommittedSample"] as? NSNumber)?.int64Value ?? 0
    guard sampleRate > 0, highWater > 0 else {
      throw CommittedAudioPlayerError.invalidSession("Session has no committed audio.")
    }

    let ordered = try store.chunks().values.sorted { $0.index < $1.index }
    guard !ordered.isEmpty else {
      throw CommittedAudioPlayerError.invalidSession("Session has no committed Chunk.")
    }
    var startSample: Int64 = 0
    var descriptors: [PlaybackChunkDescriptor] = []
    descriptors.reserveCapacity(ordered.count)
    for (expectedIndex, chunk) in ordered.enumerated() {
      guard chunk.index == expectedIndex else {
        throw CommittedAudioPlayerError.invalidAudio("Chunk indexes are not contiguous.")
      }
      let url = store.directoryURL.appendingPathComponent(chunk.path)
      let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
      guard values.isRegularFile == true,
        Int64(values.fileSize ?? -1) == chunk.byteCount,
        chunk.byteCount == chunk.sampleCount * 2
      else {
        throw CommittedAudioPlayerError.invalidAudio(
          "Committed Chunk \(chunk.index) is missing or has an invalid PCM16 length."
        )
      }
      let endSample = startSample + chunk.sampleCount
      descriptors.append(
        PlaybackChunkDescriptor(
          index: chunk.index,
          url: url,
          startSample: startSample,
          endSample: endSample,
          byteCount: chunk.byteCount
        )
      )
      startSample = endSample
    }
    guard startSample == highWater else {
      throw CommittedAudioPlayerError.invalidAudio(
        "Chunk samples do not equal the committed audio high-water."
      )
    }

    sessionID = store.sessionID
    directoryURL = store.directoryURL
    self.sampleRate = sampleRate
    durationSamples = highWater
    chunks = descriptors
  }

  func clampedSample(_ sample: Int64) -> Int64 {
    min(max(0, sample), durationSamples)
  }

  func location(for sample: Int64) -> PlaybackLocation? {
    let target = clampedSample(sample)
    guard target < durationSamples else { return nil }
    var lower = 0
    var upper = chunks.count - 1
    while lower <= upper {
      let middle = (lower + upper) / 2
      let chunk = chunks[middle]
      if target < chunk.startSample {
        upper = middle - 1
      } else if target >= chunk.endSample {
        lower = middle + 1
      } else {
        return PlaybackLocation(
          chunkIndex: middle,
          offsetInChunk: target - chunk.startSample
        )
      }
    }
    return nil
  }
}

final class CommittedAudioPlayer {
  typealias Completion = (Result<[String: Any], Error>) -> Void
  typealias EventHandler = ([String: Any]) -> Void

  private let queue = DispatchQueue(label: "org.hohu.momentai.playback", qos: .userInitiated)
  private var eventHandler: EventHandler?
  private var manifest: CommittedAudioManifest?
  private var engine: AVAudioEngine?
  private var playerNode: AVAudioPlayerNode?
  private var state = "idle"
  private var baseSample: Int64 = 0
  private var pausedSample: Int64 = 0
  private var reportedSampleFloor: Int64 = 0
  private var nextChunkIndex = 0
  private var firstChunkOffset: Int64 = 0
  private var generation = 0
  private var timer: DispatchSourceTimer?
  private var scheduledBufferBytes: Int64 = 0
  private var peakBufferedBytes: Int64 = 0
  private var lastAnchorID = ""
  private var lastAnchorType = ""
  private var outputPortType = ""
  private var outputPortName = ""
  private var outputVolume: Float = 0
  private let signalProcessor = PlaybackSignalProcessor()
  private let soundDefaults: UserDefaults
  private let notificationCenter: NotificationCenter
  private var observers: [NSObjectProtocol] = []

  init(
    soundDefaults: UserDefaults = .standard,
    notificationCenter: NotificationCenter = .default
  ) {
    self.soundDefaults = soundDefaults
    self.notificationCenter = notificationCenter
    let saved = soundDefaults.object(forKey: "playbackVolume") as? NSNumber
    let volume = saved?.floatValue ?? 1
    signalProcessor.configure(
      volume: volume.isFinite ? min(max(volume, 0), 1) : 1,
      enhanced: soundDefaults.object(forKey: "playbackAutoLevel") as? Bool ?? true)
    observeAudioSession()
  }

  deinit {
    for observer in observers { notificationCenter.removeObserver(observer) }
    timer?.cancel()
    playerNode?.stop()
    engine?.stop()
  }

  private func observeAudioSession() {
    for name in [
      AVAudioSession.interruptionNotification,
      AVAudioSession.routeChangeNotification,
      AVAudioSession.mediaServicesWereResetNotification,
      Notification.Name.AVAudioEngineConfigurationChange,
    ] {
      observers.append(
        notificationCenter.addObserver(forName: name, object: nil, queue: nil) {
          [weak self] notification in
          self?.queue.async { [weak self] in self?.handleAudioSessionLocked(notification) }
        })
    }
  }

  private func handleAudioSessionLocked(_ notification: Notification) {
    guard manifest != nil else { return }
    switch notification.name {
    case AVAudioSession.interruptionNotification:
      guard
        (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue
          == AVAudioSession.InterruptionType.began.rawValue
      else { return }
    case AVAudioSession.routeChangeNotification:
      guard
        (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue
          == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
      else { return }
    case Notification.Name.AVAudioEngineConfigurationChange:
      guard let changedEngine = notification.object as? AVAudioEngine,
        changedEngine === engine
      else { return }
    case AVAudioSession.mediaServicesWereResetNotification:
      break
    default:
      return
    }
    // Freeze the last known position before discarding an invalid audio graph.
    // Returning focus or reconnecting headphones never starts playback by itself.
    pausedSample = currentSampleLocked()
    if state == "playing" { state = "paused" }
    generation += 1
    stopTimerLocked()
    playerNode?.stop()
    engine?.stop()
    playerNode = nil
    engine = nil
    scheduledBufferBytes = 0
    emitLocked()
  }

  func soundSettings(completion: @escaping Completion) {
    queue.async { self.completeLocked(completion, result: .success(self.soundSettingsLocked())) }
  }

  func setSound(volume: Float, enhanced: Bool, completion: @escaping Completion) {
    queue.async {
      guard volume.isFinite && (0...1).contains(volume) else {
        self.completeLocked(
          completion,
          result: .failure(CommittedAudioPlayerError.invalidState("Invalid playback volume.")))
        return
      }
      self.signalProcessor.configure(volume: volume, enhanced: enhanced)
      self.soundDefaults.set(volume, forKey: "playbackVolume")
      self.soundDefaults.set(enhanced, forKey: "playbackAutoLevel")
      self.completeLocked(completion, result: .success(self.soundSettingsLocked()))
    }
  }

  private func soundSettingsLocked() -> [String: Any] {
    ["volume": signalProcessor.volume, "enhanced": signalProcessor.enhanced]
  }

  private var probeSessionID = ""
  private var probeCommands: [[String: Any]] = []

  func setEventHandler(_ handler: EventHandler?) {
    queue.async {
      self.eventHandler = handler
      if handler != nil { self.emitLocked() }
    }
  }

  func play(
    directoryPath: String,
    sampleOffset: Int64,
    anchorID: String,
    anchorType: String,
    completion: @escaping Completion
  ) {
    queue.async {
      do {
        try self.stopLocked(emit: false, deactivateSession: false)
        let store = try SessionStore(
          directoryURL: URL(fileURLWithPath: directoryPath),
          create: false
        )
        let manifest = try CommittedAudioManifest(store: store)
        self.manifest = manifest
        self.signalProcessor.compensationGain = try self.analyzeLoudness(manifest)
        self.lastAnchorID = anchorID
        self.lastAnchorType = anchorType
        if self.probeSessionID != manifest.sessionID {
          self.probeSessionID = manifest.sessionID
          self.probeCommands = []
          self.peakBufferedBytes = 0
        }
        try self.prepareEngineLocked(sampleRate: manifest.sampleRate)
        let target = manifest.clampedSample(sampleOffset)
        if target == manifest.durationSamples {
          self.baseSample = target
          self.pausedSample = target
          self.reportedSampleFloor = target
          self.state = "completed"
        } else {
          try self.scheduleLocked(from: target)
          self.playerNode?.play()
          self.state = "playing"
          self.startTimerLocked()
        }
        self.appendProbeCommandLocked(
          type: "play_anchor",
          requestedSample: sampleOffset,
          resolvedSample: target,
          extra: ["anchorId": anchorID, "anchorType": anchorType]
        )
        self.emitLocked()
        self.completeLocked(completion, result: .success(self.snapshotLocked()))
      } catch {
        self.failLocked(error, completion: completion)
      }
    }
  }

  func pause(completion: @escaping Completion) {
    queue.async {
      do {
        guard self.state == "playing", let node = self.playerNode else {
          throw CommittedAudioPlayerError.invalidState("Playback is not running.")
        }
        self.pausedSample = self.currentSampleLocked()
        node.pause()
        self.state = "paused"
        self.appendProbeCommandLocked(
          type: "pause",
          requestedSample: self.pausedSample,
          resolvedSample: self.pausedSample
        )
        self.stopTimerLocked()
        self.emitLocked()
        self.completeLocked(completion, result: .success(self.snapshotLocked()))
      } catch {
        self.completeLocked(completion, result: .failure(error))
      }
    }
  }

  func resume(completion: @escaping Completion) {
    queue.async {
      do {
        guard let manifest = self.manifest else {
          throw CommittedAudioPlayerError.invalidState("No Session is prepared for playback.")
        }
        guard self.state == "completed" || self.state == "paused" else {
          throw CommittedAudioPlayerError.invalidState("Playback is not paused.")
        }
        let target = self.state == "completed" ? 0 : self.pausedSample
        self.generation += 1
        self.playerNode?.stop()
        self.engine?.stop()
        self.playerNode = nil
        self.engine = nil
        try self.prepareEngineLocked(sampleRate: manifest.sampleRate)
        try self.scheduleLocked(from: target)
        self.playerNode?.play()
        self.state = "playing"
        self.startTimerLocked()
        self.appendProbeCommandLocked(
          type: "resume",
          requestedSample: self.currentSampleLocked(),
          resolvedSample: self.currentSampleLocked(),
          extra: ["durationSamples": manifest.durationSamples]
        )
        self.emitLocked()
        self.completeLocked(completion, result: .success(self.snapshotLocked()))
      } catch {
        self.completeLocked(completion, result: .failure(error))
      }
    }
  }

  func seek(sampleOffset: Int64, completion: @escaping Completion) {
    queue.async {
      do {
        guard let manifest = self.manifest else {
          throw CommittedAudioPlayerError.invalidState("No Session is prepared for playback.")
        }
        let shouldResume = self.state == "playing"
        let target = manifest.clampedSample(sampleOffset)
        if target == manifest.durationSamples {
          self.generation += 1
          self.playerNode?.stop()
          self.baseSample = target
          self.pausedSample = target
          self.scheduledBufferBytes = 0
          self.state = "completed"
          self.stopTimerLocked()
        } else {
          if self.playerNode != nil {
            try self.scheduleLocked(from: target)
          } else {
            self.baseSample = target
            self.pausedSample = target
            self.reportedSampleFloor = target
          }
          if shouldResume {
            self.playerNode?.play()
            self.state = "playing"
            self.startTimerLocked()
          } else {
            self.state = "paused"
            self.stopTimerLocked()
          }
        }
        self.appendProbeCommandLocked(
          type: "seek",
          requestedSample: sampleOffset,
          resolvedSample: target
        )
        self.emitLocked()
        self.completeLocked(completion, result: .success(self.snapshotLocked()))
      } catch {
        self.completeLocked(completion, result: .failure(error))
      }
    }
  }

  func stop(completion: @escaping Completion) {
    queue.async {
      do {
        try self.stopLocked(emit: true, deactivateSession: true)
        self.completeLocked(completion, result: .success(self.snapshotLocked()))
      } catch {
        self.completeLocked(completion, result: .failure(error))
      }
    }
  }

  private func analyzeLoudness(_ manifest: CommittedAudioManifest) throws -> Float {
    var profile = PlaybackLoudnessProfile()
    let window = Int64(manifest.sampleRate)
    let count = min(60, max(1, Int((manifest.durationSamples + window - 1) / window)))
    for index in 0..<count {
      let target =
        count == 1 ? 0 : Int64(index) * max(0, manifest.durationSamples - window) / Int64(count - 1)
      guard let location = manifest.location(for: target) else { continue }
      let chunk = manifest.chunks[location.chunkIndex]
      let frames = min(window, chunk.endSample - target)
      let file = try FileHandle(forReadingFrom: chunk.url)
      defer { try? file.close() }
      try file.seek(toOffset: UInt64(location.offsetInChunk * 2))
      let data = file.readData(ofLength: Int(frames * 2))
      guard data.count == Int(frames * 2) else {
        throw CommittedAudioPlayerError.invalidAudio("Incomplete audio during loudness analysis.")
      }
      profile.addPCM16(data)
    }
    return profile.gain
  }

  private func prepareEngineLocked(sampleRate: Double) throws {
    let audioSession = AVAudioSession.sharedInstance()
    do {
      // Playback uses the media route; recording configures its own input session.
      try audioSession.setCategory(.playback, mode: .default)
    } catch {
      throw playbackSetupError(step: "configure audio session", error: error)
    }
    do {
      try audioSession.setActive(true)
    } catch {
      throw playbackSetupError(step: "activate audio session", error: error)
    }
    refreshOutputRouteLocked(audioSession)

    guard
      let format = AVAudioFormat(
        standardFormatWithSampleRate: sampleRate,
        channels: 1
      )
    else {
      try? audioSession.setActive(false, options: [.notifyOthersOnDeactivation])
      throw CommittedAudioPlayerError.invalidAudio(
        "Playback setup failed at create PCM format (sampleRate=\(sampleRate), channels=1)."
      )
    }

    let engine = AVAudioEngine()
    let node = AVAudioPlayerNode()
    engine.attach(node)
    engine.connect(node, to: engine.mainMixerNode, format: format)
    engine.prepare()
    do {
      try engine.start()
    } catch {
      engine.stop()
      try? audioSession.setActive(false, options: [.notifyOthersOnDeactivation])
      throw playbackSetupError(step: "start audio engine", error: error)
    }
    refreshOutputRouteLocked(audioSession)
    self.engine = engine
    playerNode = node
  }

  private func playbackSetupError(step: String, error: Error) -> Error {
    let nativeError = error as NSError
    return CommittedAudioPlayerError.invalidState(
      "Playback setup failed at \(step): \(nativeError.domain) "
        + "code \(nativeError.code) (\(nativeError.localizedDescription))."
    )
  }

  private func refreshOutputRouteLocked(_ audioSession: AVAudioSession = .sharedInstance()) {
    let outputs = audioSession.currentRoute.outputs
    outputPortType = outputs.map { $0.portType.rawValue }.joined(separator: ",")
    outputPortName = outputs.map(\.portName).joined(separator: ", ")
    outputVolume = audioSession.outputVolume
  }

  private func scheduleLocked(from sample: Int64) throws {
    guard let manifest, let node = playerNode,
      let location = manifest.location(for: sample)
    else {
      throw CommittedAudioPlayerError.invalidAudio("Playback position is outside committed audio.")
    }
    generation += 1
    node.stop()
    baseSample = sample
    pausedSample = sample
    reportedSampleFloor = sample
    nextChunkIndex = location.chunkIndex
    firstChunkOffset = location.offsetInChunk
    scheduledBufferBytes = 0
    signalProcessor.reset()
    let activeGeneration = generation
    try scheduleNextBufferLocked(generation: activeGeneration)
    if nextChunkIndex < manifest.chunks.count {
      try scheduleNextBufferLocked(generation: activeGeneration)
    }
  }

  private func scheduleNextBufferLocked(generation activeGeneration: Int) throws {
    guard let manifest, let node = playerNode,
      nextChunkIndex < manifest.chunks.count
    else { return }
    let chunk = manifest.chunks[nextChunkIndex]
    let offsetSamples = firstChunkOffset
    // Keep only two short slices queued so sound controls respond during playback.
    let frameCount = min(
      Int64(manifest.sampleRate / 10), chunk.endSample - chunk.startSample - offsetSamples)
    guard frameCount > 0, frameCount <= Int64(UInt32.max),
      let format = AVAudioFormat(
        standardFormatWithSampleRate: manifest.sampleRate,
        channels: 1
      ),
      let buffer = AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: AVAudioFrameCount(frameCount)
      ),
      let destination = buffer.floatChannelData?[0]
    else {
      throw CommittedAudioPlayerError.invalidAudio("Unable to allocate a playback buffer.")
    }
    let data = try Data(contentsOf: chunk.url, options: [.mappedIfSafe])
    let byteOffset = Int(offsetSamples * 2)
    let bytesToCopy = Int(frameCount * 2)
    guard byteOffset >= 0, byteOffset + bytesToCopy <= data.count else {
      throw CommittedAudioPlayerError.invalidAudio(
        "Chunk \(chunk.index) cannot satisfy the requested playback range."
      )
    }
    data.withUnsafeBytes { bytes in
      let source = bytes.bindMemory(to: Int16.self)
      let sourceStart = byteOffset / MemoryLayout<Int16>.size
      for index in 0..<Int(frameCount) {
        destination[index] = signalProcessor.processPCM16(
          Int16(littleEndian: source[sourceStart + index])
        )
      }
    }
    buffer.frameLength = AVAudioFrameCount(frameCount)

    firstChunkOffset += frameCount
    if firstChunkOffset >= chunk.endSample - chunk.startSample {
      nextChunkIndex += 1
      firstChunkOffset = 0
    }
    scheduledBufferBytes += Int64(bytesToCopy)
    peakBufferedBytes = max(peakBufferedBytes, scheduledBufferBytes)
    let isLast = nextChunkIndex == manifest.chunks.count
    node.scheduleBuffer(
      buffer,
      completionCallbackType: isLast ? .dataPlayedBack : .dataConsumed
    ) { [weak self] _ in
      guard let self else { return }
      self.queue.async {
        guard self.generation == activeGeneration else { return }
        self.scheduledBufferBytes = max(0, self.scheduledBufferBytes - Int64(bytesToCopy))
        if isLast {
          self.finishPlaybackLocked()
        } else {
          do {
            try self.scheduleNextBufferLocked(generation: activeGeneration)
          } catch {
            self.failLocked(error, completion: nil)
          }
        }
      }
    }
  }

  private func currentSampleLocked() -> Int64 {
    guard let manifest else { return 0 }
    if state == "paused" || state == "completed" { return pausedSample }
    guard let node = playerNode,
      let renderTime = node.lastRenderTime,
      let playerTime = node.playerTime(forNodeTime: renderTime),
      playerTime.sampleRate > 0
    else {
      return max(pausedSample, reportedSampleFloor)
    }
    let elapsedSeconds = Double(playerTime.sampleTime) / playerTime.sampleRate
    let elapsedSamples = Int64((elapsedSeconds * manifest.sampleRate).rounded(.down))
    let position = PlaybackPositionResolver.resolve(
      baseSample: baseSample,
      renderedElapsedSamples: elapsedSamples,
      reportedSampleFloor: reportedSampleFloor,
      durationSamples: manifest.durationSamples
    )
    reportedSampleFloor = position
    return position
  }

  private func finishPlaybackLocked() {
    guard let manifest else { return }
    pausedSample = manifest.durationSamples
    reportedSampleFloor = manifest.durationSamples
    state = "completed"
    stopTimerLocked()
    appendProbeCommandLocked(
      type: "completed",
      requestedSample: manifest.durationSamples,
      resolvedSample: manifest.durationSamples
    )
    emitLocked()
  }

  private func stopLocked(emit: Bool, deactivateSession: Bool) throws {
    if let manifest {
      let position = currentSampleLocked()
      appendProbeCommandLocked(
        type: "stop",
        requestedSample: position,
        resolvedSample: position,
        extra: ["durationSamples": manifest.durationSamples]
      )
    }
    generation += 1
    stopTimerLocked()
    playerNode?.stop()
    engine?.stop()
    playerNode = nil
    engine = nil
    manifest = nil
    state = "idle"
    baseSample = 0
    pausedSample = 0
    reportedSampleFloor = 0
    nextChunkIndex = 0
    firstChunkOffset = 0
    scheduledBufferBytes = 0
    lastAnchorID = ""
    lastAnchorType = ""
    if deactivateSession {
      try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
    outputPortType = ""
    outputPortName = ""
    outputVolume = 0
    if emit { emitLocked() }
  }

  private func startTimerLocked() {
    stopTimerLocked()
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now(), repeating: .milliseconds(200), leeway: .milliseconds(40))
    timer.setEventHandler { [weak self] in self?.emitLocked() }
    self.timer = timer
    timer.resume()
  }

  private func stopTimerLocked() {
    timer?.setEventHandler {}
    timer?.cancel()
    timer = nil
  }

  private func appendProbeCommandLocked(
    type: String,
    requestedSample: Int64,
    resolvedSample: Int64,
    extra: [String: Any] = [:]
  ) {
    refreshOutputRouteLocked()
    var command: [String: Any] = [
      "type": type,
      "requestedSample": requestedSample,
      "resolvedSample": resolvedSample,
      "wallTime": ISO8601DateFormatter().string(from: Date()),
      "outputPortType": outputPortType,
      "outputPortName": outputPortName,
      "outputVolume": outputVolume,
    ]
    command.merge(extra) { _, new in new }
    probeCommands.append(command)
    writeProbeLocked()
  }

  private func writeProbeLocked() {
    guard let manifest else { return }
    let probe: [String: Any] = [
      "schemaVersion": 1,
      "sessionId": manifest.sessionID,
      "sampleRate": Int(manifest.sampleRate),
      "durationSamples": manifest.durationSamples,
      "peakBufferedBytes": peakBufferedBytes,
      "outputPortType": outputPortType,
      "outputPortName": outputPortName,
      "outputVolume": outputVolume,
      "signalGainDb": signalProcessor.gainDB,
      "limiterThreshold": PlaybackSignalProcessor.limiterThreshold,
      "commands": probeCommands,
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: probe, options: [.sortedKeys])
    else {
      return
    }
    let url = manifest.directoryURL.appendingPathComponent("stage1_playback_probe.json")
    try? data.write(to: url, options: [.atomic])
  }

  private func snapshotLocked() -> [String: Any] {
    guard let manifest else {
      return [
        "state": "idle",
        "sessionId": "",
        "directory": "",
        "sampleRate": 16_000,
        "positionSample": 0,
        "durationSamples": 0,
        "positionMs": 0,
        "durationMs": 0,
        "anchorId": "",
        "anchorType": "",
        "peakBufferedBytes": peakBufferedBytes,
        "outputPortType": outputPortType,
        "outputPortName": outputPortName,
        "outputVolume": outputVolume,
        "signalGainDb": signalProcessor.gainDB,
        "limiterThreshold": PlaybackSignalProcessor.limiterThreshold,
      ]
    }
    let position = currentSampleLocked()
    return [
      "state": state,
      "sessionId": manifest.sessionID,
      "directory": manifest.directoryURL.path,
      "sampleRate": Int(manifest.sampleRate),
      "positionSample": position,
      "durationSamples": manifest.durationSamples,
      "positionMs": Int64(Double(position) / manifest.sampleRate * 1_000),
      "durationMs": Int64(Double(manifest.durationSamples) / manifest.sampleRate * 1_000),
      "anchorId": lastAnchorID,
      "anchorType": lastAnchorType,
      "peakBufferedBytes": peakBufferedBytes,
      "outputPortType": outputPortType,
      "outputPortName": outputPortName,
      "outputVolume": outputVolume,
      "signalGainDb": signalProcessor.gainDB,
      "limiterThreshold": PlaybackSignalProcessor.limiterThreshold,
    ]
  }

  private func emitLocked() {
    guard let handler = eventHandler else { return }
    if manifest != nil { refreshOutputRouteLocked() }
    let snapshot = snapshotLocked()
    DispatchQueue.main.async { handler(snapshot) }
  }

  private func completeLocked(_ completion: Completion?, result: Result<[String: Any], Error>) {
    guard let completion else { return }
    DispatchQueue.main.async { completion(result) }
  }

  private func failLocked(_ error: Error, completion: Completion?) {
    state = "failed"
    stopTimerLocked()
    var snapshot = snapshotLocked()
    snapshot["error"] = error.localizedDescription
    if let handler = eventHandler {
      DispatchQueue.main.async { handler(snapshot) }
    }
    completeLocked(completion, result: .failure(error))
  }
}
