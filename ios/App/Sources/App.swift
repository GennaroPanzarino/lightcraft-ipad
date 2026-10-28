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
            if let h = model.hero {
                HeroZoom(hero: h) { if model.hero?.id == h.id { model.hero = nil } }
                    .id(h.id)
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
        .sheet(isPresented: $model.openSettings) { SettingsSheet().environmentObject(model) }
        .onAppear(perform: testLandscape)
    }

    /// Tests (`-landscape YES`): the simulator's iPad turned on its side.
    private func testLandscape() {
        guard UserDefaults.standard.bool(forKey: "landscape") else { return }
        if #available(iOS 16.0, *) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
                scene?.windows.first?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
                scene?.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight)) { e in NSLog("lightcraft rotate: \(e)") }
            }
        }
    }
}

/// A thumbnail opening into the viewer: the picture grows from its place in the grid to its place on
/// screen (Lightroom's zoom), then the viewer under it takes over.
private struct HeroZoom: View {
    @EnvironmentObject var model: AppModel
    let hero: Hero
    let done: () -> Void
    @State private var target: CGRect?
    @State private var leaving = false

    var body: some View {
        GeometryReader { geo in
            let origin = geo.frame(in: .global).origin
            let size = CGSize(width: hero.image.width, height: hero.image.height)
            let r = fitted(size, in: target ?? hero.from).offsetBy(dx: -origin.x, dy: -origin.y)
            ZStack {
                // the library's backdrop, fading as the photo opens: the workspace appears behind it
                Lc.window.opacity(target == nil ? 1 : 0)
                Image(decorative: hero.image, scale: 1)
                    .resizable()
                    .frame(width: r.width, height: r.height)
                    .position(x: r.midX, y: r.midY)
            }
            .opacity(leaving ? 0 : 1)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .onAppear { start(Date(), measured: model.viewerMeasures) }
    }

    /// Off once the viewer has been measured in the workspace just shown (a stale or empty frame
    /// would land the photo in the wrong place).
    private func start(_ t0: Date, measured: Int) {
        let waited = Date().timeIntervalSince(t0)
        let frame = model.viewerFrame
        let fresh = model.viewerMeasures > measured || waited > 0.05
        guard frame.width > 1, frame.height > 1, fresh || waited > 0.2 else {
            if waited > 0.3 {
                go(to: UIScreen.main.bounds)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { start(t0, measured: measured) }
            }
            return
        }
        go(to: frame)
    }

    private func go(to frame: CGRect) {
        withAnimation(.easeOut(duration: 0.26)) { target = frame }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.27) {
            withAnimation(.easeOut(duration: 0.1)) { leaving = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.11) { done() }
        }
    }

    private func fitted(_ s: CGSize, in r: CGRect) -> CGRect {
        let a = s.width / max(1, s.height)
        let size = r.width / max(1, r.height) > a ? CGSize(width: r.height * a, height: r.height) : CGSize(width: r.width, height: r.width / a)
        return CGRect(x: r.midX - size.width / 2, y: r.midY - size.height / 2, width: size.width, height: size.height)
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
