import SwiftUI

/// The preferences: the camera, the transfer, the workspace, the renderer. A panel that slides in
/// from the left edge over the screen (a tap beside it closes it).
struct SettingsSheet: View {
    @EnvironmentObject var model: AppModel
    let close: () -> Void
    @State private var gpuAtStart = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Impostazioni").font(Typo.title).foregroundColor(Lc.text)
                Spacer()
                Button { close() } label: {
                    Image(systemName: "xmark").font(.system(size: 14, weight: .semibold)).foregroundColor(Lc.text2)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(PressStyle())
            }
            .padding(.leading, 18)
            .padding(.trailing, 8)
            .frame(height: 48)
            .padding(.top, windowControlsInset)
            .background(Lc.header)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    section("FOTOCAMERA") {
                        CameraSettings(tether: model.tether) { close() }
                    }
                    section("TRASFERIMENTO") {
                        Segment(options: ["RAW", "JPEG rapido (2 MP)"], selected: model.settings.raw ? 0 : 1) { model.setRaw($0 == 0) }
                            .padding(.vertical, 6)
                        Text(model.settings.raw
                             ? "La foto appare a piena risoluzione appena arriva l'inizio del RAW; il file completo segue nello stesso trasferimento."
                             : "Solo un JPEG leggero di ogni scatto, mezzo secondo dopo: per selezionare al volo.")
                            .font(Typo.caption).foregroundColor(Lc.text3).padding(.bottom, 6)
                    }
                    section("AREA DI LAVORO") {
                        ToggleRow(label: "Mostra subito il nuovo scatto", on: model.settings.followNewest) { model.settings.followNewest = $0 }
                        divider
                        ToggleRow(label: "Strumenti a sinistra", on: model.settings.toolsLeft) { model.settings.toolsLeft = $0 }
                        divider
                        ToggleRow(label: "Schermo sempre acceso durante il collegamento", on: model.settings.keepAwake) { model.settings.keepAwake = $0 }
                    }
                    section("PRESTAZIONI") {
                        ToggleRow(label: "Sviluppo sulla GPU (Metal)", on: model.settings.gpu) { model.settings.gpu = $0 }
                        if model.settings.gpu != gpuAtStart {
                            Text("Vale dal prossimo avvio dell'app.").font(Typo.caption).foregroundColor(Lc.warn).padding(.bottom, 6)
                        }
                        divider
                        HStack {
                            Text("Motore").font(Typo.label).foregroundColor(Lc.text2)
                            Spacer()
                            Text(model.renderer.isEmpty ? "—" : model.renderer).font(Typo.label).foregroundColor(Lc.text3).lineLimit(1)
                        }
                        .frame(height: 30)
                    }
                    Text("LightCraft Tether per iPad · motore LightCraft").font(Typo.caption).foregroundColor(Lc.text3)
                }
                .padding(18)
            }
        }
        .background(Lc.window.ignoresSafeArea())
        .onAppear { gpuAtStart = model.settings.gpu }
    }

    private var divider: some View { Rectangle().fill(Lc.hairline).frame(height: 0.5) }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).overline()
            VStack(alignment: .leading, spacing: 0) { content() }
                .padding(.horizontal, 12)
                .padding(.vertical, 2)
                .background(Lc.panel)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(Lc.hairline, lineWidth: 0.5))
        }
    }
}

private struct CameraSettings: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var tether: TetherLink
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.settings.login.ssid.isEmpty ? "Fotocamera" : model.settings.login.ssid).font(Typo.labelStrong).foregroundColor(Lc.text)
                    Text(model.settings.login.user.isEmpty ? "—" : model.settings.login.user).font(Typo.caption).foregroundColor(Lc.text3)
                }
                Spacer()
                LinkStatus(tether: tether, raw: model.settings.raw)
            }
            .padding(.vertical, 10)
            HStack(spacing: 6) {
                if tether.link.busy {
                    FlatButton(title: "Scollega", icon: "bolt.slash") { model.disconnect() }
                } else {
                    FlatButton(title: "Collega", icon: "bolt") { model.connect() }
                }
                FlatButton(title: "Dati di accesso", icon: "key") {
                    close()
                    model.go(.connect)
                }
            }
            .padding(.bottom, 10)
            if !model.settings.login.fingerprint.isEmpty {
                Rectangle().fill(Lc.hairline).frame(height: 0.5)
                HStack {
                    Image(systemName: "key").font(.system(size: 11)).foregroundColor(Lc.text3)
                    Text(String(model.settings.login.fingerprint.prefix(30)) + "…").font(Typo.caption).foregroundColor(Lc.text3).lineLimit(1)
                    Spacer()
                    Button("Dimentica") { model.settings.login.fingerprint = "" }.font(Typo.label).foregroundColor(Lc.accent)
                }
                .frame(height: 32)
            }
        }
    }
}
