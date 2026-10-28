import SwiftUI
import UIKit

@main
struct LightCraftTetherApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
                .statusBarHidden(true)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ZStack {
            Lc.window.ignoresSafeArea()
            if let p = model.problem {
                VStack(spacing: 16) {
                    ApertureLogo(animated: false).frame(width: 56, height: 56)
                    Text("LightCraft non è partito").font(Typo.title).foregroundColor(Lc.text)
                    Text(p).font(Typo.body).foregroundColor(Lc.text2).multilineTextAlignment(.center)
                }
                .padding(40)
            } else if model.screen == .connect {
                ConnectView(initial: model.settings.login, canGoBack: model.settings.login.complete)
                    .transition(.opacity)
            } else if !model.ready {
                VStack(spacing: 16) {
                    ApertureLogo().frame(width: 56, height: 56)
                    Text("Preparo LightCraft…").font(Typo.label).foregroundColor(Lc.text2)
                }
                .transition(.opacity)
            } else if model.screen == .browser {
                BrowserView(library: model.library)
                    .transition(.opacity)
            } else {
                Workspace(ed: model.editor)
                    .transition(.opacity)
            }
            if let n = model.note {
                VStack {
                    Spacer()
                    Toast(text: n).padding(.bottom, 100)
                }
                .animation(Motion.quick, value: model.note)
            }
        }
        .animation(Motion.quick, value: model.screen)
        .animation(Motion.quick, value: model.ready)
        .modifier(KeepAwake(tether: model.tether, on: model.settings.keepAwake))
        .onAppear(perform: testLandscape)
    }

    /// Tests (`-landscape YES`): the simulator's iPad turned on its side.
    private func testLandscape() {
        guard UserDefaults.standard.bool(forKey: "landscape") else { return }
        if #available(iOS 16.0, *) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
                scene?.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight)) { _ in }
            }
        }
    }
}

/// The screen stays on while the camera is linked (if the settings say so).
private struct KeepAwake: ViewModifier {
    @ObservedObject var tether: TetherLink
    let on: Bool

    func body(content: Content) -> some View {
        content
            .onChange(of: tether.link) { link in UIApplication.shared.isIdleTimerDisabled = on && link.busy }
            .onChange(of: on) { v in UIApplication.shared.isIdleTimerDisabled = v && tether.link.busy }
    }
}
