import UIKit

final class CameraPreviewView: UIView {
  var onAccessibilityFocus: (() -> Void)?
  override func accessibilityActivate() -> Bool {
    onAccessibilityFocus?()
    return true
  }
}

/// Shared camera layout conventions: explicit return action, fitted preview, and reachable controls.
final class CameraControlsView: UIView {
  let preview = CameraPreviewView()
  let back = UIButton(type: .system)
  let shutter = UIButton(type: .custom)
  let status = UILabel()
  let zoomDial = CameraZoomDial()
  private let panel = UIStackView()
  private let focusRing = UIView()
  private var focusHide: DispatchWorkItem?
  var onZoom: ((CGFloat) -> Void)?

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .black
    preview.clipsToBounds = true
    preview.isAccessibilityElement = true
    preview.accessibilityTraits = .button
    preview.accessibilityLabel = NativeStrings.text("camera_preview_focus")
    addSubview(preview)
    styleButton(back, title: NativeStrings.text("camera_back_to_recording"))
    back.setImage(UIImage(systemName: "chevron.backward"), for: .normal)
    back.tintColor = .white
    back.contentEdgeInsets = UIEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
    back.imageEdgeInsets = UIEdgeInsets(top: 0, left: -4, bottom: 0, right: 4)
    addSubview(back)
    status.textColor = .white
    status.font = .preferredFont(forTextStyle: .footnote)
    status.adjustsFontForContentSizeCategory = true
    status.textAlignment = .right
    status.numberOfLines = 2
    addSubview(status)

    panel.axis = .vertical
    panel.alignment = .center
    panel.spacing = 6
    addSubview(panel)
    zoomDial.onValueChanged = { [weak self] value in self?.onZoom?(value) }
    panel.addArrangedSubview(zoomDial)
    zoomDial.widthAnchor.constraint(equalTo: panel.widthAnchor).isActive = true
    zoomDial.heightAnchor.constraint(equalToConstant: 84).isActive = true
    shutter.backgroundColor = .white
    shutter.layer.cornerRadius = 38
    shutter.clipsToBounds = true
    shutter.layer.borderWidth = 4
    shutter.layer.borderColor = UIColor.lightGray.cgColor
    shutter.accessibilityLabel = NativeStrings.text("camera_take_photo")
    shutter.isEnabled = false
    panel.addArrangedSubview(shutter)
    shutter.widthAnchor.constraint(equalToConstant: 76).isActive = true
    shutter.heightAnchor.constraint(equalToConstant: 76).isActive = true

    focusRing.layer.borderColor = UIColor.systemYellow.cgColor
    focusRing.layer.borderWidth = 2
    focusRing.layer.cornerRadius = 8
    focusRing.isUserInteractionEnabled = false
    focusRing.isHidden = true
    preview.addSubview(focusRing)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func layoutSubviews() {
    super.layoutSubviews()
    let safe = bounds.inset(by: safeAreaInsets)
    let backWidth = min(max(148, back.intrinsicContentSize.width), safe.width * 0.55)
    back.frame = CGRect(x: safe.minX + 12, y: safe.minY + 6, width: backWidth, height: 52)
    status.frame = CGRect(
      x: back.frame.maxX + 12, y: back.frame.minY,
      width: max(0, safe.maxX - back.frame.maxX - 24), height: 52)
    let available = CGRect(
      x: safe.minX, y: safe.minY + 68, width: safe.width, height: max(0, safe.height - 68))
    if bounds.width > bounds.height {
      panel.frame = CGRect(x: available.maxX - 272, y: available.midY - 86, width: 260, height: 172)
      preview.frame = CGRect(
        x: available.minX, y: available.minY, width: max(0, available.width - 284),
        height: available.height)
    } else {
      panel.frame = CGRect(
        x: safe.minX + 12, y: safe.maxY - 172, width: safe.width - 24, height: 172)
      preview.frame = CGRect(
        x: available.minX, y: available.minY, width: available.width,
        height: max(0, available.height - 176))
    }
  }

  func configureZoom(minimum: CGFloat, maximum: CGFloat) {
    zoomDial.configure(minimum: minimum, maximum: maximum)
  }

  func updateZoom(_ factor: CGFloat) { zoomDial.updateValue(factor) }

  func showFocus(at point: CGPoint) {
    focusHide?.cancel()
    focusRing.frame = CGRect(
      x: min(max(0, point.x - 32), max(0, preview.bounds.width - 64)),
      y: min(max(0, point.y - 32), max(0, preview.bounds.height - 64)), width: 64, height: 64)
    focusRing.isHidden = false
    preview.bringSubviewToFront(focusRing)
    let hide = DispatchWorkItem { [weak self] in self?.focusRing.isHidden = true }
    focusHide = hide
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: hide)
  }

  private func styleButton(_ button: UIButton, title: String) {
    button.setTitle(title, for: .normal)
    button.setTitleColor(.white, for: .normal)
    button.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
    button.backgroundColor = UIColor(white: 0.19, alpha: 1)
    button.layer.cornerRadius = 24
  }

}
