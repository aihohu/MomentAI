import UIKit

/// Equal zoom ratios use equal travel, preserving precision across a wide device range.
struct CameraZoomScale {
  let minimum: CGFloat
  let maximum: CGFloat
  var span: CGFloat { log2(maximum / minimum) }

  init(minimum: CGFloat, maximum: CGFloat) {
    precondition(minimum.isFinite && maximum.isFinite && minimum > 0 && maximum >= minimum)
    self.minimum = minimum
    self.maximum = maximum
  }

  func position(_ value: CGFloat) -> CGFloat {
    log2(min(max(value, minimum), maximum) / minimum)
  }

  func fraction(_ value: CGFloat) -> CGFloat {
    span > 0 ? position(value) / span : 0
  }

  func factorAtFraction(_ fraction: CGFloat) -> CGFloat {
    factor(min(max(fraction, 0), 1) * span)
  }

  func factor(_ position: CGFloat) -> CGFloat {
    if position <= 0 { return minimum }
    if position >= span { return maximum }
    return min(max(minimum * pow(2, position), minimum), maximum)
  }
}

/// The complete device range stays visible and is reachable in a single drag.
final class CameraZoomDial: UIView {
  private var scale = CameraZoomScale(minimum: 1, maximum: 1)
  private(set) var value: CGFloat = 1
  var onValueChanged: ((CGFloat) -> Void)?

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .black
    isAccessibilityElement = true
    accessibilityTraits = .adjustable
    accessibilityLabel = NativeStrings.text("camera_zoom")
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func configure(minimum: CGFloat, maximum: CGFloat) {
    scale = CameraZoomScale(minimum: minimum, maximum: maximum)
    isUserInteractionEnabled = maximum > minimum
    updateValue(value)
  }

  func updateValue(_ factor: CGFloat) {
    value = min(max(factor, scale.minimum), scale.maximum)
    accessibilityValue = label(value)
    setNeedsDisplay()
  }

  private var trackStart: CGFloat { min(28, bounds.width / 2) }
  private var trackWidth: CGFloat { max(1, bounds.width - 2 * trackStart) }

  override func draw(_ rect: CGRect) {
    drawLabel(label(value), x: bounds.midX, y: 2, size: 19, color: .white, bold: true)
    let count = max(1, Int(trackWidth / 12))
    for tick in 0...count {
      let x = trackStart + CGFloat(tick) / CGFloat(count) * trackWidth
      line(x: x, top: 38, bottom: 50, color: .darkGray)
    }
    var lastLabelX = trackStart
    let first = Int(ceil(log2(scale.minimum)))
    let last = Int(floor(log2(scale.maximum)))
    if first <= last {
      for exponent in first...last {
        let factor = pow(2, CGFloat(exponent))
        let x = trackStart + scale.fraction(factor) * trackWidth
        if x - lastLabelX >= 48 && trackStart + trackWidth - x >= 48 {
          line(x: x, top: 34, bottom: 56, color: .lightGray)
          drawLabel(label(factor), x: x, y: 63)
          lastLabelX = x
        }
      }
    }
    line(x: trackStart, top: 34, bottom: 56, color: .lightGray)
    drawLabel(label(scale.minimum), x: trackStart, y: 63)
    if scale.maximum > scale.minimum {
      line(x: trackStart + trackWidth, top: 34, bottom: 56, color: .lightGray)
      drawLabel(label(scale.maximum), x: trackStart + trackWidth, y: 63)
    }
    let pointer = trackStart + scale.fraction(value) * trackWidth
    UIColor.white.setFill()
    UIBezierPath(roundedRect: CGRect(x: pointer - 5, y: 29, width: 10, height: 31), cornerRadius: 5)
      .fill()
  }

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
    if let touch = touches.first { selectZoom(at: touch.location(in: self).x) }
  }

  override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
    if let touch = touches.first { selectZoom(at: touch.location(in: self).x) }
  }

  func selectZoom(at x: CGFloat) {
    updateValue(scale.factorAtFraction((x - trackStart) / trackWidth))
    onValueChanged?(value)
  }

  override func accessibilityIncrement() { changePosition(scale.position(value) + 0.125) }
  override func accessibilityDecrement() { changePosition(scale.position(value) - 0.125) }

  private func changePosition(_ position: CGFloat) {
    updateValue(scale.factor(position))
    onValueChanged?(value)
  }

  private func label(_ factor: CGFloat) -> String {
    String(format: abs(factor.rounded() - factor) < 0.01 ? "%.0f×" : "%.1f×", Double(factor))
  }

  private func line(x: CGFloat, top: CGFloat, bottom: CGFloat, color: UIColor, width: CGFloat = 1) {
    color.setStroke()
    let path = UIBezierPath()
    path.lineWidth = width
    path.move(to: CGPoint(x: x, y: top))
    path.addLine(to: CGPoint(x: x, y: bottom))
    path.stroke()
  }

  private func drawLabel(
    _ text: String, x: CGFloat, y: CGFloat, size: CGFloat = 12,
    color: UIColor = .lightGray, bold: Bool = false
  ) {
    let attributes: [NSAttributedString.Key: Any] = [
      .font: UIFont.monospacedDigitSystemFont(ofSize: size, weight: bold ? .semibold : .regular),
      .foregroundColor: color,
    ]
    let width = (text as NSString).size(withAttributes: attributes).width
    (text as NSString).draw(at: CGPoint(x: x - width / 2, y: y), withAttributes: attributes)
  }
}
