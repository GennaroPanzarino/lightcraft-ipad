import SwiftUI
import UIKit

/// Capture One's main window on the iPad: the toolbar, the tools in a column at the side, the photo,
/// the shots in a strip under it. Tethering happens here: each new shot lands in the strip and on
/// screen, ready to be developed in the column. A tap on the photo hides the toolbar and the column
/// together (and brings them back).
struct Workspace: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var ed: EditorModel
    @State private var before: CGImage?
    @State private var exportOpen = false

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            let panelW: CGFloat = landscape ? 350 : 320
            let tools = model.toolsShown && model.chrome
            VStack(spacing: 0) {
                if model.chrome {
                    WorkspaceBar(ed: ed, before: $before, export: $exportOpen)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                HStack(spacing: 0) {
                    if tools && model.settings.toolsOnLeft {
                        ToolPanel(ed: ed).frame(width: panelW)
                            .transition(.move(edge: .leading))
                        Rectangle().fill(Lc.line).frame(width: 1)
                    }
                    VStack(spacing: 0) {
                        ViewerArea(library: model.library, ed: ed, before: before)
                        Filmstrip(library: model.library, current: model.current)
                    }
                    if tools && !model.settings.toolsOnLeft {
                        Rectangle().fill(Lc.line).frame(width: 1)
                        ToolPanel(ed: ed).frame(width: panelW)
                            .transition(.move(edge: .trailing))
                    }
                }
            }
        }
        .background(Lc.window.ignoresSafeArea())
        .background(KeyCommands(ed: ed, export: $exportOpen))
        .sheet(isPresented: Binding(get: { exportOpen || (model.export != nil && model.screen == .workspace) }, set: { if !$0 { exportOpen = false; if model.export?.finished != false { model.export = nil } } })) {
            ExportSheet(keys: model.current.map { [$0] } ?? []) { exportOpen = false }.environmentObject(model)
        }
    }
}

/// A keyboard's shortcuts (Lightroom's): ⌘Z / ⇧⌘Z undo and redo, the arrows go through the shots,
/// 0–5 rate, P picks, X rejects, U unflags, ⌘E exports, Esc leaves the cursor tool.
private struct KeyCommands: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var ed: EditorModel
    @Binding var export: Bool
    /// A field is being typed in: the plain keys are its own.
    @State private var typing = false

    var body: some View {
        ZStack {
            key("z", .command) { ed.undo() }
            key("z", [.command, .shift]) { ed.redo() }
            key("e", .command) { export = true }
            Group {
                key(.leftArrow, []) { model.step(-1) }
                key(.rightArrow, []) { model.step(1) }
                key(.escape, []) {
                    if ed.cursorTool == .crop { ed.exitCrop() } else { ed.cursorTool = .none }
                    ed.picking = false
                }
                ForEach(0..<6) { n in
                    key(KeyEquivalent(Character("\(n)")), []) { if let k = model.current { model.rate([k], n) } }
                }
                key("p", []) { if let k = model.current { model.flag([k], "pick") } }
                key("x", []) { if let k = model.current { model.flag([k], "reject") } }
                key("u", []) { if let k = model.current { model.flag([k], "none") } }
            }
            .disabled(typing)
        }
        .onReceive(NotificationCenter.default.publisher(for: UITextField.textDidBeginEditingNotification)) { _ in typing = true }
        .onReceive(NotificationCenter.default.publisher(for: UITextField.textDidEndEditingNotification)) { _ in typing = false }
        .frame(width: 0, height: 0)
        .opacity(0)
        .allowsHitTesting(false)
    }

    private func key(_ k: KeyEquivalent, _ m: EventModifiers, _ action: @escaping () -> Void) -> some View {
        Button("", action: action).keyboardShortcut(k, modifiers: m)
    }
}

/// Room above the toolbars for iPadOS's own window controls (the three dots at the top).
let windowControlsInset: CGFloat = 12

/// The toolbar: the library and the tools on the left, the photo's name and rating in the middle,
/// the commands and the camera on the right.
private struct WorkspaceBar: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var ed: EditorModel
    @Binding var before: CGImage?
    @Binding var export: Bool
    /// The two groups of buttons and the bar, measured: the title gets the room between them.
    @State private var left: CGFloat = 0
    @State private var right: CGFloat = 0
    @State private var total: CGFloat = 0

    var body: some View {
        // the title stays in the middle of the bar, in what the wider side leaves of it
        let room = max(0, total - 16 - 2 * max(left, right) - 20)
        ZStack {
            HStack(spacing: 0) {
                leading.background(Measure(side: 0))
                Spacer(minLength: 8)
                trailing.background(Measure(side: 1))
            }
            if room > 40 {
                CurrentTitle(library: model.library, key: model.current, room: room)
                    .frame(width: room)
            }
        }
        .onPreferenceChange(BarSides.self) { w in
            left = w[0] ?? left
            right = w[1] ?? right
        }
        .padding(.horizontal, 8)
        .frame(height: 48)
        .background(GeometryReader { g in
            Color.clear
                .onAppear { total = g.size.width }
                .onChange(of: g.size.width) { total = $0 }
        })
        .padding(.top, windowControlsInset)
        .background(Lc.header)
        .overlay(Rectangle().fill(Lc.line).frame(height: 1), alignment: .bottom)
    }

    private var leading: some View {
        HStack(spacing: 2) {
            ToolIcon(icon: "house") { model.goHome() }
            ToolIcon(icon: model.settings.toolsOnLeft ? "sidebar.left" : "sidebar.right", active: !model.toolsShown) {
                withAnimation(Motion.chrome) { model.toolsShown.toggle() }
            }
            Rectangle().fill(Lc.hairline2).frame(width: 1, height: 22).padding(.horizontal, 6)
            ToolIcon(icon: "eyedropper", active: ed.picking, enabled: ed.photo != 0) {
                ed.cursorTool = ed.cursorTool == .crop ? .none : ed.cursorTool
                ed.picking.toggle()
            }
            ToolIcon(icon: "crop", active: ed.cursorTool == .crop, enabled: ed.photo != 0) {
                if ed.cursorTool == .crop { ed.exitCrop() } else { ed.enterCrop() }
            }
            ToolIcon(icon: "bandage", active: ed.cursorTool == .spot, enabled: ed.photo != 0) {
                ed.picking = false
                if ed.cursorTool == .crop { ed.exitCrop() }
                ed.cursorTool = ed.cursorTool == .spot ? .none : .spot
            }
            ToolIcon(icon: "paintbrush.pointed", active: ed.cursorTool == .paint, enabled: ed.photo != 0) {
                ed.picking = false
                if ed.cursorTool == .crop { ed.exitCrop() }
                if ed.cursorTool == .paint {
                    ed.cursorTool = .none
                } else if let m = ed.masks.first(where: { $0.id == ed.selectedMask }), m.part(ed.selectedPart)?.kind == "brush" {
                    ed.cursorTool = .paint
                } else {
                    ed.addMask("brush")
                }
            }
            BeforeButton(ed: ed, before: $before)
        }
    }

    private var trailing: some View {
        HStack(spacing: 2) {
            ToolIcon(icon: "arrow.uturn.backward", enabled: ed.canUndo) { ed.undo() }
            // apart, so a thumb never takes one for the other
            Spacer().frame(width: 18)
            ToolIcon(icon: "arrow.uturn.forward", enabled: ed.canRedo) { ed.redo() }
            Spacer().frame(width: 6)
            Menu {
                Button(role: .destructive) { ed.reset() } label: { Label("Azzera tutte le regolazioni", systemImage: "arrow.counterclockwise") }
            } label: {
                Image(systemName: "arrow.counterclockwise").font(.system(size: 17)).foregroundColor(ed.photo != 0 ? Lc.text : Lc.text3)
                    .frame(width: 38, height: 38)
            }
            .disabled(ed.photo == 0)
            ToolIcon(icon: "square.and.arrow.up", enabled: ed.photo != 0) { export = true }
            Rectangle().fill(Lc.hairline2).frame(width: 1, height: 22).padding(.horizontal, 6)
            Button { model.openSettings = true } label: {
                LinkStatus(tether: model.tether, raw: model.settings.raw)
            }
            .buttonStyle(PressStyle())
        }
    }
}

/// The widths of the toolbar's two groups of buttons (0: leading, 1: trailing).
private struct BarSides: PreferenceKey {
    static var defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue()) { $1 }
    }
}

private struct Measure: View {
    let side: Int
    var body: some View {
        GeometryReader { g in Color.clear.preference(key: BarSides.self, value: [side: g.size.width]) }
    }
}

/// Hold to see the photo before its edits.
private struct BeforeButton: View {
    @ObservedObject var ed: EditorModel
    @Binding var before: CGImage?
    @State private var holding = false

    var body: some View {
        Image(systemName: "rectangle.lefthalf.inset.filled")
            .font(.system(size: 17))
            .foregroundColor(holding ? Lc.accent : (ed.photo != 0 ? Lc.text : Lc.text3))
            .frame(width: 38, height: 38)
            .background(holding ? Lc.pressed : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !holding, ed.photo != 0 else { return }
                        holding = true
                        Task {
                            let img = await ed.before()
                            if holding { before = img }
                        }
                    }
                    .onEnded { _ in
                        holding = false
                        before = nil
                    }
            )
    }
}

/// The photo's name and its rating (tap the stars to rate), in the middle of the toolbar, within
/// `room` points (the name shortens, then the stars give way).
private struct CurrentTitle: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var library: Library
    let key: String?
    let room: CGFloat

    var body: some View {
        let shot = key.flatMap { library.shot($0) }
        HStack(spacing: 10) {
            if let t = shot?.label { Circle().fill(t.color).frame(width: 9, height: 9) }
            Text(shot?.name ?? "LightCraft").font(Typo.labelStrong).foregroundColor(Lc.text).lineLimit(1).truncationMode(.middle)
                .layoutPriority(1)
            if let s = shot, s.photo != 0, room >= 190 {
                StarRating(rating: s.rating, size: 11, spacing: -4) { model.rate([s.key], $0) }
                    .fixedSize()
            }
        }
    }
}

/// The photo, its pictures straight from the engine; what is shown while a shot arrives.
private struct ViewerArea: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var library: Library
    @ObservedObject var ed: EditorModel
    let before: CGImage?
    @State private var px = (w: 2048, h: 1536)
    @State private var zoomed = false

    var body: some View {
        let shots = library.shots.filter { $0.stage != .failed }
        let shot = model.current.flatMap { library.shot($0) }
        GeometryReader { geo in
            ZStack {
                Lc.viewer
                if shots.isEmpty {
                    EmptyViewer(tether: model.tether)
                } else {
                    // the viewer stays (with its picture) under the crop tool, which takes its
                    // place once the uncropped photo is ready
                    let cropping = ed.cursorTool == .crop && ed.uncropped != nil
                    ViewerHost(model: model, key: model.current, onZoom: { z in zoomed = z > 1.4 }, before: before ?? (ed.showDepth ? ed.depthImage : nil) ?? (ed.visualizeSpots ? ed.spotMap : nil),
                               hidden: model.hero != nil || cropping)
                    if cropping {
                        CropHost(ed: ed)
                    }
                    if let s = shot, s.stage == .arriving && s.thumb == nil && model.loupe.pics[s.key] == nil {
                        VStack(spacing: 10) {
                            ProgressRing(fraction: s.progress, line: 2.5).frame(width: 44, height: 44)
                            Text(s.name).font(Typo.label).foregroundColor(Lc.text2)
                        }
                    }
                }
                VStack {
                    if ed.picking {
                        Text("Tocca un punto neutro per il bilanciamento del bianco")
                            .font(Typo.labelStrong).foregroundColor(Lc.text)
                            .padding(.horizontal, 12).frame(height: 30)
                            .background(Lc.raised.opacity(0.95))
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                            .padding(.top, model.chrome ? 12 : 12 + windowControlsInset)
                    }
                    Spacer()
                    if ed.cursorTool == .crop {
                        CropBar(ed: ed)
                            .padding(.bottom, 14)
                    } else if let w = ed.working {
                        HStack(spacing: 8) {
                            ProgressView().progressViewStyle(.circular).scaleEffect(0.7).frame(width: 16, height: 16)
                            Text(w).font(Typo.labelStrong).foregroundColor(Lc.text)
                        }
                        .padding(.horizontal, 12).frame(height: 30)
                        .background(Lc.raised.opacity(0.95))
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .padding(.bottom, 12)
                    } else if [.spot, .paint, .shape, .sample, .focus, .refine].contains(ed.cursorTool) {
                        Text(toolHint(ed.cursorTool))
                            .font(Typo.labelStrong).foregroundColor(Lc.text)
                            .padding(.horizontal, 12).frame(height: 30)
                            .background(Lc.raised.opacity(0.95))
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                            .padding(.bottom, 12)
                    }
                    if before != nil {
                        Text("PRIMA").font(Typo.group).tracking(1).foregroundColor(Lc.text)
                            .padding(.horizontal, 10).frame(height: 24)
                            .background(Color.black.opacity(0.6))
                            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                            .padding(.bottom, 12)
                    }
                }
            }
            .onAppear { measure(geo) }
            .onChange(of: geo.size) { _ in measure(geo) }
        }
        .onAppear { want() }
        .onChange(of: model.current) { _ in want() }
        .onChange(of: library.shots.map { "\($0.key)/\($0.photo)/\($0.revision)" }) { _ in want() }
        .onChange(of: zoomed) { _ in want() }
    }

    private func measure(_ geo: GeometryProxy) {
        let s = UIScreen.main.scale
        px = (w: Int(geo.size.width * s), h: Int(geo.size.height * s))
        ed.viewport = (w: min(4096, px.w), h: min(4096, px.h))
        model.viewerFrame = geo.frame(in: .global)
        model.viewerMeasures += 1
        want()
    }

    /// The shot on screen at the viewer's size (full size when zoomed into), then its neighbours.
    private func want() {
        let w = min(2560, px.w), h = min(2560, px.h)
        library.screen = (w: w, h: h)
        let shots = library.shots.filter { $0.stage != .failed }
        guard let i = shots.firstIndex(where: { $0.key == (model.current ?? shots.last?.key) }) else { return }
        let order = [i, i + 1, i - 1].filter { $0 >= 0 && $0 < shots.count }.map { shots[$0] }
        model.loupe.show(order.filter { $0.photo != 0 }.map { s in
            Loupe.Want(key: s.key, photo: s.photo, revision: s.revision, w: w, h: h)
        })
    }
}

private func toolHint(_ t: CursorTool) -> String {
    switch t {
    case .spot: return "Tocca una macchia per rimuoverla · due dita per zoomare"
    case .paint: return "Dipingi la maschera · due dita per zoomare"
    case .shape: return "Trascina le maniglie del gradiente"
    case .sample: return "Tocca il colore da selezionare"
    case .focus: return "Tocca ciò che va a fuoco, o traccia un riquadro"
    case .refine: return "Dipingi ciò che va a fuoco o sfocato · due dita per zoomare"
    default: return ""
    }
}

/// The crop tool's commands under the photo.
private struct CropBar: View {
    @ObservedObject var ed: EditorModel
    private let ratios: [(String, String)] = [
        ("original", "Originale"), ("free", "Libero"), ("1x1", "1:1"), ("4x5", "4:5"), ("5x7", "5:7"),
        ("2x3", "2:3"), ("4x3", "4:3"), ("16x9", "16:9"), ("16x10", "16:10"),
    ]

    var body: some View {
        HStack(spacing: 4) {
            Menu {
                ForEach(ratios, id: \.0) { r in Button(r.1) { ed.run("crop.aspect", ["aspect": r.0]) } }
            } label: {
                Label(aspectName(ed.cropAspect), systemImage: "aspectratio")
                    .font(Typo.labelStrong).foregroundColor(Lc.text)
                    .padding(.horizontal, 10).frame(height: 34)
            }
            ToolIcon(icon: "rotate.right") { ed.run("crop.rotateAspect") }
            ToolIcon(icon: "level") { ed.run("crop.autoStraighten") }
            ToolIcon(icon: "arrow.counterclockwise") { ed.run("crop.reset") }
            Rectangle().fill(Lc.hairline2).frame(width: 1, height: 22).padding(.horizontal, 4)
            Button { ed.exitCrop() } label: {
                Text("Fine").font(Typo.labelStrong).foregroundColor(.black)
                    .padding(.horizontal, 16).frame(height: 32)
                    .background(Lc.select)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            .buttonStyle(PressStyle())
        }
        .padding(.horizontal, 8)
        .frame(height: 46)
        .background(Lc.header.opacity(0.96))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Lc.hairline2, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
    }
}

/// No shots yet: where the link is.
private struct EmptyViewer: View {
    @ObservedObject var tether: TetherLink
    @Environment(\.screenShown) private var shown

    var body: some View {
        let (title, detail): (String, String) = {
            switch tether.link {
            case .online(let m): return ("Pronta a scattare", "Scatta con la \(m): la foto arriva qui in un istante, già con le regolazioni del prossimo scatto.")
            case .joining: return ("Connessione al Wi-Fi", "L'iPad si sta collegando alla rete della fotocamera.")
            case .searching: return ("In attesa della fotocamera", "Accendila e attiva Controllo remoto PC: si collega da sola.")
            case .connecting: return ("Collegamento…", "Accesso alla fotocamera in corso.")
            case .retrying: return ("Ricollegamento…", "Il segnale si è interrotto: riprovo da solo.")
            case .blocked(let m): return ("Serve un controllo", m)
            case .off: return ("Non collegata", "Tocca lo stato della fotocamera in alto per collegarla.")
            }
        }()
        return VStack(spacing: 14) {
            ApertureLogo(animated: shown).frame(width: 64, height: 64)
            Text(title).font(Typo.title).foregroundColor(Lc.text)
            Text(detail).font(Typo.body).foregroundColor(Lc.text2).multilineTextAlignment(.center).frame(maxWidth: 380)
        }
        .padding(30)
    }
}

private struct StripFrames: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// The session's shots under the photo, thumbnail against thumbnail: tap to show one; hold a
/// thumbnail and slide the finger along the strip to run through the shots.
struct Filmstrip: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var library: Library
    let current: String?
    @State private var frames: [String: CGRect] = [:]
    @State private var scrubbing = false

    var body: some View {
        let shots = library.shots.filter { $0.stage != .failed }
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 2) {
                    ForEach(shots) { s in
                        StripCell(shot: s, on: s.key == current)
                            .id(s.key)
                            .background(GeometryReader { g in
                                Color.clear.preference(key: StripFrames.self, value: [s.key: g.frame(in: .named("strip"))])
                            })
                            .onTapGesture { model.current = s.key }
                    }
                }
                .padding(.horizontal, 2)
                .coordinateSpace(name: "strip")
                .onPreferenceChange(StripFrames.self) { f in if !scrubbing { frames = f } }
                .gesture(
                    LongPressGesture(minimumDuration: 0.12)
                        .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named("strip")))
                        .onChanged { v in
                            guard case .second(true, let drag?) = v else { return }
                            if !scrubbing {
                                scrubbing = true
                                Haptics.confirm()
                            }
                            let x = drag.location.x
                            if let hit = frames.first(where: { $0.value.minX <= x && x < $0.value.maxX })?.key, hit != model.current {
                                Haptics.tick()
                                model.current = hit
                            }
                        }
                        .onEnded { _ in scrubbing = false }
                )
            }
            .frame(height: 70)
            .background(Lc.window)
            .overlay(Rectangle().fill(Lc.line).frame(height: 1), alignment: .top)
            .onChange(of: current) { k in
                if let k = k, !scrubbing { withAnimation(Motion.quick) { proxy.scrollTo(k, anchor: .center) } }
            }
            .onAppear { if let k = current { proxy.scrollTo(k, anchor: .center) } }
        }
    }
}

private struct StripCell: View {
    let shot: Shot
    let on: Bool

    var body: some View {
        let w = max(44, min(108, 62 * CGFloat(shot.aspect)))
        ZStack(alignment: .bottom) {
            Rectangle().fill(Lc.field)
            if let t = shot.thumb {
                Image(decorative: t, scale: 1).resizable().aspectRatio(contentMode: .fit)
            }
            if shot.stage == .arriving || shot.stage == .preview {
                Color.black.opacity(0.35)
                ProgressRing(fraction: shot.progress, line: 1.5).frame(width: 18, height: 18).padding(.bottom, 22)
            }
            if shot.rating > 0 || shot.label != nil || shot.flag != "none" {
                HStack(spacing: 3) {
                    if let t = shot.label { Circle().fill(t.color).frame(width: 6, height: 6) }
                    Stars(rating: shot.rating, size: 7)
                    if shot.flag == "pick" { Image(systemName: "flag.fill").font(.system(size: 7)).foregroundColor(Lc.live) }
                    if shot.flag == "reject" { Image(systemName: "xmark").font(.system(size: 7, weight: .bold)).foregroundColor(Lc.danger) }
                }
                .padding(.horizontal, 4)
                .frame(height: 12)
                .background(Color.black.opacity(0.55))
                .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
                .padding(.bottom, 3)
            }
        }
        .frame(width: w, height: 62)
        .overlay(Rectangle().stroke(on ? Lc.select : Color.clear, lineWidth: 2))
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
