import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Capture One's tool tabs, here as the groups of one long scrolling column.
enum ToolGroup: String, CaseIterable, Identifiable {
    case capture, exposure, color, composition, local, details, lens, retouch, adjustments, metadata
    var id: String { rawValue }
    var title: String {
        switch self {
        case .capture: return "Tethering"
        case .exposure: return "Base"
        case .color: return "Colore"
        case .composition: return "Composizione"
        case .local: return "Maschere"
        case .details: return "Dettagli"
        case .lens: return "Obiettivo"
        case .retouch: return "Ritocco"
        case .adjustments: return "Stili"
        case .metadata: return "Metadati"
        }
    }
    var icon: String {
        switch self {
        case .capture: return "camera"
        case .exposure: return "sun.max"
        case .color: return "paintpalette"
        case .composition: return "crop"
        case .local: return "square.3.layers.3d"
        case .details: return "scope"
        case .lens: return "camera.aperture"
        case .retouch: return "bandage"
        case .adjustments: return "slider.horizontal.3"
        case .metadata: return "info.circle"
        }
    }
}

/// Which tools are folded, and the group in view.
@MainActor
final class PanelState: ObservableObject {
    @Published var active: ToolGroup = .capture
    @Published var collapsed: Set<String> {
        didSet { UserDefaults.standard.set(Array(collapsed), forKey: "collapsedTools") }
    }

    init() {
        let saved = UserDefaults.standard.stringArray(forKey: "collapsedTools")
        collapsed = Set(saved ?? ["calibration", "history"])
    }

    func toggle(_ id: String) {
        if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
    }
}

private struct GroupTops: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { $1 }
    }
}

/// The tools: the group icons on top, the histogram, then every tool in one column.
struct ToolPanel: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var ed: EditorModel
    @StateObject private var state = PanelState()
    @State private var target: ToolGroup?

    var body: some View {
        VStack(spacing: 0) {
            GroupStrip(state: state) { target = $0 }
            HistogramBox(ed: ed)
                .frame(height: 70)
                .padding(.horizontal, 10)
                .padding(.top, 8)
            Text(ed.exposureLine.isEmpty ? " " : ed.exposureLine)
                .font(Typo.caption).foregroundColor(Lc.text2)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .frame(height: 22)
            Rectangle().fill(Lc.line).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(ToolGroup.allCases) { g in
                            GroupHeader(group: g).id(g)
                            tools(g)
                                .disabled(ed.photo == 0 && g != .capture)
                                .opacity(ed.photo == 0 && g != .capture ? 0.45 : 1)
                        }
                        Color.clear.frame(height: 240)
                    }
                }
                .coordinateSpace(name: "tools")
                .onPreferenceChange(GroupTops.self) { tops in
                    let shown = tops.filter { $0.value <= 30 }.max { $0.value < $1.value }?.key
                    if let s = shown, let g = ToolGroup(rawValue: s), g != state.active { state.active = g }
                }
                .onChange(of: target) { t in
                    guard let t = t else { return }
                    state.active = t
                    withAnimation(Motion.panel) { proxy.scrollTo(t, anchor: .top) }
                    target = nil
                }
                .onAppear {
                    if let t = UserDefaults.standard.string(forKey: "tool").flatMap({ ToolGroup(rawValue: $0) }) {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { target = t }
                    }
                }
            }
        }
        .background(Lc.panel)
    }

    @ViewBuilder
    private func tools(_ g: ToolGroup) -> some View {
        let s = ed.store
        switch g {
        case .capture:
            ToolBox(id: "tethering", title: "Tethering", state: state) {
                CameraTool(tether: model.tether)
                Rectangle().fill(Lc.hairline).frame(height: 0.5).padding(.vertical, 6)
                Text("PROSSIMO SCATTO").overline().padding(.bottom, 2)
                NextCaptureTool()
            }
        case .exposure:
            ToolBox(id: "basic", title: "Base", state: state, ed: ed, resetIds: basicIds, accessory: AnyView(MiniButton(title: "Auto") { ed.run("develop.auto") })) {
                BasicTool(ed: ed)
            }
            ToolBox(id: "curve", title: "Curva", state: state, ed: ed, section: "curve") { CurveTool(ed: ed) }
            ToolBox(id: "vignette", title: "Vignettatura", state: state, ed: ed, section: "vignette") {
                MenuField(label: "Metodo", value: vignetteName(ed.vignetteStyle)) {
                    ForEach(["highlightPriority", "colorPriority", "paintOverlay"], id: \.self) { v in
                        Button(vignetteName(v)) { ed.merge(["vignette": ["style": v]], label: "Vignettatura") }
                    }
                }
                Sliders(store: s, ids: ["vignette.amount", "vignette.midpoint", "vignette.roundness", "vignette.feather", "vignette.highlights"])
            }
        case .color:
            ToolBox(id: "profile", title: "Caratteristiche base", state: state, ed: ed, resetIds: ["profile.amount"]) {
                MenuField(label: "Profilo", value: model.profiles.first { $0.id == ed.profile }?.name ?? "Predefinito") {
                    ForEach(profileGroups(), id: \.self) { group in
                        Menu(groupLabel(group)) {
                            ForEach(model.profiles.filter { $0.group == group }) { p in
                                Button(p.name) { ed.setProfile(p.id) }
                            }
                        }
                    }
                }
                Sliders(store: s, ids: ["profile.amount"])
            }
            ToolBox(id: "balance", title: "Color Grading", state: state, ed: ed, section: "grading") { ColorBalanceTool(store: s) }
            ToolBox(id: "editor", title: "Editor colore", state: state, ed: ed, section: "mixer") { ColorEditorTool(ed: ed) }
            ToolBox(id: "calibration", title: "Calibrazione", state: state, ed: ed, resetIds: ["calibration.shadowsTint", "calibration.redHue", "calibration.redSat", "calibration.greenHue", "calibration.greenSat", "calibration.blueHue", "calibration.blueSat"]) {
                Sliders(store: s, ids: ["calibration.shadowsTint", "calibration.redHue", "calibration.redSat", "calibration.greenHue", "calibration.greenSat", "calibration.blueHue", "calibration.blueSat"])
            }
        case .composition:
            ToolBox(id: "crop", title: "Ritaglio e geometria", state: state) { GeometryTool(ed: ed) }
        case .local:
            ToolBox(id: "layers", title: "Maschere", state: state) { LayersTool(ed: ed) }
        case .details:
            ToolBox(id: "detail", title: "Dettagli", state: state) {
                SubHeader(title: "Nitidezza", ed: ed, resetIds: sharpenIds)
                Sliders(store: s, ids: sharpenIds)
                SubHeader(title: "Riduzione rumore", ed: ed, resetIds: noiseIds)
                Sliders(store: s, ids: noiseIds)
                SubHeader(title: "Grana", ed: ed, section: "grain")
                Sliders(store: s, ids: ["grain.amount", "grain.size", "grain.roughness"])
            }
        case .lens:
            ToolBox(id: "lens", title: "Correzione obiettivo", state: state, ed: ed, section: "optics") {
                ToggleRow(label: "Profilo obiettivo", on: ed.lensProfile) { ed.merge(["optics": ["lens_profile": $0]], label: "Profilo obiettivo") }
                if ed.lensProfile {
                    Sliders(store: s, ids: ["optics.profileDistortion", "optics.profileVignetting"],
                            labels: ["optics.profileDistortion": "Distors. profilo", "optics.profileVignetting": "Luce profilo"])
                }
                ToggleRow(label: "Rimuovi aberrazione cromatica", on: ed.removeCA) { ed.merge(["optics": ["remove_ca": $0]], label: "Aberrazione cromatica") }
                SubHeader(title: "Frange colorate", ed: ed, resetIds: fringeIds)
                Sliders(store: s, ids: fringeIds)
                SubHeader(title: "Manuale", ed: ed, resetIds: ["optics.distortion", "optics.vignetting", "optics.vignettingMidpoint"])
                Sliders(store: s, ids: ["optics.distortion"])
                // the corrected photo's curved edges stay outside the crop
                ToggleRow(label: "Vincola ritaglio", on: ed.constrainCrop) { ed.setConstrainCrop($0) }
                Sliders(store: s, ids: ["optics.vignetting", "optics.vignettingMidpoint"])
            }
            ToolBox(id: "lensBlur", title: "Sfocatura obiettivo", state: state) { LensBlurTool(ed: ed) }
        case .retouch:
            ToolBox(id: "spots", title: "Rimozione macchie", state: state) { SpotTool(ed: ed) }
        case .adjustments:
            ToolBox(id: "styles", title: "Stili e preset", state: state) { StylesTool(ed: ed) }
            ToolBox(id: "history", title: "Cronologia", state: state) { HistoryTool(ed: ed) }
        case .metadata:
            ToolBox(id: "info", title: "Valutazione e informazioni", state: state) {
                RatingTool(library: model.library, key: ed.key)
                Rectangle().fill(Lc.hairline).frame(height: 0.5).padding(.vertical, 6)
                VStack(alignment: .leading, spacing: 0) {
                    if ed.meta.isEmpty {
                        Text("—").font(Typo.label).foregroundColor(Lc.text3).frame(height: 26)
                    }
                    ForEach(ed.meta) { m in
                        HStack(alignment: .firstTextBaseline) {
                            Text(m.name).font(Typo.label).foregroundColor(Lc.text3).frame(width: 100, alignment: .leading)
                            Text(m.value).font(Typo.label).foregroundColor(Lc.text).lineLimit(2)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 4)
                    }
                    if !model.renderer.isEmpty {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Motore").font(Typo.label).foregroundColor(Lc.text3).frame(width: 100, alignment: .leading)
                            Text(model.renderer).font(Typo.label).foregroundColor(Lc.text2).lineLimit(2)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
    }

    private func profileGroups() -> [String] {
        model.profiles.map(\.group).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
    }
}

func uprightName(_ u: String) -> String {
    switch u {
    case "auto": return "Automatico"
    case "level": return "Livella"
    case "vertical": return "Verticale"
    case "full": return "Completo"
    case "guided": return "Guidato"
    default: return "Disattivato"
    }
}

func vignetteName(_ v: String) -> String {
    switch v {
    case "colorPriority": return "Priorità colore"
    case "paintOverlay": return "Sovrapposizione"
    default: return "Priorità alteluci"
    }
}

/// The group icons above the column: tap one to go to its tools.
private struct GroupStrip: View {
    @ObservedObject var state: PanelState
    let onPick: (ToolGroup) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(ToolGroup.allCases) { g in
                Button { onPick(g) } label: {
                    VStack(spacing: 0) {
                        Image(systemName: g.icon)
                            .font(.system(size: 17))
                            .foregroundColor(g == state.active ? Lc.text : Lc.text3)
                            .frame(maxWidth: .infinity, minHeight: 40)
                        Rectangle().fill(g == state.active ? Lc.accent : Color.clear).frame(height: 2)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(height: 42)
        .background(Lc.header)
        .overlay(Rectangle().fill(Lc.line).frame(height: 1), alignment: .bottom)
    }
}

/// A group's title (Capture One's tool tab), above its tools.
private struct GroupHeader: View {
    let group: ToolGroup

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: group.icon).font(.system(size: 11)).foregroundColor(Lc.text3)
            Text(group.title.uppercased()).overline()
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
        .background(Lc.window)
        .overlay(Rectangle().fill(Lc.line).frame(height: 1), alignment: .bottom)
        .background(GeometryReader { g in
            Color.clear.preference(key: GroupTops.self, value: [group.rawValue: g.frame(in: .named("tools")).minY])
        })
    }
}

/// A small push button for a tool's header or corner.
struct MiniButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(Typo.caption).foregroundColor(Lc.text)
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(Lc.raised)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        }
        .buttonStyle(PressStyle())
    }
}

/// One tool: a header (fold, name, its switch, reset), then its controls.
struct ToolBox<Content: View>: View {
    let id: String
    let title: String
    @ObservedObject var state: PanelState
    var ed: EditorModel? = nil
    /// The engine section it switches on and off and resets.
    var section: String? = nil
    /// Or the sliders its reset puts back.
    var resetIds: [String]? = nil
    var accessory: AnyView? = nil
    @ViewBuilder let content: Content

    var body: some View {
        let folded = state.collapsed.contains(id)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Button { withAnimation(Motion.quick) { state.toggle(id) } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(Lc.text3)
                            .rotationEffect(.degrees(folded ? 0 : 90))
                        Text(title).font(Typo.toolTitle).foregroundColor(Lc.text)
                        Spacer(minLength: 0)
                    }
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if let a = accessory { a }
                if let ed = ed {
                    ToolHeaderControls(ed: ed, section: section, resetIds: resetIds)
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, 8)
            .frame(height: 46)
            .background(Lc.header)
            if !folded {
                VStack(alignment: .leading, spacing: 0) { content }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            Rectangle().fill(Lc.line).frame(height: 1)
        }
    }
}

/// A tool's switch (Lightroom's eye: off shows the photo without it) and its reset.
private struct ToolHeaderControls: View {
    @ObservedObject var ed: EditorModel
    let section: String?
    let resetIds: [String]?

    var body: some View {
        HStack(spacing: 2) {
            if let s = section {
                let off = ed.disabled.contains(s)
                Button { ed.setSection(s, enabled: off) } label: {
                    Image(systemName: off ? "eye.slash" : "eye")
                        .font(.system(size: 13))
                        .foregroundColor(off ? Lc.accent : Lc.text3)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if section != nil || resetIds != nil {
                Button {
                    if let s = section { ed.resetSection(s) } else if let ids = resetIds { ed.resetControls(ids) }
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 13))
                        .foregroundColor(Lc.text3)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private let sharpenIds = ["detail.sharpenAmount", "detail.sharpenRadius", "detail.sharpenDetail", "detail.sharpenMasking"]
private let noiseIds = ["detail.nrLuminance", "detail.nrDetail", "detail.nrContrast", "detail.nrColor", "detail.nrColorDetail", "detail.nrColorSmoothness"]
private let fringeIds = ["optics.defringePurple", "optics.defringePurpleHueLo", "optics.defringePurpleHueHi", "optics.defringeGreen", "optics.defringeGreenHueLo", "optics.defringeGreenHueHi", "optics.caRed", "optics.caBlue"]

/// A part of a tool (Sharpening in Detail, Defringe in Lens Corrections): its name, its switch and
/// its reset.
struct SubHeader: View {
    let title: String
    var ed: EditorModel? = nil
    var section: String? = nil
    var resetIds: [String]? = nil

    var body: some View {
        HStack(spacing: 6) {
            Text(title.uppercased()).overline().fixedSize()
            Rectangle().fill(Lc.hairline).frame(height: 0.5)
            if let ed = ed {
                ToolHeaderControls(ed: ed, section: section, resetIds: resetIds)
            }
        }
        .frame(height: 34)
        .padding(.top, 6)
    }
}

// MARK: - The histogram

struct HistogramBox: UIViewRepresentable {
    let ed: EditorModel

    func makeUIView(context: Context) -> HistogramUIView {
        let v = HistogramUIView()
        v.layer.cornerRadius = 3
        v.clipsToBounds = true
        ed.observeHistogram(owner: v) { [weak v] h in v?.histogram = h }
        return v
    }

    func updateUIView(_ v: HistogramUIView, context: Context) {}
}

// MARK: - A standalone slider (not a develop control)

struct ValueSlider: UIViewRepresentable {
    let control: Control
    let value: Double
    var onChange: (Double) -> Void
    var onEnd: () -> Void = {}

    func makeUIView(context: Context) -> ToolSlider {
        let s = ToolSlider()
        s.control = control
        s.setValue(value)
        return s
    }

    func updateUIView(_ s: ToolSlider, context: Context) {
        s.onChange = onChange
        s.onEnd = onEnd
        s.setValue(value)
    }
}

// MARK: - Capture

private struct CameraTool: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var tether: TetherLink

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                LinkStatus(tether: tether, raw: model.settings.raw)
                Spacer()
            }
            if case .blocked(let m) = tether.link {
                Text(m).font(Typo.caption).foregroundColor(Lc.warn).fixedSize(horizontal: false, vertical: true)
            } else if let w = tether.warning {
                Text(w).font(Typo.caption).foregroundColor(Lc.warn).fixedSize(horizontal: false, vertical: true)
            }
            Segment(options: ["RAW", "JPEG rapido"], selected: model.settings.raw ? 0 : 1) { model.setRaw($0 == 0) }
            HStack(spacing: 6) {
                if tether.link.busy {
                    FlatButton(title: "Scollega", icon: "bolt.slash") { model.disconnect() }
                } else {
                    FlatButton(title: "Collega", icon: "bolt") { model.connect() }
                }
                FlatButton(title: "Accesso…", icon: "key") { model.go(.connect) }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct NextCaptureTool: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let style = model.presets.first { $0.id == model.settings.preset }?.name ?? "Nessuno"
        VStack(alignment: .leading, spacing: 0) {
            ToggleRow(label: "Copia dall'ultimo scatto", on: model.settings.copyLast) { model.settings.copyLast = $0 }
            MenuField(label: "Stile", value: style) {
                Button("Nessuno") { model.settings.preset = "" }
                ForEach(presetGroups(model.presets), id: \.self) { g in
                    Menu(groupLabel(g)) {
                        ForEach(model.presets.filter { $0.group == g }) { p in
                            Button(p.name) { model.settings.preset = p.id }
                        }
                    }
                }
            }
            .disabled(model.settings.copyLast)
            .opacity(model.settings.copyLast ? 0.4 : 1)
            ValueSlider(
                control: Control(id: "next.amount", label: "Intensità", min: 0, max: 200, def: 100, step: 1, decimals: 0, track: .plain),
                value: Double(model.settings.presetAmount),
                onChange: { model.settings.presetAmount = Int($0) }
            )
            .frame(height: ToolSlider.height)
            .disabled(model.settings.copyLast || model.settings.preset.isEmpty)
            .opacity(model.settings.copyLast || model.settings.preset.isEmpty ? 0.4 : 1)
            ToggleRow(label: "Mostra subito il nuovo scatto", on: model.settings.followNewest) { model.settings.followNewest = $0 }
        }
    }
}

func presetGroups(_ presets: [Preset]) -> [String] {
    presets.map(\.group).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
}

// MARK: - Composition

/// Crop, straighten, rotate and flip, perspective: one tool, in the order they are used.
private struct GeometryTool: View {
    @ObservedObject var ed: EditorModel
    private let ratios: [(String, String)] = [
        ("original", "Originale"), ("free", "Libero"), ("1x1", "1:1"), ("4x5", "4:5"), ("5x7", "5:7"),
        ("2x3", "2:3"), ("4x3", "4:3"), ("16x9", "16:9"), ("16x10", "16:10"),
    ]
    private let uprights: [(String, String)] = [("off", "No"), ("auto", "Auto"), ("level", "Livello"), ("vertical", "Vert."), ("full", "Tutto")]
    private let perspectiveIds = ["geometry.vertical", "geometry.horizontal", "geometry.rotate", "geometry.aspect", "geometry.scale", "geometry.offsetX", "geometry.offsetY"]

    var body: some View {
        let cropping = ed.cursorTool == .crop
        VStack(alignment: .leading, spacing: 0) {
            FlatButton(title: cropping ? "Fine" : "Ritaglia sulla foto", icon: "crop", prominent: cropping) {
                if cropping { ed.exitCrop() } else { ed.enterCrop() }
            }
            .padding(.top, 4)
            HStack(spacing: 6) {
                MenuField(label: "Proporzioni", value: aspectName(ed.cropAspect)) {
                    ForEach(ratios, id: \.0) { r in
                        Button(r.1) { ed.run("crop.aspect", ["aspect": r.0]) }
                    }
                }
                IconButton(icon: "rectangle.portrait.rotate") { ed.run("crop.rotateAspect") }
            }
            .padding(.top, 4)
            Sliders(store: ed.store, ids: ["crop.angle"])
            HStack(spacing: 6) {
                FlatButton(title: "Livella", icon: "level") { ed.run("crop.autoStraighten") }
                FlatButton(title: "Azzera ritaglio", icon: "arrow.counterclockwise") { ed.run("crop.reset") }
            }
            .padding(.vertical, 4)
            SubHeader(title: "Ruota e capovolgi")
            HStack(spacing: 6) {
                LabeledIcon(icon: "rotate.left", label: "Sinistra") { ed.run("photo.rotateLeft", ["ids": [ed.photo]]) }
                LabeledIcon(icon: "rotate.right", label: "Destra") { ed.run("photo.rotateRight", ["ids": [ed.photo]]) }
                LabeledIcon(icon: "arrow.left.and.right.righttriangle.left.righttriangle.right", label: "Orizz.") { ed.run("photo.flipHorizontal", ["ids": [ed.photo]]) }
                LabeledIcon(icon: "arrow.up.and.down.righttriangle.up.righttriangle.down", label: "Vert.") { ed.run("photo.flipVertical", ["ids": [ed.photo]]) }
            }
            SubHeader(title: "Prospettiva", ed: ed, section: "geometry")
            Segment(options: uprights.map(\.1), selected: uprights.firstIndex { $0.0 == ed.upright } ?? 0) { i in
                ed.merge(["geometry": ["upright": uprights[i].0]], label: "Upright")
            }
            .padding(.bottom, 4)
            Sliders(store: ed.store, ids: perspectiveIds)
        }
    }
}

/// A square button with an icon (beside a menu or a field).
struct IconButton: View {
    let icon: String
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 14)).foregroundColor(active ? Color.black : Lc.text)
                .frame(width: 38, height: 30)
                .background(active ? Lc.accent : Lc.raised)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .buttonStyle(PressStyle())
    }
}

/// An icon over its name, a quarter of the row wide.
struct LabeledIcon: View {
    let icon: String
    let label: String
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 15)).foregroundColor(active ? Color.black : Lc.text)
                Text(label).font(Typo.caption).foregroundColor(active ? Color.black : Lc.text2).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(active ? Lc.accent : Lc.raised)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .buttonStyle(PressStyle())
    }
}

// MARK: - Exposure

private struct CurveTool: View {
    @ObservedObject var ed: EditorModel
    @State private var ch: Channel = .master
    @State private var parametric = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Segment(options: ["Punti", "Parametrica"], selected: parametric ? 1 : 0) { parametric = $0 == 1 }
                .padding(.top, 2)
            if parametric {
                Sliders(store: ed.store, ids: ["curve.highlights", "curve.lights", "curve.darks", "curve.shadows", "curve.splitShadows", "curve.splitMid", "curve.splitHighlights", "curve.refineSaturation"])
            } else {
                HStack(spacing: 4) {
                    ForEach(Channel.allCases) { c in
                        Button { ch = c } label: {
                            Text(c.label).font(Typo.labelStrong)
                                .foregroundColor(c == ch ? Lc.text : Lc.text3)
                                .frame(maxWidth: .infinity, minHeight: 24)
                                .background(c == ch ? Lc.pressed : Lc.field)
                                .overlay(Rectangle().fill(Color(c.ui)).frame(height: 2), alignment: .bottom)
                                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                CurveBox(ed: ed, ch: ch, version: ed.curvesVersion)
                    .aspectRatio(1, contentMode: .fit)
                    .padding(.bottom, 6)
            }
        }
    }
}

private struct CurveBox: UIViewRepresentable {
    let ed: EditorModel
    let ch: Channel
    let version: Int

    func makeUIView(context: Context) -> CurveUIView {
        let v = CurveUIView()
        let ed = self.ed
        ed.observeHistogram(owner: v) { [weak v] h in v?.histogram = h }
        v.onBegin = { ed.begin("Curva") }
        v.onEnd = { ed.end() }
        return v
    }

    func updateUIView(_ v: CurveUIView, context: Context) {
        let ed = self.ed
        let ch = self.ch
        v.color = ch.ui
        v.points = ed.curves[ch] ?? [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)]
        v.onChange = { ed.curve(ch, $0) }
        v.isUserInteractionEnabled = ed.photo != 0
    }
}

// MARK: - Colour

/// The Base panel's sliders, in order: white balance, tone, presence.
private let basicIds = [
    "wb.temp", "wb.tint", "light.exposure", "light.contrast", "light.highlights", "light.shadows", "light.whites", "light.blacks",
    "color.saturation", "color.vibrance", "effects.clarity", "effects.texture", "effects.dehaze",
]

/// White balance, exposure, tone, presence: one panel (Lightroom's Basic).
private struct BasicTool: View {
    @ObservedObject var ed: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                MenuField(label: "Modalità", value: whiteModes.first { $0.0 == ed.wbMode }?.1 ?? "Personalizzato") {
                    ForEach(whiteModes, id: \.0) { m in
                        Button(m.1) { ed.whiteBalance(m.0) }
                    }
                }
                Button {
                    ed.cursorTool = .none
                    ed.picking.toggle()
                } label: {
                    Image(systemName: "eyedropper")
                        .font(.system(size: 14))
                        .foregroundColor(ed.picking ? Color.black : Lc.text)
                        .frame(width: 34, height: 28)
                        .background(ed.picking ? Lc.accent : Lc.raised)
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                }
                .buttonStyle(PressStyle())
            }
            if ed.picking {
                Text("Tocca un punto bianco o grigio neutro nella foto").font(Typo.caption).foregroundColor(Lc.accent).padding(.bottom, 4)
            }
            Sliders(store: ed.store, ids: basicIds, labels: ["wb.temp": "Temperatura", "effects.dehaze": "Dehaze"])
        }
    }
}

private let whiteModes: [(String, String)] = [
    ("asShot", "Come scattato"), ("auto", "Automatico"), ("daylight", "Luce diurna"), ("cloudy", "Nuvoloso"),
    ("shade", "Ombra"), ("tungsten", "Tungsteno"), ("fluorescent", "Fluorescente"), ("flash", "Flash"),
]

private struct WhiteBalanceTool: View {
    @ObservedObject var ed: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                MenuField(label: "Modalità", value: whiteModes.first { $0.0 == ed.wbMode }?.1 ?? "Personalizzato") {
                    ForEach(whiteModes, id: \.0) { m in
                        Button(m.1) { ed.whiteBalance(m.0) }
                    }
                }
                Button { ed.picking.toggle() } label: {
                    Image(systemName: "eyedropper")
                        .font(.system(size: 13))
                        .foregroundColor(ed.picking ? Color.black : Lc.text)
                        .frame(width: 30, height: 24)
                        .background(ed.picking ? Lc.accent : Lc.raised)
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                }
                .buttonStyle(PressStyle())
            }
            if ed.picking {
                Text("Tocca un punto bianco o grigio neutro nella foto").font(Typo.caption).foregroundColor(Lc.accent).padding(.bottom, 4)
            }
            Sliders(store: ed.store, ids: ["wb.temp", "wb.tint"])
        }
    }
}

/// Capture One's colour balance: master, the three wheels side by side, or one wheel large.
private struct ColorBalanceTool: View {
    let store: DevelopStore
    @State private var mode = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Segment(options: ["Master", "3 vie", "Ombre", "Medi", "Luci"], selected: mode) { mode = $0 }
                .padding(.top, 2)
            if mode == 1 {
                HStack(spacing: 10) {
                    ForEach([Zone.shadows, .midtones, .highlights]) { z in
                        VStack(spacing: 4) {
                            WheelRow(store: store, zone: z).aspectRatio(1, contentMode: .fit)
                            Text(z.label).font(Typo.caption).foregroundColor(Lc.text3)
                        }
                    }
                }
                Sliders(store: store, ids: ["grading.shadows.lum", "grading.midtones.lum", "grading.highlights.lum"],
                        labels: ["grading.shadows.lum": "Lumin. ombre", "grading.midtones.lum": "Lumin. medi", "grading.highlights.lum": "Lumin. luci"])
            } else {
                let z: Zone = mode == 0 ? .global : (mode == 2 ? .shadows : (mode == 3 ? .midtones : .highlights))
                WheelRow(store: store, zone: z)
                    .frame(width: 176, height: 176)
                    .frame(maxWidth: .infinity)
                    .id(z)
                Sliders(store: store, ids: ["grading.\(z.rawValue).hue", "grading.\(z.rawValue).sat", "grading.\(z.rawValue).lum"])
            }
            Sliders(store: store, ids: ["grading.blending", "grading.balance"])
        }
    }
}

/// The colour editor: pick a band, set its hue, saturation and lightness. Its Black & White switch
/// turns the photo grey and the bands into the mix (how light each colour becomes).
private struct ColorEditorTool: View {
    @ObservedObject var ed: EditorModel
    @State private var band: Band = .red

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ToggleRow(label: "Bianco e nero", on: ed.bw) { ed.setBw($0) }
            if ed.bw {
                HStack(spacing: 6) {
                    Text("Mix bianco e nero").font(Typo.labelStrong).foregroundColor(Lc.text)
                    Spacer()
                    MiniButton(title: "Auto") { ed.run("develop.autoBwMix") }
                    MiniButton(title: "Azzera") { ed.resetControls(Band.allCases.map { "bw.\($0.rawValue)" }) }
                }
                Sliders(store: ed.store, ids: Band.allCases.map { "bw.\($0.rawValue)" })
            } else {
                HStack(spacing: 0) {
                    ForEach(Band.allCases) { b in
                        Button { band = b } label: {
                            Circle().fill(b.color)
                                .frame(width: 20, height: 20)
                                .overlay(Circle().stroke(Color.white, lineWidth: b == band ? 2 : 0))
                                .frame(maxWidth: .infinity, minHeight: 32)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                Text(band.label).font(Typo.labelStrong).foregroundColor(Lc.text)
                Sliders(store: ed.store, ids: ["mixer.\(band.rawValue).hue", "mixer.\(band.rawValue).sat", "mixer.\(band.rawValue).lum"])
            }
        }
    }
}

// MARK: - Lens blur

/// Lightroom's Lens Blur: the scene's depth from the Neural Engine, what stays sharp around the focus,
/// how much the rest melts.
private struct LensBlurTool: View {
    @ObservedObject var ed: EditorModel

    var body: some View {
        let s = ed.lensBlur
        VStack(alignment: .leading, spacing: 0) {
            ToggleRow(label: "Applica", on: s.enabled) { on in
                var n = ed.lensBlur
                n.enabled = on
                ed.setLensBlur(n, live: false)
                ed.commitLensBlur()
            }
            Group {
                ValueSlider(control: Control(id: "lb.amount", label: "Quantità", min: 1, max: 100, def: 50, step: 1, decimals: 0, track: .plain),
                            value: s.amount,
                            onChange: { v in var n = ed.lensBlur; n.amount = v; ed.setLensBlur(n, live: true) },
                            onEnd: { ed.commitLensBlur() })
                    .frame(height: ToolSlider.height)
                ValueSlider(control: Control(id: "lb.focus", label: "Messa a fuoco", min: 0, max: 100, def: 85, step: 1, decimals: 0, track: .gradient([UIColor(hex: 0x30343C), UIColor(hex: 0xE8E8EA)])),
                            value: (s.focus ?? 0.85) * 100,
                            onChange: { v in var n = ed.lensBlur; n.focus = v / 100; ed.setLensBlur(n, live: true) },
                            onEnd: { ed.commitLensBlur() })
                    .frame(height: ToolSlider.height)
                ValueSlider(control: Control(id: "lb.range", label: "Profondità", min: 2, max: 100, def: 18, step: 1, decimals: 0, track: .plain),
                            value: s.range * 100,
                            onChange: { v in var n = ed.lensBlur; n.range = v / 100; ed.setLensBlur(n, live: true) },
                            onEnd: { ed.commitLensBlur() })
                    .frame(height: ToolSlider.height)
                HStack(spacing: 6) {
                    FlatButton(title: ed.cursorTool == .focus ? "Tocca la foto" : "Fuoco al tocco", icon: "scope", prominent: ed.cursorTool == .focus) {
                        ed.picking = false
                        ed.cursorTool = ed.cursorTool == .focus ? .none : .focus
                    }
                    FlatButton(title: "Soggetto", icon: "person.crop.rectangle") {
                        var n = ed.lensBlur
                        n.focus = nil
                        ed.setLensBlur(n, live: false)
                        ed.commitLensBlur()
                    }
                }
                .padding(.vertical, 4)
                ToggleRow(label: "Mostra la profondità", on: ed.showDepth) { ed.showDepth = $0 }
            }
            .disabled(!s.enabled)
            .opacity(s.enabled ? 1 : 0.45)
            Text(ed.depthSource.isEmpty ? "La profondità della scena si calcola sul Neural Engine dell'iPad." : "Profondità: \(ed.depthSource)")
                .font(Typo.caption).foregroundColor(Lc.text3)
                .padding(.vertical, 4)
        }
    }
}

// MARK: - Local adjustments

/// Capture One's layers: masks (brush, gradients, ranges), each with its own sliders.
private struct LayersTool: View {
    @ObservedObject var ed: EditorModel
    @State private var feather = 50.0
    @State private var lo = 60.0
    @State private var hi = 100.0
    @State private var page = 0
    private let pages: [(String, [String])] = [
        ("Luce", ["exposure", "contrast", "highlights", "shadows", "whites", "blacks"]),
        ("Colore", ["temp", "tint", "saturation"]),
        ("Effetti", ["clarity", "texture", "dehaze"]),
        ("Dettagli", ["sharpness", "noise", "moire", "defringe"]),
    ]

    var body: some View {
        let selected = ed.masks.first { $0.id == ed.selectedMask }
        VStack(alignment: .leading, spacing: 6) {
            Menu {
                Button { ed.addMask("brush") } label: { Label("Pennello", systemImage: "paintbrush.pointed") }
                Button { ed.addMask("linear") } label: { Label("Gradiente lineare", systemImage: "square.split.diagonal") }
                Button { ed.addMask("radial") } label: { Label("Gradiente radiale", systemImage: "circle.dashed") }
                Button { ed.addMask("luminanceRange") } label: { Label("Gamma luminanza", systemImage: "sun.max") }
                Button { ed.addMask("colorRange") } label: { Label("Gamma colore", systemImage: "eyedropper") }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus").font(.system(size: 13, weight: .semibold))
                    Text("Nuovo livello").font(Typo.labelStrong)
                }
                .foregroundColor(Lc.text)
                .frame(maxWidth: .infinity, minHeight: 34)
                .background(Lc.raised)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            .padding(.top, 2)
            if ed.masks.isEmpty {
                Text("Nessun livello. Un livello regola solo una parte della foto: dipinta, sfumata o scelta per luce o colore.")
                    .font(Typo.caption).foregroundColor(Lc.text3).fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 1) {
                ForEach(ed.masks.reversed()) { m in
                    LayerRow(mask: m, selected: m.id == ed.selectedMask,
                             onSelect: {
                                 ed.selectedMask = m.id
                                 switch m.kind {
                                 case "brush": ed.cursorTool = .paint
                                 case "linear", "radial": ed.cursorTool = .shape
                                 default: if ed.cursorTool != .crop { ed.cursorTool = .none }
                                 }
                             },
                             onVisible: { ed.setMaskVisible(m.id, !m.visible) },
                             onInvert: { ed.invertMask(m.id) },
                             onDelete: { ed.deleteMask(m.id) })
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            if let m = selected {
                ToggleRow(label: "Mostra la maschera in rosso", on: ed.maskOverlay) { ed.maskOverlay = $0 }
                shapeControls(m)
                Segment(options: pages.map(\.0), selected: page) { page = $0 }
                    .padding(.top, 8)
                Sliders(store: ed.localStore, ids: pages[page].1.map { "local.\($0)" }, labels: ["local.highlights": "Luci"])
            }
        }
        .onChange(of: ed.selectedMask) { _ in loadShape() }
        .onAppear { loadShape() }
    }

    private func loadShape() {
        guard let m = ed.masks.first(where: { $0.id == ed.selectedMask }) else { return }
        feather = m.shape["feather"].map { double($0) } ?? 50
        lo = (m.shape["lo"].map { double($0) } ?? 0.6) * 100
        hi = (m.shape["hi"].map { double($0) } ?? 1) * 100
    }

    @ViewBuilder
    private func shapeControls(_ m: MaskInfo) -> some View {
        switch m.kind {
        case "brush":
            FlatButton(title: ed.cursorTool == .paint ? "Pennello attivo" : "Dipingi sulla foto", icon: "paintbrush.pointed", prominent: ed.cursorTool == .paint) {
                ed.cursorTool = ed.cursorTool == .paint ? .none : .paint
            }
            .padding(.top, 4)
            if ed.cursorTool == .paint {
                Segment(options: ["Dipingi", "Cancella"], selected: ed.erasing ? 1 : 0) { ed.erasing = $0 == 1 }
                    .padding(.top, 6)
                ValueSlider(control: Control(id: "brush.size", label: "Dimensione", min: 0.5, max: 25, def: 3, step: 0.1, decimals: 1, track: .plain),
                            value: ed.brushSize * 100, onChange: { ed.brushSize = $0 / 100 })
                    .frame(height: ToolSlider.height)
                ValueSlider(control: Control(id: "brush.feather", label: "Sfumatura", min: 0, max: 100, def: 50, step: 1, decimals: 0, track: .plain),
                            value: ed.brushFeather, onChange: { ed.brushFeather = $0 })
                    .frame(height: ToolSlider.height)
                ValueSlider(control: Control(id: "brush.flow", label: "Flusso", min: 1, max: 100, def: 100, step: 1, decimals: 0, track: .plain),
                            value: ed.brushFlow, onChange: { ed.brushFlow = $0 })
                    .frame(height: ToolSlider.height)
            }
        case "linear", "radial":
            if m.kind == "radial" {
                ValueSlider(control: Control(id: "radial.feather", label: "Sfumatura", min: 0, max: 100, def: 50, step: 1, decimals: 0, track: .plain),
                            value: feather, onChange: { feather = $0 },
                            onEnd: {
                                var s = m.shape
                                s["feather"] = feather
                                ed.updateShape(m.id, s)
                            })
                    .frame(height: ToolSlider.height)
            }
            FlatButton(title: ed.cursorTool == .shape ? "Maniglie attive" : "Modifica sulla foto", icon: "hand.draw", prominent: ed.cursorTool == .shape) {
                ed.cursorTool = ed.cursorTool == .shape ? .none : .shape
            }
            .padding(.top, 4)
        case "luminanceRange":
            ValueSlider(control: Control(id: "lum.lo", label: "Da", min: 0, max: 100, def: 60, step: 1, decimals: 0, track: .gradient([UIColor(hex: 0x111111), UIColor(hex: 0xEEEEEE)])),
                        value: lo, onChange: { lo = $0 }, onEnd: { ed.setLuminanceRange(m.id, lo: lo / 100, hi: hi / 100) })
                .frame(height: ToolSlider.height)
            ValueSlider(control: Control(id: "lum.hi", label: "A", min: 0, max: 100, def: 100, step: 1, decimals: 0, track: .gradient([UIColor(hex: 0x111111), UIColor(hex: 0xEEEEEE)])),
                        value: hi, onChange: { hi = $0 }, onEnd: { ed.setLuminanceRange(m.id, lo: lo / 100, hi: hi / 100) })
                .frame(height: ToolSlider.height)
        case "colorRange":
            FlatButton(title: ed.cursorTool == .sample ? "Tocca la foto" : "Campiona un colore", icon: "eyedropper", prominent: ed.cursorTool == .sample) {
                ed.cursorTool = ed.cursorTool == .sample ? .none : .sample
            }
            .padding(.top, 4)
        default:
            EmptyView()
        }
    }
}

private struct LayerRow: View {
    let mask: MaskInfo
    let selected: Bool
    let onSelect: () -> Void
    let onVisible: () -> Void
    let onInvert: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onVisible) {
                Image(systemName: mask.visible ? "eye" : "eye.slash")
                    .font(.system(size: 13))
                    .foregroundColor(mask.visible ? Lc.text2 : Lc.text3)
                    .frame(width: 30, height: 34)
            }
            .buttonStyle(.plain)
            Image(systemName: mask.icon).font(.system(size: 13)).foregroundColor(selected ? Lc.accent : Lc.text2)
            Text(mask.name.isEmpty ? mask.label : mask.name).font(Typo.label).foregroundColor(selected ? Lc.text : Lc.text2).lineLimit(1)
            Spacer(minLength: 4)
            Button(action: onInvert) {
                Image(systemName: "circle.lefthalf.filled")
                    .font(.system(size: 13))
                    .foregroundColor(mask.invert ? Lc.accent : Lc.text3)
                    .frame(width: 30, height: 34)
            }
            .buttonStyle(.plain)
            Button(action: onDelete) {
                Image(systemName: "trash").font(.system(size: 12)).foregroundColor(Lc.text3).frame(width: 30, height: 34)
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 2)
        .background(selected ? Lc.pressed : Lc.field)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }
}

/// Capture One's spot removal: heal, clone or fill a spot with a touch.
private struct SpotTool: View {
    @ObservedObject var ed: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Segment(options: ["Guarisci", "Clona", "Riempi"], selected: ["heal", "clone", "fill"].firstIndex(of: ed.spotMode) ?? 0) {
                ed.spotMode = ["heal", "clone", "fill"][$0]
            }
            .padding(.top, 2)
            ValueSlider(control: Control(id: "spot.size", label: "Dimensione", min: 0.3, max: 10, def: 1.5, step: 0.1, decimals: 1, track: .plain),
                        value: ed.spotSize * 100, onChange: { ed.spotSize = $0 / 100 })
                .frame(height: ToolSlider.height)
            FlatButton(title: ed.cursorTool == .spot ? "Tocca le macchie sulla foto" : "Rimuovi macchie sulla foto", icon: "bandage", prominent: ed.cursorTool == .spot) {
                ed.picking = false
                ed.cursorTool = ed.cursorTool == .spot ? .none : .spot
            }
            HStack(spacing: 6) {
                FlatButton(title: "Trova polvere", icon: "sparkle.magnifyingglass", enabled: ed.working == nil) { ed.run("spot.findDust") }
                FlatButton(title: "Togli l'ultima", icon: "arrow.uturn.backward", enabled: !ed.spots.isEmpty) { ed.deleteSpot(ed.spots.count - 1) }
            }
            Text(ed.spots.isEmpty ? "Nessuna macchia" : (ed.spots.count == 1 ? "1 macchia corretta" : "\(ed.spots.count) macchie corrette"))
                .font(Typo.caption).foregroundColor(Lc.text3)
                .padding(.bottom, 2)
        }
    }
}

// MARK: - Adjustments

/// Styles and presets: LightCraft's and the user's (Lightroom's included), grouped; tap to apply.
private struct StylesTool: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var ed: EditorModel
    @State private var open: Set<String> = ["User Presets", "Imported Presets"]
    @State private var importing = false
    @State private var creating = false
    @State private var deleting: Preset?

    var body: some View {
        let groups = presetGroups(model.presets)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                FlatButton(title: "Copia", icon: "doc.on.doc") { ed.copySettings(); model.say("Regolazioni copiate") }
                FlatButton(title: "Applica", icon: "doc.on.clipboard", enabled: ed.hasCopy) { ed.pasteSettings() }
                FlatButton(title: "Auto", icon: "wand.and.stars") { ed.run("develop.auto") }
            }
            .padding(.top, 2)
            HStack(spacing: 6) {
                FlatButton(title: "Nuovo", icon: "plus") { creating = true }
                FlatButton(title: "Importa", icon: "square.and.arrow.down") { importing = true }
                Menu {
                    Button { model.exportForLightroom(nil) } label: { Label("Esporta i miei stili per Lightroom", systemImage: "square.and.arrow.up") }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Lc.text)
                        .frame(width: 34, height: 30)
                        .background(Lc.raised)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
            }
            .padding(.vertical, 2)
            if let id = ed.preset {
                ValueSlider(
                    control: Control(id: "style.amount", label: "Intensità", min: 0, max: 200, def: 100, step: 1, decimals: 0, track: .plain),
                    value: Double(ed.presetAmount),
                    onChange: { ed.presetAmount = Int($0) },
                    onEnd: { ed.applyPreset(id, amount: ed.presetAmount) }
                )
                .frame(height: ToolSlider.height)
            }
            ForEach(groups, id: \.self) { g in
                let isOpen = open.contains(g)
                Button {
                    if isOpen { open.remove(g) } else { open.insert(g) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundColor(Lc.text3)
                            .rotationEffect(.degrees(isOpen ? 90 : 0))
                        Text(groupLabel(g)).font(Typo.labelStrong).foregroundColor(Lc.text2)
                        Spacer()
                        Text("\(model.presets.filter { $0.group == g }.count)").font(Typo.caption).foregroundColor(Lc.text3)
                    }
                    .frame(height: 26)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if isOpen {
                    ForEach(model.presets.filter { $0.group == g }) { p in
                        StyleRow(preset: p, image: ed.variants[p.id], on: ed.preset == p.id) { ed.applyPreset(p.id, amount: ed.presetAmount) }
                            .contextMenu {
                                Button { model.exportForLightroom([p.id]) } label: { Label("Esporta per Lightroom", systemImage: "square.and.arrow.up") }
                                if !p.builtin {
                                    Button(role: .destructive) { deleting = p } label: { Label("Elimina", systemImage: "trash") }
                                }
                            }
                            .onAppear { ed.loadVariants(model.presets.filter { open.contains($0.group) }.map(\.id)) }
                    }
                }
            }
        }
        .padding(.bottom, 4)
        .sheet(isPresented: $creating) { NewStyleSheet(ed: ed).environmentObject(model) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item, .folder], allowsMultipleSelection: true) { r in
            if case .success(let urls) = r { model.importPresets(urls) }
        }
        .alert("Eliminare «\(deleting?.name ?? "")»?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Elimina", role: .destructive) { if let p = deleting { model.deletePreset(p) }; deleting = nil }
            Button("Annulla", role: .cancel) { deleting = nil }
        } message: {
            Text("Lo stile sparisce da questo iPad; le foto a cui l'hai applicato restano come sono.")
        }
    }
}

private struct StyleRow: View {
    let preset: Preset
    let image: CGImage?
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    Rectangle().fill(Lc.field)
                    if let img = image {
                        Image(decorative: img, scale: 1).resizable().aspectRatio(contentMode: .fill)
                    }
                }
                .frame(width: 44, height: 30)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
                Text(preset.name).font(Typo.label).foregroundColor(on ? Lc.text : Lc.text2).lineLimit(1)
                Spacer(minLength: 0)
                if on { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundColor(Lc.accent) }
            }
            .padding(.leading, 14)
            .frame(height: 36)
            .background(on ? Lc.pressed : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }
}

/// LightCraft's History labels (Lightroom's, in English) in Italian; the app's own are already.
func historyName(_ label: String) -> String {
    if label.isEmpty { return "Modifica" }
    if label.hasPrefix("History: ") { return historyName(String(label.dropFirst(9))) }
    if label.hasPrefix("Preset: ") { return "Stile: " + label.dropFirst(8) }
    let names = [
        "Import": "Importazione", "Remove": "Rimozione macchia", "Edit Spot": "Modifica macchia", "Delete Spot": "Elimina macchia",
        "Find Dust Spots": "Trova polvere", "Find Blemishes": "Trova imperfezioni", "Add Mask": "Nuova maschera", "Edit Mask": "Modifica maschera",
        "Brush": "Pennello", "Mask Adjustment": "Regolazione maschera", "Color Range": "Gamma colore", "Delete Mask": "Elimina maschera",
        "Delete All Masks": "Elimina le maschere", "Rename Mask": "Rinomina maschera", "Invert Mask": "Inverti maschera",
        "Toggle Mask": "Mostra/nascondi maschera", "Duplicate Mask": "Duplica maschera", "Duplicate and Invert Mask": "Duplica e inverti",
        "Reorder Masks": "Ordine maschere", "Refine Edges": "Rifinisci bordi", "Object Mask": "Selezione oggetto",
        "Invert Component": "Inverti componente", "Duplicate Component": "Duplica componente", "Delete Component": "Elimina componente",
        "Rename Component": "Rinomina componente", "Change Component Mode": "Modalità componente", "Reset": "Azzera tutto",
        "Reset Edits": "Azzera tutto", "Paste Settings": "Incolla regolazioni", "Paste from Previous": "Incolla dalla precedente",
        "Sync Settings": "Sincronizza", "Rotate": "Ruota", "Flip": "Capovolgi", "Auto": "Auto", "Auto Settings": "Auto",
        "Auto B&W Mix": "Mix B/N automatico", "Auto Straighten": "Livella", "White Balance": "Bilanciamento del bianco",
        "White Balance Selector": "Contagocce bianco", "Black & White": "Bianco e nero", "Treatment": "Bianco e nero", "Profile": "Profilo",
        "Set Profile": "Profilo", "Crop": "Ritaglio", "Crop Aspect": "Proporzioni", "Rotate Crop Aspect": "Ruota proporzioni",
        "Reset Crop": "Azzera ritaglio", "Straighten": "Raddrizza", "Tone Curve": "Curva", "Set Point Curve": "Curva",
        "Toggle Section": "Attiva/disattiva", "Edit": "Modifica", "AI Denoise": "Riduzione rumore AI", "Cleared History": "Cronologia azzerata",
        "Read Metadata from File": "Metadati dal file", "Match Total Exposures": "Uniforma esposizioni",
    ]
    return names[label] ?? label
}

private struct HistoryTool: View {
    @ObservedObject var ed: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 20) {
                FlatButton(title: "Annulla", icon: "arrow.uturn.backward", enabled: ed.canUndo) { ed.undo() }
                FlatButton(title: "Ripeti", icon: "arrow.uturn.forward", enabled: ed.canRedo) { ed.redo() }
            }
            .padding(.vertical, 4)
            ForEach(Array(ed.history.enumerated().reversed()), id: \.offset) { i, label in
                HStack {
                    Text(historyName(label)).font(Typo.label)
                        .foregroundColor(i == ed.cursor ? Lc.text : (i > ed.cursor ? Lc.text3 : Lc.text2))
                    Spacer()
                    if i == ed.cursor { Image(systemName: "circle.fill").font(.system(size: 5)).foregroundColor(Lc.accent) }
                }
                .frame(height: 24)
            }
        }
    }
}

// MARK: - Metadata

private struct RatingTool: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var library: Library
    let key: String

    var body: some View {
        let shot = library.shot(key)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Valutazione").font(Typo.label).foregroundColor(Lc.text2).frame(width: 92, alignment: .leading)
                StarRating(rating: shot?.rating ?? 0, size: 13, spacing: 0) { model.rate([key], $0) }
                Spacer()
            }
            HStack {
                Text("Tag colore").font(Typo.label).foregroundColor(Lc.text2).frame(width: 92, alignment: .leading)
                TagPicker(tag: shot?.label, size: 13) { model.tag([key], $0) }
                Spacer()
            }
            Segment(options: ["Nessuna", "Scelta", "Scartata"], selected: shot?.flag == "pick" ? 1 : (shot?.flag == "reject" ? 2 : 0)) { i in
                model.flag([key], i == 1 ? "pick" : (i == 2 ? "reject" : "none"))
            }
            .padding(.vertical, 4)
        }
    }
}

// MARK: - New style

private let styleParts: [(String, [String], Bool)] = [
    ("Esposizione e HDR", ["light"], true),
    ("Bilanciamento del bianco", ["whiteBalance"], false),
    ("Colore (vividezza, saturazione)", ["color"], true),
    ("Editor colore", ["colorMixer"], true),
    ("Bilanciamento colore", ["colorGrading"], true),
    ("Curva", ["toneCurve"], true),
    ("Chiarezza, dehaze, vignettatura, grana", ["effects", "vignette", "grain"], true),
    ("Dettagli (nitidezza, rumore)", ["detail"], false),
    ("Profilo, bianco e nero, calibrazione", ["profile", "treatment", "calibration"], true),
]

struct NewStyleSheet: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var ed: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var on = styleParts.map { $0.2 }
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button("Annulla") { dismiss() }.font(Typo.body).foregroundColor(Lc.text2)
                Spacer()
                Text("Nuovo stile").font(Typo.title).foregroundColor(Lc.text)
                Spacer()
                Button("Salva") { save() }
                    .font(Typo.body.weight(.semibold))
                    .foregroundColor(canSave ? Lc.accent : Lc.text3)
                    .disabled(!canSave)
            }
            .padding(.horizontal, 18)
            .frame(height: 50)
            .background(Lc.header)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Field(label: "Nome", text: $name, placeholder: "Es. Concerto caldo")
                    Text("Il look di questa foto, da applicare ad altre o a ogni scatto in arrivo. Si esporta anche per Lightroom.")
                        .font(Typo.caption).foregroundColor(Lc.text3)
                    Text("COSA INCLUDE").overline().padding(.top, 4)
                    VStack(spacing: 0) {
                        ForEach(styleParts.indices, id: \.self) { i in
                            ToggleRow(label: styleParts[i].0, on: on[i]) { on[i] = $0 }
                            if i < styleParts.count - 1 { Rectangle().fill(Lc.hairline).frame(height: 0.5) }
                        }
                    }
                    .padding(.horizontal, 12)
                    .background(Lc.panel)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                .padding(18)
            }
        }
        .background(Lc.window.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    private var canSave: Bool { !busy && !name.trimmingCharacters(in: .whitespaces).isEmpty && on.contains(true) }

    private func save() {
        busy = true
        let groups = styleParts.enumerated().filter { on[$0.offset] }.flatMap { $0.element.1 }
        let n = name.trimmingCharacters(in: .whitespaces)
        ed.createPreset(name: n, groups: groups) { id in
            busy = false
            model.say(id != nil ? "Stile «\(n)» salvato" : "Stile non salvato")
            dismiss()
        }
    }
}
