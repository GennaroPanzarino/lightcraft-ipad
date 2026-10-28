//! Tethering without Sony's SDK: LightCraft's own PTP/IP connection to the camera, through the
//! camera's SSH server ([`crate::ssh`], [`crate::ptp`]). The point is the raw: the SDK keeps a
//! whole 35 MB ARW in memory and hands it over complete, while here it is written as it arrives,
//! and the camera's full-size JPEG at its start ([`crate::peek`]) is on screen as soon as its first
//! ~1.8 MB have landed — in the same transfer, nothing sent twice.
//!
//! The protocol is the one documented for Sony's PC Remote by libgphoto2 and alpha2go (a6700,
//! firmware 2.00): PTP/IP to `localhost:15740` through SSH `direct-tcpip`, OpenSession, the
//! "SDIO connect" handshake (0x9201 phases 1 and 2, 0x9202, phase 3), still images to the
//! computer and the card (0xD222), the size sent (0xD268), and each shot waiting under the fixed
//! handle 0xFFFFC001 while 0xD215 has bit 15 set; one GetObject fetches (and dequeues) it.
//! Anything the camera doesn't answer as expected sends the tether back to Sony's SDK.

use std::io::{BufWriter, Read, Write};
use std::net::{SocketAddr, SocketAddrV4, TcpStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, PoisonError};
use std::time::{Duration, Instant};

use crate::peek::{Located, locate, orientation, shot_stem, with_orientation};
use crate::ptp::{self, PtpError, Session};
use crate::ssh::{Channel, Ssh, SshError};
use crate::{Choice, Event, Mode, Options, parse_ip};

const SSH_PORT: u16 = 22;
const PTP_PORT: u16 = 15740;
const CAMERA_IP: &str = "192.168.122.1";
/// The handle under which the camera keeps each shot for the computer.
const CAPTURED: u32 = 0xFFFF_C001;
const PROP_PENDING: u16 = 0xD215;
const PROP_DESTINATION: u16 = 0xD222;
const PROP_SIZE_SENT: u16 = 0xD268;
const DESTINATION_COMPUTER_AND_CARD: i64 = 0x11;
const SIZE_ORIGINAL: i64 = 1;
const SIZE_SMALL: i64 = 2;
const OP_SONY_GET_PARTIAL: u16 = 0x9211;
const OP_CLOSE_SESSION: u16 = 0x1003;
const RESP_SESSION_ALREADY_OPEN: u16 = 0x201E;
const FORMAT_RAW: u16 = 0xB101;
const GUID: [u8; 16] = *b"LightCraft-Tethr";
/// The start of a raw kept in memory to find its JPEG (an ILCE-7M4's ends at ~1.77 MB).
const HEAD_LIMIT: usize = 6 * 1024 * 1024;

/// How the direct connection ended.
pub enum Outcome {
    Stopped,
    /// The camera doesn't speak this protocol as expected: use Sony's SDK (why).
    Fallback(String),
}

enum Fail {
    /// The camera isn't there (yet).
    Unreachable,
    /// Needs the user (password): retried much later.
    Blocked(String),
    /// Not this protocol: use the SDK.
    Protocol(String),
    /// A connection that broke; try again.
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

type Emit<'a> = &'a dyn Fn(Event);

/// A connection to the camera's PTP/IP port: an SSH tunnel, or (for tests against a stand-in
/// camera, `LC_TETHER_PLAIN_PTP=host:port`) a plain socket.
pub trait Conn: Read + Write {
    /// Whatever has arrived, without waiting (`Ok(0)`: nothing yet).
    fn read_now(&mut self, buf: &mut [u8]) -> std::io::Result<usize>;
}

impl Conn for Channel<'_> {
    fn read_now(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        Channel::read_now(self, buf)
    }
}

impl Conn for TcpStream {
    fn read_now(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        self.set_nonblocking(true)?;
        let r = self.read(buf);
        self.set_nonblocking(false)?;
        match r {
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => Ok(0),
            r => r,
        }
    }
}

fn nap(stop: &AtomicBool, d: Duration) -> bool {
    let end = Instant::now() + d;
    while Instant::now() < end {
        if stop.load(Ordering::SeqCst) {
            return true;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    stop.load(Ordering::SeqCst)
}

/// Run the tether over the direct connection until stopped, or until it turns out the camera
/// needs Sony's SDK.
pub fn run(opts: &Options, stop: &AtomicBool, choice: &Mutex<Choice>, changed: &AtomicBool, emit: Emit<'_>) -> Outcome {
    if let Ok(plain) = std::env::var("LC_TETHER_PLAIN_PTP") {
        return run_plain(&plain, opts, stop, choice, changed, emit);
    }
    let Some(p) = opts.pairing.as_ref().filter(|p| !p.user.is_empty() && !p.fingerprint.is_empty()) else {
        return Outcome::Fallback("the camera isn't paired with access authentication".into());
    };
    let ip = parse_ip(if p.ip.is_empty() { CAMERA_IP } else { &p.ip }).or_else(|| parse_ip(CAMERA_IP));
    let Some([a, b, c, d]) = ip else { return Outcome::Fallback("no camera address".into()) };
    let addr = SocketAddr::V4(SocketAddrV4::new(std::net::Ipv4Addr::new(a, b, c, d), SSH_PORT));
    let mut searching = false;
    let mut worked = false;
    let mut failures = 0u32;
    let mut wifi = opts.wifi.clone();
    let mut last_join = None;
    let mut gone_since = None;
    while !stop.load(Ordering::SeqCst) {
        match session(opts, addr, &p.user, &p.password, &p.fingerprint, stop, choice, changed, emit, &mut worked, &mut wifi) {
            Ok(()) => return Outcome::Stopped,
            Err(Fail::Unreachable) => {
                if !searching {
                    emit(Event::Searching);
                    searching = true;
                }
                rejoin(wifi.as_deref(), &mut last_join, &mut gone_since);
                nap(stop, Duration::from_secs(2));
            }
            Err(Fail::Blocked(m)) => {
                emit(Event::Error(m));
                nap(stop, Duration::from_secs(30));
            }
            Err(Fail::Protocol(m)) => return Outcome::Fallback(m),
            Err(Fail::Lost(m)) => {
                searching = false;
                gone_since = None; // the camera was there a moment ago
                failures += 1;
                if !worked && failures >= 3 {
                    return Outcome::Fallback(format!("the direct connection keeps failing: {m}"));
                }
                if !stop.load(Ordering::SeqCst) {
                    emit(Event::Disconnected(m));
                }
                nap(stop, Duration::from_secs(1));
                rejoin(wifi.as_deref(), &mut last_join, &mut gone_since);
            }
        }
    }
    Outcome::Stopped
}

/// After the link dropped: if the computer's Wi-Fi is on no network (Windows doesn't go back to the
/// camera by itself) and the camera's network is around, join it again. Never away from a network
/// the user chose; every 5 s at first, every 30 s once the camera has been gone a minute (switched
/// off).
fn rejoin(profile: Option<&str>, last: &mut Option<Instant>, since: &mut Option<Instant>) {
    let Some(p) = profile else { return };
    let gone = since.get_or_insert_with(Instant::now).elapsed();
    let every = Duration::from_secs(if gone < Duration::from_secs(60) { 5 } else { 30 });
    if last.is_some_and(|t: Instant| t.elapsed() < every) {
        return;
    }
    *last = Some(Instant::now());
    if crate::wifi::current().is_some() || !crate::wifi::visible(p) {
        return;
    }
    let asked = crate::wifi::join(p);
    log::info!("tether: direct: the Wi-Fi is on no network and {p} is around: joining it ({})", if asked { "asked Windows" } else { "Windows refused" });
}

/// Against a stand-in camera on a plain socket (tests): no SSH, no pairing.
fn run_plain(addr: &str, opts: &Options, stop: &AtomicBool, choice: &Mutex<Choice>, changed: &AtomicBool, emit: Emit<'_>) -> Outcome {
    let mut worked = false;
    while !stop.load(Ordering::SeqCst) {
        let conns = TcpStream::connect(addr).and_then(|a| TcpStream::connect(addr).map(|b| (a, b)));
        let r = match conns {
            Ok((cmd, evt)) => ptp_session(cmd, evt, Instant::now(), opts, stop, choice, changed, emit, &mut worked, &mut None),
            Err(_) => Err(Fail::Unreachable),
        };
        match r {
            Ok(()) => return Outcome::Stopped,
            Err(Fail::Protocol(m)) => return Outcome::Fallback(m),
            Err(Fail::Lost(m) | Fail::Blocked(m)) => emit(Event::Disconnected(m)),
            Err(Fail::Unreachable) => {}
        }
        nap(stop, Duration::from_secs(1));
    }
    Outcome::Stopped
}

#[allow(clippy::too_many_arguments)]
fn session(
    opts: &Options,
    addr: SocketAddr,
    user: &str,
    password: &str,
    fingerprint: &str,
    stop: &AtomicBool,
    choice: &Mutex<Choice>,
    changed: &AtomicBool,
    emit: Emit<'_>,
    worked: &mut bool,
    wifi: &mut Option<String>,
) -> Result<(), Fail> {
    let t0 = Instant::now();
    let ssh = Ssh::connect(&opts.sdk_dir, addr, user, password, fingerprint).map_err(|e| match e {
        SshError::Unreachable(m) => {
            log::debug!("tether: direct: camera not reachable: {m}");
            Fail::Unreachable
        }
        SshError::Auth(m) => Fail::Blocked(format!("The camera refused its user and password ({m}): pair it again")),
        // the SDK checks the key its own way (and refuses a stranger as well)
        SshError::Fingerprint { got } => Fail::Protocol(format!("the camera's SSH key reads {got}, not the paired fingerprint")),
        SshError::Other(m) => Fail::Lost(m),
    })?;
    let cmd = ssh.channel("localhost", PTP_PORT).map_err(Fail::Lost)?;
    let evt = ssh.channel("localhost", PTP_PORT).map_err(Fail::Lost)?;
    // the network the camera was found on (its own Wi-Fi), to join again after a drop
    if let Some((ssid, profile)) = crate::wifi::current().filter(|(ssid, _)| ssid.starts_with("DIRECT-"))
        && wifi.as_deref() != Some(profile.as_str())
    {
        log::info!("tether: direct: on the camera's Wi-Fi {ssid}");
        *wifi = Some(profile.clone());
        emit(Event::Network { profile });
    }
    ptp_session(cmd, evt, t0, opts, stop, choice, changed, emit, worked, wifi)
}

/// The PTP/IP session over the two connections (command, event), until stopped or broken.
#[allow(clippy::too_many_arguments)]
fn ptp_session<C: Conn>(
    mut cmd: C,
    mut evt: C,
    t0: Instant,
    opts: &Options,
    stop: &AtomicBool,
    choice: &Mutex<Choice>,
    changed: &AtomicBool,
    emit: Emit<'_>,
    worked: &mut bool,
    _wifi: &mut Option<String>,
) -> Result<(), Fail> {
    let (conn, name) = ptp::init_command(&mut cmd, &GUID, "LightCraft")?;
    ptp::init_event(&mut evt, conn)?;
    let mut s = Session::new(cmd);
    let (_, raw) = s.call(ptp::OP_GET_DEVICE_INFO, &[])?;
    let info = ptp::parse_device_info(&raw);
    let model = if info.model.is_empty() { name } else { info.model.clone() };
    log::info!(
        "tether: direct: {model} ({} {}), {} operations, {} events, {} properties, vendor extension 0x{:X}, partial reads {}",
        info.manufacturer,
        info.version,
        info.operations.len(),
        info.events.len(),
        info.properties.len(),
        info.vendor_extension,
        info.operations.contains(&OP_SONY_GET_PARTIAL)
    );
    let ops: Vec<String> = info.operations.iter().map(|o| format!("{o:04X}")).collect();
    log::info!("tether: direct: operations {}", ops.join(" "));
    match s.call(ptp::OP_OPEN_SESSION, &[1]) {
        Ok(_) | Err(PtpError::Response { code: RESP_SESSION_ALREADY_OPEN, .. }) => {}
        Err(e) => return Err(e.into()),
    }
    let version = handshake(&mut s)?;
    log::info!("tether: direct: Sony handshake done (protocol {version}) in {:.2} s", t0.elapsed().as_secs_f64());
    *worked = true;
    emit(Event::Connected { model: model.clone() });

    let props = all_props(&mut s)?;
    let one_prop = info.operations.contains(&ptp::OP_SONY_GET_PROP);
    for code in [PROP_PENDING, PROP_DESTINATION, PROP_SIZE_SENT] {
        match props.iter().find(|p| p.code == code) {
            Some(p) => log::info!("tether: direct: property 0x{code:04X} = 0x{:X} (type {}, writable {})", p.current, p.typ, p.writable),
            None => log::info!("tether: direct: the camera has no property 0x{code:04X}"),
        }
    }
    if !props.iter().any(|p| p.code == PROP_PENDING) {
        return Err(Fail::Protocol("the camera doesn't report shots waiting for the computer (0xD215)".into()));
    }
    set_prop(&mut s, &props, PROP_DESTINATION, DESTINATION_COMPUTER_AND_CARD, emit);
    changed.store(false, Ordering::SeqCst);
    let mut c = *choice.lock().unwrap_or_else(PoisonError::into_inner);
    apply(&mut s, &props, c, emit);

    let save = opts.save_dir.clone();
    let previews = save.join("previews");
    let _ = std::fs::create_dir_all(&previews);
    let mut events = Vec::new();
    loop {
        if stop.load(Ordering::SeqCst) {
            let _ = s.call(OP_CLOSE_SESSION, &[]);
            return Ok(());
        }
        drain_events(&mut evt, &mut events);
        if changed.swap(false, Ordering::SeqCst) {
            c = *choice.lock().unwrap_or_else(PoisonError::into_inner);
            apply(&mut s, &props, c, emit);
        }
        let pending = pending(&mut s, one_prop)?;
        if pending & 0x8000 != 0 {
            let ready = Instant::now();
            match download(&mut s, &save, &previews, ready, emit) {
                // the camera said no (busy…): ask again in a moment
                Err(Fail::Protocol(m)) => {
                    log::warn!("tether: direct: {m}");
                    std::thread::sleep(Duration::from_millis(500));
                }
                r => r?,
            }
            continue;
        }
        std::thread::sleep(Duration::from_millis(40));
    }
}

/// Sony's "SDIO connect": phases 1 and 2, the extended device info (protocol 3.00, else 2.00),
/// phase 3. Returns the protocol version the camera answered with.
fn handshake(s: &mut Session<impl Conn>) -> Result<u32, Fail> {
    for phase in [1, 2] {
        s.call(ptp::OP_SONY_SDIO_CONNECT, &[phase, 0, 0])?;
    }
    let mut used = 0;
    'versions: for version in [0x12C, 0xC8] {
        for _ in 0..20 {
            match s.call(ptp::OP_SONY_GET_EXT_DEVICE_INFO, &[version, 1]) {
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
    s.call(ptp::OP_SONY_SDIO_CONNECT, &[3, 0, 0])?;
    Ok(used)
}

fn all_props(s: &mut Session<impl Conn>) -> Result<Vec<ptp::SonyProp>, Fail> {
    let (_, data) = s.call(ptp::OP_SONY_GET_ALL_PROPS, &[0])?;
    Ok(ptp::parse_sony_props(&data))
}

/// 0xD215: bit 15 set while a shot waits for the computer.
fn pending(s: &mut Session<impl Conn>, one_prop: bool) -> Result<i64, Fail> {
    if one_prop
        && let Ok((_, data)) = s.call(ptp::OP_SONY_GET_PROP, &[u32::from(PROP_PENDING)])
        && let Some(p) = ptp::parse_sony_prop(&data)
        && p.code == PROP_PENDING
    {
        return Ok(p.current);
    }
    Ok(all_props(s)?.into_iter().find(|p| p.code == PROP_PENDING).map_or(0, |p| p.current))
}

/// Set a property the camera has (and lets us write), if it isn't so already. Failures are logged.
fn set_prop(s: &mut Session<impl Conn>, props: &[ptp::SonyProp], code: u16, value: i64, emit: Emit<'_>) -> bool {
    let Some(p) = props.iter().find(|p| p.code == code) else { return false };
    if p.current == value {
        return true;
    }
    let Some(data) = ptp::encode_scalar(p.typ, value) else { return false };
    match s.send(ptp::OP_SONY_SET_PROP, &[u32::from(code)], &data) {
        Ok(_) => {
            log::info!("tether: direct: 0x{code:04X} set to 0x{value:X}");
            true
        }
        Err(e) => {
            log::warn!("tether: direct: couldn't set 0x{code:04X} to 0x{value:X}: {e}");
            if code == PROP_DESTINATION {
                emit(Event::Warning("Couldn't tell the camera to send shots to the computer: set Still Image Save Destination to computer + camera in its menu".into()));
            }
            false
        }
    }
}

/// What the camera sends for a choice: the original (RAW) or its 2 MP JPEG.
fn apply(s: &mut Session<impl Conn>, props: &[ptp::SonyProp], c: Choice, emit: Emit<'_>) {
    let size = if c.mode == Mode::Full { SIZE_ORIGINAL } else { SIZE_SMALL };
    let has = props.iter().any(|p| p.code == PROP_SIZE_SENT);
    if has && !set_prop(s, props, PROP_SIZE_SENT, size, emit) {
        emit(Event::Pending { message: "The camera doesn't accept the size to send: change mode to try again".into() });
        return;
    }
    let mut message = match c.mode {
        Mode::Full => "RAW (direct): every shot shows at full size as soon as the start of its raw lands, then the raw completes in the same transfer",
        Mode::Preview => "Preview (direct): a 2 MP JPEG of every shot, about half a second after it",
    }
    .to_string();
    if !has {
        message.push_str(" (the camera sends the size it is set to)");
    }
    emit(Event::Ready { message });
}

/// Read what the event connection has (without waiting), so the camera never waits on it.
fn drain_events(evt: &mut impl Conn, buf: &mut Vec<u8>) {
    let mut tmp = [0u8; 4096];
    for _ in 0..64 {
        match evt.read_now(&mut tmp) {
            Ok(0) | Err(_) => break,
            Ok(n) => buf.extend_from_slice(&tmp[..n]),
        }
    }
    let mut probes = 0;
    for e in ptp::take_events(buf, |_| probes += 1) {
        log::debug!("tether: direct: event 0x{:04X} {:X?}", e.code, e.params);
    }
    for _ in 0..probes {
        let _ = ptp::write_packet(evt, ptp::PROBE_RESPONSE, &[]);
    }
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

/// One shot on its way: written to `<name>.part` as it arrives; for a raw, its full-size JPEG
/// goes to `previews\<stem>.JPG` (and on screen) as soon as it is all here.
struct Incoming<'a> {
    file: BufWriter<std::fs::File>,
    preview_path: PathBuf,
    name: String,
    size: u64,
    got: u64,
    told: u64,
    raw: bool,
    head: Vec<u8>,
    jpeg: Option<(usize, usize, u32, u32)>,
    previewed: bool,
    ready: Instant,
    started: Instant,
    emit: Emit<'a>,
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
        if self.size > 0 {
            let step = self.size / 10;
            if step > 0 && self.got >= self.told + step && self.got < self.size {
                self.told = self.got - self.got % step;
                (self.emit)(Event::Transfer { name: self.name.clone(), percent: (self.got * 100 / self.size) as u32 });
            }
        }
        Ok(())
    }

    /// The raw's JPEG, once its directories and then the JPEG itself are here.
    fn look(&mut self) {
        if self.jpeg.is_none() && self.head.len() >= 256 * 1024 {
            match locate(&self.head) {
                Located::At(o, l, w, h) => self.jpeg = Some((o, l, w, h)),
                Located::Not => {
                    log::info!("tether: direct: no JPEG at the start of {}", self.name);
                    self.previewed = true;
                }
                Located::Wait if self.head.len() >= HEAD_LIMIT => self.previewed = true,
                Located::Wait => {}
            }
        }
        let Some((o, l, w, h)) = self.jpeg else { return };
        if self.head.len() < o + l {
            if o + l > HEAD_LIMIT {
                self.previewed = true;
            }
            return;
        }
        self.previewed = true;
        let jpeg = &self.head[o..o + l];
        if !(jpeg.starts_with(&[0xFF, 0xD8]) && jpeg.ends_with(&[0xFF, 0xD9])) {
            log::info!("tether: direct: the JPEG in {} isn't whole", self.name);
            return;
        }
        // a vertical shot's JPEG is stored on its side: it gets the raw's orientation
        let jpeg = with_orientation(jpeg, orientation(&self.head));
        let tmp = self.preview_path.with_extension("JPG.part");
        let saved = std::fs::write(&tmp, &jpeg).and_then(|_| {
            let _ = std::fs::remove_file(&self.preview_path);
            std::fs::rename(&tmp, &self.preview_path)
        });
        match saved {
            Ok(()) => {
                let seconds = self.ready.elapsed().as_secs_f64();
                log::info!(
                    "tether: direct: {} preview {w}×{h} ({} KB) after {:.1} MB of {:.1} MB, {seconds:.2} s after the shot was ready",
                    self.name,
                    l / 1024,
                    self.got as f64 / 1e6,
                    self.size as f64 / 1e6
                );
                (self.emit)(Event::Downloaded { path: self.preview_path.clone(), bytes: Some(l as u64), seconds: Some(seconds), preview: true });
            }
            Err(e) => log::warn!("tether: direct: couldn't save the preview of {}: {e}", self.name),
        }
        self.head = Vec::new();
    }
}

/// Fetch the shot waiting under 0xFFFFC001: written as it arrives, the raw's preview on the way.
fn download(s: &mut Session<impl Conn>, save: &Path, previews: &Path, ready: Instant, emit: Emit<'_>) -> Result<(), Fail> {
    let (_, raw) = s.call(ptp::OP_GET_OBJECT_INFO, &[CAPTURED])?;
    let info = ptp::parse_object_info(&raw);
    let name = free_name(save, &info.filename);
    let stem = shot_stem(&name);
    let path = save.join(&name);
    let part = save.join(format!("{name}.part"));
    let file = std::fs::File::create(&part).map_err(|e| Fail::Lost(format!("{}: {e}", part.display())))?;
    let lower = name.to_ascii_lowercase();
    let raw_file = info.format == FORMAT_RAW || lower.ends_with(".arw");
    log::info!("tether: direct: {name} ({:.1} MB) waiting, fetching", f64::from(info.size) / 1e6);
    let mut inc = Incoming {
        file: BufWriter::with_capacity(1 << 20, file),
        preview_path: previews.join(format!("{stem}.JPG")),
        name: name.clone(),
        size: u64::from(info.size),
        got: 0,
        told: 0,
        raw: raw_file && info.size > 4_000_000,
        head: Vec::new(),
        jpeg: None,
        previewed: false,
        ready,
        started: Instant::now(),
        emit,
    };
    let r = s.transaction(ptp::OP_GET_OBJECT, &[CAPTURED], None, &mut |b| inc.feed(b));
    let flushed = inc.file.flush();
    let took = inc.started.elapsed().as_secs_f64();
    let got = inc.got;
    drop(inc);
    if let Err(e) = r.map_err(Fail::from).and(flushed.map_err(|e| Fail::Lost(e.to_string()))) {
        let _ = std::fs::remove_file(&part);
        return Err(e);
    }
    std::fs::rename(&part, &path).map_err(|e| Fail::Lost(format!("{}: {e}", path.display())))?;
    let seconds = ready.elapsed().as_secs_f64();
    log::info!(
        "tether: direct: {name} {:.1} MB in {took:.1} s ({:.1} MB/s), {seconds:.1} s after the shot was ready",
        got as f64 / 1e6,
        if took > 0.05 { got as f64 / 1e6 / took } else { 0.0 }
    );
    emit(Event::Downloaded { path, bytes: Some(got), seconds: Some(seconds), preview: false });
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_never_overwrite() {
        let dir = std::env::temp_dir().join(format!("lc-direct-names-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        assert_eq!(free_name(&dir, "DSC08860.ARW"), "DSC08860.ARW");
        std::fs::write(dir.join("DSC08860.ARW"), b"x").unwrap();
        assert_eq!(free_name(&dir, "DSC08860.ARW"), "DSC08860(1).ARW");
        assert_eq!(free_name(&dir, "a/b:c.JPG"), "abc.JPG");
        assert_eq!(shot_stem(&free_name(&dir, "DSC08860.ARW")), "DSC08860(1)");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
