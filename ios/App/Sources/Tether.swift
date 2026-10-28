import Foundation
import NetworkExtension

/// How to reach the camera: its Wi-Fi Direct network and its PC Remote login (both on its screen).
struct CameraLogin: Codable, Equatable {
    var ssid = ""
    var wifiPassword = ""
    var user = ""
    var password = ""
    /// The camera's SSH key as seen the first time (trust on first use).
    var fingerprint = ""
    /// Tests: a stand-in camera's plain PTP/IP `host:port`.
    var plain = ""

    var complete: Bool { !plain.isEmpty || (!ssid.isEmpty && !user.isEmpty && !password.isEmpty) }
}

struct Settings: Codable, Equatable {
    var login = CameraLogin()
    var raw = true
    /// The style every new shot gets ("" = none): Capture One's next capture adjustments.
    var preset = ""
    var presetAmount = 100
    /// Next captures get the last capture's adjustments instead of the style.
    var copyLast = false
    var followNewest = true
    var keepAwake = true
    var exportQuality = 92
    var exportEdge = 0
    /// The tools on the left (Capture One's default) or on the right.
    var toolsLeft = true
    /// Rendering on the GPU (Metal); off: the CPU.
    var gpu = true
    /// The browser's thumbnail size (points).
    var gridSize = 180.0

    init() {}

    /// Settings saved by an earlier version lack the newer fields: they keep their defaults (the
    /// camera's login is never lost to an update).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        login = try c.decodeIfPresent(CameraLogin.self, forKey: .login) ?? d.login
        raw = try c.decodeIfPresent(Bool.self, forKey: .raw) ?? d.raw
        preset = try c.decodeIfPresent(String.self, forKey: .preset) ?? d.preset
        presetAmount = try c.decodeIfPresent(Int.self, forKey: .presetAmount) ?? d.presetAmount
        copyLast = try c.decodeIfPresent(Bool.self, forKey: .copyLast) ?? d.copyLast
        followNewest = try c.decodeIfPresent(Bool.self, forKey: .followNewest) ?? d.followNewest
        keepAwake = try c.decodeIfPresent(Bool.self, forKey: .keepAwake) ?? d.keepAwake
        exportQuality = try c.decodeIfPresent(Int.self, forKey: .exportQuality) ?? d.exportQuality
        exportEdge = try c.decodeIfPresent(Int.self, forKey: .exportEdge) ?? d.exportEdge
        toolsLeft = try c.decodeIfPresent(Bool.self, forKey: .toolsLeft) ?? d.toolsLeft
        gpu = try c.decodeIfPresent(Bool.self, forKey: .gpu) ?? d.gpu
        gridSize = try c.decodeIfPresent(Double.self, forKey: .gridSize) ?? d.gridSize
    }

    static func load() -> Settings {
        guard let d = UserDefaults.standard.data(forKey: "settings"), let s = try? JSONDecoder().decode(Settings.self, from: d) else { return Settings() }
        return s
    }

    func save() {
        if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: "settings") }
    }
}

/// Where the link to the camera is.
enum Link: Equatable {
    case off, joining, searching, connecting
    case online(String)
    case retrying(String)
    case blocked(String)

    var busy: Bool {
        switch self {
        case .off, .blocked: return false
        default: return true
        }
    }
}

struct Transfer: Equatable {
    let name: String
    let got: Double
    let size: Double
    var fraction: Double { size > 0 ? min(1, got / size) : 0 }
}

/// The camera link (Rust, `lc_tether_*`): joins the camera's Wi-Fi, then polls what happened.
@MainActor
final class TetherLink: ObservableObject {
    @Published private(set) var link: Link = .off
    @Published private(set) var transfer: Transfer?
    @Published private(set) var lastRate: Double = 0
    @Published var warning: String?

    /// Shots on their way and arrived (`started`, `progress`, `preview`, `shot`, `failed`) and the key seen.
    var onEvent: (([String: Any]) -> Void)?
    private var handle: UnsafeMutableRawPointer?
    private var timer: Timer?
    private var joinTask: Task<Void, Never>?

    var running: Bool { handle != nil || joinTask != nil }

    func start(_ s: Settings, saveDir: URL) {
        stop()
        warning = nil
        let login = s.login
        joinTask = Task { [weak self] in
            guard let self = self else { return }
            if login.plain.isEmpty {
                self.link = .joining
                do {
                    try await CameraWiFi.join(ssid: login.ssid, passphrase: login.wifiPassword)
                } catch {
                    self.link = .blocked("Wi-Fi della fotocamera non raggiungibile: \(error.localizedDescription)")
                    self.joinTask = nil
                    return
                }
            }
            var cfg: [String: Any] = [
                "user": login.user, "password": login.password, "fingerprint": login.fingerprint,
                "saveDir": saveDir.path, "raw": s.raw,
            ]
            if !login.plain.isEmpty { cfg["plain"] = login.plain }
            let json = String(data: (try? JSONSerialization.data(withJSONObject: cfg)) ?? Data(), encoding: .utf8) ?? "{}"
            self.handle = json.withCString { lc_tether_start($0) }
            self.joinTask = nil
            self.timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.poll() }
            }
        }
    }

    func stop() {
        joinTask?.cancel()
        joinTask = nil
        timer?.invalidate()
        timer = nil
        if let h = handle {
            handle = nil
            // stopping joins the link's thread: not on the main thread
            let p = UInt(bitPattern: h)
            DispatchQueue.global(qos: .utility).async { lc_tether_stop(UnsafeMutableRawPointer(bitPattern: p)) }
        }
        link = .off
        transfer = nil
    }

    func setRaw(_ raw: Bool) {
        if let h = handle { lc_tether_set_raw(h, raw) }
    }

    private func poll() {
        guard let h = handle, let p = lc_tether_poll(h) else { return }
        let s = String(cString: p)
        lc_free(p)
        guard let events = (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [[String: Any]], !events.isEmpty else { return }
        for e in events {
            switch e.str("type") {
            case "link":
                switch e.str("state") {
                case "connecting": link = .connecting
                case "searching": link = .searching
                case "online": link = .online(e.str("model"))
                case "retrying": link = .retrying(e.str("message")); transfer = nil
                case "blocked": link = .blocked(e.str("message"))
                case "off": if link != .off { link = .off }
                default: break
                }
            case "warning": warning = e.str("message")
            case "started": transfer = Transfer(name: e.str("name"), got: 0, size: double(e["size"]))
            case "progress": transfer = Transfer(name: e.str("name"), got: double(e["got"]), size: double(e["size"]))
            case "shot":
                transfer = nil
                if double(e["mbps"]) > 0 { lastRate = double(e["mbps"]) }
            case "failed": transfer = nil
            default: break
            }
            onEvent?(e)
        }
    }
}

/// The camera's Wi-Fi, joined by the app (iPadOS asks the user the first time).
enum CameraWiFi {
    static func join(ssid: String, passphrase: String) async throws {
        let conf = passphrase.isEmpty ? NEHotspotConfiguration(ssid: ssid) : NEHotspotConfiguration(ssid: ssid, passphrase: passphrase, isWEP: false)
        conf.joinOnce = false
        do {
            try await NEHotspotConfigurationManager.shared.apply(conf)
        } catch let e as NSError where e.domain == NEHotspotConfigurationErrorDomain && e.code == NEHotspotConfigurationError.alreadyAssociated.rawValue {
            // already on it
        }
    }
}
