import SwiftUI
import UIKit

/// The photo in the viewer: pinch to zoom (up to 5×), double tap to look closer and back, drag to
/// look around once zoomed — the system's own scroll view, with its inertia and bounce. Not zoomed,
/// a swipe goes to the next or previous shot. Pictures arrive straight from the engine (`show`), not
/// through SwiftUI.
final class PhotoViewer: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    var onTap: ((CGPoint?) -> Void)?
    var onZoom: ((CGFloat) -> Void)?
    var onSwipe: ((Int) -> Void)?

    private let scroll = UIScrollView()
    private let imageView = UIImageView()
    private var key = ""
    private var current: CGImage?
    private var held: CGImage?
    private var fitted = CGSize.zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        scroll.delegate = self
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 5
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
        let double = UITapGestureRecognizer(target: self, action: #selector(doubleTap(_:)))
        double.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(double)
        let single = UITapGestureRecognizer(target: self, action: #selector(singleTap(_:)))
        single.require(toFail: double)
        scroll.addGestureRecognizer(single)
        for d in [UISwipeGestureRecognizer.Direction.left, .right] {
            let s = UISwipeGestureRecognizer(target: self, action: #selector(swiped(_:)))
            s.direction = d
            s.delegate = self
            scroll.addGestureRecognizer(s)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        if g is UISwipeGestureRecognizer { return scroll.zoomScale <= 1.01 }
        return true
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        g is UISwipeGestureRecognizer
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
        let first = current == nil
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
            UIView.transition(with: imageView, duration: 0.18, options: [.transitionCrossDissolve, .allowUserInteraction]) {
                self.imageView.image = ui
            }
        } else {
            imageView.image = ui
        }
        layoutImage(force: false)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scroll.frame = bounds
        layoutImage(force: false)
    }

    private func layoutImage(force: Bool) {
        guard let img = imageView.image, bounds.width > 0, bounds.height > 0 else { return }
        let b = bounds.size
        let a = img.size.width / max(1, img.size.height)
        let fit = b.width / b.height > a ? CGSize(width: b.height * a, height: b.height) : CGSize(width: b.width, height: b.width / a)
        if force || abs(fit.width - fitted.width) > 0.5 || abs(fit.height - fitted.height) > 0.5 {
            fitted = fit
            let zoom = scroll.zoomScale
            scroll.zoomScale = 1
            imageView.frame = CGRect(origin: .zero, size: fit)
            scroll.contentSize = fit
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
    func scrollViewDidZoom(_ scrollView: UIScrollView) { center() }
    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) { onZoom?(scale) }

    @objc private func doubleTap(_ g: UITapGestureRecognizer) {
        if scroll.zoomScale > 1.02 {
            scroll.setZoomScale(1, animated: true)
            onZoom?(1)
        } else {
            let p = g.location(in: imageView)
            let s: CGFloat = 2.5
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

    @objc private func swiped(_ g: UISwipeGestureRecognizer) {
        onSwipe?(g.direction == .left ? 1 : -1)
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
        v.onSwipe = { by in model.step(by) }
        v.onTap = { p in
            if model.editor.picking, let p = p { model.editor.pickWhite(p) }
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
    }
}
