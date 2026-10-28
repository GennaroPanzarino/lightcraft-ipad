import SwiftUI

/// Pressing something shrinks it a little: touch feels physical.
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(Motion.snappy, value: configuration.isPressed)
    }
}

struct PrimaryButton: View {
    let title: String
    var icon: String?
    var enabled = true
    var busy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if busy {
                    ProgressView().tint(Lc.ink)
                } else {
                    HStack(spacing: 8) {
                        if let icon = icon { Image(systemName: icon).font(.system(size: 17, weight: .semibold)) }
                        Text(title).font(Typo.headline)
                    }
                    .foregroundColor(Lc.ink)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(Lc.amberGradient)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .opacity(enabled ? 1 : 0.4)
        }
        .buttonStyle(PressStyle())
        .disabled(!enabled || busy)
    }
}

struct SecondaryButton: View {
    let title: String
    var icon: String?
    var tint: Color = Lc.text
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon = icon { Image(systemName: icon) }
                Text(title).font(Typo.label)
            }
            .foregroundColor(tint)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(Lc.raised)
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Lc.hairline))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(PressStyle())
    }
}

/// A round glass button for the viewer's chrome.
struct GlassIcon: View {
    let icon: String
    var active = false
    var size: CGFloat = 46
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size * 0.38, weight: .medium))
                .foregroundColor(active ? Lc.ink : Lc.text)
                .frame(width: size, height: size)
                .background(active ? AnyShapeStyle(Lc.amber) : AnyShapeStyle(.ultraThinMaterial))
                .clipShape(Circle())
                .overlay(Circle().stroke(Lc.hairline))
        }
        .buttonStyle(PressStyle())
    }
}

struct Pill<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        HStack(spacing: 8) { content }
            .padding(.horizontal, 14)
            .frame(height: 38)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Lc.hairline))
            .environment(\.colorScheme, .dark)
    }
}

/// The link's state: a dot that breathes while it is looking, steady once connected.
struct StatusDot: View {
    let color: Color
    let pulsing: Bool
    @State private var phase = false

    var body: some View {
        ZStack {
            if pulsing {
                Circle().fill(color.opacity(0.45)).frame(width: 10, height: 10)
                    .scaleEffect(phase ? 2.4 : 1).opacity(phase ? 0 : 1)
                    .animation(.easeOut(duration: 1.4).repeatForever(autoreverses: false), value: phase)
            }
            Circle().fill(color).frame(width: 7, height: 7)
        }
        .frame(width: 12, height: 12)
        .onAppear { phase = true }
    }
}

/// A ring that fills as a shot arrives.
struct ProgressRing: View {
    let fraction: Double
    var line: CGFloat = 2.5
    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.2), lineWidth: line)
            Circle().trim(from: 0, to: max(0.001, min(1, fraction)))
                .stroke(Lc.amber, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(Motion.soft, value: fraction)
        }
    }
}

/// Two or more choices with a highlight that slides between them.
struct Segmented: View {
    let options: [String]
    let selected: Int
    let onSelect: (Int) -> Void
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { i, o in
                Button {
                    withAnimation(Motion.snappy) { onSelect(i) }
                } label: {
                    Text(o).font(Typo.label)
                        .foregroundColor(i == selected ? Lc.text : Lc.text3)
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .background {
                            if i == selected {
                                RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Lc.raised)
                                    .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(Lc.hairline2))
                                    .matchedGeometryEffect(id: "seg", in: ns)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Lc.night)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Lc.hairline))
    }
}

struct Chip: View {
    let text: String
    let on: Bool
    var icon: String?
    var accent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon = icon { Image(systemName: icon).font(.system(size: 13, weight: .semibold)) }
                Text(text).font(Typo.label)
            }
            .foregroundColor(on ? Lc.ink : (accent ? Lc.amber : Lc.text2))
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(on ? Lc.text : Lc.raised)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(on ? Color.clear : (accent ? Lc.amber.opacity(0.5) : Lc.hairline)))
        }
        .buttonStyle(PressStyle())
    }
}

/// A text field in the app's style: label above, quiet box, amber when focused.
struct Field: View {
    let label: String
    @Binding var text: String
    var placeholder = ""
    var secret = false
    @State private var shown = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label.uppercased()).overline()
            HStack {
                Group {
                    if secret && !shown {
                        SecureField(placeholder, text: $text)
                    } else {
                        TextField(placeholder, text: $text)
                    }
                }
                .focused($focused)
                .font(Typo.body)
                .foregroundColor(Lc.text)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                if secret {
                    Button { shown.toggle() } label: {
                        Image(systemName: shown ? "eye.slash" : "eye").foregroundColor(Lc.text3)
                    }
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 52)
            .background(Lc.night)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(focused ? Lc.amber.opacity(0.7) : Lc.hairline2))
            .animation(Motion.snappy, value: focused)
        }
    }
}

/// The app's mark: six blades around an opening, breathing slowly.
struct ApertureLogo: View {
    var animated = true

    var body: some View {
        TimelineView(.animation(paused: !animated)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let s = min(size.width, size.height)
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - s / 2, y: c.y - s / 2, width: s, height: s)), with: .linearGradient(Gradient(colors: [Color(hex: 0x26262C), Color(hex: 0x111114)]), startPoint: .zero, endPoint: CGPoint(x: s, y: s)))
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - s / 2, y: c.y - s / 2, width: s, height: s)), with: .color(.white.opacity(0.12)), lineWidth: 1)
                let open = animated ? 0.40 + 0.06 * sin(t * 1.2) : 0.4
                let rot = animated ? t * 15 : 0
                aperture(ctx, c, s * 0.33, CGFloat(open), CGFloat(rot), s * 0.032)
            }
        }
    }

    private func aperture(_ ctx: GraphicsContext, _ c: CGPoint, _ big: CGFloat, _ opening: CGFloat, _ rotation: CGFloat, _ stroke: CGFloat) {
        ctx.stroke(Path(ellipseIn: CGRect(x: c.x - big, y: c.y - big, width: 2 * big, height: 2 * big)), with: .color(Lc.amber), lineWidth: stroke)
        let small = big * opening
        let v: [CGPoint] = (0..<6).map { i in
            let a = (CGFloat(i) * 60 + rotation) * .pi / 180
            return CGPoint(x: c.x + small * cos(a), y: c.y + small * sin(a))
        }
        var path = Path()
        for i in 0..<6 {
            let p = v[i], q = v[(i + 1) % 6]
            let d = CGPoint(x: q.x - p.x, y: q.y - p.y)
            let len = sqrt(d.x * d.x + d.y * d.y)
            let u = CGPoint(x: d.x / len, y: d.y / len)
            let pc = CGPoint(x: p.x - c.x, y: p.y - c.y)
            let b = pc.x * u.x + pc.y * u.y
            let cc = pc.x * pc.x + pc.y * pc.y - big * big
            let t = -b + sqrt(max(b * b - cc, 0))
            path.move(to: p)
            path.addLine(to: CGPoint(x: p.x + u.x * t, y: p.y + u.y * t))
        }
        ctx.stroke(path, with: .color(Lc.amber), style: StrokeStyle(lineWidth: stroke, lineCap: .round))
    }
}

struct Toast: View {
    let text: String
    var body: some View {
        Pill { Text(text).font(Typo.label).foregroundColor(Lc.text) }
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
