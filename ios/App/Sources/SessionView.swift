import SwiftUI

/// The session: the shot on screen (swipe for the others), the link, the strip of shots, and what to do
/// with the shot.
struct SessionView: View {
    @EnvironmentObject var model: AppModel
    @State private var chrome = true
    @State private var presetSheet = false
    @State private var settingsSheet = false
    @State private var zoomedKey: String?
    @State private var px = (w: 2048, h: 1536)

    private var visible: [Shot] { model.library.shots.filter { $0.stage != .failed } }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()
                if visible.isEmpty {
                    EmptyState(link: model.tether.link)
                } else {
                    TabView(selection: Binding(get: { model.current ?? visible.last?.key ?? "" }, set: { model.current = $0 })) {
                        ForEach(visible) { s in
                            ShotPage(shot: s, pic: model.loupe.pics[s.key], onTap: { withAnimation(Motion.soft) { chrome.toggle() } }) { z in
                                if z > 1.4 { zoomedKey = s.key } else if zoomedKey == s.key { zoomedKey = nil }
                            }
                            .tag(s.key)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .ignoresSafeArea()
                }
                VStack(spacing: 0) {
                    if chrome { top.transition(.move(edge: .top).combined(with: .opacity)) }
                    Spacer()
                    if chrome && !visible.isEmpty { bottom.transition(.move(edge: .bottom).combined(with: .opacity)) }
                }
                if let key = model.pendingEdit, key == model.current {
                    Pill {
                        ProgressView().tint(Lc.amber)
                        Text("Arriva il RAW: l'editor si apre da solo").font(Typo.label).foregroundColor(Lc.text)
                    }
                    .transition(.opacity)
                }
            }
            .onAppear { measure(geo) }
            .onChange(of: geo.size) { _ in measure(geo) }
        }
        .onAppear { want() }
        .onChange(of: model.current) { _ in want() }
        .onChange(of: model.library.shots.map { "\($0.key)/\($0.photo)/\($0.revision)" }) { _ in want() }
        .onChange(of: zoomedKey) { _ in want() }
        .sheet(isPresented: $presetSheet) { PresetSheet(shot: visible.first { $0.key == model.current }).environmentObject(model) }
        .sheet(isPresented: $settingsSheet) { SettingsSheet().environmentObject(model) }
    }

    private func measure(_ geo: GeometryProxy) {
        let s = UIScreen.main.scale
        px = (w: Int(geo.size.width * s), h: Int(geo.size.height * s))
        want()
    }

    /// The shot on screen at the screen's size (2560 at most: the raw's quick development), then its
    /// neighbours; a shot zoomed into gets the sharpest.
    private func want() {
        let w = min(2560, px.w), h = min(2560, px.h)
        model.library.screen = (w: w, h: h)
        let shots = visible
        guard let i = shots.firstIndex(where: { $0.key == (model.current ?? shots.last?.key) }) else { return }
        let order = [i, i + 1, i - 1].filter { $0 >= 0 && $0 < shots.count }.map { shots[$0] }
        model.loupe.show(order.filter { $0.photo != 0 }.map {
            $0.key == zoomedKey ? Loupe.Want(key: $0.key, photo: $0.photo, revision: $0.revision, w: 2560, h: 2560) : Loupe.Want(key: $0.key, photo: $0.photo, revision: $0.revision, w: w, h: h)
        })
    }

    private var top: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                LinkPill(link: model.tether.link, raw: model.settings.raw, transfer: model.tether.transfer, rate: model.tether.lastRate)
                    .onTapGesture { settingsSheet = true }
                Spacer()
                GlassIcon(icon: "square.grid.2x2") { model.go(.library) }
                GlassIcon(icon: "gearshape") { settingsSheet = true }
            }
            if let message = problem {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(Lc.warn)
                    Text(message).font(Typo.label).foregroundColor(Lc.text)
                    Spacer()
                }
                .padding(14)
                .background(Lc.raised.opacity(0.92))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Lc.warn.opacity(0.35)))
                .frame(maxWidth: 560)
                .onTapGesture { settingsSheet = true }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 14)
        .padding(.bottom, 30)
        .background(LinearGradient(colors: [.black.opacity(0.75), .clear], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
    }

    private var problem: String? {
        if case .blocked(let m) = model.tether.link { return m }
        return model.tether.warning
    }

    private var bottom: some View {
        let shot = visible.first { $0.key == model.current }
        return VStack(spacing: 14) {
            Filmstrip(shots: visible, current: model.current) { key in withAnimation(Motion.soft) { model.current = key } } onLong: { key in
                model.selection = [key]
                model.go(.library)
            }
            HStack(spacing: 12) {
                Button { presetSheet = true } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "sparkles").foregroundColor(Lc.amber)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Preset all'arrivo").font(Typo.caption).foregroundColor(Lc.text3)
                            Text(model.presets.first { $0.id == model.settings.preset }?.name ?? "Nessun preset").font(Typo.label).foregroundColor(Lc.text).lineLimit(1)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .frame(width: 300, height: 58)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Lc.hairline))
                }
                .buttonStyle(PressStyle())
                Spacer()
                Button {
                    if let s = shot { model.selection = [s.key] }
                    model.go(.library)
                } label: {
                    Image(systemName: "square.and.arrow.down").font(.system(size: 20, weight: .medium)).foregroundColor(Lc.text)
                        .frame(width: 58, height: 58)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Lc.hairline))
                }
                .buttonStyle(PressStyle())
                Button { if let s = shot { model.openEditor(s.key) } } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "slider.horizontal.3").font(.system(size: 18, weight: .semibold))
                        Text("Modifica").font(Typo.headline)
                    }
                    .foregroundColor(Lc.ink)
                    .padding(.horizontal, 22)
                    .frame(height: 58)
                    .background(Lc.amberGradient)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(PressStyle())
                .opacity(shot == nil ? 0.4 : 1)
            }
            .padding(.horizontal, 24)
        }
        .padding(.top, 34)
        .padding(.bottom, 16)
        .environment(\.colorScheme, .dark)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.8), .black.opacity(0.92)], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
    }
}

struct ShotPage: View {
    let shot: Shot
    let pic: Pic?
    let onTap: () -> Void
    let onZoom: (CGFloat) -> Void

    var body: some View {
        ZStack {
            ZoomView(image: pic?.image ?? shot.thumb, key: shot.key, onTap: { _ in onTap() }, onZoom: onZoom)
            if shot.stage == .arriving && shot.thumb == nil && pic == nil {
                VStack(spacing: 14) {
                    ZStack {
                        ProgressRing(fraction: shot.progress, line: 3).frame(width: 64, height: 64)
                        Image(systemName: "camera").foregroundColor(Lc.text2)
                    }
                    Text(shot.name).font(Typo.label).foregroundColor(Lc.text2)
                }
            }
        }
    }
}

struct EmptyState: View {
    let link: Link

    var body: some View {
        let (title, detail): (String, String) = {
            switch link {
            case .online(let m): return ("Pronta a scattare", "Scatta con la \(m): la foto appare qui in un istante, con il tuo preset.")
            case .joining: return ("Connessione al Wi-Fi", "L'iPad si sta collegando alla rete della fotocamera.")
            case .searching: return ("In attesa della fotocamera", "Accendila e attiva Controllo remoto PC: si collega da sola.")
            case .connecting: return ("Collegamento…", "Accesso alla fotocamera in corso.")
            case .retrying: return ("Ricollegamento…", "Il segnale si è interrotto: riprovo da solo.")
            case .blocked(let m): return ("Serve un controllo", m)
            case .off: return ("Non collegato", "Apri le impostazioni per collegare la fotocamera.")
            }
        }()
        return VStack(spacing: 18) {
            ApertureLogo().frame(width: 128, height: 128)
            Text(title).font(Typo.title).foregroundColor(Lc.text).padding(.top, 18)
            Text(detail).font(Typo.body).foregroundColor(Lc.text2).multilineTextAlignment(.center).frame(maxWidth: 420)
        }
        .padding(40)
        .animation(Motion.soft, value: title)
    }
}

struct LinkPill: View {
    let link: Link
    let raw: Bool
    let transfer: Transfer?
    let rate: Double

    var body: some View {
        let (color, text, pulsing): (Color, String, Bool) = {
            switch link {
            case .online(let m): return (Lc.live, m.isEmpty ? "Fotocamera" : m, false)
            case .joining: return (Lc.amber, "Wi-Fi…", true)
            case .searching: return (Lc.amber, "Ricerca", true)
            case .connecting: return (Lc.amber, "Collegamento", true)
            case .retrying: return (Lc.warn, "Ricollegamento", true)
            case .blocked: return (Lc.danger, "Da controllare", false)
            case .off: return (Lc.text3, "Scollegata", false)
            }
        }()
        return Pill {
            StatusDot(color: color, pulsing: pulsing)
            Text(text).font(Typo.label).foregroundColor(Lc.text)
            if case .online = link {
                Circle().fill(Lc.text3).frame(width: 3, height: 3)
                Text(raw ? "RAW" : "JPEG").font(Typo.label).foregroundColor(Lc.amber)
                if let t = transfer {
                    ProgressRing(fraction: t.fraction, line: 2).frame(width: 16, height: 16)
                } else if rate > 0 {
                    Text(String(format: "%.0f MB/s", rate)).font(Typo.caption).foregroundColor(Lc.text3)
                }
            }
        }
    }
}

struct Filmstrip: View {
    let shots: [Shot]
    let current: String?
    let onPick: (String) -> Void
    let onLong: (String) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 10) {
                    ForEach(shots) { s in
                        let on = s.key == current
                        ZStack {
                            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Lc.raised)
                            if let t = s.thumb {
                                Image(decorative: t, scale: 1).resizable().scaledToFill()
                            }
                            if s.stage == .arriving || s.stage == .preview {
                                Color.black.opacity(0.4)
                                ProgressRing(fraction: s.progress, line: 2).frame(width: 22, height: 22)
                            }
                        }
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(on ? Lc.amber : .clear, lineWidth: 2))
                        .scaleEffect(on ? 1.08 : 1)
                        .animation(Motion.bouncy, value: on)
                        .id(s.key)
                        .onTapGesture { onPick(s.key) }
                        .onLongPressGesture { onLong(s.key) }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 6)
            }
            .frame(height: 78)
            .onChange(of: current) { k in
                if let k = k { withAnimation(Motion.soft) { proxy.scrollTo(k, anchor: .center) } }
            }
        }
    }
}
