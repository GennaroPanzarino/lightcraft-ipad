import SwiftUI

/// A develop slider: the name, the value, and a fine track. Dragging anywhere on the row moves it
/// (relative, so a finger never jumps the value); a double tap puts it back to its default, and a
/// light tick is felt when it passes there.
struct LcSlider: View {
    let control: Control
    let value: Double
    var label: String?
    let onChange: (Double) -> Void
    var onStart: () -> Void = {}
    var onEnd: () -> Void = {}

    @State private var dragging = false
    @State private var startValue = 0.0
    @State private var width: CGFloat = 1

    private var changed: Bool { abs(value - control.def) > control.step / 2 }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text(label ?? control.label).font(Typo.label).foregroundColor(dragging ? Lc.text : Lc.text2)
                Spacer()
                Text(control.format(value)).font(Typo.value).foregroundColor(dragging ? Lc.amber : (changed ? Lc.text : Lc.text3))
            }
            GeometryReader { geo in
                track(geo.size.width)
                    .onAppear { width = max(1, geo.size.width) }
                    .onChange(of: geo.size.width) { width = max(1, $0) }
            }
            .frame(height: 20)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            Haptics.confirm()
            onStart()
            onChange(control.def)
            onEnd()
        }
        .gesture(
            DragGesture(minimumDistance: 4)
                .onChanged { g in
                    if !dragging {
                        dragging = true
                        startValue = value
                        onStart()
                    }
                    let range = control.max - control.min
                    let raw = startValue + Double(g.translation.width / width) * range
                    let v = control.snap(raw)
                    if v != value {
                        let d = control.def
                        if (value - d) * (v - d) <= 0 { Haptics.tick() }
                        onChange(v)
                    }
                }
                .onEnded { _ in
                    dragging = false
                    onEnd()
                }
        )
    }

    private func track(_ w: CGFloat) -> some View {
        let range = control.max - control.min
        let f = CGFloat(max(0, min(1, (value - control.min) / range)))
        let zero = CGFloat(max(0, min(1, (0 - control.min) / range)))
        return ZStack(alignment: .leading) {
            switch control.track {
            case .gradient(let colors):
                Capsule().fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)).frame(height: 3)
            case .plain, .centered:
                Capsule().fill(Color.white.opacity(0.15)).frame(height: 3)
                let from: CGFloat = {
                    if case .centered = control.track, control.centered { return zero }
                    return 0
                }()
                Capsule().fill(Lc.amber)
                    .frame(width: max(0, abs(f - from) * w), height: 3)
                    .offset(x: min(from, f) * w)
            }
            if control.centered {
                Rectangle().fill(Color.white.opacity(0.4)).frame(width: 1, height: 10).offset(x: zero * w - 0.5)
            }
            Circle().fill(Color.white)
                .frame(width: 16, height: 16)
                .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                .background(Circle().fill(Lc.amber.opacity(dragging ? 0.25 : 0)).frame(width: 34, height: 34))
                .scaleEffect(dragging ? 1.25 : 1)
                .animation(Motion.bouncy, value: dragging)
                .offset(x: f * w - 8)
        }
        .frame(height: 20)
    }
}

/// A Color Grading wheel: the angle is the hue, the distance from the middle the saturation.
struct ColorWheel: View {
    let hue: Double
    let sat: Double
    let onChange: (Double, Double) -> Void
    var onStart: () -> Void = {}
    var onEnd: () -> Void = {}
    @State private var dragging = false
    private let hues: [Color] = stride(from: 0.0, through: 360.0, by: 60.0).map { Color(hue: $0.truncatingRemainder(dividingBy: 360) / 360, saturation: 1, brightness: 1) }

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            let r = s / 2 * 0.92
            let c = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            ZStack {
                Circle()
                    .fill(AngularGradient(gradient: Gradient(colors: hues), center: .center, startAngle: .degrees(0), endAngle: .degrees(360)))
                    .frame(width: 2 * r, height: 2 * r)
                Circle()
                    .fill(RadialGradient(colors: [Color(white: 0.74), Color(white: 0.74, opacity: 0)], center: .center, startRadius: 0, endRadius: r))
                    .frame(width: 2 * r, height: 2 * r)
                ForEach(1..<4) { k in
                    Circle().stroke(Color.white.opacity(0.12)).frame(width: 2 * r * CGFloat(k) / 4, height: 2 * r * CGFloat(k) / 4)
                }
                let a = hue * .pi / 180
                Circle().fill(Color(hue: hue / 360, saturation: max(0, min(1, sat / 100)), brightness: 1))
                    .frame(width: 18, height: 18)
                    .overlay(Circle().stroke(Color.white, lineWidth: 3))
                    .shadow(color: .black.opacity(0.5), radius: 3)
                    .scaleEffect(dragging ? 1.3 : 1)
                    .animation(Motion.bouncy, value: dragging)
                    .position(x: c.x + CGFloat(cos(a)) * r * CGFloat(sat / 100), y: c.y + CGFloat(sin(a)) * r * CGFloat(sat / 100))
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                Haptics.confirm()
                onStart(); onChange(hue, 0); onEnd()
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if !dragging { dragging = true; onStart() }
                        let d = CGPoint(x: g.location.x - c.x, y: g.location.y - c.y)
                        let sv = min(1, sqrt(d.x * d.x + d.y * d.y) / r) * 100
                        var h = atan2(d.y, d.x) * 180 / .pi
                        if h < 0 { h += 360 }
                        onChange(Double(h.rounded()).truncatingRemainder(dividingBy: 360), Double(sv.rounded()))
                    }
                    .onEnded { _ in dragging = false; onEnd() }
            )
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// The point curve: drag a point to move it, touch the line to add one, drag a point off the square to
/// take it away. The histogram sits behind.
struct CurveEditor: View {
    let points: CurvePoints
    let color: Color
    let histogram: Histogram?
    let onChange: (CurvePoints) -> Void
    var onStart: () -> Void = {}
    var onEnd: () -> Void = {}
    @State private var working: CurvePoints?
    @State private var active = -1

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let shown = working ?? points
            Canvas { ctx, size in
                ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 14), with: .color(Color(hex: 0x101013)))
                if let hist = histogram { drawHistogram(&ctx, hist, size, alpha: 0.5) }
                for k in 1..<4 {
                    var p = Path()
                    p.move(to: CGPoint(x: size.width * CGFloat(k) / 4, y: 0)); p.addLine(to: CGPoint(x: size.width * CGFloat(k) / 4, y: size.height))
                    p.move(to: CGPoint(x: 0, y: size.height * CGFloat(k) / 4)); p.addLine(to: CGPoint(x: size.width, y: size.height * CGFloat(k) / 4))
                    ctx.stroke(p, with: .color(.white.opacity(0.1)), lineWidth: 1)
                }
                var diag = Path()
                diag.move(to: CGPoint(x: 0, y: size.height)); diag.addLine(to: CGPoint(x: size.width, y: 0))
                ctx.stroke(diag, with: .color(.white.opacity(0.15)), lineWidth: 1)
                var curve = Path()
                for s in 0...64 {
                    let x = CGFloat(s) / 64
                    let y = max(0, min(1, curveAt(shown, x)))
                    let pt = CGPoint(x: x * size.width, y: (1 - y) * size.height)
                    if s == 0 { curve.move(to: pt) } else { curve.addLine(to: pt) }
                }
                ctx.stroke(curve, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                for (i, p) in shown.enumerated() {
                    let c = CGPoint(x: p.x * size.width, y: (1 - p.y) * size.height)
                    let big = i == active
                    let r: CGFloat = big ? 8 : 5.5
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x - r - 2, y: c.y - r - 2, width: 2 * r + 4, height: 2 * r + 4)), with: .color(.black.opacity(0.5)))
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(big ? Lc.amber : .white))
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { g in
                        if working == nil {
                            onStart()
                            var list = points
                            var i = nearest(list, g.startLocation, w, h)
                            if i < 0 {
                                let x = max(0.01, min(0.99, g.startLocation.x / w))
                                list.append(CGPoint(x: x, y: max(0, min(1, 1 - g.startLocation.y / h))))
                                list.sort { $0.x < $1.x }
                                i = list.firstIndex { $0.x == x } ?? -1
                                Haptics.tick()
                            }
                            working = list
                            active = i
                        }
                        guard var list = working, active >= 0, active < list.count else { return }
                        let i = active
                        let p = g.location
                        let off = p.y < -40 || p.y > h + 40 || p.x < -40 || p.x > w + 40
                        if off && i > 0 && i < list.count - 1 {
                            Haptics.confirm()
                            list.remove(at: i)
                            active = -1
                            working = list
                            onChange(list)
                            return
                        }
                        let lo = i == 0 ? 0 : list[i - 1].x + 0.01
                        let hi = i == list.count - 1 ? 1 : list[i + 1].x - 0.01
                        list[i] = CGPoint(x: max(lo, min(max(lo, hi), p.x / w)), y: max(0, min(1, 1 - p.y / h)))
                        working = list
                        onChange(list)
                    }
                    .onEnded { _ in
                        working = nil
                        active = -1
                        onEnd()
                    }
            )
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func nearest(_ pts: CurvePoints, _ o: CGPoint, _ w: CGFloat, _ h: CGFloat) -> Int {
        var best = -1
        var bd: CGFloat = 30
        for (i, p) in pts.enumerated() {
            let d = hypot(p.x * w - o.x, (1 - p.y) * h - o.y)
            if d < bd { bd = d; best = i }
        }
        return best
    }
}

func drawHistogram(_ ctx: inout GraphicsContext, _ hist: Histogram, _ size: CGSize, alpha: Double) {
    func channel(_ a: [CGFloat], _ c: Color) {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: size.height))
        for i in 0..<256 { p.addLine(to: CGPoint(x: CGFloat(i) / 255 * size.width, y: size.height - a[i] * size.height * 0.92)) }
        p.addLine(to: CGPoint(x: size.width, y: size.height))
        p.closeSubpath()
        ctx.fill(p, with: .color(c.opacity(alpha)))
    }
    ctx.blendMode = .screen
    channel(hist.r, Color(hex: 0xE5484D))
    channel(hist.g, Color(hex: 0x46B85A))
    channel(hist.b, Color(hex: 0x3E7BE6))
    ctx.blendMode = .normal
}

struct HistogramView: View {
    let histogram: Histogram?
    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 10), with: .color(Color(hex: 0x0B0B0E).opacity(0.8)))
            if let h = histogram { drawHistogram(&ctx, h, size, alpha: 0.85) }
        }
        .frame(width: 150, height: 58)
        .opacity(histogram == nil ? 0 : 1)
        .animation(.easeInOut(duration: 0.25), value: histogram == nil)
    }
}
