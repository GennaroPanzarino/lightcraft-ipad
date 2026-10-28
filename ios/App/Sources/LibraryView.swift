import SwiftUI

/// The session's shots in a grid: pick some, send them to Photos as JPEGs.
struct LibraryView: View {
    @EnvironmentObject var model: AppModel
    @State private var exporting = false
    @State private var confirmDelete = false

    var body: some View {
        let list = Array(model.library.shots.filter { $0.stage != .failed }.reversed())
        let selecting = !model.selection.isEmpty
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    GlassIcon(icon: "chevron.left") {
                        if selecting { model.selection = [] } else { model.go(.session) }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(selecting ? "\(model.selection.count) selezionate" : "Sessione").font(Typo.headline).foregroundColor(Lc.text)
                        Text("\(list.count) \(list.count == 1 ? "scatto" : "scatti")").font(Typo.caption).foregroundColor(Lc.text3)
                    }
                    .padding(.leading, 6)
                    Spacer()
                    Button(selecting && model.selection.count == list.count ? "Nessuna" : "Tutte") {
                        if selecting && model.selection.count == list.count { model.selection = [] } else { model.selection = Set(list.filter { $0.photo != 0 }.map(\.key)) }
                    }
                    .font(Typo.label)
                    .foregroundColor(Lc.amber)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                if list.isEmpty {
                    Spacer()
                    VStack(spacing: 14) {
                        Image(systemName: "photo.on.rectangle").font(.system(size: 44)).foregroundColor(Lc.text3)
                        Text("Nessuno scatto ancora").font(Typo.title).foregroundColor(Lc.text)
                        Text("Le foto della sessione compaiono qui.").font(Typo.body).foregroundColor(Lc.text2)
                    }
                    Spacer()
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 6)], spacing: 6) {
                            ForEach(list) { s in tile(s, selecting: selecting) }
                        }
                        .padding(.horizontal, 8)
                        .padding(.bottom, 130)
                    }
                }
            }
            if selecting { actions.transition(.move(edge: .bottom).combined(with: .opacity)) }
        }
        .background(Lc.ink.ignoresSafeArea())
        .animation(Motion.soft, value: selecting)
        .sheet(isPresented: Binding(get: { exporting || model.export != nil }, set: { if !$0 { exporting = false; if model.export?.finished != false { model.export = nil } } })) {
            ExportSheet(count: model.selection.count) { exporting = false }.environmentObject(model)
        }
    }

    private func tile(_ s: Shot, selecting: Bool) -> some View {
        let on = model.selection.contains(s.key)
        return ZStack(alignment: .topTrailing) {
            ZStack {
                Rectangle().fill(Lc.surface)
                if let t = s.thumb { Image(decorative: t, scale: 1).resizable().scaledToFill() }
                if s.stage != .ready {
                    Color.black.opacity(0.4)
                    ProgressRing(fraction: s.progress).frame(width: 28, height: 28)
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity)
            .aspectRatio(1, contentMode: .fill)
            .clipShape(RoundedRectangle(cornerRadius: on ? 14 : 6, style: .continuous))
            .padding(on ? 8 : 0)
            .background(on ? Lc.raised : Color.clear)
            if selecting {
                ZStack {
                    Circle().fill(on ? Lc.amber : Color.black.opacity(0.4)).frame(width: 26, height: 26)
                    Circle().stroke(on ? Color.clear : Color.white, lineWidth: 1.5).frame(width: 26, height: 26)
                    if on { Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundColor(Lc.ink) }
                }
                .padding(12)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .animation(Motion.snappy, value: on)
        .contentShape(Rectangle())
        .onTapGesture {
            if selecting { model.toggle(s.key) } else { model.current = s.key; model.go(.session) }
        }
        .onLongPressGesture { model.toggle(s.key) }
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Button {
                if confirmDelete { model.deleteSelected(); confirmDelete = false } else { confirmDelete = true }
            } label: {
                Image(systemName: "trash").font(.system(size: 19)).foregroundColor(confirmDelete ? .white : Lc.text2)
                    .frame(width: 58, height: 58)
                    .background(confirmDelete ? Lc.danger : Lc.raised)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(PressStyle())
            PrimaryButton(title: confirmDelete ? "Tocca il cestino per eliminare" : "Esporta JPEG (\(model.selection.count))", icon: confirmDelete ? nil : "square.and.arrow.down") {
                if confirmDelete { confirmDelete = false } else { exporting = true }
            }
            .frame(maxWidth: 460)
        }
        .padding(.horizontal, 24)
        .padding(.top, 34)
        .padding(.bottom, 18)
        .background(LinearGradient(colors: [.clear, Lc.ink.opacity(0.95), Lc.ink], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
    }
}

/// The selected shots to Photos as JPEGs.
struct ExportSheet: View {
    @EnvironmentObject var model: AppModel
    let count: Int
    let onClose: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var edge = 0
    @State private var quality = 92.0
    private let edges = [0, 4096, 2048]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let e = model.export, e.finished {
                VStack(spacing: 14) {
                    Image(systemName: e.saved > 0 ? "checkmark.circle.fill" : "xmark.octagon.fill").font(.system(size: 56)).foregroundColor(e.saved > 0 ? Lc.live : Lc.danger)
                    Text(e.saved == 1 ? "1 foto salvata" : "\(e.saved) foto salvate").font(Typo.title).foregroundColor(Lc.text)
                    Text("Le trovi nell'app Foto.").font(Typo.body).foregroundColor(Lc.text2)
                    PrimaryButton(title: "Fatto") {
                        model.export = nil
                        model.selection = []
                        onClose()
                        dismiss()
                    }
                    .padding(.top, 8)
                }
                .frame(maxWidth: .infinity)
            } else if let e = model.export {
                Text("Esportazione…").font(Typo.title).foregroundColor(Lc.text)
                Text("\(e.done) di \(e.total)").font(Typo.value).foregroundColor(Lc.text2)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Lc.raised)
                        Capsule().fill(LinearGradient(colors: [Lc.amberDeep, Lc.amber], startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(12, geo.size.width * CGFloat(e.done) / CGFloat(max(1, e.total))))
                            .animation(Motion.soft, value: e.done)
                    }
                }
                .frame(height: 6)
            } else {
                Text("Esporta \(count) foto in JPEG").font(Typo.title).foregroundColor(Lc.text)
                Text("Con le tue modifiche, nell'app Foto.").font(Typo.body).foregroundColor(Lc.text2)
                Text("DIMENSIONE").overline().padding(.top, 6)
                Segmented(options: ["Originale", "4096 px", "2048 px"], selected: edges.firstIndex(of: edge) ?? 0) { edge = edges[$0] }
                LcSlider(control: Control(id: "export.quality", label: "Qualità", min: 60, max: 100, def: 92, step: 1, decimals: 0, track: .plain), value: quality, onChange: { quality = $0 })
                    .padding(.horizontal, -20)
                PrimaryButton(title: "Esporta") { model.exportSelected(quality: Int(quality), edge: edge) }
            }
        }
        .padding(28)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Lc.surface.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onAppear {
            edge = model.settings.exportEdge
            quality = Double(model.settings.exportQuality)
        }
        .interactiveDismissDisabled(model.export != nil && model.export?.finished == false)
    }
}
