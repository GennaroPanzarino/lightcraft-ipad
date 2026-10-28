import SwiftUI

/// The preset every new shot gets: tiles of the shot on screen with each one.
struct PresetSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let shot: Shot?
    @State private var chosen = ""
    @State private var amount = 100.0
    @State private var group: String?
    @State private var importing = false

    var body: some View {
        let groups = model.presets.map(\.group).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        let photo = shot?.photo ?? 0
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Preset all'arrivo").font(Typo.title).foregroundColor(Lc.text)
                Text("Ogni nuovo scatto lo riceve appena arriva: lo vedi già sviluppato.").font(Typo.body).foregroundColor(Lc.text2)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Chip(text: "Importa", on: false, icon: "square.and.arrow.down.on.square", accent: true) { importing = true }
                        Chip(text: "Tutti", on: group == nil) { group = nil }
                        ForEach(groups, id: \.self) { g in Chip(text: groupLabel(g), on: group == g) { group = g } }
                    }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 12)], spacing: 14) {
                    PresetTile(name: "Nessuno", image: model.variants[""], selected: chosen.isEmpty, loading: photo != 0) { chosen = "" }
                    ForEach(model.presets.filter { group == nil || $0.group == group }) { p in
                        PresetTile(name: p.name, image: model.variants[p.id], selected: chosen == p.id, loading: photo != 0) { chosen = p.id }
                    }
                }
                LcSlider(control: Control(id: "tether.amount", label: "Intensità", min: 0, max: 200, def: 100, step: 1, decimals: 0, track: .plain), value: amount, onChange: { amount = $0 })
                    .padding(.horizontal, -20)
                HStack(spacing: 12) {
                    SecondaryButton(title: "Anche a questa foto") {
                        model.setTetherPreset(chosen, amount: Int(amount), alsoTo: shot?.key)
                        dismiss()
                    }
                    PrimaryButton(title: "Usa") {
                        model.setTetherPreset(chosen, amount: Int(amount), alsoTo: nil)
                        dismiss()
                    }
                }
            }
            .padding(28)
        }
        .background(Lc.surface.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onAppear {
            chosen = model.settings.preset
            amount = Double(model.settings.presetAmount)
            group = model.presets.first { $0.id == model.settings.preset }?.group
            model.loadVariants(photo: photo)
        }
        .onChange(of: model.presets) { _ in model.loadVariants(photo: photo) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { r in
            if case .success(let urls) = r { model.importPresets(urls) }
        }
    }
}

/// The camera, the transfer, the viewer.
struct SettingsSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Impostazioni").font(Typo.title).foregroundColor(Lc.text).padding(.bottom, 8)

                Text("FOTOCAMERA").overline()
                HStack(spacing: 14) {
                    Image(systemName: "camera").foregroundColor(Lc.amber).frame(width: 44, height: 44).background(Lc.raised).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.settings.login.ssid.isEmpty ? "Fotocamera" : model.settings.login.ssid).font(Typo.headline).foregroundColor(Lc.text)
                        Text(model.settings.login.user).font(Typo.caption).foregroundColor(Lc.text3)
                    }
                    Spacer()
                    LinkPill(link: model.tether.link, raw: model.settings.raw, transfer: model.tether.transfer, rate: model.tether.lastRate)
                }
                HStack(spacing: 10) {
                    if model.tether.link.busy {
                        SecondaryButton(title: "Scollega", icon: "link") { model.disconnect() }
                    } else {
                        SecondaryButton(title: "Collega", icon: "arrow.clockwise", tint: Lc.amber) { model.connect() }
                    }
                    SecondaryButton(title: "Dati di accesso") {
                        dismiss()
                        model.go(.connect)
                    }
                }
                if !model.settings.login.fingerprint.isEmpty {
                    HStack {
                        Image(systemName: "key").foregroundColor(Lc.text3)
                        Text(model.settings.login.fingerprint.prefix(30) + "…").font(Typo.caption).foregroundColor(Lc.text3)
                        Spacer()
                        Button("Azzera") { model.settings.login.fingerprint = "" }.font(Typo.label).foregroundColor(Lc.amber)
                    }
                }

                Divider().background(Lc.hairline).padding(.vertical, 10)
                Text("TRASFERIMENTO").overline()
                modeCard("RAW istantaneo", "La foto appare a piena risoluzione appena arriva l'inizio del RAW; il file completo segue nello stesso trasferimento.", icon: "camera.aperture", on: model.settings.raw) { model.setRaw(true) }
                modeCard("JPEG rapido · 2 MP", "Solo un JPEG leggero di ogni scatto, mezzo secondo dopo: per selezionare al volo.", icon: "bolt", on: !model.settings.raw) { model.setRaw(false) }

                Divider().background(Lc.hairline).padding(.vertical, 10)
                Text("VISORE").overline()
                Toggle(isOn: $model.settings.followNewest) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Segui l'ultimo scatto").font(Typo.label).foregroundColor(Lc.text)
                        Text("Ogni foto nuova va subito a schermo").font(Typo.caption).foregroundColor(Lc.text3)
                    }
                }
                .tint(Lc.amber)
                Toggle(isOn: $model.settings.keepAwake) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Schermo sempre acceso").font(Typo.label).foregroundColor(Lc.text)
                        Text("Mentre la fotocamera è collegata").font(Typo.caption).foregroundColor(Lc.text3)
                    }
                }
                .tint(Lc.amber)
                Text("LightCraft Tether per iPad · motore LightCraft").font(Typo.caption).foregroundColor(Lc.text3).padding(.top, 18)
            }
            .padding(28)
        }
        .background(Lc.surface.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    private func modeCard(_ title: String, _ body: String, icon: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: icon).font(.system(size: 20)).foregroundColor(on ? Lc.amber : Lc.text3)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(Typo.headline).foregroundColor(on ? Lc.text : Lc.text2)
                    Text(body).font(Typo.label).foregroundColor(Lc.text2).multilineTextAlignment(.leading)
                }
                Spacer()
            }
            .padding(16)
            .background(on ? Lc.raised : Lc.night)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(on ? Lc.amber.opacity(0.8) : Lc.hairline, lineWidth: on ? 1.5 : 1))
        }
        .buttonStyle(PressStyle())
    }
}
