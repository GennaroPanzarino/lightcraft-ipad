import SwiftUI
import UIKit

/// A photo fitted into the view: pinch to zoom (up to 5×), double tap to look closer and back, drag to
/// look around once zoomed — the system's own scroll view, with its inertia and bounce. Not zoomed, a
/// swipe is left to the pager around it.
struct ZoomView: UIViewRepresentable {
    let image: CGImage?
    /// A new photo (zoom back to fit); the same photo with a new picture keeps the zoom.
    let key: String
    var onTap: ((CGPoint?) -> Void)?
    /// The zoom a gesture ended at.
    var onZoom: ((CGFloat) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIScrollView {
        let v = UIScrollView()
        v.delegate = context.coordinator
        v.minimumZoomScale = 1
        v.maximumZoomScale = 5
        v.showsVerticalScrollIndicator = false
        v.showsHorizontalScrollIndicator = false
        v.contentInsetAdjustmentBehavior = .never
        v.decelerationRate = .fast
        v.backgroundColor = .clear
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFit
        iv.isUserInteractionEnabled = true
        v.addSubview(iv)
        context.coordinator.scroll = v
        context.coordinator.imageView = iv
        let double = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        double.numberOfTapsRequired = 2
        v.addGestureRecognizer(double)
        let single = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.singleTap(_:)))
        single.require(toFail: double)
        v.addGestureRecognizer(single)
        return v
    }

    func updateUIView(_ v: UIScrollView, context: Context) {
        let c = context.coordinator
        c.onTap = onTap
        c.onZoom = onZoom
        if c.key != key {
            c.key = key
            v.setZoomScale(1, animated: false)
        }
        if let image = image, c.current !== image {
            c.current = image
            UIView.transition(with: c.imageView, duration: c.imageView.image == nil ? 0.25 : 0, options: .transitionCrossDissolve) {
                c.imageView.image = UIImage(cgImage: image)
            }
            c.layout()
        }
        DispatchQueue.main.async { c.layout() }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var scroll: UIScrollView!
        var imageView: UIImageView!
        var key = ""
        var current: CGImage?
        var onTap: ((CGPoint?) -> Void)?
        var onZoom: ((CGFloat) -> Void)?
        private var bounds = CGSize.zero

        /// The picture fitted at zoom 1, centred.
        func layout() {
            guard let s = scroll, let img = imageView.image, s.bounds.width > 0 else { return }
            let b = s.bounds.size
            if b != bounds || imageView.frame.isEmpty {
                bounds = b
                let zoom = s.zoomScale
                s.zoomScale = 1
                let a = img.size.width / max(1, img.size.height)
                let fit = b.width / b.height > a ? CGSize(width: b.height * a, height: b.height) : CGSize(width: b.width, height: b.width / a)
                imageView.frame = CGRect(origin: .zero, size: fit)
                s.contentSize = fit
                s.zoomScale = zoom
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

        @objc func doubleTap(_ g: UITapGestureRecognizer) {
            if scroll.zoomScale > 1.02 {
                scroll.setZoomScale(1, animated: true)
                onZoom?(1)
            } else {
                let p = g.location(in: imageView)
                let s: CGFloat = 2.5
                let size = CGSize(width: scroll.bounds.width / s, height: scroll.bounds.height / s)
                scroll.zoom(to: CGRect(x: p.x - size.width / 2, y: p.y - size.height / 2, width: size.width, height: size.height), animated: true)
            }
        }

        @objc func singleTap(_ g: UITapGestureRecognizer) {
            let p = g.location(in: imageView)
            let size = imageView.bounds.size
            let inside = p.x >= 0 && p.y >= 0 && p.x <= size.width && p.y <= size.height && size.width > 0
            onTap?(inside ? CGPoint(x: p.x / size.width, y: p.y / size.height) : nil)
        }
    }
}
