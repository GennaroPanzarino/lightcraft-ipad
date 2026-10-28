import SwiftUI
import UIKit

/// What sits on the photo while a cursor tool is on: the spots of the Remove tool, the stroke being
/// painted (Apple Pencil pressure included), a gradient's guides and handles. It lives inside the
/// viewer's image view, so it zooms and scrolls with the photo; one finger draws, two fingers still
/// zoom and move the photo. Points go out in the image's own coordinates.
final class EditOverlay: UIView {
    var mode: CursorTool = .none {
        didSet {
            isUserInteractionEnabled = [.spot, .paint, .shape, .sample, .focus].contains(mode)
            redraw()
        }
    }
    var crop = CropState() { didSet { if crop != oldValue { redraw() } } }
    var spots: [SpotInfo] = [] { didSet { if spots != oldValue { redraw() } } }
    var maskInfo: MaskInfo? { didSet { if maskInfo != oldValue && dragging == nil { redraw() } } }
    var brushSize: CGFloat = 0.03
    var spotSize: CGFloat = 0.015
    var erasing = false { didSet { stroke.strokeColor = (erasing ? UIColor.white : Ux.accent).withAlphaComponent(0.45).cgColor } }
    /// How far the photo is zoomed in (lines keep their width on screen).
    var zoom: CGFloat = 1 { didSet { if abs(zoom - oldValue) > 0.01 { redraw() } } }

    var onSpot: ((CGPoint) -> Void)?
    var onStroke: (([CGPoint], [Float]) -> Void)?
    var onSample: ((CGPoint) -> Void)?
    /// A tap with the focus tool: where, in the picture on screen (0…1).
    var onFocus: ((CGPoint) -> Void)?
    var onShapeBegin: (() -> Void)?
    var onShape: (([String: Any]) -> Void)?
    var onShapeEnd: (() -> Void)?

    private let spotLayer = CAShapeLayer()
    private let stroke = CAShapeLayer()
    private let guides = CAShapeLayer()
    private let handles = CAShapeLayer()
    private var points: [CGPoint] = []
    private var pressure: [Float] = []
    private var downAt = CGPoint.zero
    private var moved = false
    /// The handle a finger holds, and the shape as it was when it took it.
    private var dragging: String?
    private var shapeAtStart: [String: Any] = [:]
    private var working: [String: Any]?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isMultipleTouchEnabled = false
        for l in [spotLayer, stroke, guides, handles] { layer.addSublayer(l) }
        spotLayer.fillColor = UIColor.white.withAlphaComponent(0.08).cgColor
        spotLayer.strokeColor = UIColor.white.cgColor
        stroke.fillColor = UIColor.clear.cgColor
        stroke.strokeColor = Ux.accent.withAlphaComponent(0.45).cgColor
        stroke.lineCap = .round
        stroke.lineJoin = .round
        guides.fillColor = UIColor.clear.cgColor
        guides.strokeColor = UIColor.white.withAlphaComponent(0.9).cgColor
        handles.fillColor = UIColor.white.cgColor
        handles.strokeColor = UIColor.black.withAlphaComponent(0.6).cgColor
        for l in [spotLayer, guides, handles] {
            l.shadowColor = UIColor.black.cgColor
            l.shadowOpacity = 0.6
            l.shadowRadius = 1.5
            l.shadowOffset = .zero
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        redraw()
    }

    // MARK: coordinates

    private func toImage(_ p: CGPoint) -> CGPoint {
        crop.toImage(CGPoint(x: p.x / max(bounds.width, 1), y: p.y / max(bounds.height, 1)))
    }

    private func toView(_ q: CGPoint) -> CGPoint {
        let u = crop.toView(q)
        return CGPoint(x: u.x * bounds.width, y: u.y * bounds.height)
    }

    /// A length as a fraction of the image's long edge → points of this view.
    private func length(_ fraction: CGFloat) -> CGFloat { crop.toViewWidth(fraction) * bounds.width }

    private static func point(_ v: Any?) -> CGPoint? {
        if let o = v as? [String: Any] { return CGPoint(x: double(o["x"]), y: double(o["y"])) }
        if let a = v as? [Any], a.count >= 2 { return CGPoint(x: double(a[0]), y: double(a[1])) }
        return nil
    }

    private static func json(_ p: CGPoint) -> [String: Any] { ["x": Double(p.x), "y": Double(p.y)] }

    // MARK: drawing

    private func redraw() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let line = 1.5 / zoom
        spotLayer.lineWidth = line
        guides.lineWidth = line
        handles.lineWidth = 1 / zoom
        // spots
        let sp = UIBezierPath()
        if mode == .spot {
            for s in spots {
                let c = toView(s.center)
                let r = max(4 / zoom, length(s.size))
                sp.append(UIBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)))
            }
        }
        spotLayer.path = sp.cgPath
        // gradients
        let g = UIBezierPath()
        let h = UIBezierPath()
        let shape = working ?? maskInfo?.shape ?? [:]
        if mode == .shape {
            let k: CGFloat = 7 / zoom
            func knob(_ p: CGPoint) { h.append(UIBezierPath(ovalIn: CGRect(x: p.x - k, y: p.y - k, width: 2 * k, height: 2 * k))) }
            switch shape.str("kind") {
            case "linear":
                if let s0 = EditOverlay.point(shape["start"]), let e0 = EditOverlay.point(shape["end"]) {
                    let s = toView(s0), e = toView(e0)
                    let d = CGPoint(x: e.x - s.x, y: e.y - s.y)
                    let len = max(1, hypot(d.x, d.y))
                    let n = CGPoint(x: -d.y / len, y: d.x / len)
                    let reach = max(bounds.width, bounds.height) * 2
                    for p in [s, e] {
                        g.move(to: CGPoint(x: p.x - n.x * reach, y: p.y - n.y * reach))
                        g.addLine(to: CGPoint(x: p.x + n.x * reach, y: p.y + n.y * reach))
                    }
                    g.move(to: s)
                    g.addLine(to: e)
                    knob(s)
                    knob(e)
                    knob(CGPoint(x: (s.x + e.x) / 2, y: (s.y + e.y) / 2))
                }
            case "radial":
                if let c0 = EditOverlay.point(shape["center"]) {
                    let c = toView(c0)
                    let rx = length(CGFloat(double(shape["rx"]))), ry = length(CGFloat(double(shape["ry"])))
                    let a = CGFloat(double(shape["angle"]) + crop.angle) * .pi / 180
                    var t = CGAffineTransform(translationX: c.x, y: c.y).rotated(by: a)
                    let path = CGPath(ellipseIn: CGRect(x: -rx, y: -ry, width: 2 * rx, height: 2 * ry), transform: &t)
                    g.append(UIBezierPath(cgPath: path))
                    knob(c)
                    knob(CGPoint(x: c.x + cos(a) * rx, y: c.y + sin(a) * rx))
                    knob(CGPoint(x: c.x - sin(a) * ry, y: c.y + cos(a) * ry))
                }
            default: break
            }
        }
        guides.path = g.cgPath
        handles.path = h.cgPath
        // the stroke being painted
        let s = UIBezierPath()
        if let f = points.first {
            s.move(to: f)
            for p in points.dropFirst() { s.addLine(to: p) }
            if points.count == 1 { s.addLine(to: CGPoint(x: f.x + 0.1, y: f.y)) }
        }
        stroke.path = s.cgPath
        stroke.lineWidth = max(2 / zoom, 2 * length(brushSize))
        CATransaction.commit()
    }

    // MARK: touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first else { return }
        let p = t.location(in: self)
        downAt = p
        moved = false
        switch mode {
        case .paint:
            points = [p]
            pressure = [force(t)]
            redraw()
        case .shape:
            grabHandle(at: p)
        default: break
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first else { return }
        let p = t.location(in: self)
        if hypot(p.x - downAt.x, p.y - downAt.y) > 6 / zoom { moved = true }
        switch mode {
        case .paint:
            // every sample the Pencil gave since the last frame
            for c in event?.coalescedTouches(for: t) ?? [t] {
                points.append(c.location(in: self))
                pressure.append(force(c))
            }
            redraw()
        case .shape:
            moveHandle(to: p)
        default: break
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first else { return }
        let p = t.location(in: self)
        switch mode {
        case .paint:
            let pts = points.map(toImage)
            let pr = pressure
            points = []
            pressure = []
            redraw()
            if !pts.isEmpty { onStroke?(pts, pr) }
        case .spot:
            if !moved { onSpot?(toImage(p)) }
        case .sample:
            if !moved { onSample?(toImage(p)) }
        case .focus:
            if !moved { onFocus?(CGPoint(x: p.x / max(bounds.width, 1), y: p.y / max(bounds.height, 1))) }
        case .shape:
            if dragging != nil {
                dragging = nil
                working = nil
                onShapeEnd?()
                redraw()
            }
        default: break
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        points = []
        pressure = []
        if dragging != nil {
            dragging = nil
            working = nil
            onShapeEnd?()
        }
        redraw()
    }

    private func force(_ t: UITouch) -> Float {
        guard t.type == .pencil || t.maximumPossibleForce > 0 && t.force > 0 else { return 1 }
        return Float(max(0.05, min(1, t.force / max(t.maximumPossibleForce, 0.001))))
    }

    // MARK: gradient handles

    private func grabHandle(at p: CGPoint) {
        guard let shape = maskInfo?.shape else { return }
        var best: (String, CGFloat)?
        func consider(_ name: String, _ q: CGPoint) {
            let d = hypot(q.x - p.x, q.y - p.y)
            if d < 44 / zoom && d < (best?.1 ?? .infinity) { best = (name, d) }
        }
        switch shape.str("kind") {
        case "linear":
            if let s0 = EditOverlay.point(shape["start"]), let e0 = EditOverlay.point(shape["end"]) {
                let s = toView(s0), e = toView(e0)
                consider("start", s)
                consider("end", e)
                consider("move", CGPoint(x: (s.x + e.x) / 2, y: (s.y + e.y) / 2))
            }
        case "radial":
            if let c0 = EditOverlay.point(shape["center"]) {
                let c = toView(c0)
                let rx = length(CGFloat(double(shape["rx"]))), ry = length(CGFloat(double(shape["ry"])))
                let a = CGFloat(double(shape["angle"]) + crop.angle) * .pi / 180
                consider("rx", CGPoint(x: c.x + cos(a) * rx, y: c.y + sin(a) * rx))
                consider("ry", CGPoint(x: c.x - sin(a) * ry, y: c.y + cos(a) * ry))
                consider("move", c)
                // anywhere inside the ellipse moves it
                if best == nil {
                    let q = CGPoint(x: p.x - c.x, y: p.y - c.y)
                    let u = (q.x * cos(a) + q.y * sin(a)) / max(rx, 1), v = (-q.x * sin(a) + q.y * cos(a)) / max(ry, 1)
                    if u * u + v * v <= 1 { best = ("move", 0) }
                }
            }
        default: break
        }
        guard let b = best else { return }
        dragging = b.0
        shapeAtStart = shape
        downAt = p
        onShapeBegin?()
    }

    private func moveHandle(to p: CGPoint) {
        guard let handle = dragging else { return }
        var s = shapeAtStart
        let dImage = { (from: CGPoint, to: CGPoint) -> CGPoint in
            let a = self.toImage(from), b = self.toImage(to)
            return CGPoint(x: b.x - a.x, y: b.y - a.y)
        }
        switch (s.str("kind"), handle) {
        case ("linear", "start"):
            s["start"] = EditOverlay.json(toImage(p))
        case ("linear", "end"):
            s["end"] = EditOverlay.json(toImage(p))
        case ("linear", "move"):
            let d = dImage(downAt, p)
            if let a = EditOverlay.point(shapeAtStart["start"]), let b = EditOverlay.point(shapeAtStart["end"]) {
                s["start"] = EditOverlay.json(CGPoint(x: a.x + d.x, y: a.y + d.y))
                s["end"] = EditOverlay.json(CGPoint(x: b.x + d.x, y: b.y + d.y))
            }
        case ("radial", "move"):
            let d = dImage(downAt, p)
            if let c = EditOverlay.point(shapeAtStart["center"]) { s["center"] = EditOverlay.json(CGPoint(x: c.x + d.x, y: c.y + d.y)) }
        case ("radial", "rx"), ("radial", "ry"):
            if let c0 = EditOverlay.point(shapeAtStart["center"]) {
                let c = toView(c0)
                let r = hypot(p.x - c.x, p.y - c.y)
                let perLong = max(length(1), 1)
                s[handle] = max(0.005, min(0.9, Double(r / perLong)))
            }
        default: break
        }
        working = s
        redraw()
        onShape?(s)
    }
}

// MARK: - Crop

/// Capture One's crop: the whole photo, turned by the straighten angle, under a frame that stays
/// square to the screen; drag a corner or a side to resize it, inside to move it; two fingers turn
/// the photo. The engine keeps the crop inside the photo and its proportions locked.
final class CropView: UIView, UIGestureRecognizerDelegate {
    var image: CGImage? {
        didSet { if image !== oldValue { imageView.image = image.map { UIImage(cgImage: $0) } } }
    }
    var crop = CropState() {
        didSet { if crop != oldValue { setNeedsLayout() } }
    }
    var onBegin: (() -> Void)?
    var onDrag: ((String, CGPoint, CGPoint, CGRect) -> Void)?
    var onEnd: (() -> Void)?
    var onAngle: ((Double, Bool) -> Void)?

    private let imageView = UIImageView()
    private let dim = CAShapeLayer()
    private let frameLayer = CAShapeLayer()
    private let grid = CAShapeLayer()
    private let corners = CAShapeLayer()
    private var box = CGRect.zero
    private var handle: String?
    private var from = CGPoint.zero
    private var start = CGRect.zero
    private var angleAtStart: Double = 0
    private var showGrid = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        clipsToBounds = true
        imageView.contentMode = .scaleToFill
        addSubview(imageView)
        dim.fillRule = .evenOdd
        dim.fillColor = UIColor.black.withAlphaComponent(0.62).cgColor
        frameLayer.fillColor = UIColor.clear.cgColor
        frameLayer.strokeColor = UIColor.white.cgColor
        frameLayer.lineWidth = 1
        grid.fillColor = UIColor.clear.cgColor
        grid.strokeColor = UIColor.white.withAlphaComponent(0.5).cgColor
        grid.lineWidth = 0.5
        corners.fillColor = UIColor.clear.cgColor
        corners.strokeColor = UIColor.white.cgColor
        corners.lineWidth = 3
        corners.lineCap = .square
        for l in [dim, grid, frameLayer, corners] { layer.addSublayer(l) }
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)
        let rotate = UIRotationGestureRecognizer(target: self, action: #selector(rotated(_:)))
        rotate.delegate = self
        addGestureRecognizer(rotate)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let a = max(crop.aspect, 0.01)
        let t = CGFloat(crop.angle) * .pi / 180
        let bw = a * abs(cos(t)) + abs(sin(t)), bh = a * abs(sin(t)) + abs(cos(t))
        let avail = bounds.insetBy(dx: 36, dy: 36)
        let s = max(1, min(avail.width / bw, avail.height / bh))
        box = CGRect(x: bounds.midX - a * s / 2, y: bounds.midY - s / 2, width: a * s, height: s)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageView.transform = .identity
        imageView.frame = box
        imageView.transform = CGAffineTransform(rotationAngle: t)
        let r = cropRect
        let d = UIBezierPath(rect: bounds)
        d.append(UIBezierPath(rect: r))
        dim.path = d.cgPath
        frameLayer.path = UIBezierPath(rect: r).cgPath
        let g = UIBezierPath()
        if showGrid {
            for k in 1...2 {
                let x = r.minX + r.width * CGFloat(k) / 3, y = r.minY + r.height * CGFloat(k) / 3
                g.move(to: CGPoint(x: x, y: r.minY)); g.addLine(to: CGPoint(x: x, y: r.maxY))
                g.move(to: CGPoint(x: r.minX, y: y)); g.addLine(to: CGPoint(x: r.maxX, y: y))
            }
        }
        grid.path = g.cgPath
        let c = UIBezierPath()
        let L: CGFloat = 18
        for (p, dx, dy) in [(CGPoint(x: r.minX, y: r.minY), L, L), (CGPoint(x: r.maxX, y: r.minY), -L, L), (CGPoint(x: r.minX, y: r.maxY), L, -L), (CGPoint(x: r.maxX, y: r.maxY), -L, -L)] {
            c.move(to: CGPoint(x: p.x + dx, y: p.y)); c.addLine(to: p); c.addLine(to: CGPoint(x: p.x, y: p.y + dy))
        }
        for (a0, b0) in [(CGPoint(x: r.midX - L / 2, y: r.minY), CGPoint(x: r.midX + L / 2, y: r.minY)), (CGPoint(x: r.midX - L / 2, y: r.maxY), CGPoint(x: r.midX + L / 2, y: r.maxY)),
                         (CGPoint(x: r.minX, y: r.midY - L / 2), CGPoint(x: r.minX, y: r.midY + L / 2)), (CGPoint(x: r.maxX, y: r.midY - L / 2), CGPoint(x: r.maxX, y: r.midY + L / 2))] {
            c.move(to: a0); c.addLine(to: b0)
        }
        corners.path = c.cgPath
        CATransaction.commit()
    }

    /// The photo turns at once with the straighten slider or two fingers; the crop the engine fits
    /// to the new angle follows when the gesture ends.
    func liveAngle(_ a: Double) {
        guard abs(a - crop.angle) > 0.0001 else { return }
        crop.angle = a
    }

    /// The crop on screen (the turned frame shares the unturned image's box: same scale, same centre).
    private var cropRect: CGRect {
        CGRect(x: box.minX + crop.rect.minX * box.width, y: box.minY + crop.rect.minY * box.height, width: crop.rect.width * box.width, height: crop.rect.height * box.height)
    }

    private func normalized(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - box.minX) / max(box.width, 1), y: (p.y - box.minY) / max(box.height, 1))
    }

    private func pick(_ p: CGPoint) -> String {
        let r = cropRect
        let near: CGFloat = 34
        let left = abs(p.x - r.minX) < near, right = abs(p.x - r.maxX) < near
        let top = abs(p.y - r.minY) < near, bottom = abs(p.y - r.maxY) < near
        let inX = p.x > r.minX - near && p.x < r.maxX + near, inY = p.y > r.minY - near && p.y < r.maxY + near
        switch (left && inY, right && inY, top && inX, bottom && inX) {
        case (true, _, true, _): return "topLeft"
        case (_, true, true, _): return "topRight"
        case (true, _, _, true): return "bottomLeft"
        case (_, true, _, true): return "bottomRight"
        case (true, _, _, _): return "left"
        case (_, true, _, _): return "right"
        case (_, _, true, _): return "top"
        case (_, _, _, true): return "bottom"
        default: return "move"
        }
    }

    @objc private func panned(_ g: UIPanGestureRecognizer) {
        let p = g.location(in: self)
        switch g.state {
        case .began:
            handle = pick(p)
            from = normalized(p)
            start = crop.rect
            showGrid = true
            onBegin?()
            setNeedsLayout()
        case .changed:
            guard let h = handle else { return }
            onDrag?(h, from, normalized(p), start)
        default:
            handle = nil
            showGrid = false
            setNeedsLayout()
            onEnd?()
        }
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { false }

    @objc private func rotated(_ g: UIRotationGestureRecognizer) {
        switch g.state {
        case .began:
            angleAtStart = crop.angle
            showGrid = true
            onAngle?(angleAtStart, false)
        case .changed:
            let a = max(-45, min(45, angleAtStart + Double(g.rotation) * 180 / .pi))
            liveAngle((a * 100).rounded() / 100)
            onAngle?(crop.angle, false)
        default:
            showGrid = false
            setNeedsLayout()
            onAngle?(crop.angle, true)
        }
    }
}

/// The crop tool in the viewer's place.
struct CropHost: UIViewRepresentable {
    @ObservedObject var ed: EditorModel

    func makeUIView(context: Context) -> CropView {
        let v = CropView()
        let ed = self.ed
        v.onBegin = { ed.begin("Ritaglio") }
        v.onDrag = { h, from, to, start in ed.cropDrag(h, from: from, to: to, start: start) }
        v.onEnd = { ed.end() }
        ed.store.observe(["crop.angle"], owner: v) { [weak v] _, a in v?.liveAngle(a) }
        var turning = false
        v.onAngle = { a, done in
            if !turning && !done {
                turning = true
                ed.store.onBegin?("Raddrizza")
            }
            ed.store.userSet("crop.angle", a, from: nil)
            if done && turning {
                turning = false
                ed.store.onEnd?()
            }
        }
        return v
    }

    func updateUIView(_ v: CropView, context: Context) {
        v.image = ed.uncropped
        v.crop = ed.crop
    }
}
