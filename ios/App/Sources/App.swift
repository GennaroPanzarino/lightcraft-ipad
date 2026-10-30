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
            } else {
                if model.ready {
                    // the workspace and the library both stay made (switching between them is
                    // instant, and each keeps its place): the one not shown is invisible
                    Workspace(ed: model.editor)
                        .environment(\.screenShown, workspaceOpacity > 0)
                        .opacity(workspaceOpacity)
                        .allowsHitTesting(model.screen == .workspace && model.hero == nil)
                    BrowserView(library: model.library)
                        .environment(\.screenShown, browserOpacity > 0)
                        .opacity(browserOpacity)
                        .allowsHitTesting(model.screen == .browser && model.hero == nil)
                }
                if model.screen == .connect {
                    ConnectView(initial: model.settings.login, canGoBack: true)
                        .transition(.opacity)
                        .zIndex(3)
                } else if !model.ready {
                    VStack(spacing: 16) {
                        ApertureLogo().frame(width: 56, height: 56)
                        Text("Preparo LightCraft…").font(Typo.label).foregroundColor(Lc.text2)
                    }
                    .transition(.opacity)
                }
            }
            if let h = model.hero {
                HeroZoom(hero: h) { model.heroLanded(h.id) }
                    .id(h.id)
                    .zIndex(4)
            }
            if let e = model.lastEnd {
                VStack {
                    Spacer()
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "exclamationmark.triangle").foregroundColor(Lc.warn)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("L'app si è chiusa all'improvviso").font(Typo.labelStrong).foregroundColor(Lc.text)
                            Text("Stava facendo: \(e)").font(Typo.caption).foregroundColor(Lc.text2).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        Button("Copia") { UIPasteboard.general.string = "LightCraft · chiusura durante: \(e)" }
                            .font(Typo.labelStrong).foregroundColor(Lc.accent)
                        Button { model.lastEnd = nil } label: { Image(systemName: "xmark").foregroundColor(Lc.text3) }
                    }
                    .padding(14)
                    .frame(maxWidth: 560)
                    .background(Lc.raised)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Lc.hairline2, lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
                    .padding(.bottom, 90)
                }
            }
            if let n = model.note {
                VStack {
                    Spacer()
                    Toast(text: n).padding(.bottom, 100)
                }
                .animation(Motion.quick, value: model.note)
            }
        }
        .animation(Motion.quick, value: model.ready)
        .modifier(KeepAwake(tether: model.tether, on: model.settings.keepAwake))
        .overlay(SettingsSide(open: model.openSettings) { model.openSettings = false })
        .onAppear(perform: testLandscape)
    }

    private var workspaceOpacity: Double {
        model.screen == .workspace || model.hero != nil ? 1 : 0
    }

    /// The library over the workspace: fading out as a photo flies into the viewer, in as it flies
    /// back into its tile.
    private var browserOpacity: Double {
        guard let h = model.hero else { return model.screen == .browser ? 1 : 0 }
        return h.back == model.heroFade ? 1 : 0
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

/// A photo flying between its tile in the library and the viewer (Photos' and Lightroom's
/// transition): the picture itself moves and grows (or shrinks) on a spring, from where it is to
/// where it goes, while the screen it leaves fades and the one it reaches appears beneath it. Its
/// place at both ends stays empty meanwhile, so it is never seen twice; when it lands, the photo
/// under it takes over in exactly its place.
private struct HeroZoom: View {
    @EnvironmentObject var model: AppModel
    let hero: Hero
    let done: () -> Void
    @State private var target: CGRect?
    @State private var lifted = false

    var body: some View {
        GeometryReader { geo in
            let origin = geo.frame(in: .global).origin
            let size = CGSize(width: hero.image.width, height: hero.image.height)
            let r = fitted(size, in: target ?? hero.from).offsetBy(dx: -origin.x, dy: -origin.y)
            Image(decorative: hero.image, scale: 1)
                .resizable()
                .interpolation(.high)
                .frame(width: r.width, height: r.height)
                // lifted off the page while it flies
                .shadow(color: .black.opacity(lifted ? 0.45 : 0), radius: lifted ? 22 : 0, y: lifted ? 8 : 0)
                .opacity(gone ? 0 : 1)
                .position(x: r.midX, y: r.midY)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .onAppear { start(Date(), measured: hero.back ? model.tileMeasures : model.viewerMeasures) }
    }

    /// Where the photo lands: its place in the viewer, or its tile in the library (measured afresh:
    /// the library may scroll to bring the tile into sight).
    private func start(_ t0: Date, measured: Int) {
        let waited = Date().timeIntervalSince(t0)
        if hero.back {
            if let t = model.tileFrame, t.key == hero.key, t.frame.width > 1, model.tileMeasures > measured || waited > 0.12 {
                go(to: t.frame)
            } else if waited > 0.3 {
                // no tile to land in: the photo shrinks away into the library
                let s = UIScreen.main.bounds
                go(to: CGRect(x: s.midX - 40, y: s.midY - 30, width: 80, height: 60), vanish: true)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { start(t0, measured: measured) }
            }
            return
        }
        let frame = model.viewerFrame
        guard frame.width > 1, frame.height > 1 else {
            if waited > 0.3 {
                go(to: UIScreen.main.bounds)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { start(t0, measured: measured) }
            }
            return
        }
        go(to: frame)
    }

    @State private var gone = false

    private func go(to frame: CGRect, vanish: Bool = false) {
        withAnimation(Motion.hero) {
            target = frame
            lifted = true
        }
        if vanish { withAnimation(.easeIn(duration: 0.3)) { gone = true } }
        withAnimation(.easeOut(duration: 0.3)) { model.heroFade = true }
        // the shadow settles as it lands
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) {
            withAnimation(.easeOut(duration: 0.18)) { lifted = false }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.46) { done() }
    }

    private func fitted(_ s: CGSize, in r: CGRect) -> CGRect {
        let a = s.width / max(1, s.height)
        let size = r.width / max(1, r.height) > a ? CGSize(width: r.height * a, height: r.height) : CGSize(width: r.width, height: r.width / a)
        return CGRect(x: r.midX - size.width / 2, y: r.midY - size.height / 2, width: size.width, height: size.height)
    }
}

/// The settings sliding in from the left edge, the rest of the screen dimmed (a tap there closes).
private struct SettingsSide: View {
    let open: Bool
    let close: () -> Void

    var body: some View {
        ZStack(alignment: .leading) {
            if open {
                Color.black.opacity(0.45)
                    .ignoresSafeArea()
                    .onTapGesture(perform: close)
                    .transition(.opacity)
                SettingsSheet(close: close)
                    .frame(width: 400)
                    .frame(maxHeight: .infinity)
                    .shadow(color: .black.opacity(0.5), radius: 24, x: 6)
                    .transition(.move(edge: .leading))
                    .ignoresSafeArea(edges: .bottom)
            }
        }
        .animation(.easeOut(duration: 0.2), value: open)
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
