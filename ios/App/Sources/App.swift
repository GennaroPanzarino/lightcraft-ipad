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
                .statusBarHidden(false)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ZStack {
            Lc.ink.ignoresSafeArea()
            if let p = model.problem {
                VStack(spacing: 20) {
                    ApertureLogo(animated: false).frame(width: 96, height: 96)
                    Text("LightCraft non è partito").font(Typo.title).foregroundColor(Lc.text)
                    Text(p).font(Typo.body).foregroundColor(Lc.text2).multilineTextAlignment(.center)
                }
                .padding(40)
            } else if model.screen == .connect {
                ConnectView(initial: model.settings.login, canGoBack: model.settings.login.complete)
                    .transition(.opacity)
            } else if !model.ready {
                VStack(spacing: 22) {
                    ApertureLogo().frame(width: 96, height: 96)
                    Text("Preparo LightCraft…").font(Typo.label).foregroundColor(Lc.text2)
                }
                .transition(.opacity)
            } else {
                Group {
                    switch model.screen {
                    case .editor: EditorView(ed: model.editor)
                    case .library: LibraryView()
                    default: SessionView()
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.99)))
            }
            if let n = model.note {
                VStack {
                    Spacer()
                    Toast(text: n).padding(.bottom, 110)
                }
                .animation(Motion.soft, value: model.note)
            }
        }
        .animation(Motion.soft, value: model.screen)
        .onChange(of: model.tether.link) { link in
            UIApplication.shared.isIdleTimerDisabled = model.settings.keepAwake && link.busy
        }
    }
}
