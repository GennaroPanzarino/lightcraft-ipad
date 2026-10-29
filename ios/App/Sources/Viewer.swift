import SwiftUI
import UIKit

/// The photo in the viewer: pinch to zoom (up to 16×), double tap to look closer and back, drag to
/// look around once zoomed — the system's own scroll view, with its inertia and bounce. Zoomed in,
/// only what is on screen is developed again, sharp, at the screen's resolution (Lightroom's way:
/// never the whole 33 MP photo). Not zoomed, the photo follows a horizontal drag and the next or
/// previous shot slides in with it, as in a gallery. Pictures arrive straight from the engine.
final class PhotoViewer: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    /// A single tap (once it is clear no second one follows): where, 0…1 of the picture.
    var onTap: ((CGPoint?) -> Void)?
    /// A tap that cannot start a double tap (the white-balance picker): handled at once.
    var tapsAtOnce: (() -> Bool)?
    var onZoom: ((CGFloat) -> Void)?
    /// Go to the next (+1) or previous (−1) shot; `neighbor` gives its picture (nil: there is none).
    var onPage: ((Int) -> Void)?
    var neighbor: ((Int) -> CGImage?)?
    /// A sharp picture of the window `rect` (0…1 of the picture) of the photo drawn whole at `full`
    /// pixels: `token` comes back with it.
    var onRegion: ((CGRect, CGSize, Int) -> Void)?

    private let scroll = UIScrollView()
    private let imageView = UIImageView()
    private let detail = UIImageView()
    private let side = UIImageView()
    /// Spots, strokes, the mask and gradients on the photo (it zooms with it).
    let overlay = EditOverlay()
    /// The shot shown.
    private(set) var key = ""
    private var current: CGImage?
    private var held: CGImage?
    private var fitted = CGSize.zero
    private var paging: UIPanGestureRecognizer!
    private var taps: UITapGestureRecognizer!
    private var sideImage: CGImage?
    private var sideDir = 0
    private let gap: CGFloat = 24
    private var regionToken = 0
    /// The first tap of what may become a double tap.
    private var pendingTap: DispatchWorkItem?
    private var lastTapAt: CFTimeInterval = 0
    private var lastTapPoint = CGPoint.zero
    private var zoomTaps = true
    /// A double tap's zoom, frame by frame.
    private var zoomLink: CADisplayLink?
    private var zoomStart: CFTimeInterval = 0
    private var zoomFrom = (scale: CGFloat(1), center: CGPoint.zero)
    private var zoomTo = (scale: CGFloat(1), center: CGPoint.zero)
    /// A swipe's landing still on its way (the neighbour becoming the photo): a new swipe lands it
    /// at once, so every swipe moves from the photo really shown.
    private var pageLanding: (() -> Void)?
    private var pageToken = 0

    /// How long a first tap waits for a second one (a double tap) before it counts as a tap.
    static let doubleTapWindow: CFTimeInterval = 0.26
    static let zoomDuration: CFTimeInterval = 0.24

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        clipsToBounds = true
        scroll.delegate = self
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 16
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.decelerationRate = .fast
        scroll.backgroundColor = .clear
        addSubview(scroll)
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        imageView.layer.minificationFilter = .trilinear
        scroll.addSubview(imageView)
        detail.isHidden = true
        detail.contentMode = .scaleToFill
        detail.layer.minificationFilter = .trilinear
        imageView.addSubview(detail)
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.isUserInteractionEnabled = false
        imageView.addSubview(overlay)
        side.contentMode = .scaleAspectFit
        side.isHidden = true
        addSubview(side)
        taps = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        taps.delegate = self
        scroll.addGestureRecognizer(taps)
        paging = UIPanGestureRecognizer(target: self, action: #selector(paged(_:)))
        paging.delegate = self
        addGestureRecognizer(paging)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        if g === paging {
            guard scroll.zoomScale <= 1.01, zoomLink == nil else { return false }
            let v = paging.velocity(in: self)
            return abs(v.x) > abs(v.y)
        }
        return true
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        (g === paging && other === scroll.panGestureRecognizer) || (g is UITapGestureRecognizer && other is UITapGestureRecognizer)
    }

    /// The photo hidden (a picture flying into its place from the library draws it meanwhile).
    var photoHidden = false {
        didSet { if photoHidden != oldValue { scroll.alpha = photoHidden ? 0 : 1 } }
    }

    /// Whether a picture is on screen.
    var hasPicture: Bool { imageView.image != nil }

    /// A new shot: back to fit.
    func reset(for key: String) {
        guard key != self.key else { return }
        self.key = key
        stopZoom()
        pendingTap?.cancel()
        pendingTap = nil
        scroll.setZoomScale(1, animated: false)
        current = nil
        held = nil
        dropDetail()
    }

    func show(_ image: CGImage?, draft: Bool = false) {
        guard let image = image, image !== current else { return }
        let first = current == nil && imageView.image == nil
        current = image
        guard held == nil else { return }
        set(image, fade: first)
        // a new look: its sharp window follows once the finger lifts
        if scroll.zoomScale > 1.05 {
            dropDetail()
            if !draft { requestDetail() }
        }
    }

    /// Another picture over the photo for a while (the "before" button, the depth map).
    func hold(_ image: CGImage?) {
        guard image !== held else { return }
        held = image
        detail.isHidden = image != nil || detail.image == nil
        if let i = image { set(i, fade: false) } else if let c = current { set(c, fade: false) }
    }

    private func set(_ image: CGImage, fade: Bool) {
        let ui = UIImage(cgImage: image)
        if fade {
            UIView.transition(with: imageView, duration: 0.12, options: [.transitionCrossDissolve, .allowUserInteraction]) {
                self.imageView.image = ui
            }
        } else {
            imageView.image = ui
        }
        layoutImage(force: false)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if scroll.transform == .identity { scroll.frame = bounds }
        layoutImage(force: false)
    }

    private func fit(_ size: CGSize) -> CGSize {
        let b = bounds.size
        let a = size.width / max(1, size.height)
        return b.width / max(1, b.height) > a ? CGSize(width: b.height * a, height: b.height) : CGSize(width: b.width, height: b.width / a)
    }

    private func layoutImage(force: Bool) {
        guard let img = imageView.image, bounds.width > 0, bounds.height > 0 else { return }
        let f = fit(img.size)
        if force || abs(f.width - fitted.width) > 0.5 || abs(f.height - fitted.height) > 0.5 {
            stopZoom()
            fitted = f
            let zoom = scroll.zoomScale
            scroll.zoomScale = 1
            imageView.frame = CGRect(origin: .zero, size: f)
            overlay.frame = imageView.bounds
            scroll.contentSize = f
            scroll.zoomScale = zoom
            dropDetail()
        }
        center()
    }

    private func center() {
        let b = scroll.bounds.size
        let f = imageView.frame.size
        scroll.contentInset = UIEdgeInsets(top: max(0, (b.height - f.height) / 2), left: max(0, (b.width - f.width) / 2), bottom: 0, right: 0)
    }

    // MARK: zoom, and the sharp window

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        center()
        overlay.zoom = scrollView.zoomScale
        if scrollView.zoomScale <= 1.05 { dropDetail() }
    }

    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) { stopZoom() }
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { stopZoom() }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        onZoom?(scale)
        requestDetail()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { requestDetail() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { requestDetail() }

    private func dropDetail() {
        regionToken += 1
        detail.isHidden = true
        detail.image = nil
    }

    /// What is on screen, developed again at the screen's resolution.
    private func requestDetail() {
        guard scroll.zoomScale > 1.05, held == nil, zoomLink == nil, imageView.bounds.width > 0 else { return }
        let b = imageView.bounds
        let visible = scroll.convert(scroll.bounds, to: imageView).intersection(b)
        guard visible.width > 1, visible.height > 1 else { return }
        let scale = scroll.zoomScale * (window?.screen.scale ?? UIScreen.main.scale)
        let full = CGSize(width: (b.width * scale).rounded(), height: (b.height * scale).rounded())
        let n = CGRect(x: visible.minX / b.width, y: visible.minY / b.height, width: visible.width / b.width, height: visible.height / b.height)
        regionToken += 1
        onRegion?(n, full, regionToken)
    }

    func showDetail(_ image: CGImage, _ n: CGRect, token: Int) {
        guard token == regionToken, scroll.zoomScale > 1.05, held == nil else { return }
        let b = imageView.bounds
        detail.image = UIImage(cgImage: image)
        detail.frame = CGRect(x: n.minX * b.width, y: n.minY * b.height, width: n.width * b.width, height: n.height * b.height)
        detail.isHidden = false
    }

    // MARK: taps

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        let now = CACurrentMediaTime()
        let p = g.location(in: self)
        // the second tap of a double tap: zoom, and the first one never counts
        if zoomTaps, let first = pendingTap, now - lastTapAt < PhotoViewer.doubleTapWindow, hypot(p.x - lastTapPoint.x, p.y - lastTapPoint.y) < 44 {
            first.cancel()
            pendingTap = nil
            lastTapAt = 0
            doubleTapped(at: g.location(in: imageView))
            return
        }
        let q = g.location(in: imageView)
        let size = imageView.bounds.size
        let inside = q.x >= 0 && q.y >= 0 && q.x <= size.width && q.y <= size.height && size.width > 0
        let u = inside ? CGPoint(x: q.x / size.width, y: q.y / size.height) : nil
        if !zoomTaps || tapsAtOnce?() == true {
            onTap?(u)
            return
        }
        pendingTap?.cancel()
        lastTapAt = now
        lastTapPoint = p
        let work = DispatchWorkItem { [weak self] in
            self?.pendingTap = nil
            self?.onTap?(u)
        }
        pendingTap = work
        DispatchQueue.main.asyncAfter(deadline: .now() + PhotoViewer.doubleTapWindow, execute: work)
    }

    /// Zoom in on the point tapped (3×), or back to the whole photo.
    private func doubleTapped(at p: CGPoint) {
        if scroll.zoomScale > 1.02 {
            animateZoom(to: 1, center: CGPoint(x: fitted.width / 2, y: fitted.height / 2))
        } else {
            animateZoom(to: 3, center: p)
        }
    }

    /// The scroll offset that shows `c` (a point of the unzoomed photo) in the middle at `scale`,
    /// kept inside the photo.
    private func offset(scale s: CGFloat, center c: CGPoint) -> CGPoint {
        let b = scroll.bounds.size
        let cw = fitted.width * s, ch = fitted.height * s
        let x = cw > b.width ? min(max(c.x * s - b.width / 2, 0), cw - b.width) : -(b.width - cw) / 2
        let y = ch > b.height ? min(max(c.y * s - b.height / 2, 0), ch - b.height) : -(b.height - ch) / 2
        return CGPoint(x: x, y: y)
    }

    /// The zoom glides from where it is to `scale` around `c` (a point of the unzoomed photo):
    /// scale and centre move together on one curve, every frame of the display.
    private func animateZoom(to scale: CGFloat, center c: CGPoint) {
        stopZoom()
        guard fitted.width > 0 else { return }
        let s0 = scroll.zoomScale
        let b = scroll.bounds.size
        let o = scroll.contentOffset
        zoomFrom = (s0, CGPoint(x: (o.x + b.width / 2) / s0, y: (o.y + b.height / 2) / s0))
        let s1 = max(scroll.minimumZoomScale, min(scroll.maximumZoomScale, scale))
        // the end centre as the clamped end offset shows it (no slide at the end)
        let end = offset(scale: s1, center: c)
        zoomTo = (s1, CGPoint(x: (end.x + b.width / 2) / s1, y: (end.y + b.height / 2) / s1))
        dropDetail()
        zoomStart = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(zoomStep(_:)))
        if #available(iOS 15.0, *) {
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        }
        link.add(to: .main, forMode: .common)
        zoomLink = link
    }

    @objc private func zoomStep(_ link: CADisplayLink) {
        let t = min(1, (CACurrentMediaTime() - zoomStart) / PhotoViewer.zoomDuration)
        // ease out (quint): quick to start, a soft landing
        let e = CGFloat(1 - pow(1 - t, 5))
        let s = zoomFrom.scale + (zoomTo.scale - zoomFrom.scale) * e
        let c = CGPoint(x: zoomFrom.center.x + (zoomTo.center.x - zoomFrom.center.x) * e, y: zoomFrom.center.y + (zoomTo.center.y - zoomFrom.center.y) * e)
        scroll.zoomScale = s
        scroll.contentOffset = offset(scale: s, center: c)
        if t >= 1 {
            stopZoom()
            onZoom?(s)
            requestDetail()
        }
    }

    private func stopZoom() {
        zoomLink?.invalidate()
        zoomLink = nil
    }

    /// A cursor tool on the photo: one finger is the tool's, two fingers still move and zoom.
    func setTool(_ tool: CursorTool) {
        overlay.mode = tool
        let drawing = [.spot, .paint, .shape, .sample, .focus, .refine].contains(tool)
        scroll.panGestureRecognizer.minimumNumberOfTouches = drawing ? 2 : 1
        paging.isEnabled = !drawing
        // taps on the photo are the tool's (a spot, a colour, the focus): the viewer's own tap
        // recognizer would take the touch from it (it cancels the touches it recognizes), and the
        // scroll view would hold the first touch back while it waits to see a scroll
        taps.isEnabled = !drawing
        scroll.delaysContentTouches = !drawing
        zoomTaps = !drawing
    }

    // MARK: paging

    /// The neighbour's picture beside the photo, `dx` the photo's offset.
    private func placeSide(_ dx: CGFloat) {
        let dir = dx < 0 ? 1 : -1
        if dir != sideDir {
            sideDir = dir
            sideImage = neighbor?(dir)
            side.image = sideImage.map { UIImage(cgImage: $0) }
        }
        guard let img = side.image else {
            side.isHidden = true
            return
        }
        side.isHidden = false
        let f = fit(img.size)
        let x = bounds.midX + dx + (dir > 0 ? bounds.width + gap : -(bounds.width + gap))
        side.frame = CGRect(x: x - f.width / 2, y: bounds.midY - f.height / 2, width: f.width, height: f.height)
    }

    @objc private func paged(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: self).x
        switch g.state {
        case .began:
            if let land = pageLanding {
                pageLanding = nil
                scroll.layer.removeAllAnimations()
                side.layer.removeAllAnimations()
                land()
            }
            sideDir = 0
            pendingTap?.cancel()
            pendingTap = nil
        case .changed:
            placeSide(t)
            // no neighbour that way: the photo resists, more the further it goes
            let dx = side.image == nil ? t / (1 + abs(t) / 120) : t
            scroll.transform = CGAffineTransform(translationX: dx, y: 0)
            if side.image == nil { side.isHidden = true }
        default:
            let v = g.velocity(in: self).x
            let dir = t < 0 ? 1 : -1
            let go = side.image != nil && g.state == .ended && (abs(t) > bounds.width * 0.22 || abs(v) > 500) && (abs(v) < 50 || (v < 0) == (t < 0))
            let current = scroll.transform.tx
            if go {
                let shift = CGFloat(-dir) * (bounds.width + gap)
                let next = sideImage
                // the finger's speed carries on into the spring
                let rest = shift - current
                let speed = abs(rest) > 1 ? max(0, min(30, v / rest)) : 0
                // the neighbour becomes the photo without a flicker; its sharp picture follows
                let land = { [weak self] in
                    guard let self = self else { return }
                    if let n = next {
                        self.imageView.image = UIImage(cgImage: n)
                        self.current = n
                        self.layoutImage(force: true)
                    }
                    self.scroll.transform = .identity
                    self.scroll.frame = self.bounds
                    self.side.isHidden = true
                    self.sideDir = 0
                    Haptics.tick()
                    self.onPage?(dir)
                }
                pageToken += 1
                let token = pageToken
                pageLanding = land
                UIView.animate(withDuration: 0.42, delay: 0, usingSpringWithDamping: 0.94, initialSpringVelocity: speed, options: [.allowUserInteraction, .beginFromCurrentState]) {
                    self.scroll.transform = CGAffineTransform(translationX: shift, y: 0)
                    self.placeSide(shift)
                } completion: { _ in
                    guard self.pageToken == token, let l = self.pageLanding else { return }
                    self.pageLanding = nil
                    l()
                }
            } else {
                let speed = abs(current) > 1 ? max(0, min(30, -v / current)) : 0
                UIView.animate(withDuration: 0.38, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: speed, options: [.allowUserInteraction, .beginFromCurrentState]) {
                    self.scroll.transform = .identity
                    self.placeSide(0.001 * CGFloat(-dir))
                } completion: { _ in
                    self.side.isHidden = true
                    self.sideDir = 0
                }
            }
        }
    }
}

/// The viewer in the workspace: the shot on screen, its pictures straight from the loupe.
struct ViewerHost: UIViewRepresentable {
    let model: AppModel
    let key: String?
    var onZoom: (CGFloat) -> Void
    var before: CGImage?
    /// The photo hidden (a thumbnail is flying into its place).
    var hidden = false

    func makeUIView(context: Context) -> PhotoViewer {
        let v = PhotoViewer()
        let model = self.model
        model.loupe.onViewer = { [weak v] p in v?.show(p.image, draft: p.draft) }
        let ed = model.editor
        v.overlay.onSpot = { p in ed.addSpot(p) }
        v.overlay.onSample = { p in ed.sampleColor(p, add: false) }
        v.overlay.onFocus = { u in ed.focus(at: u) }
        v.overlay.onFocusBox = { r in ed.focus(box: r) }
        v.overlay.onRefine = { pts in ed.refineStroke(pts) }
        v.overlay.onStrokeBegin = { ed.strokeBegan() }
        v.overlay.onStrokeMove = { pts, pr in ed.strokePart(pts, pressure: pr) }
        v.overlay.onStroke = { pts, pr in ed.stroke(pts, pressure: pr) }
        v.overlay.onShapeBegin = { ed.strokeBegan(); ed.begin("Maschera") }
        v.overlay.onShape = { s in if let id = ed.selectedMask { ed.updateShape(id, s) } }
        v.overlay.onShapeEnd = { ed.end() }
        v.onPage = { by in model.step(by) }
        v.neighbor = { by in model.neighborPicture(by) }
        v.tapsAtOnce = { model.editor.picking }
        v.onTap = { p in
            if model.editor.picking, let p = p {
                model.editor.pickWhite(p)
            } else if model.editor.cursorTool == .none {
                withAnimation(Motion.chrome) { model.chrome.toggle() }
            }
        }
        v.onRegion = { [weak v] n, full, token in
            model.renderDetail(window: n, full: full) { img, rect in v?.showDetail(img, rect, token: token) }
        }
        return v
    }

    func updateUIView(_ v: PhotoViewer, context: Context) {
        v.onZoom = onZoom
        let loupe = model.loupe
        loupe.viewerKey = key
        // the viewer's own shot, not the loupe's: a viewer made again (back from the crop tool or
        // the camera's login) shows the picture at once
        if v.key != (key ?? "") {
            v.reset(for: key ?? "")
            if let k = key { v.show(loupe.pics[k]?.image ?? model.library.shot(k)?.thumb) }
        } else if let k = key, !v.hasPicture || loupe.pics[k] == nil {
            v.show(loupe.pics[k]?.image ?? model.library.shot(k)?.thumb)
        }
        v.photoHidden = hidden
        v.hold(before)
        let ed = model.editor
        v.setTool(ed.cursorTool)
        v.overlay.crop = ed.crop
        v.overlay.spots = ed.spots
        v.overlay.partShape = ed.masks.first { $0.id == ed.selectedMask }?.part(ed.selectedPart)?.shape ?? [:]
        v.overlay.overlayColor = ed.overlayColor
        v.overlay.overlayOpacity = ed.overlayOpacity / 100
        v.overlay.maskImage = ed.maskImage
        v.overlay.showMask = ed.maskOverlayShown
        v.overlay.brushSize = CGFloat(ed.cursorTool == .refine ? ed.refineSize : ed.brushSize)
        v.overlay.spotSize = CGFloat(ed.spotSize)
        v.overlay.erasing = ed.erasing
    }
}
