import AVFoundation
import UIKit

protocol CameraProbeControllerDelegate: AnyObject {
  func cameraProbeController(
    _ controller: CameraProbeController,
    preparePhotoCapture completion: @escaping (Result<[String: Any], Error>) -> Void
  )
  func cameraProbeController(
    _ controller: CameraProbeController,
    didCapture jpegData: Data,
    eventID: String,
    completion: @escaping (Result<[String: Any], Error>) -> Void
  )
  func cameraProbeController(
    _ controller: CameraProbeController,
    didFailCapture eventID: String,
    error: Error,
    completion: @escaping () -> Void
  )
  func cameraProbeController(
    _ controller: CameraProbeController, didFinish results: [[String: Any]])
  func cameraProbeController(_ controller: CameraProbeController, didFail error: Error)
  func cameraProbeControllerDidCancel(_ controller: CameraProbeController)
}

/// A sessionQueue-confined gate that makes the AVCaptureSession lifecycle
/// explicit. AVCaptureVideoPreviewLayer(session:) can synchronously mutate the
/// capture session, so startRunning must not be called until the main-thread
/// preview attachment has completed and acknowledged back on sessionQueue.
final class CameraSessionLifecycleGate {
  private(set) var configurationStarted = false
  private(set) var configurationCommitted = false
  private(set) var previewAttached = false
  private(set) var stopRequested = false
  private(set) var running = false

  func beginConfiguration() -> Bool {
    guard !configurationStarted, !stopRequested else { return false }
    configurationStarted = true
    return true
  }

  func markConfigurationCommitted() {
    configurationCommitted = true
  }

  func markPreviewAttached() {
    previewAttached = true
  }

  func consumeStartPermission() -> Bool {
    guard configurationCommitted, previewAttached, !stopRequested, !running else { return false }
    running = true
    return true
  }

  func requestStop() -> Bool {
    stopRequested = true
    let shouldStop = running
    running = false
    return shouldStop
  }

  func markConfigurationFailed() {
    stopRequested = true
    running = false
  }
}

final class CameraProbeController: UIViewController, AVCapturePhotoCaptureDelegate {
  weak var delegate: CameraProbeControllerDelegate?

  private let captureSession = AVCaptureSession()
  private let photoOutput = AVCapturePhotoOutput()
  private let sessionQueue = DispatchQueue(label: "org.hohu.momentai.poc.camera")
  private let lifecycle = CameraSessionLifecycleGate()
  private let controls = CameraControlsView()
  private var camera: AVCaptureDevice?
  private var zoomMultiplier: CGFloat = 1
  private var minimumZoom: CGFloat = 1
  private var maximumZoom: CGFloat = 1
  private var currentZoom: CGFloat = 1
  private var pinchStartZoom: CGFloat = 1
  private var finishRequested = false
  private var focusReset: DispatchWorkItem?
  var recordingState = "unknown" {
    didSet {
      if recordingState != oldValue && !isSavingPhoto && !finishRequested { updateStatus() }
    }
  }
  private var orientation: AVCaptureVideoOrientation = .portrait
  private var previewLayer: AVCaptureVideoPreviewLayer?
  private var closeButton: UIButton?
  private var shutterButton: UIButton?
  private var statusLabel: UILabel?
  private var captureResults: [[String: Any]] = []
  private var isSavingPhoto = false
  private var pendingEventID: String?

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black
    configureControls()
    requestCameraAndConfigure()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    controls.frame = view.bounds
    controls.layoutIfNeeded()
    previewLayer?.frame = controls.preview.bounds
    if let value = view.window?.windowScene?.interfaceOrientation,
      let rotation = AVCaptureVideoOrientation(rawValue: value.rawValue)
    {
      orientation = rotation
    }
    if let connection = previewLayer?.connection, connection.isVideoOrientationSupported {
      connection.videoOrientation = orientation
    }
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    focusReset?.cancel()
    sessionQueue.async { [weak self] in
      guard let self else { return }
      let shouldStop = self.lifecycle.requestStop()
      if shouldStop || self.captureSession.isRunning {
        self.captureSession.stopRunning()
      }
    }
  }

  private func requestCameraAndConfigure() {
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized:
      configureCaptureSession()
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
        if granted {
          self?.configureCaptureSession()
        } else {
          self?.report(CameraProbeError.permissionDenied)
        }
      }
    default:
      report(CameraProbeError.permissionDenied)
    }
  }

  private func configureCaptureSession() {
    sessionQueue.async { [weak self] in
      guard let self else { return }
      guard self.lifecycle.beginConfiguration() else { return }
      var configurationOpen = false
      do {
        self.captureSession.automaticallyConfiguresApplicationAudioSession = false
        self.captureSession.beginConfiguration()
        configurationOpen = true
        self.captureSession.sessionPreset = .photo
        let cameraTypes: [AVCaptureDevice.DeviceType] = [
          .builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera,
        ]
        guard
          let camera = cameraTypes.compactMap({
            AVCaptureDevice.default($0, for: .video, position: .back)
          }).first
        else {
          throw CameraProbeError.cameraUnavailable
        }
        let input = try AVCaptureDeviceInput(device: camera)
        guard self.captureSession.canAddInput(input),
          self.captureSession.canAddOutput(self.photoOutput)
        else {
          throw CameraProbeError.configurationFailed
        }

        // Keep camera capture video-only; RecordingRuntime exclusively owns the audio session.
        self.captureSession.addInput(input)
        self.captureSession.addOutput(self.photoOutput)
        self.camera = camera
        self.captureSession.commitConfiguration()
        configurationOpen = false
        self.lifecycle.markConfigurationCommitted()
        let multiplier: CGFloat
        if #available(iOS 18.0, *) {
          multiplier = camera.displayVideoZoomFactorMultiplier
        } else if camera.constituentDevices.first?.deviceType == .builtInUltraWideCamera,
          let wideSwitch = camera.virtualDeviceSwitchOverVideoZoomFactors.first
        {
          multiplier = 1 / CGFloat(truncating: wideSwitch)
        } else {
          multiplier = 1
        }
        self.zoomMultiplier = multiplier
        try camera.lockForConfiguration()
        camera.videoZoomFactor = min(
          max(1 / multiplier, camera.minAvailableVideoZoomFactor),
          camera.maxAvailableVideoZoomFactor)
        if camera.isFocusModeSupported(.continuousAutoFocus) {
          camera.focusMode = .continuousAutoFocus
        }
        if camera.isExposureModeSupported(.continuousAutoExposure) {
          camera.exposureMode = .continuousAutoExposure
        }
        camera.unlockForConfiguration()
        let minimumZoom = camera.minAvailableVideoZoomFactor * multiplier
        let maximumZoom = camera.maxAvailableVideoZoomFactor * multiplier
        let currentZoom = camera.videoZoomFactor * multiplier

        DispatchQueue.main.async { [weak self] in
          guard let self else { return }
          let layer = AVCaptureVideoPreviewLayer(session: self.captureSession)
          layer.videoGravity = .resizeAspect
          layer.frame = self.controls.preview.bounds
          self.controls.preview.layer.insertSublayer(layer, at: 0)
          self.previewLayer = layer
          self.minimumZoom = minimumZoom
          self.maximumZoom = maximumZoom
          self.currentZoom = currentZoom
          self.controls.configureZoom(minimum: minimumZoom, maximum: maximumZoom)
          self.controls.updateZoom(currentZoom)
          self.view.setNeedsLayout()
          self.sessionQueue.async { [weak self] in
            guard let self else { return }
            self.lifecycle.markPreviewAttached()
            guard self.lifecycle.consumeStartPermission() else { return }
            self.captureSession.startRunning()
            let minimum = camera.minAvailableVideoZoomFactor * multiplier
            let maximum = camera.maxAvailableVideoZoomFactor * multiplier
            let zoom = camera.videoZoomFactor * multiplier
            DispatchQueue.main.async { [weak self] in
              guard let self, self.viewIfLoaded?.window != nil else { return }
              self.minimumZoom = minimum
              self.maximumZoom = maximum
              self.currentZoom = zoom
              self.controls.configureZoom(minimum: minimum, maximum: maximum)
              self.controls.updateZoom(zoom)
              self.shutterButton?.isEnabled = true
            }
          }
        }
      } catch {
        if configurationOpen {
          self.captureSession.commitConfiguration()
        }
        self.lifecycle.markConfigurationFailed()
        self.report(error)
      }
    }
  }

  override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

  private func configureControls() {
    view.addSubview(controls)
    closeButton = controls.back
    shutterButton = controls.shutter
    statusLabel = controls.status
    updateStatus()
    controls.back.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
    controls.shutter.addTarget(self, action: #selector(shutterTapped), for: .touchUpInside)
    controls.onZoom = { [weak self] value in self?.setZoom(value) }
    controls.preview.onAccessibilityFocus = { [weak self] in
      guard let self else { return }
      self.focus(
        at: CGPoint(x: self.controls.preview.bounds.midX, y: self.controls.preview.bounds.midY))
    }
    let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinchZoom(_:)))
    controls.preview.addGestureRecognizer(pinch)
    let tap = UITapGestureRecognizer(target: self, action: #selector(focus(_:)))
    tap.require(toFail: pinch)
    controls.preview.addGestureRecognizer(tap)
  }

  private func configureDevice(_ change: @escaping (AVCaptureDevice) -> Void) {
    sessionQueue.async { [weak self] in
      guard let self, !self.lifecycle.stopRequested, let camera = self.camera else { return }
      do {
        try camera.lockForConfiguration()
        defer { camera.unlockForConfiguration() }
        change(camera)
      } catch {
        DispatchQueue.main.async { [weak self] in
          self?.statusLabel?.text = NativeStrings.text("camera_control_unavailable")
        }
      }
    }
  }

  private func setZoom(_ value: CGFloat) {
    guard !isSavingPhoto else {
      controls.updateZoom(currentZoom)
      return
    }
    focusReset?.cancel()
    currentZoom = min(max(value, minimumZoom), maximumZoom)
    controls.updateZoom(currentZoom)
    let requested = currentZoom
    configureDevice { [weak self] camera in
      guard let self else { return }
      camera.videoZoomFactor = min(
        max(requested / self.zoomMultiplier, camera.minAvailableVideoZoomFactor),
        camera.maxAvailableVideoZoomFactor)
      if camera.isFocusModeSupported(.continuousAutoFocus) {
        camera.focusMode = .continuousAutoFocus
      }
    }
  }

  @objc private func pinchZoom(_ gesture: UIPinchGestureRecognizer) {
    if gesture.state == .began { pinchStartZoom = currentZoom }
    if gesture.state == .began || gesture.state == .changed {
      setZoom(pinchStartZoom * gesture.scale)
    }
  }

  @objc private func focus(_ gesture: UITapGestureRecognizer) {
    focus(at: gesture.location(in: controls.preview))
  }

  private func focus(at position: CGPoint) {
    guard !isSavingPhoto, let layer = previewLayer else { return }
    let imageRect = layer.layerRectConverted(
      fromMetadataOutputRect: CGRect(x: 0, y: 0, width: 1, height: 1))
    guard imageRect.contains(position) else { return }
    let point = layer.captureDevicePointConverted(fromLayerPoint: position)
    controls.showFocus(at: position)
    configureDevice { camera in
      if camera.isFocusPointOfInterestSupported {
        camera.focusPointOfInterest = point
        if camera.isFocusModeSupported(.autoFocus) { camera.focusMode = .autoFocus }
      }
      if camera.isExposurePointOfInterestSupported {
        camera.exposurePointOfInterest = point
        if camera.isExposureModeSupported(.continuousAutoExposure) {
          camera.exposureMode = .continuousAutoExposure
        }
      }
    }
    focusReset?.cancel()
    let reset = DispatchWorkItem { [weak self] in
      self?.configureDevice { camera in
        if camera.isFocusModeSupported(.continuousAutoFocus) {
          camera.focusMode = .continuousAutoFocus
        }
      }
    }
    focusReset = reset
    DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: reset)
  }

  @objc private func closeTapped() {
    if isSavingPhoto {
      finishRequested = true
      statusLabel?.text = NativeStrings.text("camera_saving_before_return")
      return
    }
    if captureResults.isEmpty {
      delegate?.cameraProbeControllerDidCancel(self)
    } else {
      delegate?.cameraProbeController(self, didFinish: captureResults)
    }
    dismiss(animated: true)
  }

  @objc private func shutterTapped() {
    guard !isSavingPhoto else { return }
    isSavingPhoto = true
    shutterButton?.isEnabled = false
    statusLabel?.text = NativeStrings.text("camera_saving_photo")
    delegate?.cameraProbeController(
      self,
      preparePhotoCapture: { [weak self] result in
        DispatchQueue.main.async {
          guard let self else { return }
          switch result {
          case .success(let payload):
            guard let eventID = payload["eventId"] as? String, !eventID.isEmpty else {
              self.report(CameraProbeError.invalidAnchor)
              return
            }
            self.pendingEventID = eventID
            self.statusLabel?.text = NativeStrings.text("camera_saving_photo")
            let settings = AVCapturePhotoSettings()
            settings.flashMode = .off
            let rotation = self.orientation
            self.sessionQueue.async {
              if let connection = self.photoOutput.connection(with: .video),
                connection.isVideoOrientationSupported
              {
                connection.videoOrientation = rotation
              }
              self.photoOutput.capturePhoto(with: settings, delegate: self)
            }
          case .failure(let error):
            self.report(error)
          }
        }
      })
  }

  func photoOutput(
    _ output: AVCapturePhotoOutput,
    didFinishProcessingPhoto photo: AVCapturePhoto,
    error: Error?
  ) {
    // Photo callbacks may arrive on an AVFoundation queue; the capture ticket and UI are main-thread owned.
    guard Thread.isMainThread else {
      DispatchQueue.main.async {
        self.photoOutput(output, didFinishProcessingPhoto: photo, error: error)
      }
      return
    }
    if let error {
      failPendingCapture(error)
      return
    }
    guard let data = photo.fileDataRepresentation() else {
      failPendingCapture(CameraProbeError.encodingFailed)
      return
    }
    guard let eventID = pendingEventID else {
      report(CameraProbeError.invalidAnchor)
      return
    }
    delegate?.cameraProbeController(self, didCapture: data, eventID: eventID) {
      [weak self] result in
      DispatchQueue.main.async {
        guard let self else { return }
        self.isSavingPhoto = false
        switch result {
        case .success(let payload):
          self.pendingEventID = nil
          self.captureResults.append(payload)
          self.updateStatus()
          self.closeButton?.isEnabled = true
          self.shutterButton?.isEnabled = true
          if self.finishRequested { self.closeTapped() }
        case .failure(let error):
          self.failPendingCapture(error)
        }
      }
    }
  }

  private func failPendingCapture(_ error: Error) {
    guard let eventID = pendingEventID else {
      report(error)
      return
    }
    pendingEventID = nil
    delegate?.cameraProbeController(self, didFailCapture: eventID, error: error) { [weak self] in
      self?.report(error)
    }
  }

  static func recordingStatusKey(_ state: String) -> String {
    switch state {
    case "recording": return "camera_recording_continues"
    case "paused": return "camera_recording_paused"
    default: return "camera_recording_check"
    }
  }

  private func updateStatus() {
    let audio = NativeStrings.text(Self.recordingStatusKey(recordingState))
    statusLabel?.text =
      audio + "\n" + NativeStrings.text("camera_saved_count", String(captureResults.count))
  }

  private func report(_ error: Error) {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.delegate?.cameraProbeController(self, didFail: error)
      self.dismiss(animated: true)
    }
  }
}

enum CameraProbeError: LocalizedError {
  case permissionDenied
  case cameraUnavailable
  case configurationFailed
  case encodingFailed
  case invalidAnchor

  var errorDescription: String? {
    switch self {
    case .permissionDenied: return "Camera permission was not granted. Recording continues."
    case .cameraUnavailable: return "No back camera is available."
    case .configurationFailed: return "The video-only camera session could not be configured."
    case .encodingFailed: return "The captured photo could not be encoded."
    case .invalidAnchor: return "The photo clock anchor could not be created."
    }
  }
}
