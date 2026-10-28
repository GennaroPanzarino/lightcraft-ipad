import SwiftUI

/// First run (and "change camera"): how to reach the camera, with the steps to find it on its screen.
struct ConnectView: View {
    @EnvironmentObject var model: AppModel
    let canGoBack: Bool
    @State private var login: CameraLogin
    @State private var developer: Bool

    init(initial: CameraLogin, canGoBack: Bool) {
        self.canGoBack = canGoBack
        _login = State(initialValue: initial)
        _developer = State(initialValue: !initial.plain.isEmpty)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if canGoBack {
                    ToolIcon(icon: "chevron.left") { model.go(model.beforeConnect) }
                }
                Text("Collega la fotocamera").font(Typo.labelStrong).foregroundColor(Lc.text)
                Spacer()
            }
            .padding(.horizontal, 8)
            .frame(height: 48)
            .padding(.top, windowControlsInset)
            .background(Lc.header)
            .overlay(Rectangle().fill(Lc.line).frame(height: 1), alignment: .bottom)
            GeometryReader { geo in
                ScrollView {
                    Group {
                        if geo.size.width > 900 {
                            HStack(alignment: .top, spacing: 40) { intro; form }
                        } else {
                            VStack(alignment: .leading, spacing: 28) { intro; form }
                        }
                    }
                    .padding(.horizontal, 40)
                    .padding(.vertical, 44)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .background(Lc.window.ignoresSafeArea())
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 0) {
            ApertureLogo()
                .frame(width: 56, height: 56)
                .onLongPressGesture { withAnimation(Motion.quick) { developer.toggle() } }
            Text("LIGHTCRAFT TETHER").font(Typo.group).tracking(1.4).foregroundColor(Lc.accent).padding(.top, 22)
            Text("Scatta.\nÈ già qui.").font(Typo.display).foregroundColor(Lc.text).lineSpacing(1).padding(.top, 8)
            Text("La Sony si collega all'iPad via Wi-Fi: ogni scatto arriva in un istante, già con le tue regolazioni, e il RAW lo sviluppa LightCraft, qui.")
                .font(Typo.body).foregroundColor(Lc.text2).fixedSize(horizontal: false, vertical: true).padding(.top, 12)
            VStack(alignment: .leading, spacing: 10) {
                Text("DOVE TROVO QUESTI DATI").overline()
                step(1, "Sulla fotocamera: MENU › Rete › Controllo remoto PC, attivato.")
                step(2, "Metodo di connessione Wi-Fi Direct: lo schermo mostra il nome della rete (DIRECT-…) e la password.")
                step(3, "In Autenticazione d'accesso trovi utente e password.")
                step(4, "Destinazione di salvataggio PC + fotocamera: gli scatti restano anche sulla scheda.")
            }
            .padding(14)
            .background(Lc.panel)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(Lc.hairline, lineWidth: 0.5))
            .padding(.top, 22)
        }
        .frame(maxWidth: 420, alignment: .leading)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Wi-Fi della fotocamera", systemImage: "wifi").font(Typo.labelStrong).foregroundColor(Lc.text)
            Field(label: "Nome rete (SSID)", text: $login.ssid, placeholder: "DIRECT-xxxx:ILCE-7M4")
            Field(label: "Password Wi-Fi", text: $login.wifiPassword, secret: true)
            Rectangle().fill(Lc.hairline).frame(height: 0.5).padding(.vertical, 2)
            Label("Autenticazione d'accesso", systemImage: "lock").font(Typo.labelStrong).foregroundColor(Lc.text)
            Field(label: "Utente", text: $login.user)
            Field(label: "Password", text: $login.password, secret: true)
            if developer {
                Field(label: "PTP diretto (solo test)", text: $login.plain, placeholder: "127.0.0.1:15740")
                    .transition(.opacity)
            }
            FlatButton(title: "Collega", icon: "bolt", prominent: true, enabled: login.complete) {
                model.connect(with: login)
            }
            .padding(.top, 6)
            Text("I dati restano solo su questo iPad. La prima volta iPadOS chiede di accedere alla rete della fotocamera.")
                .font(Typo.caption).foregroundColor(Lc.text3)
        }
        .padding(20)
        .background(Lc.panel)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Lc.hairline, lineWidth: 0.5))
        .frame(maxWidth: 440)
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)").font(Typo.caption).foregroundColor(Lc.text).frame(width: 18, height: 18).background(Lc.raised).clipShape(Circle())
            Text(text).font(Typo.label).foregroundColor(Lc.text2).fixedSize(horizontal: false, vertical: true)
        }
    }
}
