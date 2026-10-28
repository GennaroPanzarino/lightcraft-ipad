import SwiftUI

/// First run (and "change camera"): how to reach the camera, with the steps to find it on its screen.
struct ConnectView: View {
    @EnvironmentObject var model: AppModel
    let canGoBack: Bool
    @State private var login: CameraLogin
    @State private var developer: Bool
    @State private var help = false

    init(initial: CameraLogin, canGoBack: Bool) {
        self.canGoBack = canGoBack
        _login = State(initialValue: initial)
        _developer = State(initialValue: !initial.plain.isEmpty)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RadialGradient(colors: [Lc.amber.opacity(0.18), Lc.amber.opacity(0.03), .clear], center: UnitPoint(x: 0.25, y: 0.18), startRadius: 0, endRadius: 900)
                .ignoresSafeArea()
            GeometryReader { geo in
                ScrollView {
                    Group {
                        if geo.size.width > 980 {
                            HStack(alignment: .top, spacing: 56) { welcome; form }
                        } else {
                            VStack(alignment: .leading, spacing: 36) { welcome; form }
                        }
                    }
                    .padding(.horizontal, 48)
                    .padding(.vertical, 64)
                    .frame(maxWidth: .infinity)
                }
            }
            if canGoBack {
                GlassIcon(icon: "chevron.left") { model.go(.session) }
                    .padding(24)
            }
        }
    }

    /// The welcome (on the left in landscape).
    private var welcome: some View {
        VStack(alignment: .leading, spacing: 0) {
            ApertureLogo()
                .frame(width: 96, height: 96)
                .onLongPressGesture { withAnimation(Motion.soft) { developer.toggle() } }
            Spacer().frame(height: 32)
            Text("LIGHTCRAFT TETHER").font(Typo.overline).tracking(1.4).foregroundColor(Lc.amber)
            Spacer().frame(height: 12)
            Text("Scatta.
È già qui.").font(Typo.display).foregroundColor(Lc.text).lineSpacing(2)
            Spacer().frame(height: 16)
            Text("Collega la tua Sony all'iPad via Wi-Fi: ogni scatto arriva in un istante, già con il tuo preset, e il RAW vero lo sviluppa LightCraft.")
                .font(Typo.body).foregroundColor(Lc.text2).fixedSize(horizontal: false, vertical: true)
            Spacer().frame(height: 24)
            helpCard
        }
        .frame(maxWidth: 460, alignment: .leading)
    }

    /// The camera's data.
    private var form: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Wi-Fi della fotocamera", systemImage: "wifi").font(Typo.headline).foregroundColor(Lc.text)
            Field(label: "Nome rete (SSID)", text: $login.ssid, placeholder: "DIRECT-xxxx:ILCE-7M4")
            Field(label: "Password Wi-Fi", text: $login.wifiPassword, secret: true)
            Label("Autenticazione d'accesso", systemImage: "lock").font(Typo.headline).foregroundColor(Lc.text).padding(.top, 6)
            Field(label: "Utente", text: $login.user)
            Field(label: "Password", text: $login.password, secret: true)
            if developer {
                Field(label: "PTP diretto (solo test)", text: $login.plain, placeholder: "127.0.0.1:15740")
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            PrimaryButton(title: "Collega la fotocamera", icon: "camera.aperture", enabled: login.complete) {
                model.connect(with: login)
            }
            .padding(.top, 8)
            Text("I dati restano solo su questo iPad. La prima volta iPadOS ti chiederà di accedere alla rete della fotocamera.")
                .font(Typo.caption).foregroundColor(Lc.text3)
        }
        .padding(26)
        .background(Lc.glass)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(Lc.hairline))
        .frame(maxWidth: 480)
    }

    private var helpCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(Motion.soft) { help.toggle() } } label: {
                HStack {
                    Text("Dove trovo questi dati?").font(Typo.label).foregroundColor(Lc.text)
                    Spacer()
                    Image(systemName: "chevron.down").foregroundColor(Lc.text2).rotationEffect(.degrees(help ? 180 : 0))
                }
            }
            .buttonStyle(.plain)
            if help {
                VStack(alignment: .leading, spacing: 12) {
                    step(1, "Sulla fotocamera apri MENU › Rete › Controllo remoto PC e attivalo.")
                    step(2, "Come metodo di connessione scegli Wi-Fi Direct: la fotocamera mostra nome rete (DIRECT-…) e password.")
                    step(3, "In Autenticazione d'accesso trovi utente e password.")
                    step(4, "Imposta la destinazione di salvataggio su PC + fotocamera: gli scatti restano anche sulla scheda.")
                }
                .padding(.top, 14)
                .transition(.opacity)
            }
        }
        .padding(18)
        .background(Lc.glass)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Lc.hairline))
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)").font(Typo.caption).foregroundColor(Lc.amber).frame(width: 22, height: 22).background(Lc.raised).clipShape(Circle())
            Text(text).font(Typo.body).foregroundColor(Lc.text2).fixedSize(horizontal: false, vertical: true)
        }
    }
}
