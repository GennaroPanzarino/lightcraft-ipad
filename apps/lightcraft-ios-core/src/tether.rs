//! The camera link for the iPad app: the same session the desktop's direct engine and the Android app
//! run (PTP/IP to `localhost:15740` through the camera's SSH server, the Sony handshake, each shot
//! streamed to disk with its full-size JPEG taken out of the raw's start), with SSH by `russh` (pure
//! Rust: it builds for iOS). The app polls what happened as JSON events.
//!
//! Joining the camera's Wi-Fi is the app's (NEHotspotConfiguration): this side just keeps trying the
//! camera's address until it answers.

use std::collections::VecDeque;
use std::io::{BufWriter, Read, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::{Duration, Instant};

use russh::client;
use russh::keys::{HashAlg, PublicKeyOrCertificate};
use serde_json::{Value, json};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio_util::io::SyncIoBridge;

use crate::peek::{Located, locate, orientation, shot_stem, with_orientation};
use crate::ptp::{self, PtpError, Session};

const PTP_PORT: u16 = 15740;
const CAPTURED: u32 = 0xFFFF_C001;
const PROP_PENDING: u16 = 0xD215;
const PROP_DESTINATION: u16 = 0xD222;
const PROP_SIZE_SENT: u16 = 0xD268;
const DESTINATION_PHONE_AND_CARD: i64 = 0x11;
const SIZE_ORIGINAL: i64 = 1;
const SIZE_SMALL: i64 = 2;
const OP_CLOSE_SESSION: u16 = 0x1003;
const RESP_SESSION_ALREADY_OPEN: u16 = 0x201E;
const FORMAT_RAW: u16 = 0xB101;
const GUID: [u8; 16] = *b"LightCraft-Tethr";
/// The start of a raw kept in memory to find its JPEG (an ILCE-7M4's ends at ~1.77 MB).
const HEAD_LIMIT: usize = 6 * 1024 * 1024;

/// How to reach the camera.
#[derive(Clone, Debug)]
pub struct Config {
    pub host: String,
    pub ssh_port: u16,
    pub user: String,
    pub password: String,
    /// The camera's key as seen before (`SHA256:…`); none: whatever it shows is trusted (and reported).
    pub fingerprint: Option<String>,
    /// Tests: a stand-in camera's plain PTP/IP `host:port` (no SSH).
    pub plain: Option<String>,
    pub save_dir: PathBuf,
    /// The raw (else the camera's 2 MP JPEG).
    pub raw: bool,
}

impl Config {
    pub fn from_json(v: &Value) -> Config {
        let s = |k: &str| v.get(k).and_then(Value::as_str).unwrap_or("").to_string();
        Config {
            host: Some(s("host")).filter(|h| !h.is_empty()).unwrap_or_else(|| "192.168.122.1".into()),
            ssh_port: v.get("sshPort").and_then(Value::as_u64).map_or(22, |p| p as u16),
            user: s("user"),
            password: s("password"),
            fingerprint: Some(s("fingerprint")).filter(|f| !f.is_empty()),
            plain: Some(s("plain")).filter(|p| !p.is_empty()),
            save_dir: PathBuf::from(s("saveDir")),
            raw: v.get("raw").and_then(Value::as_bool).unwrap_or(true),
        }
    }
}

struct Shared {
    stop: AtomicBool,
    raw: AtomicBool,
    mode_changed: AtomicBool,
    events: Mutex<VecDeque<Value>>,
}

impl Shared {
    fn emit(&self, v: Value) {
        let mut q = self.events.lock().unwrap_or_else(PoisonError::into_inner);
        // progress is only interesting as its latest value
        if v["type"] == "progress"
            && let Some(last) = q.back_mut()
            && last["type"] == "progress"
            && last["name"] == v["name"]
        {
            *last = v;
            return;
        }
        q.push_back(v);
        while q.len() > 500 {
            q.pop_front();
        }
    }

    fn link(&self, state: &str, extra: Value) {
        let mut v = json!({"type": "link", "state": state});
        if let (Some(o), Some(e)) = (v.as_object_mut(), extra.as_object()) {
            for (k, x) in e {
                o.insert(k.clone(), x.clone());
            }
        }
        self.emit(v);
    }

    fn stopped(&self) -> bool {
        self.stop.load(Ordering::SeqCst)
    }
}

/// A running tether (stops when dropped).
pub struct Tether {
    shared: Arc<Shared>,
    thread: Option<std::thread::JoinHandle<()>>,
}

impl Tether {
    pub fn start(cfg: Config) -> Tether {
        let shared = Arc::new(Shared {
            stop: AtomicBool::new(false),
            raw: AtomicBool::new(cfg.raw),
            mode_changed: AtomicBool::new(false),
            events: Mutex::new(VecDeque::new()),
        });
        let s = shared.clone();
        let thread = std::thread::Builder::new().name("lightcraft-tether".into()).spawn(move || run(cfg, &s)).ok();
        Tether { shared, thread }
    }

    /// What happened since the last call.
    pub fn poll(&self) -> Vec<Value> {
        self.shared.events.lock().unwrap_or_else(PoisonError::into_inner).drain(..).collect()
    }

    pub fn set_raw(&self, raw: bool) {
        if self.shared.raw.swap(raw, Ordering::SeqCst) != raw {
            self.shared.mode_changed.store(true, Ordering::SeqCst);
        }
    }

    pub fn stop(&mut self) {
        self.shared.stop.store(true, Ordering::SeqCst);
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}

impl Drop for Tether {
    fn drop(&mut self) {
        self.stop();
    }
}

enum Fail {
    /// The camera isn't there (yet).
    Unreachable,
    /// Needs the user (password, a changed key).
    Blocked(String),
    /// The camera answered as nothing a tether can use.
    Protocol(String),
    /// A connection that broke: try again.
    Lost(String),
}

impl From<PtpError> for Fail {
    fn from(e: PtpError) -> Self {
        match e {
            PtpError::Io(e) => Fail::Lost(e.to_string()),
            e => Fail::Protocol(e.to_string()),
        }
    }
}

fn nap(s: &Shared, d: Duration) {
    let end = Instant::now() + d;
    while Instant::now() < end && !s.stopped() {
        std::thread::sleep(Duration::from_millis(50));
    }
}

fn run(cfg: Config, s: &Shared) {
    let rt = match tokio::runtime::Builder::new_multi_thread().worker_threads(2).enable_all().build() {
        Ok(rt) => rt,
        Err(e) => {
            s.link("blocked", json!({"message": format!("tether: {e}")}));
            return;
        }
    };
    let mut protocol_failures = 0;
    let mut searching = false;
    while !s.stopped() {
        if !searching {
            s.link("connecting", json!({}));
        }
        let r = match &cfg.plain {
            Some(addr) => plain(addr, &cfg, s),
            None => over_ssh(&rt, &cfg, s),
        };
        match r {
            Ok(()) => break,
            Err(Fail::Unreachable) => {
                if !searching {
                    s.link("searching", json!({}));
                    searching = true;
                }
                nap(s, Duration::from_secs(2));
            }
            Err(Fail::Blocked(m)) => {
                s.link("blocked", json!({"message": m}));
                return;
            }
            Err(Fail::Protocol(m)) => {
                searching = false;
                protocol_failures += 1;
                if protocol_failures >= 3 {
                    s.link("blocked", json!({"message": format!("La fotocamera non risponde come previsto ({m})")}));
                    return;
                }
                s.link("retrying", json!({"message": m}));
                nap(s, Duration::from_millis(1500));
            }
            Err(Fail::Lost(m)) => {
                searching = false;
                if s.stopped() {
                    break;
                }
                log::warn!("tether: {m}");
                s.link("retrying", json!({"message": m}));
                nap(s, Duration::from_secs(1));
            }
        }
    }
    s.link("off", json!({}));
}

/// The stand-in camera of the tests: two plain sockets.
fn plain(addr: &str, cfg: &Config, s: &Shared) -> Result<(), Fail> {
    let connect = || std::net::TcpStream::connect(addr).map_err(|_| Fail::Unreachable);
    let mut cmd = connect()?;
    let mut evt = connect()?;
    cmd.set_nodelay(true).ok();
    let (conn, name) = ptp::init_command(&mut cmd, &GUID, "LightCraft Tether")?;
    ptp::init_event(&mut evt, conn)?;
    // the event connection is read (and its probes answered) on a thread of its own
    let mut reader = evt.try_clone().map_err(|e| Fail::Lost(e.to_string()))?;
    let done = Arc::new(AtomicBool::new(false));
    let d = done.clone();
    std::thread::spawn(move || {
        let mut buf = Vec::new();
        let mut tmp = [0u8; 4096];
        reader.set_read_timeout(Some(Duration::from_millis(200))).ok();
        while !d.load(Ordering::SeqCst) {
            match reader.read(&mut tmp) {
                Ok(0) => break,
                Ok(n) => {
                    buf.extend_from_slice(&tmp[..n]);
                    let mut probes = 0;
                    ptp::take_events(&mut buf, |_| probes += 1);
                    for _ in 0..probes {
                        let _ = ptp::write_packet(&mut evt, ptp::PROBE_RESPONSE, &[]);
                    }
                }
                Err(e) if matches!(e.kind(), std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut) => {}
                Err(_) => break,
            }
        }
    });
    let r = session(cmd, name, cfg, s);
    done.store(true, Ordering::SeqCst);
    r
}

/// The camera's SSH key: checked against the one seen before.
struct Keys {
    known: Option<String>,
    seen: Arc<Mutex<Option<String>>>,
}

impl client::Handler for Keys {
    type Error = russh::Error;

    async fn check_server_key(&mut self, key: &PublicKeyOrCertificate) -> Result<bool, Self::Error> {
        let fp = match key {
            PublicKeyOrCertificate::PublicKey { key, .. } => key.fingerprint(HashAlg::Sha256).to_string(),
            PublicKeyOrCertificate::Certificate(c) => c.public_key().fingerprint(HashAlg::Sha256).to_string(),
        };
        let ok = self.known.as_deref().is_none_or(|k| k == fp);
        *self.seen.lock().unwrap_or_else(PoisonError::into_inner) = Some(fp);
        Ok(ok)
    }
}

fn ssh_config() -> client::Config {
    use russh::{cipher, kex, mac};
    let mut c = client::Config {
        keepalive_interval: Some(Duration::from_secs(5)),
        keepalive_max: 5,
        inactivity_timeout: None,
        nodelay: true,
        window_size: 2 * 1024 * 1024,
        ..Default::default()
    };
    // the camera's server (libssh2-era): the classic algorithms first, the modern ones still offered
    let mut kexes = vec![kex::ECDH_SHA2_NISTP256, kex::CURVE25519, kex::CURVE25519_PRE_RFC_8731, kex::DH_G14_SHA256, kex::DH_GEX_SHA256, kex::DH_G14_SHA1, kex::DH_GEX_SHA1, kex::DH_G1_SHA1];
    kexes.extend(c.preferred.kex.iter().filter(|k| k.as_ref().starts_with("ext-info") || k.as_ref().starts_with("kex-strict")));
    c.preferred.kex = kexes.into();
    c.preferred.cipher = vec![cipher::AES_128_CTR, cipher::AES_256_CTR, cipher::AES_192_CTR, cipher::AES_128_CBC, cipher::AES_256_CBC].into();
    c.preferred.mac = vec![mac::HMAC_SHA256, mac::HMAC_SHA1, mac::HMAC_SHA512].into();
    c
}

fn over_ssh(rt: &tokio::runtime::Runtime, cfg: &Config, s: &Shared) -> Result<(), Fail> {
    // the tunnels close themselves when dropped, which takes the runtime: it is this thread's
    let _ctx = rt.enter();
    let seen = Arc::new(Mutex::new(None));
    let handler = Keys { known: cfg.fingerprint.clone(), seen: seen.clone() };
    let addr = format!("{}:{}", cfg.host, cfg.ssh_port);
    let handle = rt.block_on(async {
        let tcp = tokio::time::timeout(Duration::from_secs(6), tokio::net::TcpStream::connect(&addr)).await;
        let tcp = match tcp {
            Ok(Ok(t)) => t,
            _ => return Err(Fail::Unreachable),
        };
        tcp.set_nodelay(true).ok();
        let connected = tokio::time::timeout(Duration::from_secs(15), client::connect_stream(Arc::new(ssh_config()), tcp, handler)).await;
        let mut h = match connected {
            Err(_) => return Err(Fail::Lost("the camera's SSH server didn't answer in time".into())),
            Ok(Err(russh::Error::UnknownKey)) => {
                let got = seen.lock().unwrap_or_else(PoisonError::into_inner).clone().unwrap_or_default();
                return Err(Fail::Blocked(format!("La chiave della fotocamera è cambiata ({got}). Se è la tua, azzerala in Impostazioni")));
            }
            Ok(Err(e)) => return Err(Fail::Lost(format!("SSH: {e}"))),
            Ok(Ok(h)) => h,
        };
        if login(&mut h, &cfg.user, &cfg.password).await.map_err(|e| Fail::Lost(format!("SSH: {e}")))? {
            Ok(h)
        } else {
            Err(Fail::Blocked("La fotocamera ha rifiutato utente e password: controllali in Impostazioni".into()))
        }
    })?;
    if let Some(fp) = seen.lock().unwrap_or_else(PoisonError::into_inner).clone()
        && cfg.fingerprint.is_none()
    {
        s.emit(json!({"type": "fingerprint", "value": fp}));
    }
    let tunnel = |h: &client::Handle<Keys>| {
        rt.block_on(async { h.channel_open_direct_tcpip("localhost", u32::from(PTP_PORT), "127.0.0.1", 0).await })
            .map(|c| c.into_stream())
            .map_err(|e| Fail::Lost(format!("tunnel: {e}")))
    };
    let cmd_stream = tunnel(&handle)?;
    let evt_stream = tunnel(&handle)?;
    let mut cmd = SyncIoBridge::new_with_handle(cmd_stream, rt.handle().clone());
    let mut evt = SyncIoBridge::new_with_handle(evt_stream, rt.handle().clone());
    let (conn, name) = ptp::init_command(&mut cmd, &GUID, "LightCraft Tether")?;
    ptp::init_event(&mut evt, conn)?;
    // the event connection: read (its probes answered) by a task of its own
    let evt = evt.into_inner();
    let reader = rt.spawn(async move {
        let (mut r, mut w) = tokio::io::split(evt);
        let mut buf = Vec::new();
        let mut tmp = [0u8; 4096];
        loop {
            match r.read(&mut tmp).await {
                Ok(0) | Err(_) => break,
                Ok(n) => {
                    buf.extend_from_slice(&tmp[..n]);
                    let mut probes = 0;
                    ptp::take_events(&mut buf, |_| probes += 1);
                    for _ in 0..probes {
                        let _ = w.write_all(&[8, 0, 0, 0, ptp::PROBE_RESPONSE as u8, 0, 0, 0]).await;
                    }
                }
            }
        }
    });
    let r = session(cmd, name, cfg, s);
    reader.abort();
    rt.block_on(async {
        let _ = handle.disconnect(russh::Disconnect::ByApplication, "", "").await;
    });
    r
}

/// The camera's login: keyboard-interactive (what it offers), else a plain password.
async fn login(h: &mut client::Handle<Keys>, user: &str, password: &str) -> Result<bool, russh::Error> {
    use russh::client::KeyboardInteractiveAuthResponse as R;
    let mut r = h.authenticate_keyboard_interactive_start(user, None).await?;
    for _ in 0..5 {
        match r {
            R::Success => return Ok(true),
            R::Failure { .. } => break,
            R::InfoRequest { prompts, .. } => {
                r = h.authenticate_keyboard_interactive_respond(prompts.iter().map(|_| password.to_string()).collect()).await?;
            }
        }
    }
    Ok(h.authenticate_password(user, password).await?.success())
}

/// The PTP/IP session over the command connection, until stopped or broken.
fn session<C: Read + Write>(cmd: C, name: String, cfg: &Config, s: &Shared) -> Result<(), Fail> {
    let t0 = Instant::now();
    let mut ses = Session::new(cmd);
    let (_, raw) = ses.call(ptp::OP_GET_DEVICE_INFO, &[])?;
    let info = ptp::parse_device_info(&raw);
    let model = if info.model.is_empty() { name } else { info.model.clone() };
    match ses.call(ptp::OP_OPEN_SESSION, &[1]) {
        Ok(_) | Err(PtpError::Response { code: RESP_SESSION_ALREADY_OPEN, .. }) => {}
        Err(e) => return Err(e.into()),
    }
    handshake(&mut ses)?;
    log::info!("tether: {model} ({} {}) ready in {:.2} s", info.manufacturer, info.version, t0.elapsed().as_secs_f64());
    s.link("online", json!({"model": model, "firmware": info.version}));

    let props = all_props(&mut ses)?;
    let one_prop = info.operations.contains(&ptp::OP_SONY_GET_PROP);
    if !props.iter().any(|p| p.code == PROP_PENDING) {
        return Err(Fail::Protocol("the camera doesn't report shots waiting (0xD215)".into()));
    }
    if !set_prop(&mut ses, &props, PROP_DESTINATION, DESTINATION_PHONE_AND_CARD) {
        s.emit(json!({"type": "warning", "message": "La fotocamera non accetta di inviare gli scatti: imposta Destinazione salvataggio su PC + fotocamera"}));
    }
    s.mode_changed.store(false, Ordering::SeqCst);
    apply(&mut ses, &props, s);
    let previews = cfg.save_dir.join("previews");
    let _ = std::fs::create_dir_all(&previews);
    loop {
        if s.stopped() {
            let _ = ses.call(OP_CLOSE_SESSION, &[]);
            return Ok(());
        }
        if s.mode_changed.swap(false, Ordering::SeqCst) {
            apply(&mut ses, &props, s);
        }
        if pending(&mut ses, one_prop)? & 0x8000 != 0 {
            match download(&mut ses, &cfg.save_dir, &previews, Instant::now(), s) {
                // the camera said no (busy…): ask again in a moment
                Err(Fail::Protocol(m)) => {
                    log::warn!("tether: {m}");
                    std::thread::sleep(Duration::from_millis(500));
                }
                r => r?,
            }
            continue;
        }
        std::thread::sleep(Duration::from_millis(40));
    }
}

/// Sony's "SDIO connect": phases 1 and 2, the extended device info (3.00, else 2.00), phase 3.
fn handshake<C: Read + Write>(ses: &mut Session<C>) -> Result<u32, Fail> {
    for phase in [1, 2] {
        ses.call(ptp::OP_SONY_SDIO_CONNECT, &[phase, 0, 0])?;
    }
    let mut used = 0;
    'versions: for version in [0x12C, 0xC8] {
        for _ in 0..20 {
            match ses.call(ptp::OP_SONY_GET_EXT_DEVICE_INFO, &[version, 1]) {
                Ok((_, data)) if data.len() > 8 => {
                    used = version;
                    break 'versions;
                }
                Ok(_) => std::thread::sleep(Duration::from_millis(100)),
                Err(PtpError::Response { .. }) => continue 'versions,
                Err(e) => return Err(e.into()),
            }
        }
    }
    if used == 0 {
        return Err(Fail::Protocol("the camera didn't give its extended device info".into()));
    }
    ses.call(ptp::OP_SONY_SDIO_CONNECT, &[3, 0, 0])?;
    Ok(used)
}

fn all_props<C: Read + Write>(ses: &mut Session<C>) -> Result<Vec<ptp::SonyProp>, Fail> {
    let (_, data) = ses.call(ptp::OP_SONY_GET_ALL_PROPS, &[0])?;
    Ok(ptp::parse_sony_props(&data))
}

fn pending<C: Read + Write>(ses: &mut Session<C>, one_prop: bool) -> Result<i64, Fail> {
    if one_prop
        && let Ok((_, data)) = ses.call(ptp::OP_SONY_GET_PROP, &[u32::from(PROP_PENDING)])
        && let Some(p) = ptp::parse_sony_prop(&data)
        && p.code == PROP_PENDING
    {
        return Ok(p.current);
    }
    Ok(all_props(ses)?.into_iter().find(|p| p.code == PROP_PENDING).map_or(0, |p| p.current))
}

fn set_prop<C: Read + Write>(ses: &mut Session<C>, props: &[ptp::SonyProp], code: u16, value: i64) -> bool {
    let Some(p) = props.iter().find(|p| p.code == code) else { return false };
    if p.current == value {
        return true;
    }
    let Some(data) = ptp::encode_scalar(p.typ, value) else { return false };
    ses.send(ptp::OP_SONY_SET_PROP, &[u32::from(code)], &data).is_ok()
}

fn apply<C: Read + Write>(ses: &mut Session<C>, props: &[ptp::SonyProp], s: &Shared) {
    let raw = s.raw.load(Ordering::SeqCst);
    let has = props.iter().any(|p| p.code == PROP_SIZE_SENT);
    if has && !set_prop(ses, props, PROP_SIZE_SENT, if raw { SIZE_ORIGINAL } else { SIZE_SMALL }) {
        s.emit(json!({"type": "warning", "message": "La fotocamera non accetta il formato da inviare: riprova a cambiare modalità"}));
    }
    s.emit(json!({"type": "ready", "raw": raw}));
}

/// A free name in `dir` for the camera's file name (`DSC08860.ARW`, else `DSC08860(1).ARW`…).
fn free_name(dir: &Path, name: &str) -> String {
    let clean: String = name.chars().filter(|c| !matches!(c, '\\' | '/' | ':' | '*' | '?' | '"' | '<' | '>' | '|')).collect();
    let clean = if clean.is_empty() { "SHOT.ARW".to_string() } else { clean };
    if !dir.join(&clean).exists() {
        return clean;
    }
    let (stem, ext) = clean.rsplit_once('.').map_or((clean.as_str(), ""), |(s, e)| (s, e));
    (1..1000).map(|i| if ext.is_empty() { format!("{stem}({i})") } else { format!("{stem}({i}).{ext}") }).find(|n| !dir.join(n).exists()).unwrap_or(clean)
}

/// One shot on its way: written as it arrives; a raw's JPEG saved as soon as it is all here.
struct Incoming<'a> {
    file: BufWriter<std::fs::File>,
    preview_path: PathBuf,
    name: String,
    size: u64,
    got: u64,
    told: u64,
    raw: bool,
    head: Vec<u8>,
    jpeg: Option<(usize, usize)>,
    previewed: bool,
    ready: Instant,
    s: &'a Shared,
}

impl Incoming<'_> {
    fn feed(&mut self, b: &[u8]) -> std::io::Result<()> {
        self.file.write_all(b)?;
        self.got += b.len() as u64;
        if self.raw && !self.previewed {
            let room = HEAD_LIMIT.saturating_sub(self.head.len());
            self.head.extend_from_slice(&b[..b.len().min(room)]);
            self.look();
        }
        if self.size > 0 && (self.got - self.told >= self.size / 50 || self.got >= self.size) {
            self.told = self.got;
            self.s.emit(json!({"type": "progress", "name": self.name, "got": self.got, "size": self.size}));
        }
        Ok(())
    }

    fn look(&mut self) {
        if self.jpeg.is_none() && self.head.len() >= 256 * 1024 {
            match locate(&self.head) {
                Located::At(o, l, _, _) => self.jpeg = Some((o, l)),
                Located::Not => self.previewed = true,
                Located::Wait if self.head.len() >= HEAD_LIMIT => self.previewed = true,
                Located::Wait => {}
            }
        }
        let Some((o, l)) = self.jpeg else { return };
        if self.head.len() < o + l {
            if o + l > HEAD_LIMIT {
                self.previewed = true;
            }
            return;
        }
        self.previewed = true;
        let jpeg = &self.head[o..o + l];
        if jpeg.starts_with(&[0xFF, 0xD8]) && jpeg.ends_with(&[0xFF, 0xD9]) {
            // a vertical shot's JPEG is stored on its side: it gets the raw's orientation
            let jpeg = with_orientation(jpeg, orientation(&self.head));
            let tmp = self.preview_path.with_extension("JPG.part");
            if std::fs::write(&tmp, &jpeg).and_then(|_| std::fs::rename(&tmp, &self.preview_path)).is_ok() {
                self.s.emit(json!({
                    "type": "preview", "name": self.name, "path": self.preview_path.to_string_lossy(),
                    "seconds": self.ready.elapsed().as_secs_f64(),
                }));
            }
        }
        self.head = Vec::new();
    }
}

fn download<C: Read + Write>(ses: &mut Session<C>, save: &Path, previews: &Path, ready: Instant, s: &Shared) -> Result<(), Fail> {
    let (_, raw) = ses.call(ptp::OP_GET_OBJECT_INFO, &[CAPTURED])?;
    let info = ptp::parse_object_info(&raw);
    let _ = std::fs::create_dir_all(save);
    let name = free_name(save, &info.filename);
    let path = save.join(&name);
    let part = save.join(format!("{name}.part"));
    let file = std::fs::File::create(&part).map_err(|e| Fail::Lost(format!("{}: {e}", part.display())))?;
    let raw_file = (info.format == FORMAT_RAW || name.to_ascii_lowercase().ends_with(".arw")) && info.size > 4_000_000;
    s.emit(json!({"type": "started", "name": name, "size": info.size}));
    let mut inc = Incoming {
        file: BufWriter::with_capacity(1 << 20, file),
        preview_path: previews.join(format!("{}.JPG", shot_stem(&name))),
        name: name.clone(),
        size: u64::from(info.size),
        got: 0,
        told: 0,
        raw: raw_file,
        head: Vec::new(),
        jpeg: None,
        previewed: !raw_file,
        ready,
        s,
    };
    let started = Instant::now();
    let r = ses.transaction(ptp::OP_GET_OBJECT, &[CAPTURED], None, &mut |b| inc.feed(b));
    let flushed = inc.file.flush();
    let got = inc.got;
    drop(inc);
    if let Err(e) = r.map_err(Fail::from).and(flushed.map_err(|e| Fail::Lost(e.to_string()))) {
        let _ = std::fs::remove_file(&part);
        s.emit(json!({"type": "failed", "name": name}));
        return Err(e);
    }
    std::fs::rename(&part, &path).map_err(|e| Fail::Lost(format!("{}: {e}", path.display())))?;
    let took = started.elapsed().as_secs_f64();
    s.emit(json!({
        "type": "shot", "name": name, "path": path.to_string_lossy(), "seconds": ready.elapsed().as_secs_f64(),
        "mbps": if took > 0.05 { got as f64 / 1e6 / took } else { 0.0 },
    }));
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use russh::server::{self, Auth, Msg, Server as _};
    use russh::{Channel, MethodKind, MethodSet};

    /// The camera's SSH server, as far as the tether sees it: keyboard-interactive only, and
    /// `direct-tcpip` to `localhost:15740` forwarded to the stand-in camera's port.
    #[derive(Clone)]
    struct Camera {
        ptp: String,
    }

    impl server::Server for Camera {
        type Handler = Camera;
        fn new_client(&mut self, _: Option<std::net::SocketAddr>) -> Camera {
            self.clone()
        }
    }

    impl server::Handler for Camera {
        type Error = russh::Error;

        async fn auth_keyboard_interactive<'a>(&'a mut self, user: &str, _: &str, response: Option<server::Response<'a>>) -> Result<Auth, Self::Error> {
            Ok(match response {
                None => Auth::Partial { name: "".into(), instructions: "".into(), prompts: vec![("Password: ".into(), false)].into() },
                Some(mut r) => {
                    if user == "admin" && r.next().as_deref() == Some(b"secret".as_slice()) {
                        Auth::Accept
                    } else {
                        Auth::reject()
                    }
                }
            })
        }

        async fn channel_open_direct_tcpip(
            &mut self,
            channel: Channel<Msg>,
            host: &str,
            port: u32,
            _: &str,
            _: u32,
            reply: server::ChannelOpenHandle,
            _: &mut server::Session,
        ) -> Result<(), Self::Error> {
            if host != "localhost" || port != u32::from(PTP_PORT) {
                return Ok(()); // dropped: refused, as the camera refuses 127.0.0.1
            }
            reply.accept().await;
            let ptp = self.ptp.clone();
            tokio::spawn(async move {
                let mut stream = channel.into_stream();
                if let Ok(mut tcp) = tokio::net::TcpStream::connect(ptp).await {
                    tcp.set_nodelay(true).ok();
                    let _ = tokio::io::copy_bidirectional(&mut stream, &mut tcp).await;
                }
            });
            Ok(())
        }
    }

    /// Against scratchpad `fake_ptp_camera.py` on 127.0.0.1:15740 (`LC_FAKECAM=N` shots it sends)
    /// behind a stand-in SSH server (`LC_TEST_HOSTKEY`: an OpenSSH private key).
    #[test]
    fn a_session_through_the_cameras_ssh() {
        let (Ok(n), Ok(key)) = (std::env::var("LC_FAKECAM"), std::env::var("LC_TEST_HOSTKEY")) else { return };
        let want: usize = n.parse().unwrap();
        let host_key = russh::keys::load_secret_key(&key, None).unwrap();
        let expected = host_key.public_key().fingerprint(HashAlg::Sha256).to_string();
        let rt = tokio::runtime::Runtime::new().unwrap();
        let mut methods = MethodSet::server_supported();
        for m in [MethodKind::None, MethodKind::Password, MethodKind::PublicKey, MethodKind::HostBased] {
            methods.remove(m);
        }
        let config = Arc::new(server::Config { keys: vec![host_key], methods, auth_rejection_time: Duration::from_millis(50), ..Default::default() });
        let listener = rt.block_on(tokio::net::TcpListener::bind("127.0.0.1:0")).unwrap();
        let port = listener.local_addr().unwrap().port();
        rt.spawn(async move {
            let mut camera = Camera { ptp: "127.0.0.1:15740".into() };
            let _ = camera.run_on_socket(config, &listener).await;
        });

        let dir = std::env::temp_dir().join(format!("lc-ios-tether-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let cfg = Config {
            host: "127.0.0.1".into(),
            ssh_port: port,
            user: "admin".into(),
            password: "secret".into(),
            fingerprint: None,
            plain: None,
            save_dir: dir.clone(),
            raw: true,
        };
        let t0 = Instant::now();
        let mut t = Tether::start(cfg);
        let (mut previews, mut shots, mut fingerprint) = (0, 0, None);
        while shots < want && t0.elapsed() < Duration::from_secs(150) {
            for e in t.poll() {
                if e["type"] != "progress" {
                    eprintln!("[{:6.2}] {e}", t0.elapsed().as_secs_f64());
                }
                match e["type"].as_str() {
                    Some("preview") => previews += 1,
                    Some("shot") => shots += 1,
                    Some("fingerprint") => fingerprint = e["value"].as_str().map(str::to_string),
                    Some("link") if e["state"] == "blocked" => panic!("{e}"),
                    _ => {}
                }
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        t.stop();
        assert_eq!(shots, want);
        assert_eq!(previews, want);
        assert_eq!(fingerprint.as_deref(), Some(expected.as_str()));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
