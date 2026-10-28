import SwiftUI
import UIKit

/// Capture One's browser in grid view: the session's shots side by side, each with its name, rating,
/// colour tag and flag. A tap opens a shot (it zooms out of its thumbnail); long press or Seleziona
/// to select several; pinch to make the thumbnails bigger or smaller.
struct BrowserView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var library: Library
    @State private var minRating = 0
    @State private var tagFilter: ColorTag?
    @State private var flagFilter = "all"
    @State private var sort = "time"
    @State private var multi = false
    @State private var cell: CGFloat = 180
    @State private var pinchFrom: CGFloat?
    @State private var exportOpen = false
    @State private var confirmDelete = false

    private var list: [Shot] {
        var l = library.shots.filter { $0.stage != .failed }
        if minRating > 0 { l = l.filter { $0.rating >= minRating } }
        if let t = tagFilter { l = l.filter { $0.label == t } }
        switch flagFilter {
        case "pick": l = l.filter { $0.flag == "pick" }
        case "reject": l = l.filter { $0.flag == "reject" }
        case "none": l = l.filter { $0.flag == "none" }
        default: break
        }
        switch sort {
        case "timeDesc": l.reverse()
        case "name": l.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case "rating": l.sort { $0.rating > $1.rating }
        default: break
        }
        return l
    }

    var body: some View {
        let shots = list
        VStack(spacing: 0) {
            bar(shots)
            ZStack(alignment: .bottom) {
                Lc.viewer
                if shots.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "photo.on.rectangle").font(.system(size: 34)).foregroundColor(Lc.text3)
                        Text(library.shots.isEmpty ? "Nessuno scatto ancora" : "Nessuna foto con questi filtri").font(Typo.title).foregroundColor(Lc.text)
                        Text(library.shots.isEmpty ? "Le foto della sessione compaiono qui." : "Cambia i filtri in alto.").font(Typo.body).foregroundColor(Lc.text2)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: cell, maximum: cell * 1.5), spacing: 3)], spacing: 3) {
                            ForEach(shots) { s in
                                BrowserCell(shot: s, selected: model.selection.contains(s.key), current: s.key == model.current, multi: multi)
                                    .overlay(GeometryReader { g in
                                        Color.clear
                                            .contentShape(Rectangle())
                                            .onTapGesture { tap(s, frame: g.frame(in: .global)) }
                                            .onLongPressGesture {
                                                Haptics.tick()
                                                multi = true
                                                model.toggle(s.key)
                                            }
                                    })
                            }
                        }
                        .padding(3)
                        .padding(.bottom, model.selection.isEmpty || !multi ? 0 : 50)
                    }
                    .simultaneousGesture(
                        MagnificationGesture()
                            .onChanged { m in
                                if pinchFrom == nil { pinchFrom = cell }
                                cell = max(110, min(420, (pinchFrom ?? cell) * m))
                            }
                            .onEnded { _ in
                                pinchFrom = nil
                                model.settings.gridSize = Double(cell)
                            }
                    )
                }
                if multi && !model.selection.isEmpty {
                    SelectionBar(library: library, exportOpen: $exportOpen, confirmDelete: $confirmDelete)
                        .transition(.move(edge: .bottom))
                }
            }
            .ignoresSafeArea(edges: .bottom)
        }
        .background(Lc.window.ignoresSafeArea())
        .onAppear { cell = CGFloat(model.settings.gridSize) }
        .sheet(isPresented: Binding(get: { exportOpen || (model.export != nil && model.screen == .browser) }, set: { if !$0 { exportOpen = false; if model.export?.finished != false { model.export = nil } } })) {
            ExportSheet(keys: model.selection) { exportOpen = false }.environmentObject(model)
        }
        .alert("Eliminare \(model.selection.count == 1 ? "la foto" : "\(model.selection.count) foto")?", isPresented: $confirmDelete) {
            Button("Elimina", role: .destructive) {
                model.delete(model.selection)
                multi = false
            }
            Button("Annulla", role: .cancel) {}
        } message: {
            Text("Spariscono da questo iPad, con le loro regolazioni. Sulla scheda della fotocamera restano.")
        }
    }

    private func tap(_ s: Shot, frame: CGRect) {
        if multi {
            model.toggle(s.key)
            if model.selection.isEmpty { multi = false }
            return
        }
        guard s.photo != 0 || s.thumb != nil else { return }
        model.selection = [s.key]
        // the picture's place in the cell: where the zoom starts
        let box = CGRect(x: frame.minX + 8, y: frame.minY + 8, width: frame.width - 16, height: frame.width * 3 / 4 - 12)
        model.open(s.key, from: box)
    }

    private func bar(_ shots: [Shot]) -> some View {
        HStack(spacing: 6) {
            ToolIcon(icon: "slider.horizontal.below.rectangle", enabled: model.current != nil) {
                if let k = model.current { model.open(k, from: nil) }
            }
            VStack(alignment: .leading, spacing: 0) {
                Text("Libreria").font(Typo.labelStrong).foregroundColor(Lc.text)
                Text(multi ? "\(model.selection.count) selezionate" : "\(shots.count) di \(library.shots.count)").font(Typo.caption).foregroundColor(Lc.text3)
            }
            .padding(.leading, 4)
            Spacer()
            filterMenu(title: minRating == 0 ? "Valutazione" : "≥ \(String(repeating: "★", count: minRating))", active: minRating > 0) {
                Button("Tutte") { minRating = 0 }
                ForEach(1...5, id: \.self) { n in Button("Almeno " + String(repeating: "★", count: n)) { minRating = n } }
            }
            filterMenu(title: tagFilter?.label ?? "Tag", active: tagFilter != nil, dot: tagFilter?.color) {
                Button("Tutti") { tagFilter = nil }
                ForEach(ColorTag.allCases) { t in Button(t.label) { tagFilter = t } }
            }
            filterMenu(title: ["pick": "Scelte", "reject": "Scartate", "none": "Senza flag"][flagFilter] ?? "Flag", active: flagFilter != "all") {
                Button("Tutte") { flagFilter = "all" }
                Button("Scelte") { flagFilter = "pick" }
                Button("Scartate") { flagFilter = "reject" }
                Button("Senza flag") { flagFilter = "none" }
            }
            filterMenu(title: ["time": "Data ↑", "timeDesc": "Data ↓", "name": "Nome", "rating": "Valutazione"][sort] ?? "Ordina", active: false, icon: "arrow.up.arrow.down") {
                Button("Data, dal primo") { sort = "time" }
                Button("Data, dall'ultimo") { sort = "timeDesc" }
                Button("Nome") { sort = "name" }
                Button("Valutazione") { sort = "rating" }
            }
            Rectangle().fill(Lc.hairline2).frame(width: 1, height: 22).padding(.horizontal, 4)
            barButton(multi ? "Fine" : "Seleziona", accent: multi) {
                withAnimation(Motion.quick) {
                    multi.toggle()
                    if !multi { model.selection = [] }
                }
            }
            if multi {
                barButton("Tutte") { model.selection = Set(shots.filter { $0.photo != 0 }.map(\.key)) }
            }
            Rectangle().fill(Lc.hairline2).frame(width: 1, height: 22).padding(.horizontal, 4)
            Button { model.openSettings = true } label: {
                LinkStatus(tether: model.tether, raw: model.settings.raw)
            }
            .buttonStyle(PressStyle())
        }
        .padding(.horizontal, 8)
        .frame(height: 48)
        .padding(.top, windowControlsInset)
        .background(Lc.header)
        .overlay(Rectangle().fill(Lc.line).frame(height: 1), alignment: .bottom)
    }

    private func barButton(_ title: String, accent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(Typo.labelStrong).foregroundColor(accent ? Lc.accent : Lc.text)
                .padding(.horizontal, 11).frame(height: 32)
                .background(Lc.raised)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .buttonStyle(PressStyle())
    }

    private func filterMenu<Items: View>(title: String, active: Bool, dot: Color? = nil, icon: String = "line.3.horizontal.decrease", @ViewBuilder items: () -> Items) -> some View {
        Menu {
            items()
        } label: {
            HStack(spacing: 5) {
                if let d = dot { Circle().fill(d).frame(width: 8, height: 8) } else { Image(systemName: icon).font(.system(size: 11)) }
                Text(title).font(Typo.label).lineLimit(1)
            }
            .foregroundColor(active ? Lc.accent : Lc.text2)
            .padding(.horizontal, 10).frame(height: 32)
            .background(Lc.field)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(active ? Lc.accent.opacity(0.5) : Lc.hairline, lineWidth: 0.5))
        }
    }
}

/// One shot in the grid: the picture fitted in its box (never cropped, never spilling over the next)
/// with its stars, tag and flag over its bottom edge, the name under it.
private struct BrowserCell: View {
    let shot: Shot
    let selected: Bool
    let current: Bool
    let multi: Bool

    var body: some View {
        VStack(spacing: 0) {
            Color.clear
                .aspectRatio(4.0 / 3.0, contentMode: .fit)
                .overlay(
                    ZStack(alignment: .bottom) {
                        if let t = shot.thumb {
                            Image(decorative: t, scale: 1)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            Rectangle().fill(Lc.field)
                        }
                        if shot.stage == .arriving || shot.stage == .preview {
                            ProgressRing(fraction: shot.progress, line: 2).frame(width: 26, height: 26)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        if shot.rating > 0 || shot.label != nil || shot.flag != "none" {
                            HStack(spacing: 4) {
                                if let t = shot.label { Circle().fill(t.color).frame(width: 7, height: 7) }
                                Stars(rating: shot.rating, size: 8)
                                if shot.flag == "pick" { Image(systemName: "flag.fill").font(.system(size: 8)).foregroundColor(Lc.live) }
                                if shot.flag == "reject" { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundColor(Lc.danger) }
                            }
                            .padding(.horizontal, 5)
                            .frame(height: 15)
                            .background(Color.black.opacity(0.6))
                            .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
                            .padding(.bottom, 4)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                )
            Text(shot.name)
                .font(Typo.caption)
                .foregroundColor(selected ? Lc.text : Lc.text2)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 6)
                .padding(.bottom, 5)
        }
        .background(selected ? Lc.pressed : Lc.panel)
        .overlay(alignment: .topTrailing) {
            if multi {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17))
                    .foregroundColor(selected ? Lc.accent : Color.white.opacity(0.7))
                    .padding(8)
            }
        }
        .overlay(Rectangle().stroke(selected ? Lc.select : (current ? Lc.hairline2 : Color.clear), lineWidth: selected ? 1 : 0.5))
    }
}

/// What to do with the selected shots: rate, tag, flag, style, paste, export, delete.
private struct SelectionBar: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var library: Library
    @Binding var exportOpen: Bool
    @Binding var confirmDelete: Bool

    var body: some View {
        let sel = library.shots.filter { model.selection.contains($0.key) }
        let rating = Set(sel.map(\.rating)).count == 1 ? (sel.first?.rating ?? 0) : 0
        let tag: ColorTag? = Set(sel.map { $0.label?.rawValue ?? "" }).count == 1 ? sel.first?.label : nil
        HStack(spacing: 10) {
            StarRating(rating: rating, size: 12, spacing: -2) { model.rate(model.selection, $0) }
            Rectangle().fill(Lc.hairline2).frame(width: 1, height: 20)
            TagPicker(tag: tag, size: 12) { model.tag(model.selection, $0) }
            Rectangle().fill(Lc.hairline2).frame(width: 1, height: 20)
            ToolIcon(icon: "flag", size: 32) { model.flag(model.selection, "pick") }
            ToolIcon(icon: "xmark", size: 32) { model.flag(model.selection, "reject") }
            ToolIcon(icon: "flag.slash", size: 32) { model.flag(model.selection, "none") }
            Spacer(minLength: 4)
            Menu {
                ForEach(presetGroups(model.presets), id: \.self) { g in
                    Menu(groupLabel(g)) {
                        ForEach(model.presets.filter { $0.group == g }) { p in
                            Button(p.name) { model.applyStyle(p.id, to: model.selection) }
                        }
                    }
                }
            } label: {
                Label("Stile", systemImage: "sparkles").font(Typo.labelStrong).foregroundColor(Lc.text)
                    .padding(.horizontal, 10).frame(height: 30)
                    .background(Lc.raised)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            Button { model.paste(to: model.selection) } label: {
                Label("Applica regolazioni", systemImage: "doc.on.clipboard").font(Typo.labelStrong)
                    .foregroundColor(model.editor.hasCopy ? Lc.text : Lc.text3)
                    .padding(.horizontal, 10).frame(height: 30)
                    .background(Lc.raised)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            .buttonStyle(PressStyle())
            .disabled(!model.editor.hasCopy)
            Button { exportOpen = true } label: {
                Label("Esporta", systemImage: "square.and.arrow.up").font(Typo.labelStrong).foregroundColor(.black)
                    .padding(.horizontal, 12).frame(height: 30)
                    .background(Lc.select)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            .buttonStyle(PressStyle())
            ToolIcon(icon: "trash", size: 32) { confirmDelete = true }
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(Lc.header.opacity(0.98))
        .overlay(Rectangle().fill(Lc.line).frame(height: 1), alignment: .top)
    }
}

/// Capture One's process recipe: JPEG or TIFF at a size, into Photos or to Files / AirDrop; or the
/// photo's look as a Lightroom preset.
struct ExportSheet: View {
    @EnvironmentObject var model: AppModel
    let keys: Set<String>
    let onClose: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var format = 0
    @State private var edge = 0
    @State private var quality = 92.0
    @State private var toPhotos = true
    private let edges = [0, 4096, 2048, 1080]
    private let formats = ["JPEG", "TIFF 8 bit", "TIFF 16 bit", "Preset Lightroom"]

    private var recipe: ExportRecipe {
        switch format {
        case 1: return ExportRecipe(format: .tiff8, quality: Int(quality), edge: edge, toPhotos: toPhotos)
        case 2: return ExportRecipe(format: .tiff16, quality: Int(quality), edge: edge, toPhotos: toPhotos)
        case 3: return ExportRecipe(format: .lightroom, quality: Int(quality), edge: edge, toPhotos: false)
        default: return ExportRecipe(format: .jpeg, quality: Int(quality), edge: edge, toPhotos: toPhotos)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(model.export?.finished == false ? " " : "Chiudi") { close() }
                    .font(Typo.body).foregroundColor(Lc.text2)
                    .disabled(model.export?.finished == false)
                Spacer()
                Text(keys.count == 1 ? "Esporta 1 foto" : "Esporta \(keys.count) foto").font(Typo.title).foregroundColor(Lc.text)
                Spacer()
                Button("Esporta") { model.exportShots(keys, recipe: recipe) }
                    .font(Typo.body.weight(.semibold))
                    .foregroundColor(model.export == nil ? Lc.accent : Lc.text3)
                    .disabled(model.export != nil)
            }
            .padding(.horizontal, 18)
            .frame(height: 52)
            .background(Lc.header)
            VStack(alignment: .leading, spacing: 14) {
                if let e = model.export {
                    if e.finished {
                        VStack(spacing: 10) {
                            Image(systemName: e.saved > 0 ? "checkmark.circle" : "xmark.octagon").font(.system(size: 40, weight: .light)).foregroundColor(e.saved > 0 ? Lc.live : Lc.danger)
                            Text(e.saved == 1 ? "1 file esportato" : "\(e.saved) file esportati").font(Typo.title).foregroundColor(Lc.text)
                            Text(e.message).font(Typo.body).foregroundColor(Lc.text2).multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 20)
                    } else {
                        Text("Esportazione… \(e.done) di \(e.total)").font(Typo.labelStrong).foregroundColor(Lc.text2)
                        ProgressView(value: Double(e.done), total: Double(max(1, e.total))).tint(Lc.accent)
                    }
                } else {
                    Text("FORMATO").overline()
                    Segment(options: formats, selected: format) { format = $0 }
                    if format == 3 {
                        Text("Le regolazioni di ogni foto come preset Lightroom (.xmp): in Lightroom, Importa profili e preset. Ritaglio e ritocchi restano fuori.")
                            .font(Typo.caption).foregroundColor(Lc.text3).fixedSize(horizontal: false, vertical: true)
                    } else {
                        if format == 0 {
                            ValueSlider(
                                control: Control(id: "export.quality", label: "Qualità", min: 60, max: 100, def: 92, step: 1, decimals: 0, track: .plain),
                                value: quality,
                                onChange: { quality = $0 }
                            )
                            .frame(height: ToolSlider.height)
                        } else {
                            Text(format == 1 ? "sRGB, 8 bit per canale, compressione LZW." : "Adobe RGB, 16 bit per canale, compressione ZIP: per ritoccare altrove.")
                                .font(Typo.caption).foregroundColor(Lc.text3)
                        }
                        Text("DIMENSIONE").overline().padding(.top, 4)
                        Segment(options: ["Originale", "4096 px", "2048 px", "1080 px"], selected: edges.firstIndex(of: edge) ?? 0) { edge = edges[$0] }
                        Text("DESTINAZIONE").overline().padding(.top, 4)
                        Segment(options: ["App Foto", "File, AirDrop…"], selected: toPhotos ? 0 : 1) { toPhotos = $0 == 0 }
                    }
                }
                Spacer()
            }
            .padding(18)
        }
        .background(Lc.window.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onAppear {
            edge = model.settings.exportEdge
            quality = Double(model.settings.exportQuality)
        }
        .interactiveDismissDisabled(model.export?.finished == false)
    }

    private func close() {
        model.export = nil
        onClose()
        dismiss()
    }
}
