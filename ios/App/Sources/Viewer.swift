import SwiftUI
import UIKit

/// The photo in the viewer: pinch to zoom (up to 16×: the photo is rendered at full size once you
/// zoom in), double tap to look closer and back, drag to look around once zoomed — the system's own
/// scroll view, with its inertia and bounce. Not zoomed, the photo follows a horizontal drag and the
/// next or previous shot slides in with it, as in a gallery. Pictures arrive straight from the engine
/// (`show`), not through SwiftUI.
final class PhotoViewer: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    var onTap: ((CGPoint?) -> Void)?
    var onZoom: ((CGFloat) -> Void)?
    /// Go to the next (+1) or previous (−1) shot; `neighbor` gives its picture (nil: there is none).
    var onPage: ((Int) -> Void)?
    var neighbor: ((Int) -> CGImage?)?

    private let scroll = UIScrollView()
    private let imageView = UIImageView()
    /// Spots, strokes and gradients on the photo (it zooms with it).
    let overlay = EditOverlay()
    private let side = UIImageView()
    private var key = ""
    private var current: CGImage?
    private var held: CGImage?
    private var fitted = CGSize.zero
    private var paging: UIPanGestureRecognizer!
    private var sideImage: CGImage?
    private var sideDir = 0
    private let gap: CGFloat = 24

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
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.isUserInteractionEnabled = false
        imageView.addSubview(overlay)
        side.contentMode = .scaleAspectFit
        side.isHidden = true
        addSubview(side)
        let double = UITapGestureRecognizer(target: self, action: #selector(doubleTap(_:)))
        double.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(double)
        let single = UITapGestureRecognizer(target: self, action: #selector(singleTap(_:)))
        single.require(toFail: double)
        scroll.addGestureRecognizer(single)
        paging = UIPanGestureRecognizer(target: self, action: #selector(paged(_:)))
        paging.delegate = self
        addGestureRecognizer(paging)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        if g === paging {
            guard scroll.zoomScale <= 1.01 else { return false }
            let v = paging.velocity(in: self)
            return abs(v.x) > abs(v.y)
        }
        return true
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        g === paging && other === scroll.panGestureRecognizer
    }

    /// A new shot: back to fit.
    func reset(for key: String) {
        guard key != self.key else { return }
        self.key = key
        scroll.setZoomScale(1, animated: false)
        current = nil
        held = nil
    }

    func show(_ image: CGImage?) {
        guard let image = image, image !== current else { return }
        let first = current == nil && imageView.image == nil
        current = image
        guard held == nil else { return }
        set(image, fade: first)
    }

    /// Another picture over the photo for a while (the "before" button).
    func hold(_ image: CGImage?) {
        guard image !== held else { return }
        held = image
        if let i = image { set(i, fade: false) } else if let c = current { set(c, fade: false) }
    }

    private func set(_ image: CGImage, fade: Bool) {
        let ui = UIImage(cgImage: image)
        if fade {
            UIView.transition(with: imageView, duration: 0.15, options: [.transitionCrossDissolve, .allowUserInteraction]) {
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
            fitted = f
            let zoom = scroll.zoomScale
            scroll.zoomScale = 1
            imageView.frame = CGRect(origin: .zero, size: f)
            overlay.frame = imageView.bounds
            scroll.contentSize = f
            scroll.zoomScale = zoom
        }
        center()
    }

    private func center() {
        let b = scroll.bounds.size
        let f = imageView.frame.size
        scroll.contentInset = UIEdgeInsets(top: max(0, (b.height - f.height) / 2), left: max(0, (b.width - f.width) / 2), bottom: 0, right: 0)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        center()
        overlay.zoom = scrollView.zoomScale
    }

    /// A cursor tool on the photo: one finger is the tool's, two fingers still move and zoom.
    func setTool(_ tool: CursorTool) {
        overlay.mode = tool
        let drawing = [.spot, .paint, .shape, .sample, .focus].contains(tool)
        scroll.panGestureRecognizer.minimumNumberOfTouches = drawing ? 2 : 1
        paging.isEnabled = !drawing
    }
    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) { onZoom?(scale) }

    @objc private func doubleTap(_ g: UITapGestureRecognizer) {
        if scroll.zoomScale > 1.02 {
            scroll.setZoomScale(1, animated: true)
            onZoom?(1)
        } else {
            let p = g.location(in: imageView)
            let s: CGFloat = 3
            let size = CGSize(width: scroll.bounds.width / s, height: scroll.bounds.height / s)
            scroll.zoom(to: CGRect(x: p.x - size.width / 2, y: p.y - size.height / 2, width: size.width, height: size.height), animated: true)
            onZoom?(s)
        }
    }

    @objc private func singleTap(_ g: UITapGestureRecognizer) {
        let p = g.location(in: imageView)
        let size = imageView.bounds.size
        let inside = p.x >= 0 && p.y >= 0 && p.x <= size.width && p.y <= size.height && size.width > 0
        onTap?(inside ? CGPoint(x: p.x / size.width, y: p.y / size.height) : nil)
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
            sideDir = 0
        case .changed:
            placeSide(t)
            // no neighbour that way: the photo resists
            let dx = side.image == nil ? t * 0.3 : t
            scroll.transform = CGAffineTransform(translationX: dx, y: 0)
            if side.image == nil { side.isHidden = true }
        default:
            let v = g.velocity(in: self).x
            let dir = t < 0 ? 1 : -1
            let go = side.image != nil && g.state == .ended && (abs(t) > bounds.width * 0.22 || abs(v) > 650) && (v == 0 || (v < 0) == (t < 0))
            if go {
                let shift = CGFloat(-dir) * (bounds.width + gap)
                let next = sideImage
                UIView.animate(withDuration: 0.24, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
                    self.scroll.transform = CGAffineTransform(translationX: shift, y: 0)
                    self.placeSide(shift)
                } completion: { _ in
                    // the neighbour becomes the photo without a flicker; its sharp picture follows
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
            } else {
                UIView.animate(withDuration: 0.22, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0, options: [.allowUserInteraction]) {
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

    func makeUIView(context: Context) -> PhotoViewer {
        let v = PhotoViewer()
        let model = self.model
        model.loupe.onViewer = { [weak v] p in v?.show(p.image) }
        let ed = model.editor
        v.overlay.onSpot = { p in ed.addSpot(p) }
        v.overlay.onSample = { p in ed.sampleColor(p, add: false) }
        v.overlay.onFocus = { u in ed.focus(at: u) }
        v.overlay.onStroke = { pts, pr in ed.stroke(pts, pressure: pr) }
        v.overlay.onShapeBegin = { ed.begin("Maschera") }
        v.overlay.onShape = { s in if let id = ed.selectedMask { ed.updateShape(id, s) } }
        v.overlay.onShapeEnd = { ed.end() }
        v.onPage = { by in model.step(by) }
        v.neighbor = { by in model.neighborPicture(by) }
        v.onTap = { p in
            if model.editor.picking, let p = p {
                model.editor.pickWhite(p)
            } else if model.editor.cursorTool == .none {
                withAnimation(Motion.panel) { model.chrome.toggle() }
            }
        }
        return v
    }

    func updateUIView(_ v: PhotoViewer, context: Context) {
        v.onZoom = onZoom
        let loupe = model.loupe
        if loupe.viewerKey != key {
            loupe.viewerKey = key
            v.reset(for: key ?? "")
            if let k = key { v.show(loupe.pics[k]?.image ?? model.library.shot(k)?.thumb) }
        } else if let k = key, loupe.pics[k] == nil, let t = model.library.shot(k)?.thumb {
            v.show(t)
        }
        v.hold(before)
        let ed = model.editor
        v.setTool(ed.cursorTool)
        v.overlay.crop = ed.crop
        v.overlay.spots = ed.spots
        v.overlay.maskInfo = ed.masks.first { $0.id == ed.selectedMask }
        v.overlay.brushSize = CGFloat(ed.brushSize)
        v.overlay.erasing = ed.erasing
    }
}
