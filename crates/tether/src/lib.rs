//! Tethered capture (fork): Sony cameras over the camera's own Wi-Fi (Wi-Fi Direct, "PC Remote" /
//! "Remote Shoot"), through Sony's Camera Remote SDK loaded at run time from beside the executable.
//!
//! [`Tether::start`] runs a worker thread that finds the camera, connects with the access
//! authentication a pairing saved ([`pair`]) and reports what happens as [`Event`]s; the app
//! imports each [`Event::Downloaded`] file.
//!
//! The camera keeps every shot on its card and sends it to the computer ([`Mode`] picks a 2 MP JPEG,
//! the camera's 8 / 14 MP JPEG, or the raw). A raw shows long before it is complete: the SDK writes
//! it as it arrives, and its first ~2 MB are the camera's own full-size JPEG of the shot, which
//! [`peek`] takes out at once; the raw replaces it in the library a few seconds later.
//!
//! With [`Options::transfer`], LightCraft first tries Sony's "remote transfer" instead (cameras whose
//! firmware has it): it pulls from the card the camera's screen-size JPEG of each shot, then the
//! original; the newest shot's original goes first, a new shot's preview overtakes an original on
//! its way, and shots taken while the Wi-Fi was down are pulled when the camera is back. Connections
//! that drop are searched for again.
#![deny(clippy::unwrap_used, clippy::expect_used, clippy::panic, clippy::unimplemented, clippy::todo, clippy::unreachable)]

#[cfg(windows)]
mod direct;
#[cfg_attr(not(windows), allow(dead_code))]
mod peek;
#[cfg_attr(not(windows), allow(dead_code))]
mod ptp;
#[cfg(windows)]
mod sdk;
#[cfg(windows)]
mod ssh;
#[cfg(windows)]
mod wifi;

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
#[cfg(windows)]
use std::sync::mpsc::channel;
use std::sync::mpsc::Receiver;
use std::sync::{Arc, Mutex, PoisonError};
use std::thread::JoinHandle;

/// What the computer gets of each shot.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Mode {
    /// The instant preview only (2 MP), or with [`Size::Mp8`] / [`Size::Mp14`] the camera's own
    /// JPEG at that size after it (RAW+JPEG); the raw stays on the card.
    Preview,
    /// The instant preview, then the original: the raw (else the full JPEG), a few seconds later.
    Full,
}

impl Mode {
    pub fn id(self) -> &'static str {
        match self {
            Mode::Preview => "preview",
            Mode::Full => "full",
        }
    }

    pub fn from_id(s: &str) -> Option<Mode> {
        match s {
            "preview" => Some(Mode::Preview),
            "full" | "raw" => Some(Mode::Full),
            _ => None,
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            Mode::Preview => "Preview",
            Mode::Full => "Full Size",
        }
    }
}

/// How large the preview JPEG is. 8 and 14 MP are the camera's own JPEG at size S or M, which
/// LightCraft sets only when the camera shoots RAW+JPEG (the raw keeps full quality on the card) and
/// puts back as it was for Full Size and when the tether stops.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Size {
    Mp2,
    Mp8,
    Mp14,
}

impl Size {
    pub fn id(self) -> &'static str {
        match self {
            Size::Mp2 => "2mp",
            Size::Mp8 => "8mp",
            Size::Mp14 => "14mp",
        }
    }

    pub fn from_id(s: &str) -> Option<Size> {
        match s {
            "2mp" | "2" => Some(Size::Mp2),
            "8mp" | "8" | "s" => Some(Size::Mp8),
            "14mp" | "14" | "m" => Some(Size::Mp14),
            _ => None,
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            Size::Mp2 => "2 MP",
            Size::Mp8 => "8 MP",
            Size::Mp14 => "14 MP",
        }
    }
}

/// What the camera sends: the mode, and the preview's size.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Choice {
    pub mode: Mode,
    pub size: Size,
}

/// The camera's access authentication saved by a pairing, and where it was found.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Pairing {
    pub user: String,
    pub password: String,
    /// The camera's SSH fingerprint, checked before every connection.
    pub fingerprint: String,
    /// Address and MAC, for when the SDK's own search doesn't see the camera.
    pub ip: String,
    pub mac: String,
}

/// Called after every event, from the tether's threads: the app wakes up and imports a shot at once
/// instead of at its next look.
#[derive(Clone)]
pub struct Waker(pub Arc<dyn Fn() + Send + Sync>);

impl std::fmt::Debug for Waker {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("Waker")
    }
}

#[derive(Clone, Debug)]
pub struct Options {
    /// The folder with `Cr_Core.dll` and `CrAdapter\` (the executable's folder).
    pub sdk_dir: PathBuf,
    /// Where the camera's files are saved (the app imports them from there).
    pub save_dir: PathBuf,
    pub pairing: Option<Pairing>,
    pub choice: Choice,
    pub wake: Option<Waker>,
    /// Try remote transfer first (the ILCE-7M4 on firmware 2.00 refuses it over Wi-Fi Direct).
    pub transfer: bool,
    /// LightCraft's own connection ([`direct`]: a raw shows from its first 2 MB) before Sony's SDK.
    pub direct: bool,
    /// The camera's Wi-Fi (a saved Windows profile, from an earlier [`Event::Network`]): joined again
    /// when the computer's Wi-Fi dropped and is on no network.
    pub wifi: Option<String>,
}

/// What the tether reports, in order.
#[derive(Clone, Debug, PartialEq)]
pub enum Event {
    /// No camera found yet: the computer must be on the camera's Wi-Fi with remote shooting on.
    Searching,
    Connected { model: String },
    /// The camera accepted the mode: what it will send.
    Ready { message: String },
    /// The camera doesn't accept the mode yet (just reconnected, busy…): retried every few seconds.
    Pending { message: String },
    /// A shot arrived (`bytes` long), `seconds` after the shutter when known. `preview`: the
    /// camera's screen-size JPEG of it (in `previews\`), which its original replaces if it follows.
    Downloaded { path: PathBuf, bytes: Option<u64>, seconds: Option<f64>, preview: bool },
    /// An original on its way from the card: its name and how far along it is.
    Transfer { name: String, percent: u32 },
    /// The computer is on the camera's Wi-Fi: this profile (remembered, to join it again after a drop).
    Network { profile: String },
    Info(String),
    Warning(String),
    Disconnected(String),
    Error(String),
}

/// A running tether (stopped on drop).
pub struct Tether {
    stop: Arc<AtomicBool>,
    choice: Arc<Mutex<Choice>>,
    changed: Arc<AtomicBool>,
    events: Receiver<Event>,
    thread: Option<JoinHandle<()>>,
}

impl Tether {
    /// Start looking for the camera (on a worker thread).
    pub fn start(opts: Options) -> Result<Tether, String> {
        #[cfg(windows)]
        {
            let stop = Arc::new(AtomicBool::new(false));
            let choice = Arc::new(Mutex::new(opts.choice));
            let changed = Arc::new(AtomicBool::new(false));
            let (tx, events) = channel();
            let (s, m, c) = (stop.clone(), choice.clone(), changed.clone());
            let thread = std::thread::Builder::new()
                .name("lc-tether".into())
                .spawn(move || worker::run(opts, &s, &m, &c, tx))
                .map_err(|e| format!("tethered capture: could not start: {e}"))?;
            Ok(Tether { stop, choice, changed, events, thread: Some(thread) })
        }
        #[cfg(not(windows))]
        {
            let _ = opts;
            Err(UNSUPPORTED.into())
        }
    }

    /// Switch what the camera sends (applied at once when connected).
    pub fn set_choice(&self, choice: Choice) {
        *self.choice.lock().unwrap_or_else(PoisonError::into_inner) = choice;
        self.changed.store(true, Ordering::SeqCst);
    }

    pub fn choice(&self) -> Choice {
        *self.choice.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// The events since the last call.
    pub fn poll(&self) -> Vec<Event> {
        self.events.try_iter().collect()
    }

    /// Disconnect and wait for the worker (a few seconds at most).
    pub fn stop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
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

/// What [`find`] saw: enough for the pairing dialog to show and check.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Found {
    pub model: String,
    pub ssh: bool,
    /// The fingerprint to compare with the camera's screen (access authentication on).
    pub fingerprint: Option<String>,
    pub ip: String,
    pub mac: String,
}

#[cfg(not(windows))]
const UNSUPPORTED: &str = "Tethered capture needs Windows (Sony's Camera Remote SDK)";

/// Look for the camera once (blocking: run it off the UI thread).
pub fn find(sdk_dir: &Path) -> Result<Found, String> {
    #[cfg(windows)]
    {
        worker::find(sdk_dir)
    }
    #[cfg(not(windows))]
    {
        let _ = sdk_dir;
        Err(UNSUPPORTED.into())
    }
}

/// Connect once with the camera's user and password to check them, then disconnect (blocking).
pub fn pair(sdk_dir: &Path, found: &Found, user: &str, password: &str) -> Result<Pairing, String> {
    #[cfg(windows)]
    {
        worker::pair(sdk_dir, found, user, password)
    }
    #[cfg(not(windows))]
    {
        let _ = (sdk_dir, found, user, password);
        Err(UNSUPPORTED.into())
    }
}

/// Call last when the app quits, with everything saved and the tether stopped: if Sony's SDK was
/// loaded, it is shut down and the process ends here (otherwise it would hang on exit).
pub fn end_process_if_sdk_loaded() {
    #[cfg(windows)]
    sdk::end_process_if_loaded();
}

/// The SDK's error and warning codes (CrError.h, SDK 2.02) in words.
pub fn describe(code: u32) -> String {
    let what = match code {
        0x8201 => "the connection failed",
        0x8202 => "the network connection failed",
        0x8207 => "the camera disconnected",
        0x8208 => "timed out",
        0x8209 => "the camera didn't come back in time",
        0x820A => "the camera refused the connection",
        0x820B => "the camera is busy (connected to a phone or another program?)",
        0x8206 => "the SDK's network module is missing (CrAdapter beside lightcraft.exe)",
        0x8210 => "another program already has a session with the camera",
        0x8213 => "invalid user or password",
        0x8214 => "the encrypted connection failed",
        0x8215 => "the camera's fingerprint doesn't match",
        0x8216 => "wrong user or password",
        0x8218 => "couldn't read the camera's fingerprint",
        0x8402 => "the camera doesn't accept this setting now",
        0x8703 => "no camera found",
        0x8705 => "the SDK's modules are missing (CrAdapter)",
        u32::MAX => "the camera doesn't report this setting",
        0x20094 => "the camera couldn't send it",
        0x20095 => "the camera is busy",
        0x2009A | 0x2009B => "stopped",
        _ => "error",
    };
    if code == u32::MAX { what.to_string() } else { format!("{what} (0x{code:X})") }
}

/// A MAC address from Windows' `arp -a` (`dc-fe-23-e9-5d-95`) or `dc:fe:…`.
pub fn parse_mac(s: &str) -> Option<[u8; 6]> {
    let parts: Vec<&str> = s.split(['-', ':']).collect();
    if parts.len() != 6 {
        return None;
    }
    let mut mac = [0u8; 6];
    for (b, p) in mac.iter_mut().zip(parts) {
        *b = u8::from_str_radix(p, 16).ok()?;
    }
    Some(mac)
}

pub fn parse_ip(s: &str) -> Option<[u8; 4]> {
    s.trim().parse::<std::net::Ipv4Addr>().ok().map(|a| a.octets())
}

#[cfg(windows)]
mod worker {
    use std::collections::{HashSet, VecDeque};
    use std::path::{Path, PathBuf};
    use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
    use std::sync::mpsc::{Receiver, Sender, channel};
    use std::sync::{Arc, Mutex, PoisonError};
    use std::time::{Duration, Instant};

    use super::{Choice, Event, Found, Mode, Options, Pairing, Size, Waker, describe, parse_ip, parse_mac};
    use crate::peek::Peeker;
    use crate::sdk::{self, Api, Camera, CallbackObject, Content, ContentFile, FORMAT_HEIF, FORMAT_JPEG, FORMAT_RAW, Sink};

    const MODEL_ILCE_7M4: u32 = 7;
    /// Sony cameras' usual address on their own Wi-Fi (Wi-Fi Direct).
    const CAMERA_IP: &str = "192.168.122.1";
    const DP_FILE_TYPE: u32 = 0x106;
    const DP_STILL_STORE_DEST: u32 = 0x119;
    const DP_REMOTE_SAVE_SIZE: u32 = 0x27E;
    const DP_STILL_TRANS_SIZE: u32 = 0x506;
    const DP_RAW_J_PC_SAVE: u32 = 0x507;
    /// The camera's JPEG size (1 L, 2 M, 3 S) and its RAW type (0 uncompressed, 1 compressed, 2–5 lossless, 6 compressed HQ).
    const DP_IMAGE_SIZE: u32 = 0x110;
    const DP_RAW_TYPE: u32 = 0x131;
    const STORE_PC_AND_CARD: u64 = 3;
    const W_RECONNECTED: u32 = 0x20001;
    const W_RECONNECTING: u32 = 0x20002;
    const W_STORAGE_FULL: u32 = 0x20003;
    const W_SETFILENAME_FAILED: u32 = 0x20004;
    const W_GETIMAGE_FAILED: u32 = 0x20005;
    const W_NETWORK_ERROR: u32 = 0x20007;
    const N_CAPTURED: u32 = 0x20011;
    const TIMED_OUT: u32 = 0x8208;
    const STORE_CARD: u64 = 2;
    /// The SDK's settings for a connection (Setting_Key_*): live view and post view (the camera
    /// sending each shot), both off for remote transfer.
    const SETTING_LIVE_VIEW: u32 = 0;
    const SETTING_POST_VIEW: u32 = 9;
    /// Whether the SDK has the card's list (CrDeviceProperty_MediaSLOT1/2_ContentsInfoListEnableStatus).
    const DP_SLOT1_LIST_READY: u32 = 0x7A5;
    /// OnNotifyRemoteTransferResult / …ContentsListChanged (CrError.h, SDK 2.02).
    const RT_OK: u32 = 0x20093;
    const RT_IN_PROGRESS: u32 = 0x20099;
    const RT_CHANGED_ALL: u32 = 0x20096;
    const RT_CHANGED_CLEAR: u32 = 0x20098;
    /// More new shots than this in one look at the card is the SDK (re)loading its list, not shooting.
    const RELOAD: usize = 30;

    /// Where events go, and who to wake when one is sent (the app, so a shot is imported at once).
    #[derive(Clone)]
    pub struct Out {
        tx: Sender<Event>,
        wake: Option<Waker>,
    }

    fn send(tx: &Out, e: Event) {
        let _ = tx.tx.send(e);
        if let Some(w) = &tx.wake {
            (w.0)();
        }
    }

    /// Sleep up to `d`, waking early when asked to stop. `true` = stop.
    fn nap(stop: &AtomicBool, d: Duration) -> bool {
        let end = Instant::now() + d;
        while Instant::now() < end {
            if stop.load(Ordering::SeqCst) {
                return true;
            }
            std::thread::sleep(Duration::from_millis(100));
        }
        stop.load(Ordering::SeqCst)
    }

    /// What the SDK said about the card and the transfers (for the worker thread).
    enum Note {
        Transferred { notify: u32, percent: u32, path: String },
        Changed { notify: u32, slot: u32, added: u32 },
    }

    /// One connection's state, shared with the SDK's callback threads.
    struct Link {
        tx: Out,
        connected: AtomicBool,
        ended: AtomicBool,
        last_error: AtomicU32,
        captured_at: Mutex<Option<Instant>>,
        mode_changed: Arc<AtomicBool>,
        notes: Mutex<Sender<Note>>,
        /// Files the SDK reported complete since the worker last looked.
        completed: Mutex<Vec<PathBuf>>,
        /// A shot failed or the link had an error since the worker last looked.
        trouble: AtomicBool,
    }

    impl Link {
        fn new(tx: Out, mode_changed: Arc<AtomicBool>) -> (Arc<Link>, Receiver<Note>) {
            let (notes, rx) = channel();
            let link = Link {
                tx,
                connected: AtomicBool::new(false),
                ended: AtomicBool::new(false),
                last_error: AtomicU32::new(0),
                captured_at: Mutex::new(None),
                mode_changed,
                notes: Mutex::new(notes),
                completed: Mutex::new(Vec::new()),
                trouble: AtomicBool::new(false),
            };
            (Arc::new(link), rx)
        }

        fn note(&self, n: Note) {
            let _ = self.notes.lock().unwrap_or_else(PoisonError::into_inner).send(n);
        }
    }

    impl Sink for Link {
        fn transferred(&self, notify: u32, percent: u32, path: String) {
            self.note(Note::Transferred { notify, percent, path });
        }
        fn contents_changed(&self, notify: u32, slot: u32, added: u32) {
            self.note(Note::Changed { notify, slot, added });
        }
        fn connected(&self) {
            self.connected.store(true, Ordering::SeqCst);
        }
        fn disconnected(&self, error: u32) {
            self.last_error.store(error, Ordering::SeqCst);
            self.connected.store(false, Ordering::SeqCst);
            self.ended.store(true, Ordering::SeqCst);
        }
        fn error(&self, error: u32) {
            self.last_error.store(error, Ordering::SeqCst);
            self.ended.store(true, Ordering::SeqCst);
        }
        fn downloaded(&self, path: String) {
            let seconds = self.captured_at.lock().unwrap_or_else(PoisonError::into_inner).take().map(|t| t.elapsed().as_secs_f64());
            let meta = std::fs::metadata(&path).ok();
            let bytes = meta.as_ref().map(std::fs::Metadata::len);
            // how long the file was being written (a raw written as it arrives gives its preview early)
            if let Some(age) = meta.and_then(|m| m.created().ok()).and_then(|c| c.elapsed().ok())
                && bytes.is_some_and(|b| b > 5_000_000)
            {
                log::info!("tether: {path} was being written for {:.2} s", age.as_secs_f64());
            }
            let path = PathBuf::from(path);
            self.completed.lock().unwrap_or_else(PoisonError::into_inner).push(path.clone());
            send(&self.tx, Event::Downloaded { path, bytes, seconds, preview: false });
        }
        fn warning(&self, code: u32) {
            match code {
                N_CAPTURED => *self.captured_at.lock().unwrap_or_else(PoisonError::into_inner) = Some(Instant::now()),
                W_RECONNECTING => send(&self.tx, Event::Warning("Lost the connection to the camera: reconnecting…".into())),
                W_RECONNECTED => {
                    send(&self.tx, Event::Info("Camera reconnected".into()));
                    // after a drop the camera may have forgotten what to send
                    self.mode_changed.store(true, Ordering::SeqCst);
                }
                W_GETIMAGE_FAILED | W_SETFILENAME_FAILED => {
                    self.trouble.store(true, Ordering::SeqCst);
                    send(&self.tx, Event::Warning("A shot didn't reach the computer (it is still on the card)".into()))
                }
                W_STORAGE_FULL => send(&self.tx, Event::Warning("The computer's disk is full: shots are no longer saved".into())),
                W_NETWORK_ERROR => {
                    self.trouble.store(true, Ordering::SeqCst);
                    send(&self.tx, Event::Warning("Network error with the camera".into()))
                }
                _ => {}
            }
            if code == W_RECONNECTING {
                self.trouble.store(true, Ordering::SeqCst);
            }
        }
    }

    /// The camera the SDK finds; else one at its usual Wi-Fi Direct address, with the MAC the
    /// pairing saved or Windows' ARP table gives.
    fn locate(api: &Api, pairing: Option<&Pairing>, ssh: bool) -> Option<Camera> {
        if let Some(c) = api.enumerate() {
            return Some(c);
        }
        let ip_text = pairing.map(|p| p.ip.as_str()).filter(|s| !s.is_empty()).unwrap_or(CAMERA_IP);
        let ip = parse_ip(ip_text)?;
        let mac = pairing.and_then(|p| parse_mac(&p.mac)).or_else(|| mac_for(ip_text))?;
        api.camera_at(MODEL_ILCE_7M4, ip, mac, ssh)
    }

    /// The MAC of `ip` from Windows' ARP table (after a ping, so it is there).
    fn mac_for(ip: &str) -> Option<[u8; 6]> {
        use std::os::windows::process::CommandExt;
        const NO_WINDOW: u32 = 0x0800_0000;
        let _ = std::process::Command::new("ping").args(["-n", "1", "-w", "800", ip]).creation_flags(NO_WINDOW).output();
        let out = std::process::Command::new("arp").args(["-a", ip]).creation_flags(NO_WINDOW).output().ok()?;
        let text = String::from_utf8_lossy(&out.stdout);
        text.lines().filter(|l| l.split_whitespace().next() == Some(ip)).find_map(|l| l.split_whitespace().nth(1).and_then(parse_mac))
    }

    enum End {
        NotFound,
        /// Try again in a few seconds.
        Failed(String),
        /// Needs the user (pairing, changed fingerprint): try again much later.
        Blocked(String),
        /// A connection that worked has ended.
        Done(String),
        /// Connected, but the camera's card can't be read this way: use remote control.
        NoTransfer(String),
    }

    /// What the camera had before LightCraft changed it, to put back: its JPEG size.
    #[derive(Default)]
    struct Restore {
        jpeg_size: Option<u64>,
    }

    /// The shots on the camera's cards LightCraft knows of, kept across connections so the shots
    /// taken while the Wi-Fi was down are pulled when it is back: (slot, folder number, file number).
    #[derive(Default)]
    struct Card {
        seen: HashSet<(u32, u32, u32)>,
        /// Slots whose earlier shots were taken in: anything new there after that is a shot to pull.
        listed: HashSet<u32>,
        /// Shots whose preview was delivered (not pulled again after a reconnection).
        previewed: HashSet<(u32, u32, u32)>,
        /// Remote transfer worked during this run.
        transfer_worked: bool,
        /// Early previews out of raws being written are off for this run (a shot failed right
        /// after one was read: see [`crate::peek`]).
        peek_off: bool,
    }

    pub fn run(opts: Options, stop: &AtomicBool, choice: &Mutex<Choice>, changed: &Arc<AtomicBool>, tx: Sender<Event>) {
        let out = Out { tx, wake: opts.wake.clone() };
        let tx = &out;
        if opts.direct {
            match crate::direct::run(&opts, stop, choice, changed, &|e| send(tx, e)) {
                crate::direct::Outcome::Stopped => return,
                crate::direct::Outcome::Fallback(why) => {
                    log::warn!("tether: direct connection not usable ({why}): Sony's SDK takes over");
                    send(tx, Event::Info(format!("Using Sony's SDK ({why})")));
                }
            }
        }
        let api = match sdk::api(&opts.sdk_dir) {
            Ok(a) => a,
            Err(e) => return send(tx, Event::Error(e)),
        };
        log::info!("tether: Sony Camera Remote SDK {}", api.version());
        let mut searching = false;
        let mut restore = Restore::default();
        let mut card = Card::default();
        // remote transfer when asked for (instant previews, then the originals), with remote control
        // (the camera sends each shot) when the camera can't: after two failed connections where it
        // never worked
        let mut transfer = opts.transfer;
        let mut failures = 0u32;
        while !stop.load(Ordering::SeqCst) {
            match session(api, &opts, stop, choice, changed, &mut restore, &mut card, transfer, tx) {
                End::NotFound => {
                    if !searching {
                        send(tx, Event::Searching);
                        searching = true;
                    }
                    nap(stop, Duration::from_secs(3));
                }
                End::Failed(m) => {
                    if opts.transfer && !card.transfer_worked {
                        failures += 1;
                        if failures >= 2 {
                            // both ways failing means the Wi-Fi, not the mode: alternate
                            transfer = !transfer;
                            failures = 0;
                            log::warn!("tether: next attempt by {}", if transfer { "remote transfer" } else { "remote control" });
                        }
                    }
                    send(tx, Event::Error(m));
                    nap(stop, Duration::from_secs(5));
                }
                End::Blocked(m) => {
                    send(tx, Event::Error(m));
                    nap(stop, Duration::from_secs(30));
                }
                End::Done(m) => {
                    searching = false;
                    if !stop.load(Ordering::SeqCst) {
                        send(tx, Event::Disconnected(m));
                    }
                }
                End::NoTransfer(m) => {
                    log::warn!("tether: remote transfer doesn't work with this camera ({m}): it will send each shot itself");
                    send(tx, Event::Info("This camera can't hand over its card, so it sends each shot itself (no instant previews)".into()));
                    transfer = false;
                }
            }
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn session(
        api: &Api,
        opts: &Options,
        stop: &AtomicBool,
        choice: &Mutex<Choice>,
        mode_changed: &Arc<AtomicBool>,
        restore: &mut Restore,
        card: &mut Card,
        transfer: bool,
        tx: &Out,
    ) -> End {
        let pairing = opts.pairing.as_ref().filter(|p| !p.user.is_empty());
        let Some(cam) = locate(api, opts.pairing.as_ref(), pairing.is_some()) else { return End::NotFound };
        let info = cam.info();
        let auth = if info.ssh {
            let Some(p) = pairing else {
                return End::Blocked("The camera asks for its user and password: pair it first (File ▸ Tethered Capture ▸ Pair Camera…)".into());
            };
            let fp = match api.fingerprint(&cam) {
                Ok(f) => f,
                Err(e) => return End::Failed(format!("Couldn't read the camera's fingerprint: {}", describe(e))),
            };
            if !p.fingerprint.is_empty() && fp != p.fingerprint {
                return End::Blocked(
                    "The camera's fingerprint changed, so LightCraft doesn't connect. If you reset the camera, pair it again.".into(),
                );
            }
            Some((p.user.clone(), p.password.clone(), fp))
        } else {
            None
        };
        let (link, notes) = Link::new(tx.clone(), mode_changed.clone());
        let callbacks = CallbackObject::new(link.clone());
        let mut handle = 0i64;
        let err = api.connect(&cam, &callbacks, &mut handle, auth.as_ref().map(|(u, p, f)| (u.as_str(), p.as_str(), f.as_str())), transfer);
        drop(cam);
        if err != 0 {
            return End::Failed(format!("Couldn't connect to the camera: {}", describe(err)));
        }
        let deadline = Instant::now() + Duration::from_secs(30);
        while !link.connected.load(Ordering::SeqCst) && !link.ended.load(Ordering::SeqCst) && Instant::now() < deadline {
            if nap(stop, Duration::from_millis(200)) {
                break;
            }
        }
        if !link.connected.load(Ordering::SeqCst) {
            api.release_device(handle);
            drop(callbacks);
            let e = link.last_error.load(Ordering::SeqCst);
            return End::Failed(format!("Couldn't connect to the camera: {}", describe(if e == 0 { TIMED_OUT } else { e })));
        }
        log::info!("tether: {} connected by {}", info.model, if transfer { "remote transfer" } else { "remote control" });
        send(tx, Event::Connected { model: info.model });

        // the shots (and the previews) go into the save folder
        if let Err(e) = std::fs::create_dir_all(&opts.save_dir) {
            send(tx, Event::Warning(format!("Couldn't create {}: {e}", opts.save_dir.display())));
        }
        let e = api.set_save_dir(handle, &opts.save_dir);
        if e != 0 {
            send(tx, Event::Warning(format!("Couldn't set the folder for the shots: {}", describe(e))));
        }
        nap(stop, Duration::from_secs(1)); // right after connecting the camera may refuse settings
        let outcome = if transfer {
            transfer_loop(api, handle, opts, stop, choice, mode_changed, restore, card, &link, &notes, tx)
        } else {
            push_loop(api, handle, &opts.save_dir, stop, choice, mode_changed, restore, &mut card.peek_off, &link, tx);
            None
        };
        if !link.ended.load(Ordering::SeqCst) {
            // stopping: the camera's JPEG goes back to the size it had
            if let Some(size) = restore.jpeg_size
                && api.set_property(handle, DP_IMAGE_SIZE, size) == 0
            {
                restore.jpeg_size = None;
            }
            api.disconnect(handle);
            let end = Instant::now() + Duration::from_secs(5);
            while !link.ended.load(Ordering::SeqCst) && Instant::now() < end {
                std::thread::sleep(Duration::from_millis(100));
            }
        }
        api.release_device(handle);
        drop(callbacks); // the SDK no longer calls it after ReleaseDevice
        if let Some(end) = outcome {
            return end;
        }
        let e = link.last_error.load(Ordering::SeqCst);
        End::Done(if e == 0 { "the connection ended".into() } else { describe(e) })
    }

    /// Remote control: the camera keeps every shot on its card and sends it to the computer. A raw
    /// shows before it is complete: the full-size JPEG at its start is taken out as soon as it has
    /// landed ([`crate::peek`]).
    #[allow(clippy::too_many_arguments)]
    fn push_loop(
        api: &Api,
        handle: i64,
        save_dir: &Path,
        stop: &AtomicBool,
        choice: &Mutex<Choice>,
        mode_changed: &Arc<AtomicBool>,
        restore: &mut Restore,
        peek_off: &mut bool,
        link: &Link,
        tx: &Out,
    ) {
        // no live view: the Wi-Fi is for the shots
        let e = api.set_setting(handle, SETTING_LIVE_VIEW, 0);
        if e != 0 {
            log::info!("tether: live view stays on ({})", describe(e));
        }
        let e = set(api, handle, DP_STILL_STORE_DEST, STORE_PC_AND_CARD, 5, stop);
        if e != 0 {
            send(
                tx,
                Event::Warning(format!(
                    "Couldn't tell the camera to send shots to the computer ({}): set Still Image Save Destination to computer + camera in its menu",
                    describe(e)
                )),
            );
        }
        mode_changed.store(false, Ordering::SeqCst);
        let mut failing = None;
        let mut retry_at = (!apply(api, handle, choice, restore, tx, &mut failing, 3, stop)).then(|| Instant::now() + Duration::from_secs(3));
        let mut peeker = Peeker::new(save_dir, &save_dir.join("previews"));
        while !link.ended.load(Ordering::SeqCst) && !stop.load(Ordering::SeqCst) {
            let due = retry_at.is_some_and(|t| Instant::now() >= t);
            if mode_changed.swap(false, Ordering::SeqCst) || due {
                let ok = apply(api, handle, choice, restore, tx, &mut failing, 2, stop);
                retry_at = (!ok).then(|| Instant::now() + Duration::from_secs(3));
            }
            for p in std::mem::take(&mut *link.completed.lock().unwrap_or_else(PoisonError::into_inner)) {
                peeker.finished(&p);
            }
            if link.trouble.swap(false, Ordering::SeqCst) {
                peeker.suspect();
                *peek_off |= peeker.is_off();
            }
            if *peek_off {
                std::thread::sleep(Duration::from_millis(100));
                continue;
            }
            for p in peeker.scan() {
                let shutter = *link.captured_at.lock().unwrap_or_else(PoisonError::into_inner);
                let seconds = shutter.map(|t| t.elapsed().as_secs_f64());
                log::info!(
                    "tether: {} preview {}×{} ({} KB) out of {} with {:.1} MB of it there{}",
                    p.path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default(),
                    p.width,
                    p.height,
                    p.bytes / 1024,
                    p.from,
                    p.at as f64 / 1_000_000.0,
                    seconds.map_or_else(String::new, |s| format!(", {s:.2} s after the shutter"))
                );
                send(tx, Event::Downloaded { path: p.path, bytes: Some(p.bytes), seconds, preview: true });
            }
            std::thread::sleep(Duration::from_millis(25));
        }
    }

    /// One file to bring from the card.
    #[derive(Clone, Debug)]
    struct Pull {
        key: (u32, u32, u32),
        slot: u32,
        content: u32,
        file: u32,
        /// The file's name on the card; a preview is saved as `<stem>.JPG` in `previews\`.
        name: String,
        size: u64,
        preview: bool,
        /// The shutter (else when the shot showed up on the card), for the timings.
        shot: Instant,
        tries: u32,
    }

    struct Current {
        pull: Pull,
        started: Instant,
        /// Last word from the SDK about it.
        heard: Instant,
        percent: u32,
        /// Progress last reported to the app (originals, in steps of 10 %).
        told: u32,
        /// Asked to stop so a preview can overtake it (it is pulled again afterwards).
        canceling: bool,
        /// The SDK refused to stop it: let it finish.
        unstoppable: bool,
    }

    /// The file to make a shot's preview of, and the original to bring after it, for a choice:
    /// RAW goes for the raw, 8 / 14 MP for the camera's JPEG (RAW+JPEG), 2 MP for the preview alone.
    pub(crate) fn plan(files: &[ContentFile], choice: Choice) -> (Option<&ContentFile>, Option<&ContentFile>) {
        let of = |format: u32| files.iter().find(|f| f.format == format);
        let (raw, jpeg, heif) = (of(FORMAT_RAW), of(FORMAT_JPEG), of(FORMAT_HEIF));
        let preview = jpeg.or(raw).or(heif);
        let original = match (choice.mode, choice.size) {
            (Mode::Full, _) => raw.or(jpeg).or(heif),
            (Mode::Preview, Size::Mp2) => None,
            (Mode::Preview, _) => jpeg.or(heif),
        };
        (preview, original)
    }

    /// A shot's name without extension (`DSC08822`), from its file on the card.
    pub(crate) fn stem_of(name: &str, number: u32) -> String {
        match name.rsplit_once('.') {
            Some((stem, _)) if !stem.is_empty() => stem.to_string(),
            _ if !name.is_empty() => name.to_string(),
            _ => format!("DSC{number:05}"),
        }
    }

    /// Width and height of a JPEG, from its first frame header.
    pub(crate) fn jpeg_dims(b: &[u8]) -> Option<(u32, u32)> {
        if b.get(..2)? != [0xFF, 0xD8] {
            return None;
        }
        let mut i = 2;
        while i + 9 < b.len() {
            if b[i] != 0xFF {
                i += 1;
                continue;
            }
            let marker = b[i + 1];
            let len = usize::from(u16::from_be_bytes([b[i + 2], b[i + 3]]));
            if matches!(marker, 0xC0..=0xC3 | 0xC5..=0xC7 | 0xC9..=0xCB | 0xCD..=0xCF) {
                let h = u16::from_be_bytes([b[i + 5], b[i + 6]]);
                let w = u16::from_be_bytes([b[i + 7], b[i + 8]]);
                return Some((u32::from(w), u32::from(h)));
            }
            if marker == 0xD8 || marker == 0x01 || (0xD0..=0xD7).contains(&marker) {
                i += 2;
            } else {
                i += 2 + len;
            }
        }
        None
    }

    /// Remote transfer: what is on the cards, and what is being brought from them.
    struct Puller<'a> {
        api: &'a Api,
        handle: i64,
        save_dir: PathBuf,
        previews_dir: PathBuf,
        tx: &'a Out,
        link: &'a Link,
        previews: VecDeque<Pull>,
        originals: Vec<Pull>,
        current: Option<Current>,
        /// Slots the SDK could list (looked at again now and then, in case a change isn't announced).
        slots: Vec<u32>,
        /// A shot was announced in this slot but isn't in the list yet: look again until then.
        recheck: Vec<(u32, Instant)>,
        next_look: Instant,
        look_every: Duration,
        /// Don't ask for the next file before this (after a refusal).
        hold: Option<Instant>,
        connected_at: Instant,
        /// The SDK said it has (re)read the whole card.
        all_listed: bool,
        /// The first looks at a slot, before its earlier shots are taken in: how many, since when.
        first_counts: Vec<(u32, usize, Instant)>,
    }

    impl Puller<'_> {
        /// Look at the card in `slot`: shots not seen before are queued (the first time, what is
        /// there already is only taken in, once the SDK has the whole list).
        fn look(&mut self, slot: u32, card: &mut Card, choice: Choice) -> Result<bool, u32> {
            let t0 = Instant::now();
            let contents = self.api.contents(self.handle, slot)?;
            let took = t0.elapsed();
            if !self.slots.contains(&slot) {
                self.slots.push(slot);
                card.transfer_worked = true;
                log::info!("tether: card {slot}: {} items, listed in {:.2} s", contents.len(), took.as_secs_f64());
            }
            if took > Duration::from_millis(400) && self.look_every < Duration::from_secs(10) {
                // a slow list (a big card over Wi-Fi): only when the camera announces a change
                log::info!("tether: listing card {slot} took {:.2} s: looking only when the camera says so", took.as_secs_f64());
                self.look_every = Duration::from_secs(10);
            }
            if !card.listed.contains(&slot) {
                let n = contents.len();
                let stable = self.first_counts.iter().any(|(s, m, since)| {
                    *s == slot && *m == n && since.elapsed() >= Duration::from_secs(2) && self.connected_at.elapsed() >= Duration::from_secs(4)
                });
                let ready = self.all_listed || self.api.property(self.handle, DP_SLOT1_LIST_READY + slot.saturating_sub(1)) == Some(1) || stable;
                if !ready {
                    match self.first_counts.iter_mut().find(|(s, ..)| *s == slot) {
                        Some(e) if e.1 != n => *e = (slot, n, Instant::now()),
                        Some(_) => {}
                        None => self.first_counts.push((slot, n, Instant::now())),
                    }
                    return Ok(false);
                }
                for c in &contents {
                    card.seen.insert((slot, c.dir, c.number));
                }
                card.listed.insert(slot);
                log::info!("tether: card {slot}: {n} earlier shots taken in, new shots will be pulled");
                return Ok(false);
            }
            let mut new: Vec<&Content> = contents.iter().filter(|c| !card.seen.contains(&(slot, c.dir, c.number))).collect();
            if new.is_empty() {
                return Ok(false);
            }
            if new.len() > RELOAD {
                log::info!("tether: card {slot}: {} items appeared at once (the list was reloaded): not pulled", new.len());
                for c in new {
                    card.seen.insert((slot, c.dir, c.number));
                }
                return Ok(false);
            }
            let shot = self
                .link
                .captured_at
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .take()
                .filter(|t| t.elapsed() < Duration::from_secs(30))
                .unwrap_or_else(Instant::now);
            new.sort_by_key(|c| (c.dir, c.number));
            for c in new {
                card.seen.insert((slot, c.dir, c.number));
                self.queue(slot, c, choice, card, shot);
            }
            Ok(true)
        }

        fn queue(&mut self, slot: u32, c: &Content, choice: Choice, card: &Card, shot: Instant) {
            let key = (slot, c.dir, c.number);
            let (preview, original) = plan(&c.files, choice);
            let Some(source) = preview.or(original) else {
                log::info!("tether: card {slot}: {:?} isn't a photo: left on the card", c.files.iter().map(|f| f.name.as_str()).collect::<Vec<_>>());
                return;
            };
            let stem = stem_of(&source.name, c.number);
            log::info!("tether: {stem} on the card {:.2} s after the shutter", shot.elapsed().as_secs_f64());
            let pull = |f: &ContentFile, name: String, preview: bool| Pull {
                key,
                slot,
                content: c.id,
                file: f.id,
                name,
                size: f.size,
                preview,
                shot,
                tries: 0,
            };
            if let Some(p) = preview
                && !card.previewed.contains(&key)
            {
                self.previews.push_back(pull(p, format!("{stem}.JPG"), true));
            }
            if let Some(o) = original {
                let name = if o.name.is_empty() { format!("{stem}.ARW") } else { o.name.clone() };
                self.originals.push(pull(o, name, false));
            }
        }

        /// Ask for the next file: previews first (oldest first), then the newest shot's original.
        fn start_next(&mut self) {
            if self.current.is_some() || self.hold.is_some_and(|t| Instant::now() < t) {
                return;
            }
            self.hold = None;
            loop {
                let pull = match self.previews.pop_front() {
                    Some(p) => p,
                    None => {
                        self.originals.sort_by_key(|p| p.key);
                        match self.originals.pop() {
                            Some(p) => p,
                            None => return,
                        }
                    }
                };
                let dir = if pull.preview { self.previews_dir.clone() } else { self.save_dir.clone() };
                let target = dir.join(&pull.name);
                if let Ok(m) = std::fs::metadata(&target) {
                    if !pull.preview && m.len() == pull.size {
                        log::info!("tether: {} is here already", pull.name);
                        continue;
                    }
                    // an earlier preview, or a piece of a transfer that was stopped
                    let _ = std::fs::remove_file(&target);
                }
                let name = pull.preview.then_some(pull.name.as_str());
                let err = self.api.pull(self.handle, pull.slot, pull.content, pull.file, &dir, name, pull.preview);
                if err != 0 {
                    log::warn!("tether: couldn't ask for {}: {}", pull.name, describe(err));
                    self.retry(pull, err);
                    return;
                }
                let now = Instant::now();
                self.current = Some(Current { pull, started: now, heard: now, percent: 0, told: 0, canceling: false, unstoppable: false });
                return;
            }
        }

        /// Put a pull back in line (after a refusal or a failure); given up after three tries.
        fn retry(&mut self, mut p: Pull, why: u32) {
            p.tries += 1;
            if p.tries >= 3 {
                send(self.tx, Event::Warning(format!("Couldn't bring {} from the card ({}): it stays there", p.name, describe(why))));
                return;
            }
            self.hold = Some(Instant::now() + Duration::from_millis(700));
            if p.preview {
                self.previews.push_front(p);
            } else {
                self.originals.push(p);
            }
        }

        fn on_note(&mut self, note: Note, card: &mut Card, choice: Choice) {
            match note {
                Note::Changed { notify, slot, added } => {
                    log::debug!("tether: card {slot} changed (0x{notify:X}, {added} added)");
                    if notify == RT_CHANGED_CLEAR {
                        // the card was emptied or swapped: what is on it later is taken in afresh
                        card.listed.remove(&slot);
                        card.seen.retain(|k| k.0 != slot);
                        card.previewed.retain(|k| k.0 != slot);
                        self.first_counts.retain(|(s, ..)| *s != slot);
                        return;
                    }
                    if notify == RT_CHANGED_ALL {
                        self.all_listed = true;
                    }
                    match self.look(slot, card, choice) {
                        Ok(true) => {}
                        Ok(false) if added > 0 => self.recheck.push((slot, Instant::now() + Duration::from_secs(3))),
                        Ok(false) => {}
                        Err(e) => log::info!("tether: couldn't list card {slot}: {}", describe(e)),
                    }
                }
                Note::Transferred { notify, percent, path } => {
                    let Some(cur) = self.current.as_mut() else {
                        log::debug!("tether: transfer note 0x{notify:X} with nothing asked");
                        return;
                    };
                    cur.heard = Instant::now();
                    if notify == RT_IN_PROGRESS {
                        cur.percent = percent;
                        if !cur.pull.preview && percent >= cur.told + 10 && percent < 100 {
                            cur.told = percent - percent % 10;
                            send(self.tx, Event::Transfer { name: cur.pull.name.clone(), percent });
                        }
                        return;
                    }
                    let Some(cur) = self.current.take() else { return };
                    if notify == RT_OK {
                        self.finish(cur, &path, card);
                    } else if cur.canceling {
                        log::info!("tether: {} paused at {} % for a newer preview", cur.pull.name, cur.percent);
                        self.originals.push(cur.pull);
                    } else {
                        log::warn!("tether: {} didn't come: {}", cur.pull.name, describe(notify));
                        self.retry(cur.pull, notify);
                    }
                }
            }
        }

        fn finish(&mut self, cur: Current, path: &str, card: &mut Card) {
            let p = cur.pull;
            let dir = if p.preview { &self.previews_dir } else { &self.save_dir };
            let expected = dir.join(&p.name);
            let mut file = if path.is_empty() { expected.clone() } else { PathBuf::from(path) };
            if p.preview && file != expected && file.is_file() {
                // under the shot's name, so its original finds it
                let _ = std::fs::remove_file(&expected);
                if std::fs::rename(&file, &expected).is_ok() {
                    file = expected;
                }
            }
            let bytes = std::fs::metadata(&file).ok().map(|m| m.len());
            let seconds = p.shot.elapsed().as_secs_f64();
            let took = cur.started.elapsed().as_secs_f64();
            if p.preview {
                let head = std::fs::File::open(&file).ok().and_then(|f| {
                    use std::io::Read;
                    let mut b = Vec::with_capacity(65536);
                    f.take(65536).read_to_end(&mut b).ok().map(|_| b)
                });
                let Some(head) = head.filter(|h| h.starts_with(&[0xFF, 0xD8])) else {
                    log::warn!("tether: the preview of {} isn't a JPEG ({}): skipped", p.name, file.display());
                    return;
                };
                let dims = jpeg_dims(&head).map_or_else(|| "?".to_string(), |(w, h)| format!("{w}×{h}"));
                log::info!(
                    "tether: {} preview {dims}, {} KB in {took:.2} s: {seconds:.2} s after the shutter",
                    p.name,
                    bytes.unwrap_or(0) / 1024
                );
                card.previewed.insert(p.key);
            } else {
                let mb = bytes.unwrap_or(p.size) as f64 / 1_000_000.0;
                log::info!(
                    "tether: {} {mb:.1} MB in {took:.1} s ({:.1} MB/s): {seconds:.1} s after the shutter",
                    p.name,
                    if took > 0.05 { mb / took } else { 0.0 }
                );
            }
            send(self.tx, Event::Downloaded { path: file, bytes, seconds: Some(seconds), preview: p.preview });
        }

        /// A new shot's preview doesn't wait for an original on its way: that one is stopped and
        /// pulled again afterwards (unless nearly there).
        fn overtake(&mut self) {
            if self.previews.is_empty() {
                return;
            }
            let Some(cur) = self.current.as_mut() else { return };
            if cur.pull.preview || cur.canceling || cur.unstoppable || cur.percent >= 70 {
                return;
            }
            let e = self.api.cancel_pull(self.handle);
            if e == 0 {
                cur.canceling = true;
            } else {
                log::info!("tether: couldn't pause {} for a preview: {}", cur.pull.name, describe(e));
                cur.unstoppable = true;
            }
        }

        /// A transfer the SDK stopped talking about is given up and asked for again.
        fn watchdog(&mut self) {
            let Some(cur) = &self.current else { return };
            let limit = Duration::from_secs(if cur.pull.preview { 10 } else { 40 });
            if cur.heard.elapsed() < limit {
                return;
            }
            log::warn!("tether: no news of {} for {} s: asking again", cur.pull.name, limit.as_secs());
            if !cur.pull.preview {
                self.api.cancel_pull(self.handle);
            }
            if let Some(cur) = self.current.take() {
                self.retry(cur.pull, TIMED_OUT);
            }
        }
    }

    /// Remote transfer: the camera keeps the shots, LightCraft brings what it wants of each new one.
    /// `Some` when it can't work with this camera.
    #[allow(clippy::too_many_arguments)]
    fn transfer_loop(
        api: &Api,
        handle: i64,
        opts: &Options,
        stop: &AtomicBool,
        choice: &Mutex<Choice>,
        mode_changed: &Arc<AtomicBool>,
        restore: &mut Restore,
        card: &mut Card,
        link: &Link,
        notes: &Receiver<Note>,
        tx: &Out,
    ) -> Option<End> {
        let previews_dir = opts.save_dir.join("previews");
        if let Err(e) = std::fs::create_dir_all(&previews_dir) {
            send(tx, Event::Warning(format!("Couldn't create {}: {e}", previews_dir.display())));
        }
        // the camera sends nothing by itself (no live view, no post view, shots to the card only):
        // the Wi-Fi is all for what LightCraft asks for
        for (key, what) in [(SETTING_LIVE_VIEW, "live view"), (SETTING_POST_VIEW, "post view")] {
            let e = api.set_setting(handle, key, 0);
            if e != 0 {
                log::info!("tether: {what} stays as it is ({})", describe(e));
            }
        }
        let e = set(api, handle, DP_STILL_STORE_DEST, STORE_CARD, 3, stop);
        if e != 0 {
            log::info!("tether: still image destination stays as it is ({})", describe(e));
        }
        mode_changed.store(false, Ordering::SeqCst);
        let mut failing = None;
        let mut retry_at = (!apply_transfer(api, handle, choice, restore, tx, &mut failing, 3, stop)).then(|| Instant::now() + Duration::from_secs(3));
        let now = Instant::now();
        let mut p = Puller {
            api,
            handle,
            save_dir: opts.save_dir.clone(),
            previews_dir,
            tx,
            link,
            previews: VecDeque::new(),
            originals: Vec::new(),
            current: None,
            slots: Vec::new(),
            recheck: Vec::new(),
            next_look: now,
            look_every: Duration::from_secs(2),
            hold: None,
            connected_at: now,
            all_listed: false,
            first_counts: Vec::new(),
        };
        let give_up = now + Duration::from_secs(20);
        let mut last_error = 0;
        while !link.ended.load(Ordering::SeqCst) && !stop.load(Ordering::SeqCst) {
            let c = *choice.lock().unwrap_or_else(PoisonError::into_inner);
            if let Ok(n) = notes.recv_timeout(Duration::from_millis(50)) {
                p.on_note(n, card, c);
                while let Ok(n) = notes.try_recv() {
                    p.on_note(n, card, c);
                }
            }
            let due = retry_at.is_some_and(|t| Instant::now() >= t);
            if mode_changed.swap(false, Ordering::SeqCst) || due {
                let ok = apply_transfer(api, handle, choice, restore, tx, &mut failing, 2, stop);
                retry_at = (!ok).then(|| Instant::now() + Duration::from_secs(3));
                let c = *choice.lock().unwrap_or_else(PoisonError::into_inner);
                if c.mode == Mode::Preview && c.size == Size::Mp2 && !p.originals.is_empty() {
                    log::info!("tether: {} originals no longer wanted", p.originals.len());
                    p.originals.clear();
                }
            }
            let now = Instant::now();
            let mut looks: Vec<u32> = Vec::new();
            p.recheck.retain(|(slot, until)| {
                if now < *until {
                    looks.push(*slot);
                    true
                } else {
                    false
                }
            });
            if now >= p.next_look {
                p.next_look = now + p.look_every;
                looks.extend(if p.slots.is_empty() { vec![1, 2] } else { p.slots.clone() });
            }
            looks.sort_unstable();
            looks.dedup();
            for slot in looks {
                match p.look(slot, card, c) {
                    Ok(true) => p.recheck.retain(|(s, _)| *s != slot),
                    Ok(false) => {}
                    Err(e) => last_error = e,
                }
            }
            if p.slots.is_empty() && now >= give_up {
                return Some(End::NoTransfer(format!("its card can't be listed: {}", describe(last_error))));
            }
            p.overtake();
            p.watchdog();
            p.start_next();
        }
        if p.current.as_ref().is_some_and(|c| !c.pull.preview) && !link.ended.load(Ordering::SeqCst) {
            api.cancel_pull(handle);
        }
        // what didn't arrive is pulled after the next connection
        let left: Vec<(u32, u32, u32)> =
            p.current.iter().map(|c| c.pull.key).chain(p.previews.iter().map(|x| x.key)).chain(p.originals.iter().map(|x| x.key)).collect();
        for key in left {
            card.seen.remove(&key);
        }
        None
    }

    /// Set a property, retrying (1 s apart) while the camera refuses it. 0 = done.
    fn set(api: &Api, handle: i64, code: u32, value: u64, attempts: u32, stop: &AtomicBool) -> u32 {
        let mut err = 0;
        for i in 0..attempts {
            err = api.set_property(handle, code, value);
            if err == 0 || err == u32::MAX || i + 1 == attempts || nap(stop, Duration::from_secs(1)) {
                break;
            }
        }
        err
    }

    fn file_format(t: Option<u64>) -> &'static str {
        match t {
            Some(1) => "JPEG",
            Some(2) => "RAW",
            Some(3) => "RAW & JPEG",
            Some(4) => "RAW & HEIF",
            Some(5) => "HEIF",
            _ => "unknown",
        }
    }

    fn raw_type(t: Option<u64>) -> Option<&'static str> {
        match t? {
            0 => Some("uncompressed"),
            1 => Some("compressed"),
            2..=5 => Some("lossless compressed"),
            6 => Some("compressed HQ"),
            _ => None,
        }
    }

    /// The camera's JPEG at size `want` (S = 3, M = 2), or back to the size it had. 0 = done.
    fn set_jpeg_size(api: &Api, handle: i64, want: Option<u64>, restore: &mut Restore, attempts: u32, stop: &AtomicBool) -> u32 {
        match want {
            Some(v) => {
                if restore.jpeg_size.is_none() {
                    restore.jpeg_size = api.property(handle, DP_IMAGE_SIZE);
                }
                set(api, handle, DP_IMAGE_SIZE, v, attempts, stop)
            }
            None => {
                let Some(v) = restore.jpeg_size else { return 0 };
                let err = set(api, handle, DP_IMAGE_SIZE, v, attempts, stop);
                if err == 0 {
                    restore.jpeg_size = None;
                }
                err
            }
        }
    }

    /// Ask the camera to send what the choice wants. Reports Ready, or Pending once per choice;
    /// `false` = retry.
    #[allow(clippy::too_many_arguments)]
    fn apply(
        api: &Api,
        handle: i64,
        choice: &Mutex<Choice>,
        restore: &mut Restore,
        tx: &Out,
        failing: &mut Option<Choice>,
        attempts: u32,
        stop: &AtomicBool,
    ) -> bool {
        let c = *choice.lock().unwrap_or_else(PoisonError::into_inner);
        let format = api.property(handle, DP_FILE_TYPE);
        let raw_and_jpeg = matches!(format, Some(3 | 4));
        // 8 / 14 MP previews are the camera's own JPEG at size S or M: only with RAW+JPEG, where the
        // raw keeps full quality on the card; otherwise the camera's JPEG keeps (or gets back) its size
        let jpeg_size = match (c.mode, c.size) {
            (Mode::Preview, Size::Mp8) if raw_and_jpeg => Some(3),
            (Mode::Preview, Size::Mp14) if raw_and_jpeg => Some(2),
            _ => None,
        };
        let jpeg_err = set_jpeg_size(api, handle, jpeg_size, restore, attempts, stop);
        // what goes to the computer: a 2 MP JPEG (1616×1080, made by the camera even of a raw), or
        // the file as the camera saved it. The older property first (firmware 2.x: 0 original,
        // 1 small), else the newer one (1 large, 2 small)
        let small = jpeg_size.is_none() && c.mode == Mode::Preview;
        let sizes = if small { [(DP_STILL_TRANS_SIZE, 1), (DP_REMOTE_SAVE_SIZE, 2)] } else { [(DP_STILL_TRANS_SIZE, 0), (DP_REMOTE_SAVE_SIZE, 1)] };
        let mut size_err = 0;
        for (code, value) in sizes {
            size_err = set(api, handle, code, value, attempts, stop);
            if size_err == 0 {
                break;
            }
        }
        // with RAW+JPEG/HEIF, what goes to the computer: 1 the JPEG, 4 the HEIF (Preview), or 2 the
        // raw alone (Full Size: its own full-size JPEG is the instant preview, the camera's JPEG
        // would only come after it)
        let which = match (c.mode, format) {
            (Mode::Preview, Some(3)) => Some(1),
            (Mode::Preview, Some(4)) => Some(4),
            (Mode::Full, Some(3 | 4)) => Some(2),
            _ => None,
        };
        let which_err = which.map_or(0, |v| set(api, handle, DP_RAW_J_PC_SAVE, v, 2, stop));
        let err = [size_err, which_err, jpeg_err].into_iter().find(|e| *e != 0).unwrap_or(if format.is_none() { u32::MAX } else { 0 });
        let what = match c.mode {
            Mode::Preview => format!("the {} preview", c.size.label()),
            Mode::Full => "Full Size".to_string(),
        };
        if err != 0 {
            if *failing != Some(c) {
                *failing = Some(c);
                send(tx, Event::Pending { message: format!("The camera doesn't accept {what} yet ({}): retrying…", describe(err)) });
            }
            return false;
        }
        *failing = None;
        let f = file_format(format);
        let raw = raw_type(api.property(handle, DP_RAW_TYPE));
        let raw_note = |s: &str| match raw {
            Some(r) => format!("{s}, {r} raw"),
            None => s.to_string(),
        };
        let mut message = match (c.mode, format) {
            (Mode::Full, Some(1 | 5)) => {
                format!("Full Size: the camera shoots {f} only, so the computer gets the full {f}. For the raw, set File Format to RAW.")
            }
            (Mode::Full, _) => raw_note("RAW: every shot shows at full size as soon as the start of its raw lands, then the raw takes its place"),
            (Mode::Preview, Some(2)) if c.size != Size::Mp2 => format!(
                "Preview: a 2 MP JPEG the camera makes of each raw ({} needs File Format RAW & JPEG)",
                c.size.label()
            ),
            (Mode::Preview, Some(2)) => "Preview: a 2 MP JPEG the camera makes of each raw".to_string(),
            (Mode::Preview, _) if jpeg_size.is_some() => {
                format!("Preview: the computer gets the camera's {} JPEG (the raw stays full size on the card)", c.size.label())
            }
            (Mode::Preview, _) if c.size != Size::Mp2 => format!(
                "Preview: 2 MP, as the camera shoots {f} only ({} needs RAW & JPEG, so LightCraft never shrinks your only file)",
                c.size.label()
            ),
            (Mode::Preview, _) => format!("Preview: the computer gets a 2 MP JPEG (File Format {f})"),
        };
        if c.mode == Mode::Full && raw == Some("uncompressed") {
            message.push_str(". Tip: Lossless Compressed RAW is the same quality at about half the size, so it arrives about twice as fast.");
        }
        send(tx, Event::Ready { message });
        true
    }

    /// Remote transfer: the camera's JPEG size for 8 / 14 MP, and what LightCraft will bring.
    /// Reports Ready, or Pending once per choice; `false` = retry.
    #[allow(clippy::too_many_arguments)]
    fn apply_transfer(
        api: &Api,
        handle: i64,
        choice: &Mutex<Choice>,
        restore: &mut Restore,
        tx: &Out,
        failing: &mut Option<Choice>,
        attempts: u32,
        stop: &AtomicBool,
    ) -> bool {
        let c = *choice.lock().unwrap_or_else(PoisonError::into_inner);
        let format = api.property(handle, DP_FILE_TYPE);
        let raw_and_jpeg = matches!(format, Some(3 | 4));
        // 8 / 14 MP: the camera's own JPEG at size S / M, only beside a raw (never the only file)
        let jpeg_size = match (c.mode, c.size) {
            (Mode::Preview, Size::Mp8) if raw_and_jpeg => Some(3),
            (Mode::Preview, Size::Mp14) if raw_and_jpeg => Some(2),
            _ => None,
        };
        let err = set_jpeg_size(api, handle, jpeg_size, restore, attempts, stop);
        if err != 0 {
            if *failing != Some(c) {
                *failing = Some(c);
                send(tx, Event::Pending { message: format!("The camera doesn't accept the {} JPEG yet ({}): retrying…", c.size.label(), describe(err)) });
            }
            return false;
        }
        *failing = None;
        let f = file_format(format);
        let raw = raw_type(api.property(handle, DP_RAW_TYPE));
        let mut message = match (c.mode, format) {
            (Mode::Full, Some(1 | 5)) => format!("Instant: every shot shows at once, then the full {f} takes its place"),
            (Mode::Full, _) => match raw {
                Some(r) => format!("Instant: every shot shows at once, then its raw ({r}) takes its place a few seconds later"),
                None => "Instant: every shot shows at once, then its raw takes its place a few seconds later".to_string(),
            },
            (Mode::Preview, _) if c.size == Size::Mp2 => "Preview: every shot shows at once; the originals stay on the card".to_string(),
            (Mode::Preview, _) if jpeg_size.is_some() => {
                format!("Preview: every shot shows at once, then the camera's {} JPEG (the raw stays full size on the card)", c.size.label())
            }
            (Mode::Preview, Some(1 | 5)) => format!("Preview: every shot shows at once, then the camera's full {f}"),
            (Mode::Preview, _) => format!(
                "Preview: every shot shows at once; {} needs File Format RAW & JPEG on the camera (it shoots {f}), RAW brings the raw",
                c.size.label()
            ),
        };
        if c.mode == Mode::Full && raw == Some("uncompressed") {
            message.push_str(". Tip: Lossless Compressed RAW is the same quality at about half the size, so it arrives about twice as fast.");
        }
        send(tx, Event::Ready { message });
        true
    }

    pub fn find(sdk_dir: &Path) -> Result<Found, String> {
        let api = sdk::api(sdk_dir)?;
        let found = |cam: &Camera, fingerprint: Option<String>| {
            let i = cam.info();
            Found { model: i.model, ssh: i.ssh, fingerprint, ip: i.ip, mac: i.mac }
        };
        if let Some(cam) = api.enumerate() {
            let fp = if cam.info().ssh { Some(api.fingerprint(&cam).map_err(|e| format!("Couldn't read the camera's fingerprint: {}", describe(e)))?) } else { None };
            return Ok(found(&cam, fp));
        }
        let Some(mac) = mac_for(CAMERA_IP) else {
            return Err("No camera found. Connect this computer to the camera's Wi-Fi (DIRECT-…) and turn on remote shooting from the computer.".into());
        };
        let ip = parse_ip(CAMERA_IP).ok_or("bad address")?;
        // with access authentication first: a camera without it has no fingerprint to give
        if let Some(cam) = api.camera_at(MODEL_ILCE_7M4, ip, mac, true)
            && let Ok(fp) = api.fingerprint(&cam)
        {
            let mut f = found(&cam, Some(fp));
            f.ssh = true;
            return Ok(f);
        }
        let cam = api.camera_at(MODEL_ILCE_7M4, ip, mac, false).ok_or("The camera answers but the SDK can't use it")?;
        let mut f = found(&cam, None);
        f.ssh = false;
        Ok(f)
    }

    pub fn pair(sdk_dir: &Path, found: &Found, user: &str, password: &str) -> Result<Pairing, String> {
        let api = sdk::api(sdk_dir)?;
        let pairing = Pairing {
            user: user.to_string(),
            password: password.to_string(),
            fingerprint: found.fingerprint.clone().unwrap_or_default(),
            ip: found.ip.clone(),
            mac: found.mac.clone(),
        };
        let cam = locate(api, Some(&pairing), found.ssh).ok_or("The camera is no longer there: is the computer still on its Wi-Fi?")?;
        let fp = if found.ssh { Some(api.fingerprint(&cam).map_err(describe)?) } else { None };
        if let (Some(now), Some(before)) = (&fp, &found.fingerprint)
            && now != before
        {
            return Err("The camera's fingerprint changed meanwhile: search again".into());
        }
        let (tx, _rx) = std::sync::mpsc::channel();
        let (link, _notes) = Link::new(Out { tx, wake: None }, Arc::new(AtomicBool::new(false)));
        let callbacks = CallbackObject::new(link.clone());
        let mut handle = 0i64;
        let auth = fp.as_deref().map(|f| (user, password, f));
        let err = api.connect(&cam, &callbacks, &mut handle, auth, false);
        drop(cam);
        if err != 0 {
            return Err(format!("Couldn't connect: {}", describe(err)));
        }
        let deadline = Instant::now() + Duration::from_secs(30);
        while !link.connected.load(Ordering::SeqCst) && !link.ended.load(Ordering::SeqCst) && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(200));
        }
        let ok = link.connected.load(Ordering::SeqCst);
        if ok {
            api.disconnect(handle);
            let end = Instant::now() + Duration::from_secs(5);
            while !link.ended.load(Ordering::SeqCst) && Instant::now() < end {
                std::thread::sleep(Duration::from_millis(100));
            }
        }
        api.release_device(handle);
        drop(callbacks);
        if !ok {
            let e = link.last_error.load(Ordering::SeqCst);
            return Err(format!("Couldn't connect: {}", describe(if e == 0 { TIMED_OUT } else { e })));
        }
        Ok(Pairing { fingerprint: fp.unwrap_or_default(), ..pairing })
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use super::*;

    #[test]
    fn modes_round_trip() {
        for m in [Mode::Preview, Mode::Full] {
            assert_eq!(Mode::from_id(m.id()), Some(m));
        }
        assert_eq!(Mode::from_id("raw"), Some(Mode::Full));
        assert_eq!(Mode::from_id("nope"), None);
        for s in [Size::Mp2, Size::Mp8, Size::Mp14] {
            assert_eq!(Size::from_id(s.id()), Some(s));
        }
        assert_eq!(Size::from_id("10mp"), None);
    }

    #[test]
    fn macs_and_addresses_parse() {
        assert_eq!(parse_mac("dc-fe-23-e9-5d-95"), Some([0xdc, 0xfe, 0x23, 0xe9, 0x5d, 0x95]));
        assert_eq!(parse_mac("DC:FE:23:E9:5D:95"), Some([0xdc, 0xfe, 0x23, 0xe9, 0x5d, 0x95]));
        assert_eq!(parse_mac("dc-fe-23"), None);
        assert_eq!(parse_mac("zz-fe-23-e9-5d-95"), None);
        assert_eq!(parse_ip("192.168.122.1"), Some([192, 168, 122, 1]));
        assert_eq!(parse_ip("nope"), None);
    }

    #[test]
    fn errors_have_words() {
        assert!(describe(0x8216).contains("wrong user or password"));
        assert!(describe(0x1234).contains("0x1234"));
        assert_eq!(describe(u32::MAX), "the camera doesn't report this setting");
    }

    #[cfg(windows)]
    #[test]
    fn a_missing_sdk_is_an_error_event_not_a_crash() {
        let dir = std::env::temp_dir().join("lc-tether-no-sdk");
        let opts = Options {
            sdk_dir: dir.clone(),
            save_dir: dir,
            pairing: None,
            choice: Choice { mode: Mode::Preview, size: Size::Mp8 },
            wake: None,
            transfer: false,
            direct: false,
            wifi: None,
        };
        let mut t = Tether::start(opts).unwrap();
        std::thread::sleep(Duration::from_millis(300));
        let events = t.poll();
        t.stop();
        assert!(matches!(events.first(), Some(Event::Error(m)) if m.contains("not found")), "{events:?}");
    }

    #[cfg(windows)]
    #[test]
    fn each_choice_brings_the_right_files() {
        use crate::sdk::{ContentFile, FORMAT_JPEG, FORMAT_RAW};
        let file = |id: u32, name: &str, format: u32| ContentFile { id, name: name.into(), format, size: 1 };
        let raw_only = [file(1, "DSC08822.ARW", FORMAT_RAW)];
        let both = [file(1, "DSC08822.JPG", FORMAT_JPEG), file(2, "DSC08822.ARW", FORMAT_RAW)];
        let jpeg_only = [file(1, "DSC08822.JPG", FORMAT_JPEG)];
        let ids = |(p, o): (Option<&ContentFile>, Option<&ContentFile>)| (p.map(|f| f.id), o.map(|f| f.id));
        let full = Choice { mode: Mode::Full, size: Size::Mp2 };
        let small = Choice { mode: Mode::Preview, size: Size::Mp2 };
        let mid = Choice { mode: Mode::Preview, size: Size::Mp14 };
        // RAW: the preview of the shot, then the raw, whatever the camera saves beside it
        assert_eq!(ids(worker::plan(&raw_only, full)), (Some(1), Some(1)));
        assert_eq!(ids(worker::plan(&both, full)), (Some(1), Some(2)));
        assert_eq!(ids(worker::plan(&jpeg_only, full)), (Some(1), Some(1)));
        // 2 MP: the preview alone
        assert_eq!(ids(worker::plan(&both, small)), (Some(1), None));
        assert_eq!(ids(worker::plan(&raw_only, small)), (Some(1), None));
        // 14 MP: the camera's JPEG, never the raw
        assert_eq!(ids(worker::plan(&both, mid)), (Some(1), Some(1)));
        assert_eq!(ids(worker::plan(&raw_only, mid)), (Some(1), None));
        // a clip: nothing
        assert_eq!(ids(worker::plan(&[file(1, "C0001.MP4", 0xB982)], full)), (None, None));
    }

    #[cfg(windows)]
    #[test]
    fn shot_names_and_jpeg_sizes() {
        assert_eq!(worker::stem_of("DSC08822.ARW", 8822), "DSC08822");
        assert_eq!(worker::stem_of("", 8822), "DSC08822");
        // SOI, an APP0 segment, then a baseline frame header of 1616×1080
        let mut jpeg = vec![0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x04, 0x00, 0x00];
        jpeg.extend([0xFF, 0xC0, 0x00, 0x11, 0x08, 0x04, 0x38, 0x06, 0x50, 0x03, 0, 0, 0, 0, 0, 0, 0, 0]);
        assert_eq!(worker::jpeg_dims(&jpeg), Some((1616, 1080)));
        assert_eq!(worker::jpeg_dims(b"not a jpeg"), None);
    }
}
