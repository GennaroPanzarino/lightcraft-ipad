import SwiftUI
import UIKit

// The develop controls are UIKit views drawn with layers: a finger moves them at the display's rate
// (120 Hz on a ProMotion iPad) and SwiftUI draws nothing while it does. Each one must fail before the
// panel's scroll view may begin, and fails at once on a vertical move: a horizontal drag adjusts, a
// vertical one scrolls.

/// A gesture in one of the controls wins over the scroll view around it.
private func winsOverScroll(_ other: UIGestureRecognizer) -> Bool {
    other.view is UIScrollView && other is UIPanGestureRecognizer
}

// MARK: - Slider

/// Capture One's slider on one row: the name, a fine track, the value in a field. Drag anywhere on
/// the row (relative: the value never jumps under the finger); move the finger up or down away from
/// the row while dragging for finer steps; double tap to go back to the default; tap the value to
/// type one. A light tick is felt where the default is.
final class ToolSlider: UIView, UIGestureRecognizerDelegate, UITextFieldDelegate {
    var control: Control? {
        didSet { if control?.id != oldValue?.id { configure() } }
    }
    var labelOverride: String? {
        didSet { label.text = labelOverride ?? control?.label }
    }
    var onChange: ((Double) -> Void)?
    var onBegin: (() -> Void)?
    var onEnd: (() -> Void)?
    var enabled = true {
        didSet { alpha = enabled ? 1 : 0.4; isUserInteractionEnabled = enabled }
    }
    private(set) var value: Double = 0

    private let label = UILabel()
    private let field = UITextField()
    private let trackLayer = CALayer()
    private let gradientLayer = CAGradientLayer()
    private let fillLayer = CALayer()
    private let zeroLayer = CALayer()
    private let knobLayer = CALayer()
    private var pan: UIPanGestureRecognizer!
    private var dragging = false
    private var raw: Double = 0
    private var lastX: CGFloat = 0
    private let ticker = UISelectionFeedbackGenerator()

    static let height: CGFloat = 30
    private let labelWidth: CGFloat = 92
    private let fieldWidth: CGFloat = 48

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        label.font = UTypo.label
        label.textColor = Ux.text2
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        field.font = UTypo.value
        field.textColor = Ux.text
        field.textAlignment = .right
        field.backgroundColor = Ux.field
        field.layer.cornerRadius = 3
        field.layer.borderWidth = 0.5
        field.layer.borderColor = Ux.hairline.cgColor
        field.keyboardType = .numbersAndPunctuation
        field.returnKeyType = .done
        field.delegate = self
        field.rightView = UIView(frame: CGRect(x: 0, y: 0, width: 6, height: 10))
        field.rightViewMode = .always
        addSubview(field)
        for l in [trackLayer, gradientLayer, fillLayer, zeroLayer, knobLayer] { layer.addSublayer(l) }
        trackLayer.backgroundColor = Ux.track.cgColor
        trackLayer.cornerRadius = 1
        gradientLayer.startPoint = CGPoint(x: 0, y: 0.5)
        gradientLayer.endPoint = CGPoint(x: 1, y: 0.5)
        gradientLayer.cornerRadius = 1.5
        fillLayer.backgroundColor = Ux.fill.cgColor
        zeroLayer.backgroundColor = UIColor(white: 1, alpha: 0.35).cgColor
        knobLayer.backgroundColor = Ux.knob.cgColor
        knobLayer.shadowColor = UIColor.black.cgColor
        knobLayer.shadowOpacity = 0.5
        knobLayer.shadowRadius = 1.5
        knobLayer.shadowOffset = CGSize(width: 0, height: 0.5)

        pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.delegate = self
        addGestureRecognizer(pan)
        let reset = UITapGestureRecognizer(target: self, action: #selector(resetTapped))
        reset.numberOfTapsRequired = 2
        reset.delegate = self
        reset.delaysTouchesEnded = false
        addGestureRecognizer(reset)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: Self.height) }

    private func configure() {
        guard let c = control else { return }
        label.text = labelOverride ?? c.label
        if case .gradient(let colors) = c.track {
            gradientLayer.colors = colors.map(\.cgColor)
            gradientLayer.isHidden = false
            trackLayer.isHidden = true
        } else {
            gradientLayer.isHidden = true
            trackLayer.isHidden = false
        }
        setValue(value)
    }

    /// A value from elsewhere (the engine, another control): shown unless a finger is on it.
    func setValue(_ v: Double) {
        guard !dragging else { return }
        value = v
        raw = v
        if !field.isFirstResponder { field.text = control?.format(v) }
        label.textColor = changed ? Ux.text : Ux.text2
        layoutTrack()
    }

    private var changed: Bool {
        guard let c = control else { return false }
        return abs(value - c.def) > c.step / 2
    }

    private var trackRect: CGRect {
        let x0 = labelWidth + 8
        let x1 = bounds.width - fieldWidth - 12
        return CGRect(x: x0, y: bounds.midY - 1, width: max(20, x1 - x0), height: 2)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = CGRect(x: 0, y: 0, width: labelWidth, height: bounds.height)
        field.frame = CGRect(x: bounds.width - fieldWidth, y: (bounds.height - 21) / 2, width: fieldWidth, height: 21)
        layoutTrack()
    }

    private func layoutTrack() {
        guard let c = control else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let r = trackRect
        trackLayer.frame = r
        gradientLayer.frame = r.insetBy(dx: 0, dy: -0.5)
        let range = max(c.max - c.min, 1e-9)
        let f = CGFloat(max(0, min(1, (value - c.min) / range)))
        let zero = CGFloat(max(0, min(1, (0 - c.min) / range)))
        let x = r.minX + f * r.width
        if case .gradient = c.track {
            fillLayer.isHidden = true
        } else {
            fillLayer.isHidden = false
            let from = c.centered ? r.minX + zero * r.width : r.minX
            fillLayer.frame = CGRect(x: min(from, x), y: r.minY, width: abs(x - from), height: r.height)
        }
        zeroLayer.isHidden = !c.centered
        zeroLayer.frame = CGRect(x: r.minX + zero * r.width - 0.5, y: r.midY - 4, width: 1, height: 8)
        let d: CGFloat = dragging ? 16 : 12
        knobLayer.frame = CGRect(x: x - d / 2, y: r.midY - d / 2, width: d, height: d)
        knobLayer.cornerRadius = d / 2
        knobLayer.backgroundColor = (dragging ? UIColor.white : Ux.knob).cgColor
        CATransaction.commit()
    }

    // MARK: gestures

    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        if g === pan {
            let v = pan.velocity(in: self)
            return abs(v.x) > abs(v.y)
        }
        return true
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        g === pan && winsOverScroll(other)
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        touch.view !== field && !field.isFirstResponder
    }

    @objc private func panned(_ g: UIPanGestureRecognizer) {
        guard let c = control else { return }
        let p = g.location(in: self)
        switch g.state {
        case .began:
            dragging = true
            raw = value
            lastX = p.x
            ticker.prepare()
            onBegin?()
            layoutTrack()
        case .changed:
            // fine control: the farther the finger from the row, the smaller the steps
            let away = max(0, abs(p.y - bounds.midY) - bounds.height)
            let factor = 1 / (1 + Double(away) / 60)
            let dx = Double(p.x - lastX)
            lastX = p.x
            let before = raw
            raw = min(c.max, max(c.min, raw + dx / Double(max(trackRect.width, 1)) * (c.max - c.min) * factor))
            let v = c.snap(raw)
            if before != raw && (before - c.def) * (raw - c.def) <= 0 { ticker.selectionChanged() }
            if v != value {
                value = v
                field.text = c.format(v)
                label.textColor = changed ? Ux.text : Ux.text2
                layoutTrack()
                onChange?(v)
            }
        default:
            dragging = false
            layoutTrack()
            onEnd?()
        }
    }

    @objc private func resetTapped() {
        guard let c = control, enabled else { return }
        Haptics.confirm()
        onBegin?()
        value = c.def
        raw = c.def
        field.text = c.format(c.def)
        label.textColor = Ux.text2
        layoutTrack()
        onChange?(c.def)
        onEnd?()
    }

    // MARK: typing a value

    func textFieldShouldReturn(_ t: UITextField) -> Bool {
        t.resignFirstResponder()
        return true
    }

    func textFieldDidBeginEditing(_ t: UITextField) {
        t.text = t.text?.replacingOccurrences(of: "+", with: "")
        t.selectAll(nil)
    }

    func textFieldDidEndEditing(_ t: UITextField) {
        guard let c = control else { return }
        let s = (t.text ?? "").replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: "+", with: "").trimmingCharacters(in: .whitespaces)
        guard let typed = Double(s) else {
            t.text = c.format(value)
            return
        }
        let v = c.snap(typed)
        onBegin?()
        value = v
        raw = v
        t.text = c.format(v)
        layoutTrack()
        onChange?(v)
        onEnd?()
    }
}

/// A slider of the store's photo, by control id.
struct SliderRow: UIViewRepresentable {
    let store: DevelopStore
    let id: String
    var label: String? = nil

    func makeUIView(context: Context) -> ToolSlider {
        let s = ToolSlider()
        bind(s)
        return s
    }

    func updateUIView(_ s: ToolSlider, context: Context) {
        if s.control?.id != id { bind(s) }
        if s.labelOverride != label { s.labelOverride = label }
    }

    private func bind(_ s: ToolSlider) {
        s.control = store.control(id)
        s.labelOverride = label
        let store = self.store
        let id = self.id
        store.observe([id], owner: s) { [weak s] _, v in
            s?.enabled = store.enabled
            s?.setValue(v)
        }
        s.onBegin = { store.onBegin?(store.control(id)?.label ?? id) }
        s.onChange = { [weak s] v in store.userSet(id, v, from: s) }
        s.onEnd = { store.onEnd?() }
    }
}

/// Sliders, one per row.
struct Sliders: View {
    let store: DevelopStore
    let ids: [String]
    var labels: [String: String] = [:]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(ids, id: \.self) { id in
                if store.control(id) != nil {
                    SliderRow(store: store, id: id, label: labels[id])
                        .frame(height: ToolSlider.height)
                }
            }
        }
    }
}

// MARK: - Colour wheel

/// A colour balance wheel: the angle is the hue, the distance from the middle the saturation. Drag
/// the puck (from where it is when the touch lands near it), double tap to take the colour out.
final class WheelView: UIView, UIGestureRecognizerDelegate {
    private(set) var hue: Double = 0
    private(set) var sat: Double = 0
    var onChange: ((Double, Double) -> Void)?
    var onBegin: (() -> Void)?
    var onEnd: (() -> Void)?

    private let ring = CAGradientLayer()
    private let fade = CAGradientLayer()
    private let ringMask = CAShapeLayer()
    private let rim = CAShapeLayer()
    private let cross = CAShapeLayer()
    private let puck = CALayer()
    private var dragging = false
    private var grab = CGPoint.zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        ring.type = .conic
        ring.startPoint = CGPoint(x: 0.5, y: 0.5)
        ring.endPoint = CGPoint(x: 1, y: 0.5)
        // conic gradients turn clockwise on screen: hues go anticlockwise, as the angle does
        ring.colors = stride(from: 360.0, through: 0.0, by: -30.0).map { UIColor(hue: CGFloat($0.truncatingRemainder(dividingBy: 360) / 360), saturation: 0.85, brightness: 0.9, alpha: 1).cgColor }
        ring.mask = ringMask
        layer.addSublayer(ring)
        fade.type = .radial
        fade.startPoint = CGPoint(x: 0.5, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 1)
        fade.colors = [UIColor(white: 0.62, alpha: 1).cgColor, UIColor(white: 0.62, alpha: 0).cgColor]
        layer.addSublayer(fade)
        rim.fillColor = UIColor.clear.cgColor
        rim.strokeColor = UIColor(white: 0, alpha: 0.6).cgColor
        rim.lineWidth = 1
        layer.addSublayer(rim)
        cross.strokeColor = UIColor(white: 0, alpha: 0.35).cgColor
        cross.lineWidth = 0.5
        layer.addSublayer(cross)
        puck.borderColor = UIColor.white.cgColor
        puck.borderWidth = 2
        puck.shadowColor = UIColor.black.cgColor
        puck.shadowOpacity = 0.6
        puck.shadowRadius = 2
        puck.shadowOffset = .zero
        layer.addSublayer(puck)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.delegate = self
        addGestureRecognizer(pan)
        let reset = UITapGestureRecognizer(target: self, action: #selector(resetTapped))
        reset.numberOfTapsRequired = 2
        addGestureRecognizer(reset)
    }

    required init?(coder: NSCoder) { fatalError() }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        winsOverScroll(other)
    }

    private var radius: CGFloat { max(4, min(bounds.width, bounds.height) / 2 - 2) }
    private var middle: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let r = radius
        let box = CGRect(x: middle.x - r, y: middle.y - r, width: 2 * r, height: 2 * r)
        ring.frame = bounds
        ringMask.path = UIBezierPath(ovalIn: box).cgPath
        fade.frame = box
        fade.cornerRadius = r
        rim.path = UIBezierPath(ovalIn: box).cgPath
        let c = UIBezierPath()
        c.move(to: CGPoint(x: box.minX, y: box.midY)); c.addLine(to: CGPoint(x: box.maxX, y: box.midY))
        c.move(to: CGPoint(x: box.midX, y: box.minY)); c.addLine(to: CGPoint(x: box.midX, y: box.maxY))
        cross.path = c.cgPath
        CATransaction.commit()
        place()
    }

    func set(hue: Double, sat: Double) {
        guard !dragging else { return }
        self.hue = hue
        self.sat = sat
        place()
    }

    private func puckPoint() -> CGPoint {
        let a = CGFloat(hue) * .pi / 180
        let d = CGFloat(min(1, max(0, sat / 100))) * radius
        return CGPoint(x: middle.x + cos(a) * d, y: middle.y - sin(a) * d)
    }

    private func place() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let p = puckPoint()
        let s: CGFloat = dragging ? 20 : 15
        puck.frame = CGRect(x: p.x - s / 2, y: p.y - s / 2, width: s, height: s)
        puck.cornerRadius = s / 2
        puck.backgroundColor = UIColor(hue: CGFloat(hue / 360), saturation: CGFloat(min(1, sat / 100)), brightness: 0.95, alpha: 1).cgColor
        CATransaction.commit()
    }

    @objc private func panned(_ g: UIPanGestureRecognizer) {
        let p = g.location(in: self)
        switch g.state {
        case .began:
            dragging = true
            onBegin?()
            let at = puckPoint()
            grab = hypot(p.x - at.x, p.y - at.y) < 30 ? CGPoint(x: at.x - p.x, y: at.y - p.y) : .zero
            move(to: p)
        case .changed:
            move(to: p)
        default:
            dragging = false
            place()
            onEnd?()
        }
    }

    private func move(to p: CGPoint) {
        let q = CGPoint(x: p.x + grab.x - middle.x, y: middle.y - (p.y + grab.y))
        let d = min(1, hypot(q.x, q.y) / radius)
        var h = atan2(q.y, q.x) * 180 / .pi
        if h < 0 { h += 360 }
        hue = Double(h).rounded().truncatingRemainder(dividingBy: 360)
        sat = (Double(d) * 100).rounded()
        place()
        onChange?(hue, sat)
    }

    @objc private func resetTapped() {
        Haptics.confirm()
        onBegin?()
        sat = 0
        place()
        onChange?(hue, 0)
        onEnd?()
    }
}

/// A wheel of the store's photo (`grading.<zone>.hue` / `.sat`).
struct WheelRow: UIViewRepresentable {
    let store: DevelopStore
    let zone: Zone

    func makeUIView(context: Context) -> WheelView {
        let w = WheelView()
        bind(w)
        context.coordinator.zone = zone
        return w
    }

    func updateUIView(_ w: WheelView, context: Context) {
        if context.coordinator.zone != zone {
            bind(w)
            context.coordinator.zone = zone
        }
    }

    func makeCoordinator() -> Bound { Bound() }

    final class Bound { var zone: Zone? }

    private func bind(_ w: WheelView) {
        let hueId = "grading.\(zone.rawValue).hue", satId = "grading.\(zone.rawValue).sat"
        let store = self.store
        store.forget(w)
        store.observe([hueId, satId], owner: w) { [weak w] _, _ in
            w?.set(hue: store.value(hueId), sat: store.value(satId))
            w?.isUserInteractionEnabled = store.enabled
        }
        w.onBegin = { store.onBegin?("Bilanciamento colore") }
        w.onChange = { [weak w] h, s in
            store.userSet(hueId, h, from: w)
            store.userSet(satId, s, from: w)
        }
        w.onEnd = { store.onEnd?() }
    }
}

// MARK: - Histogram

/// The RGB histogram of a picture (normalised to its tallest bars, the extremes clipped).
struct Histogram {
    let r: [CGFloat]
    let g: [CGFloat]
    let b: [CGFloat]
    /// Shares of pixels clipped to black / white.
    let lowClip: Double
    let highClip: Double

    static func of(_ image: CGImage) -> Histogram? {
        let w = 256, h = max(1, 256 * image.height / max(1, image.width))
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = px.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        var hr = [Int](repeating: 0, count: 256), hg = hr, hb = hr
        var lo = 0, hi = 0
        var i = 0
        while i < px.count {
            let r = Int(px[i]), g = Int(px[i + 1]), b = Int(px[i + 2])
            hr[r] += 1
            hg[g] += 1
            hb[b] += 1
            if r <= 1 && g <= 1 && b <= 1 { lo += 1 }
            if r >= 254 || g >= 254 || b >= 254 { hi += 1 }
            i += 4
        }
        var all = Array(hr[2..<254])
        all.append(contentsOf: hg[2..<254])
        all.append(contentsOf: hb[2..<254])
        all.sort()
        let cap = CGFloat(max(1, all[min(all.count - 1, Int(Double(all.count) * 0.995))]))
        func norm(_ a: [Int]) -> [CGFloat] { a.map { min(1, CGFloat($0) / cap) } }
        let n = Double(max(1, w * h))
        return Histogram(r: norm(hr), g: norm(hg), b: norm(hb), lowClip: Double(lo) / n, highClip: Double(hi) / n)
    }
}

/// The histogram drawn as Capture One draws it: the three channels added up.
final class HistogramUIView: UIView {
    var histogram: Histogram? {
        didSet { setNeedsDisplay() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        contentMode = .redraw
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.setFillColor(UIColor(hex: 0x0E0E10).cgColor)
        ctx.fill(bounds)
        ctx.setStrokeColor(UIColor(white: 1, alpha: 0.06).cgColor)
        ctx.setLineWidth(0.5)
        for k in 1..<4 {
            let x = bounds.width * CGFloat(k) / 4
            ctx.move(to: CGPoint(x: x, y: 0))
            ctx.addLine(to: CGPoint(x: x, y: bounds.height))
        }
        ctx.strokePath()
        guard let h = histogram else { return }
        ctx.setBlendMode(.screen)
        for (a, c) in [(h.r, UIColor(hex: 0xD8414A)), (h.g, UIColor(hex: 0x3FAE5A)), (h.b, UIColor(hex: 0x3E6FE0))] {
            let p = UIBezierPath()
            p.move(to: CGPoint(x: 0, y: bounds.height))
            for i in 0..<256 { p.addLine(to: CGPoint(x: CGFloat(i) / 255 * bounds.width, y: bounds.height - a[i] * bounds.height * 0.94)) }
            p.addLine(to: CGPoint(x: bounds.width, y: bounds.height))
            p.close()
            ctx.setFillColor(c.withAlphaComponent(0.9).cgColor)
            ctx.addPath(p.cgPath)
            ctx.fillPath()
        }
        ctx.setBlendMode(.normal)
    }
}

// MARK: - Curve

/// The point curve: drag a point to move it, touch the line to add one, drag a point out of the box
/// to take it away; the histogram behind it.
final class CurveUIView: UIView, UIGestureRecognizerDelegate {
    var points: CurvePoints = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)] {
        didSet { if working == nil { redraw() } }
    }
    var color: UIColor = UIColor(hex: 0xE6E6E9) {
        didSet { redraw() }
    }
    var histogram: Histogram? {
        didSet { histoView.histogram = histogram }
    }
    var onChange: ((CurvePoints) -> Void)?
    var onBegin: (() -> Void)?
    var onEnd: (() -> Void)?

    private let histoView = HistogramUIView()
    private let grid = CAShapeLayer()
    private let diagonal = CAShapeLayer()
    private let line = CAShapeLayer()
    private let dots = CAShapeLayer()
    private let activeDot = CAShapeLayer()
    private var working: CurvePoints?
    private var active = -1
    private var dragging = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        histoView.alpha = 0.55
        histoView.isUserInteractionEnabled = false
        addSubview(histoView)
        for l in [grid, diagonal, line, dots, activeDot] { layer.addSublayer(l) }
        grid.strokeColor = UIColor(white: 1, alpha: 0.08).cgColor
        grid.lineWidth = 0.5
        diagonal.strokeColor = UIColor(white: 1, alpha: 0.14).cgColor
        diagonal.lineWidth = 0.5
        line.fillColor = UIColor.clear.cgColor
        line.lineWidth = 1.5
        dots.fillColor = UIColor.white.cgColor
        dots.strokeColor = UIColor.black.cgColor
        dots.lineWidth = 1
        activeDot.fillColor = Ux.accent.cgColor
        activeDot.strokeColor = UIColor.black.cgColor
        activeDot.lineWidth = 1
        layer.borderColor = UIColor(white: 1, alpha: 0.08).cgColor
        layer.borderWidth = 0.5
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.delegate = self
        addGestureRecognizer(pan)
        let press = UILongPressGestureRecognizer(target: self, action: #selector(pressed(_:)))
        press.minimumPressDuration = 0
        press.delegate = self
        addGestureRecognizer(press)
    }

    required init?(coder: NSCoder) { fatalError() }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        winsOverScroll(other)
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        other.view === self
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        histoView.frame = bounds
        redraw()
    }

    private func pt(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * bounds.width, y: (1 - p.y) * bounds.height) }

    private func redraw() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let w = bounds.width, h = bounds.height
        let g = UIBezierPath()
        for k in 1..<4 {
            g.move(to: CGPoint(x: w * CGFloat(k) / 4, y: 0)); g.addLine(to: CGPoint(x: w * CGFloat(k) / 4, y: h))
            g.move(to: CGPoint(x: 0, y: h * CGFloat(k) / 4)); g.addLine(to: CGPoint(x: w, y: h * CGFloat(k) / 4))
        }
        grid.path = g.cgPath
        let d = UIBezierPath()
        d.move(to: CGPoint(x: 0, y: h)); d.addLine(to: CGPoint(x: w, y: 0))
        diagonal.path = d.cgPath
        let shown = working ?? points
        let c = UIBezierPath()
        for s in 0...96 {
            let x = CGFloat(s) / 96
            let y = max(0, min(1, curveAt(shown, x)))
            let p = CGPoint(x: x * w, y: (1 - y) * h)
            if s == 0 { c.move(to: p) } else { c.addLine(to: p) }
        }
        line.path = c.cgPath
        line.strokeColor = color.cgColor
        let dp = UIBezierPath()
        let ap = UIBezierPath()
        for (i, p) in shown.enumerated() {
            let q = pt(p)
            if i == active {
                ap.append(UIBezierPath(ovalIn: CGRect(x: q.x - 7, y: q.y - 7, width: 14, height: 14)))
            } else {
                dp.append(UIBezierPath(ovalIn: CGRect(x: q.x - 4.5, y: q.y - 4.5, width: 9, height: 9)))
            }
        }
        dots.path = dp.cgPath
        activeDot.path = ap.cgPath
        CATransaction.commit()
    }

    private func nearest(_ o: CGPoint, in pts: CurvePoints) -> Int {
        var best = -1
        var bd: CGFloat = 30
        for (i, p) in pts.enumerated() {
            let q = pt(p)
            let d = hypot(q.x - o.x, q.y - o.y)
            if d < bd { bd = d; best = i }
        }
        return best
    }

    @objc private func pressed(_ g: UILongPressGestureRecognizer) {
        // a touch picks the point under it (or adds one on the line) before any drag
        if g.state == .ended || g.state == .cancelled {
            if !dragging && working != nil { finish() }
            return
        }
        guard g.state == .began, working == nil else { return }
        let o = g.location(in: self)
        var list = points
        var i = nearest(o, in: list)
        if i < 0 {
            let x = max(0.01, min(0.99, o.x / bounds.width))
            let y = max(0, min(1, 1 - o.y / bounds.height))
            guard abs(curveAt(list, x) - y) * bounds.height < 28 else { return }
            list.append(CGPoint(x: x, y: curveAt(list, x)))
            list.sort { $0.x < $1.x }
            i = list.firstIndex { $0.x == x } ?? -1
            Haptics.tick()
        }
        onBegin?()
        working = list
        active = i
        redraw()
        if list.count != points.count { onChange?(list) }
    }

    @objc private func panned(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began:
            dragging = true
        case .changed:
            guard var list = working, active >= 0, active < list.count else { return }
            let i = active
            let p = g.location(in: self)
            let w = bounds.width, h = bounds.height
            let off = p.y < -36 || p.y > h + 36 || p.x < -36 || p.x > w + 36
            if off && i > 0 && i < list.count - 1 {
                Haptics.confirm()
                list.remove(at: i)
                active = -1
                working = list
                redraw()
                onChange?(list)
                return
            }
            let lo = i == 0 ? 0 : list[i - 1].x + 0.01
            let hi = i == list.count - 1 ? 1 : list[i + 1].x - 0.01
            list[i] = CGPoint(x: max(lo, min(max(lo, hi), p.x / w)), y: max(0, min(1, 1 - p.y / h)))
            working = list
            redraw()
            onChange?(list)
        default:
            dragging = false
            if working != nil { finish() }
        }
    }

    private func finish() {
        let w = working
        working = nil
        active = -1
        if let w = w { points = w } else { redraw() }
        onEnd?()
    }
}
