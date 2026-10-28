import SwiftUI
import UIKit

/// A pressed control darkens a little, at once: no bounce.
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// A toolbar icon (Capture One's cursor tools and commands).
struct ToolIcon: View {
    let icon: String
    var active = false
    var enabled = true
    var size: CGFloat = 38
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .regular))
                .foregroundColor(active ? Lc.accent : (enabled ? Lc.text : Lc.text3.opacity(0.6)))
                .frame(width: size, height: size)
                .background(active ? Lc.pressed : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .disabled(!enabled)
    }
}

/// A flat button with a title (Capture One's grey push buttons).
struct FlatButton: View {
    let title: String
    var icon: String?
    var prominent = false
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon = icon { Image(systemName: icon).font(.system(size: 13, weight: .medium)) }
                Text(title).font(Typo.labelStrong).lineLimit(1)
            }
            .foregroundColor(prominent ? Color.black : Lc.text)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 34)
            .background(prominent ? Lc.select : Lc.raised)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(Lc.hairline, lineWidth: 0.5))
            .opacity(enabled ? 1 : 0.4)
        }
        .buttonStyle(PressStyle())
        .disabled(!enabled)
    }
}

/// Two or more choices side by side (Capture One's tool tabs and modes).
struct Segment: View {
    let options: [String]
    let selected: Int
    let onSelect: (Int) -> Void

    var body: some View {
        HStack(spacing: 1) {
            ForEach(Array(options.enumerated()), id: \.offset) { i, o in
                Button { onSelect(i) } label: {
                    Text(o).font(Typo.label)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .foregroundColor(i == selected ? Lc.text : Lc.text2)
                        .frame(maxWidth: .infinity, minHeight: 30)
                        .background(i == selected ? Lc.pressed : Lc.field)
                }
                .buttonStyle(.plain)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(Lc.hairline, lineWidth: 0.5))
    }
}

/// A switch on a row, the label on the left.
struct ToggleRow: View {
    let label: String
    let on: Bool
    var enabled = true
    let onChange: (Bool) -> Void

    var body: some View {
        HStack {
            Text(label).font(Typo.label).foregroundColor(Lc.text2)
            Spacer()
            Toggle("", isOn: Binding(get: { on }, set: { onChange($0) }))
                .labelsHidden()
                .toggleStyle(SwitchToggleStyle(tint: Lc.accent))
                .scaleEffect(0.8, anchor: .trailing)
        }
        .frame(height: 34)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }
}

/// A menu that looks like a field: the choice on the left, a chevron on the right.
struct MenuField<Items: View>: View {
    let label: String
    let value: String
    @ViewBuilder let items: Items

    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(Typo.label).foregroundColor(Lc.text2).frame(width: 100, alignment: .leading)
            Menu {
                items
            } label: {
                HStack {
                    Text(value).font(Typo.label).foregroundColor(Lc.text).lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundColor(Lc.text3)
                }
                .padding(.horizontal, 9)
                .frame(height: 28)
                .background(Lc.field)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).stroke(Lc.hairline, lineWidth: 0.5))
            }
        }
        .frame(height: 34)
    }
}

/// Five stars: tap one to rate, the same one again to clear.
struct StarRating: View {
    let rating: Int
    var size: CGFloat = 12
    var spacing: CGFloat = 3
    let onRate: (Int) -> Void

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(1...5, id: \.self) { n in
                Image(systemName: n <= rating ? "star.fill" : "star")
                    .font(.system(size: size, weight: .regular))
                    .foregroundColor(n <= rating ? Lc.star : Lc.text3)
                    .frame(width: size + 8, height: size + 10)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        Haptics.tick()
                        onRate(n == rating ? 0 : n)
                    }
            }
        }
    }
}

/// Stars as a read-only line (thumbnails).
struct Stars: View {
    let rating: Int
    var size: CGFloat = 7

    var body: some View {
        HStack(spacing: 1) {
            ForEach(0..<rating, id: \.self) { _ in
                Image(systemName: "star.fill").font(.system(size: size)).foregroundColor(Lc.star)
            }
        }
    }
}

/// The colour tags: tap one to tag, the same again to clear.
struct TagPicker: View {
    let tag: ColorTag?
    var size: CGFloat = 14
    let onTag: (ColorTag?) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(ColorTag.allCases) { t in
                Circle().fill(t.color)
                    .frame(width: size, height: size)
                    .overlay(Circle().stroke(Color.white, lineWidth: tag == t ? 2 : 0))
                    .frame(width: size + 10, height: size + 12)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        Haptics.tick()
                        onTag(tag == t ? nil : t)
                    }
            }
        }
    }
}

/// The link's state: a dot that breathes while it looks, steady once connected.
struct StatusDot: View {
    let color: Color
    let pulsing: Bool
    @State private var phase = false

    var body: some View {
        ZStack {
            if pulsing {
                Circle().fill(color.opacity(0.45)).frame(width: 8, height: 8)
                    .scaleEffect(phase ? 2.2 : 1).opacity(phase ? 0 : 1)
                    .animation(.easeOut(duration: 1.4).repeatForever(autoreverses: false), value: phase)
            }
            Circle().fill(color).frame(width: 6, height: 6)
        }
        .frame(width: 10, height: 10)
        .onAppear { phase = true }
    }
}

/// A ring that fills as a shot arrives.
struct ProgressRing: View {
    let fraction: Double
    var line: CGFloat = 2
    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.2), lineWidth: line)
            Circle().trim(from: 0, to: max(0.001, min(1, fraction)))
                .stroke(Color.white, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

/// A text field: label above, a quiet box.
struct Field: View {
    let label: String
    @Binding var text: String
    var placeholder = ""
    var secret = false
    @State private var shown = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
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
                        Image(systemName: shown ? "eye.slash" : "eye").font(.system(size: 13)).foregroundColor(Lc.text3)
                    }
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(Lc.field)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(focused ? Lc.accent.opacity(0.7) : Lc.hairline2, lineWidth: focused ? 1 : 0.5))
        }
    }
}

/// The app's mark: six blades around an opening.
struct ApertureLogo: View {
    var animated = true

    var body: some View {
        TimelineView(.animation(paused: !animated)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let s = min(size.width, size.height)
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let open = animated ? 0.40 + 0.05 * sin(t * 1.1) : 0.4
                let rot = animated ? t * 12 : 0
                aperture(ctx, c, s * 0.46, CGFloat(open), CGFloat(rot), max(1, s * 0.035))
            }
        }
    }

    private func aperture(_ ctx: GraphicsContext, _ c: CGPoint, _ big: CGFloat, _ opening: CGFloat, _ rotation: CGFloat, _ stroke: CGFloat) {
        ctx.stroke(Path(ellipseIn: CGRect(x: c.x - big, y: c.y - big, width: 2 * big, height: 2 * big)), with: .color(Lc.text.opacity(0.85)), lineWidth: stroke)
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
        ctx.stroke(path, with: .color(Lc.accent), style: StrokeStyle(lineWidth: stroke, lineCap: .round))
    }
}

/// A short message at the bottom of the screen.
struct Toast: View {
    let text: String
    var body: some View {
        Text(text).font(Typo.labelStrong).foregroundColor(Lc.text)
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(Lc.raised)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(Lc.hairline2, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
            .transition(.opacity)
    }
}

/// The link to the camera in the toolbar: a dot, the camera, RAW / JPEG, the transfer.
struct LinkStatus: View {
    @ObservedObject var tether: TetherLink
    let raw: Bool

    var body: some View {
        let (color, text, pulsing): (Color, String, Bool) = {
            switch tether.link {
            case .online(let m): return (Lc.live, m.isEmpty ? "Fotocamera" : m, false)
            case .joining: return (Lc.warn, "Wi-Fi…", true)
            case .searching: return (Lc.warn, "Ricerca", true)
            case .connecting: return (Lc.warn, "Collegamento", true)
            case .retrying: return (Lc.warn, "Ricollegamento", true)
            case .blocked: return (Lc.danger, "Da controllare", false)
            case .off: return (Lc.text3, "Scollegata", false)
            }
        }()
        return HStack(spacing: 7) {
            StatusDot(color: color, pulsing: pulsing)
            Text(text).font(Typo.labelStrong).foregroundColor(Lc.text).lineLimit(1)
            if case .online = tether.link {
                Text(raw ? "RAW" : "JPEG").font(Typo.micro).foregroundColor(Lc.text2)
                    .padding(.horizontal, 4).frame(height: 15)
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(Lc.hairline2, lineWidth: 0.5))
                if let t = tether.transfer {
                    ProgressRing(fraction: t.fraction, line: 1.5).frame(width: 13, height: 13)
                } else if tether.lastRate > 0 {
                    Text(String(format: "%.0f MB/s", tether.lastRate)).font(Typo.caption).foregroundColor(Lc.text3)
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(Lc.field)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(Lc.hairline, lineWidth: 0.5))
    }
}

/// The system's share sheet (Files, AirDrop, Lightroom…), over whatever is on screen (a sheet
/// included); on the iPad it is a popover, in the middle of the screen.
@MainActor
enum Share {
    static func present(_ urls: [URL]) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              let root = scene.windows.first(where: \.isKeyWindow)?.rootViewController ?? scene.windows.first?.rootViewController
        else { return }
        var top = root
        while let p = top.presentedViewController { top = p }
        let vc = UIActivityViewController(activityItems: urls, applicationActivities: nil)
        if let pop = vc.popoverPresentationController {
            pop.sourceView = top.view
            pop.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 1, height: 1)
            pop.permittedArrowDirections = []
        }
        top.present(vc, animated: true)
    }
}
