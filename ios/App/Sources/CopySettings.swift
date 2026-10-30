import SwiftUI

/// What a copy (or a sync) carries, Lightroom's way: the photo's settings by group, each ticked or
/// not. The engine's own groups, in the panel's order.
enum CopyGroups {
    static let sections: [(String, [(id: String, name: String)])] = [
        ("Base", [
            ("profile", "Profilo"), ("treatment", "Bianco e nero"), ("whiteBalance", "Bilanciamento del bianco"), ("light", "Luce"),
            ("toneCurve", "Curva"), ("color", "Colore"), ("colorMixer", "Editor colore"), ("colorGrading", "Color Grading"),
            ("effects", "Effetti"), ("vignette", "Vignettatura"), ("grain", "Grana"), ("detail", "Dettagli"), ("calibration", "Calibrazione"),
        ]),
        ("Obiettivo e geometria", [("optics", "Correzione obiettivo"), ("lensBlur", "Sfocatura obiettivo"), ("geometry", "Prospettiva"), ("crop", "Ritaglio")]),
        ("Ritocchi", [("masks", "Maschere"), ("spots", "Rimozione macchie"), ("redEye", "Occhi rossi")]),
    ]

    static var all: Set<String> { Set(sections.flatMap { $0.1.map(\.id) }) }

    /// Lightroom's default: everything but the framing and the retouching of one photo.
    static var standard: Set<String> { all.subtracting(["crop", "masks", "spots", "redEye"]) }

    /// The last choice (the next copy starts from it).
    static var last: Set<String> {
        get { UserDefaults.standard.stringArray(forKey: "copyGroups").map(Set.init) ?? standard }
        set { UserDefaults.standard.set(Array(newValue), forKey: "copyGroups") }
    }

    /// The engine's order (the panel's).
    static func ordered(_ s: Set<String>) -> [String] { sections.flatMap { $0.1.map(\.id) }.filter { s.contains($0) } }
}

/// Lightroom's Copy Settings: tick what goes, then copy (or sync). Everything, nothing or the
/// usual choice in one tap; the choice is remembered.
struct CopySettingsSheet: View {
    let title: String
    let action: String
    var note: String? = nil
    let done: ([String]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var on = CopyGroups.last

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button("Annulla") { dismiss() }.font(Typo.body).foregroundColor(Lc.text2)
                Spacer()
                Text(title).font(Typo.title).foregroundColor(Lc.text)
                Spacer()
                Button(action) {
                    CopyGroups.last = on
                    done(CopyGroups.ordered(on))
                    dismiss()
                }
                .font(Typo.body.weight(.semibold))
                .foregroundColor(on.isEmpty ? Lc.text3 : Lc.accent)
                .disabled(on.isEmpty)
            }
            .padding(.horizontal, 18)
            .frame(height: 50)
            .background(Lc.header)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let n = note {
                        Text(n).font(Typo.caption).foregroundColor(Lc.text2).fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 8) {
                        MiniButton(title: "Tutto") { on = CopyGroups.all }
                        MiniButton(title: "Niente") { on = [] }
                        MiniButton(title: "Predefinito") { on = CopyGroups.standard }
                        Spacer()
                        Text("\(on.count) di \(CopyGroups.all.count)").font(Typo.caption).foregroundColor(Lc.text3)
                    }
                    ForEach(CopyGroups.sections, id: \.0) { section in
                        VStack(alignment: .leading, spacing: 0) {
                            sectionHeader(section)
                            ForEach(section.1, id: \.id) { g in
                                check(g.name, on.contains(g.id), indent: true) {
                                    if on.contains(g.id) { on.remove(g.id) } else { on.insert(g.id) }
                                }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(Lc.panel)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                }
                .padding(18)
            }
        }
        .background(Lc.window.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    /// A section's own box: all of it on or off.
    private func sectionHeader(_ section: (String, [(id: String, name: String)])) -> some View {
        let ids = Set(section.1.map(\.id))
        let all = ids.isSubset(of: on), none = ids.isDisjoint(with: on)
        return Button {
            if all { on.subtract(ids) } else { on.formUnion(ids) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: all ? "checkmark.square.fill" : (none ? "square" : "minus.square.fill"))
                    .font(.system(size: 18)).foregroundColor(none ? Lc.text3 : Lc.accent)
                Text(section.0.uppercased()).overline()
                Spacer()
            }
            .frame(height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func check(_ label: String, _ isOn: Bool, indent: Bool, _ toggle: @escaping () -> Void) -> some View {
        Button(action: toggle) {
            HStack(spacing: 10) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 17)).foregroundColor(isOn ? Lc.accent : Lc.text3)
                Text(label).font(Typo.label).foregroundColor(isOn ? Lc.text : Lc.text2)
                Spacer()
            }
            .padding(.leading, indent ? 22 : 0)
            .frame(height: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
