import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Develop one shot: the photo large on the left, the tools in a column on the right.
struct EditorView: View {
    @EnvironmentObject var model: AppModel
    /// The model's editor, observed directly so its sliders redraw on their own.
    @ObservedObject var ed: EditorModel
    /// (tests: `-tool curve` opens on that tool)
    @State private var tool: Tool = Tool(rawValue: UserDefaults.standard.string(forKey: "tool") ?? "") ?? .light
    @State private var before: CGImage?
    @State private var holdingBefore = false

    var body: some View {
        let shot = model.library.shot(ed.key)
        VStack(spacing: 0) {
            topBar(shot)
            HStack(spacing: 0) {
                photo(shot)
                panel
                    .frame(width: 400)
                    .background(LinearGradient(colors: [Lc.surface, Lc.night], startPoint: .top, endPoint: .bottom))
                    .overlay(Rectangle().fill(Lc.hairline).frame(width: 1), alignment: .leading)
            }
        }
        .background(Lc.ink.ignoresSafeArea())
    }

    private func topBar(_ shot: Shot?) -> some View {
        HStack(spacing: 6) {
            iconButton("chevron.left") { model.go(.session) }
            VStack(alignment: .leading, spacing: 2) {
                Text(shot?.name ?? ed.key).font(Typo.headline).foregroundColor(Lc.text).lineLimit(1)
                Text("RAW · LightCraft").font(Typo.caption).foregroundColor(Lc.text3)
            }
            .padding(.leading, 6)
            Spacer()
            iconButton("arrow.uturn.backward", enabled: ed.canUndo) { ed.undo() }
            iconButton("arrow.uturn.forward", enabled: ed.canRedo) { ed.redo() }
            iconButton("arrow.counterclockwise") { ed.reset() }
            iconButton("square.and.arrow.down") {
                model.selection = [ed.key]
                model.go(.library)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func iconButton(_ icon: String, enabled: Bool = true, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 19, weight: .medium))
                .foregroundColor(enabled ? Lc.text : Lc.text3.opacity(0.5))
                .frame(width: 46, height: 46)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .disabled(!enabled)
    }

    private func photo(_ shot: Shot?) -> some View {
        GeometryReader { geo in
            ZStack {
                let pic = model.loupe.pics[ed.key]
                ZoomView(image: before ?? pic?.image ?? shot?.thumb, key: ed.key, onTap: { p in
                    if ed.picking, let p = p { ed.pickWhite(p) }
                })
                VStack {
                    HStack {
                        if ed.picking {
                            Pill {
                                Image(systemName: "eyedropper").foregroundColor(Lc.amber)
                                Text("Tocca un punto bianco o grigio").font(Typo.label).foregroundColor(Lc.text)
                            }
                        }
                        Spacer()
                        HistogramView(histogram: ed.histogram)
                    }
                    Spacer()
                    HStack {
                        // hold to see the photo as it was
                        Image(systemName: "rectangle.lefthalf.inset.filled")
                            .font(.system(size: 18))
                            .foregroundColor(holdingBefore ? Lc.ink : Lc.text)
                            .frame(width: 46, height: 46)
                            .background(holdingBefore ? AnyShapeStyle(Lc.amber) : AnyShapeStyle(Material.ultraThinMaterial))
                            .clipShape(Circle())
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { _ in
                                        guard !holdingBefore else { return }
                                        holdingBefore = true
                                        let (w, h) = ed.viewport
                                        let p = ed.photo
                                        Task {
                                            if let r = try? await model.libraryEngineBefore(p, w, h), holdingBefore { before = r }
                                        }
                                    }
                                    .onEnded { _ in holdingBefore = false; before = nil }
                            )
                        Spacer()
                    }
                }
                .padding(16)
                if pic == nil && shot?.thumb == nil { ProgressView().tint(Lc.amber) }
            }
            .onAppear { ed.viewport = (w: Int(geo.size.width * UIScreen.main.scale), h: Int(geo.size.height * UIScreen.main.scale)) }
            .onChange(of: geo.size) { s in ed.viewport = (w: Int(s.width * UIScreen.main.scale), h: Int(s.height * UIScreen.main.scale)) }
        }
    }

    // ---- the tools

    private var panel: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Tool.allCases) { t in
                        Button { withAnimation(Motion.snappy) { tool = t } } label: {
                            VStack(spacing: 5) {
                                Image(systemName: t.icon).font(.system(size: 18, weight: .medium))
                                Text(t.label).font(Typo.caption)
                                Circle().fill(Lc.amber).frame(width: 4, height: 4).opacity(t == tool ? 1 : 0)
                            }
                            .foregroundColor(t == tool ? Lc.amber : Lc.text3)
                            .frame(width: 64, height: 62)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
            }
            .frame(height: 70)
            Rectangle().fill(Lc.hairline).frame(height: 1)
            ScrollView {
                Group {
                    switch tool {
                    case .presets: PresetsPanel(ed: ed)
                    case .white: WhitePanel(ed: ed)
                    case .light: SliderList(ed: ed, sections: [("", Controls.light)])
                    case .color: ColorPanel(ed: ed)
                    case .hsl: HslPanel(ed: ed)
                    case .grading: GradingPanel(ed: ed)
                    case .curve: CurvePanel(ed: ed)
                    case .effects: SliderList(ed: ed, sections: [("", Controls.effects), ("Vignettatura", Controls.vignette), ("Grana", Controls.grain)])
                    case .detail: SliderList(ed: ed, sections: [("", Controls.sharpen), ("Riduzione rumore", Controls.noise), ("Rumore colore", Controls.colorNoise)])
                    }
                }
                .padding(.vertical, 10)
                .transition(.opacity)
                .id(tool)
            }
        }
    }
}

extension AppModel {
    func libraryEngineBefore(_ photo: Int64, _ w: Int, _ h: Int) async throws -> CGImage {
        try await library.engine.renderBefore(photo, w, h).image
    }
}

/// A slider of the editor's photo.
struct EdSlider: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var ed: EditorModel
    let id: String
    var label: String?

    var body: some View {
        if let c = model.controls[id] {
            LcSlider(control: c, value: ed.values[id] ?? c.def, label: label, onChange: { ed.set(id, $0) }, onStart: { ed.start(c.label) }, onEnd: { ed.end() })
        }
    }
}

struct SliderList: View {
    @ObservedObject var ed: EditorModel
    let sections: [(String, [String])]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(sections.enumerated()), id: \.offset) { _, s in
                if !s.0.isEmpty { Text(s.0.uppercased()).overline().padding(.leading, 20).padding(.top, 18).padding(.bottom, 4) }
                ForEach(s.1, id: \.self) { id in EdSlider(ed: ed, id: id) }
            }
        }
    }
}

struct ColorPanel: View {
    @ObservedObject var ed: EditorModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Segmented(options: ["Colore", "Bianco e nero"], selected: ed.bw ? 1 : 0) { ed.setBw($0 == 1) }
                .padding(.horizontal, 20).padding(.vertical, 6)
            Text("PRESENZA").overline().padding(.leading, 20).padding(.top, 14).padding(.bottom, 2)
            EdSlider(ed: ed, id: "color.vibrance")
            EdSlider(ed: ed, id: "color.saturation")
        }
    }
}

private let whiteModes: [(String, String)] = [
    ("asShot", "Come scattato"), ("auto", "Auto"), ("daylight", "Luce diurna"), ("cloudy", "Nuvoloso"),
    ("shade", "Ombra"), ("tungsten", "Tungsteno"), ("fluorescent", "Fluorescente"), ("flash", "Flash"),
]

/// White balance: the presets, the picker (touch something neutral on the photo), temperature and tint.
struct WhitePanel: View {
    @ObservedObject var ed: EditorModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FlowChips(items: ed.wbMode == "custom" ? [("custom", "Personalizzato")] + whiteModes : whiteModes, selected: ed.wbMode) { m in
                if m != "custom" { ed.whiteBalance(m) }
            }
            .padding(.horizontal, 16).padding(.vertical, 6)
            Button { ed.picking.toggle() } label: {
                HStack(spacing: 12) {
                    Image(systemName: "eyedropper").font(.system(size: 19))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Contagocce").font(Typo.label)
                        Text(ed.picking ? "Tocca un punto neutro sulla foto" : "Prendi il bianco da un punto grigio o bianco").font(Typo.caption).opacity(0.75)
                    }
                    Spacer()
                }
                .foregroundColor(ed.picking ? Lc.ink : Lc.text)
                .padding(16)
                .background(ed.picking ? AnyShapeStyle(Lc.amber) : AnyShapeStyle(Lc.raised))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Lc.hairline))
            }
            .buttonStyle(PressStyle())
            .padding(.horizontal, 20).padding(.vertical, 10)
            EdSlider(ed: ed, id: "wb.temp")
            EdSlider(ed: ed, id: "wb.tint")
        }
    }
}

/// Chips that wrap onto rows (the side panel is narrow).
struct FlowChips: View {
    let items: [(String, String)]
    let selected: String
    let onPick: (String) -> Void

    var body: some View {
        let rows = stride(from: 0, to: items.count, by: 3).map { Array(items[$0..<min($0 + 3, items.count)]) }
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 8) {
                    ForEach(row.indices, id: \.self) { j in
                        Chip(text: row[j].1, on: row[j].0 == selected) { onPick(row[j].0) }
                    }
                }
            }
        }
    }
}

struct HslPanel: View {
    @ObservedObject var ed: EditorModel
    @State private var band: Band = .red

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                ForEach(Band.allCases) { b in
                    let on = b == band
                    let edited = ["hue", "sat", "lum"].contains { (ed.values["mixer.\(b.rawValue).\($0)"] ?? 0) != 0 }
                    Button { withAnimation(Motion.bouncy) { band = b } } label: {
                        Circle().fill(b.color)
                            .frame(width: 30, height: 30)
                            .overlay(Circle().fill(Color.white).frame(width: 5, height: 5).opacity(edited ? 1 : 0))
                            .padding(3)
                            .overlay(Circle().stroke(Color.white, lineWidth: on ? 2 : 0))
                    }
                    .buttonStyle(.plain)
                    if b != .magenta { Spacer(minLength: 2) }
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            Text(band.label).font(Typo.headline).foregroundColor(Lc.text).padding(.horizontal, 20).padding(.vertical, 4)
            EdSlider(ed: ed, id: "mixer.\(band.rawValue).hue")
            EdSlider(ed: ed, id: "mixer.\(band.rawValue).sat")
            EdSlider(ed: ed, id: "mixer.\(band.rawValue).lum")
        }
    }
}

struct GradingPanel: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var ed: EditorModel
    @State private var zone: Zone = .midtones

    var body: some View {
        let hueId = "grading.\(zone.rawValue).hue", satId = "grading.\(zone.rawValue).sat"
        let h = ed.values[hueId] ?? 0, s = ed.values[satId] ?? 0
        VStack(alignment: .leading, spacing: 0) {
            Segmented(options: Zone.allCases.map(\.label), selected: Zone.allCases.firstIndex(of: zone) ?? 1) { zone = Zone.allCases[$0] }
                .padding(.horizontal, 20).padding(.vertical, 6)
            ColorWheel(hue: h, sat: s, onChange: { ed.set(hueId, $0); ed.set(satId, $1) }, onStart: { ed.start("Color Grading") }, onEnd: { ed.end() })
                .frame(width: 220, height: 220)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            HStack {
                Text("Tonalità \(Int(h))°").font(Typo.value).foregroundColor(Lc.text2)
                Spacer()
                Text("Saturazione \(Int(s))").font(Typo.value).foregroundColor(Lc.text2)
            }
            .padding(.horizontal, 20)
            EdSlider(ed: ed, id: "grading.\(zone.rawValue).lum")
            EdSlider(ed: ed, id: "grading.blending")
            EdSlider(ed: ed, id: "grading.balance")
        }
    }
}

struct CurvePanel: View {
    @ObservedObject var ed: EditorModel
    @State private var ch: Channel = .master
    @State private var parametric = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Segmented(options: ["Punti", "Parametrica"], selected: parametric ? 1 : 0) { parametric = $0 == 1 }
                .padding(.horizontal, 20).padding(.vertical, 6)
            if parametric {
                ForEach(Controls.parametric, id: \.self) { EdSlider(ed: ed, id: $0) }
            } else {
                HStack(spacing: 10) {
                    ForEach(Channel.allCases) { c in
                        let on = c == ch
                        Button { ch = c } label: {
                            Text(c.label).font(Typo.caption).foregroundColor(on ? Lc.text : Lc.text2)
                                .frame(width: 44, height: 34)
                                .background(on ? c.color.opacity(0.22) : Color.clear)
                                .clipShape(Capsule())
                                .overlay(Capsule().stroke(on ? c.color : Lc.hairline2, lineWidth: 1.5))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 10)
                CurveEditor(points: ed.curves[ch] ?? [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)], color: ch.color, histogram: ed.histogram, onChange: { ed.curve(ch, $0) }, onStart: { ed.start("Curva") }, onEnd: { ed.end() })
                    .padding(.horizontal, 20)
                    .id(ch)
            }
        }
    }
}

struct PresetsPanel: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var ed: EditorModel
    @State private var group: String?
    @State private var creating = false
    @State private var importing = false
    @State private var deleting: Preset?

    var body: some View {
        let groups = model.presets.map(\.group).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        let shown = model.presets.filter { group == nil || $0.group == group }
        VStack(alignment: .leading, spacing: 14) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Chip(text: "Importa", on: false, icon: "square.and.arrow.down.on.square", accent: true) { importing = true }
                    Chip(text: "Tutti", on: group == nil) { group = nil }
                    ForEach(groups, id: \.self) { g in Chip(text: groupLabel(g), on: group == g) { group = g } }
                }
                .padding(.horizontal, 16)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 10)], spacing: 14) {
                NewPresetTile { creating = true }
                ForEach(shown) { p in
                    PresetTile(name: p.name, image: ed.variants[p.id], selected: p.id == ed.preset) { ed.applyPreset(p.id, amount: ed.presetAmount) }
                        .contextMenu {
                            if !p.builtin {
                                Button(role: .destructive) { deleting = p } label: { Label("Elimina", systemImage: "trash") }
                            }
                        }
                }
            }
            .padding(.horizontal, 16)
            if let id = ed.preset, let c = presetAmountControl {
                LcSlider(control: c, value: Double(ed.presetAmount), label: "Intensità", onChange: { ed.presetAmount = Int($0) }, onEnd: { ed.applyPreset(id, amount: ed.presetAmount) })
            }
        }
        .onAppear { ed.loadVariants(model.presets.map(\.id)) }
        .onChange(of: model.presets) { p in ed.loadVariants(p.map(\.id)) }
        .onChange(of: ed.variants.isEmpty) { empty in if empty { ed.loadVariants(model.presets.map(\.id)) } }
        .sheet(isPresented: $creating) { NewPresetSheet(ed: ed).environmentObject(model) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { r in
            if case .success(let urls) = r { model.importPresets(urls) }
        }
        .alert("Eliminare «\(deleting?.name ?? "")»?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Elimina", role: .destructive) { if let p = deleting { model.deletePreset(p) }; deleting = nil }
            Button("Annulla", role: .cancel) { deleting = nil }
        } message: {
            Text("Il preset sparisce da questo iPad; le foto a cui l'hai applicato restano come sono.")
        }
    }

    private var presetAmountControl: Control? { Control(id: "preset.amount", label: "Intensità", min: 0, max: 200, def: 100, step: 1, decimals: 0, track: .plain) }
}

struct PresetTile: View {
    let name: String
    let image: CGImage?
    let selected: Bool
    var loading = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack(alignment: .topTrailing) {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Lc.raised)
                    if let img = image {
                        Image(decorative: img, scale: 1).resizable().scaledToFill()
                    } else if loading {
                        ProgressView().tint(Lc.text3).frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        Text(name.split(separator: " ").prefix(2).map { String($0.prefix(1)) }.joined())
                            .font(Typo.title).foregroundColor(Lc.amber.opacity(0.8)).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    if selected {
                        Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundColor(Lc.ink)
                            .frame(width: 22, height: 22).background(Lc.amber).clipShape(Circle()).padding(6)
                    }
                }
                .frame(height: 126)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(selected ? Lc.amber : Lc.hairline, lineWidth: selected ? 2 : 1))
                .scaleEffect(selected ? 1.03 : 1)
                .animation(Motion.bouncy, value: selected)
                Text(name).font(Typo.caption).foregroundColor(selected ? Lc.text : Lc.text2).lineLimit(1)
            }
        }
        .buttonStyle(PressStyle())
    }
}

struct NewPresetTile: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Lc.night)
                    Circle().fill(Lc.amberGlow).frame(width: 44, height: 44)
                    Image(systemName: "plus").font(.system(size: 20, weight: .semibold)).foregroundColor(Lc.amber)
                }
                .frame(height: 126)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Lc.amber.opacity(0.6), lineWidth: 1.5))
                Text("Nuovo").font(Typo.caption).foregroundColor(Lc.amber)
            }
        }
        .buttonStyle(PressStyle())
    }
}

/// What a new preset holds: LightCraft's settings groups, as the panels name them.
private let presetParts: [(String, [String], Bool)] = [
    ("Luce", ["light"], true),
    ("Bilanciamento del bianco", ["whiteBalance"], false),
    ("Colore", ["color"], true),
    ("HSL", ["colorMixer"], true),
    ("Color grading", ["colorGrading"], true),
    ("Curve", ["toneCurve"], true),
    ("Effetti, vignettatura e grana", ["effects", "vignette", "grain"], true),
    ("Dettagli (nitidezza e rumore)", ["detail"], false),
    ("Profilo e bianco e nero", ["profile", "treatment", "calibration"], true),
]

struct NewPresetSheet: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var ed: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var on = presetParts.map { $0.2 }
    @State private var busy = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Nuovo preset").font(Typo.title).foregroundColor(Lc.text)
                Text("Il look di questa foto, da applicare ad altre o a ogni scatto in arrivo.").font(Typo.body).foregroundColor(Lc.text2)
                Field(label: "Nome", text: $name, placeholder: "Es. Concerto caldo")
                Text("COSA INCLUDE").overline().padding(.top, 6)
                ForEach(presetParts.indices, id: \.self) { i in
                    Toggle(isOn: $on[i]) { Text(presetParts[i].0).font(Typo.label).foregroundColor(Lc.text) }
                        .tint(Lc.amber)
                }
                PrimaryButton(title: "Salva preset", enabled: !name.trimmingCharacters(in: .whitespaces).isEmpty && on.contains(true), busy: busy) {
                    busy = true
                    let groups = presetParts.enumerated().filter { on[$0.offset] }.flatMap { $0.element.1 }
                    let n = name.trimmingCharacters(in: .whitespaces)
                    ed.createPreset(name: n, groups: groups) { id in
                        busy = false
                        model.say(id != nil ? "Preset «\(n)» salvato" : "Preset non salvato")
                        dismiss()
                    }
                }
                .padding(.top, 8)
            }
            .padding(28)
        }
        .background(Lc.surface.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }
}
