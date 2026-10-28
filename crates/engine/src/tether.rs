//! Tethered capture (fork): the settings kept in the config folder (`tether.json`: the camera's
//! pairing, what it sends, the preset, the folder), the running [`lightcraft_tether::Tether`], and
//! what it reported. The app calls [`TetherState::poll`] every frame, imports each shot that
//! arrived ([`TetherState::take_arrived`]) into the session's album with the preset, and shows the
//! status in its Tethered Capture bar. The `tether.*` commands (`cmd::tether`) drive it.

use std::collections::HashSet;
use std::path::{Path, PathBuf};

use lightcraft_tether::{Choice, Event, Mode, Pairing, Size, Tether};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

/// What `tether.json` holds.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct TetherSettings {
    /// The paired camera's model, user, password and SSH fingerprint (access authentication), and
    /// where it was (for when the SDK's search doesn't see it).
    pub camera: String,
    pub user: String,
    pub password: String,
    pub fingerprint: String,
    pub ip: String,
    pub mac: String,
    /// `preview` (the instant preview, or the camera's JPEG) or `full` (the preview, then the raw).
    pub mode: String,
    /// The preview's size: `2mp`, `8mp` (default) or `14mp` (8 and 14 MP: the camera's JPEG, with RAW+JPEG).
    pub size: String,
    /// A preset applied to every shot as it is imported (preset id).
    pub preset: Option<String>,
    /// Where the shots are saved, one subfolder per day (default: Pictures\Tethering).
    pub folder: Option<String>,
    /// Try Sony's remote transfer first (newer firmware; not in the window: `tether.json` only).
    pub remote_transfer: bool,
    /// Use Sony's SDK only, never LightCraft's own (direct) connection.
    pub sdk_only: bool,
    /// The camera's Wi-Fi (Windows profile name), learnt when it connects: joined again when the
    /// computer's Wi-Fi drops to no network during a session.
    pub wifi: Option<String>,
}

impl TetherSettings {
    pub fn mode(&self) -> Mode {
        Mode::from_id(&self.mode).unwrap_or(Mode::Preview)
    }

    pub fn size(&self) -> Size {
        Size::from_id(&self.size).unwrap_or(Size::Mp8)
    }

    pub fn choice(&self) -> Choice {
        Choice { mode: self.mode(), size: self.size() }
    }

    pub fn paired(&self) -> bool {
        !self.user.is_empty()
    }

    fn pairing(&self) -> Option<Pairing> {
        (self.paired() || !self.mac.is_empty()).then(|| Pairing {
            user: self.user.clone(),
            password: self.password.clone(),
            fingerprint: self.fingerprint.clone(),
            ip: self.ip.clone(),
            mac: self.mac.clone(),
        })
    }
}

/// Where the tether stands, for the bar and `tether.status`.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct TetherStatus {
    /// `off`, `searching`, `connecting`, `ready`, `pending`, `error`.
    pub state: String,
    /// The camera's model while connected.
    pub camera: String,
    /// The latest thing worth saying (what the camera sends, an error…).
    pub message: String,
    /// Shots received since the tether started.
    pub received: u32,
    /// The latest shot's file name, size (MB), seconds from the shutter to the computer, and the
    /// speed that makes (MB/s).
    pub last: Option<String>,
    pub last_mb: Option<f64>,
    pub last_seconds: Option<f64>,
    pub last_rate: Option<f64>,
    /// Seconds from the shutter to the latest instant preview on the computer.
    pub last_preview_seconds: Option<f64>,
    /// The original on its way from the card (`DSC08822.ARW 40 %`).
    pub transfer: Option<String>,
}

/// The session's tethered capture.
#[derive(Default)]
pub struct TetherState {
    settings: Option<TetherSettings>,
    running: Option<Tether>,
    pub status: TetherStatus,
    /// The day's folder and album, set when the tether starts.
    pub save_dir: Option<PathBuf>,
    pub album_name: String,
    /// The album the shots go to, once it exists.
    pub album: Option<u64>,
    arrived: Vec<PathBuf>,
    /// The shots counted (file stems, lower case): a preview and its original are one shot.
    counted: HashSet<String>,
    notices: Vec<String>,
    /// Wakes the app when the camera reports something (set by the app before starting).
    pub waker: Option<lightcraft_tether::Waker>,
    /// Held while tethering: one LightCraft window at a time talks to the camera.
    lock: Option<std::fs::File>,
}

fn settings_path() -> Option<PathBuf> {
    crate::config::config_dir().map(|d| d.join("tether.json"))
}

/// `tether.lock` in the config folder, open for this window alone while it tethers: two windows
/// would take the camera from each other, and neither would get the shots.
fn take_lock() -> Result<Option<std::fs::File>, String> {
    let Some(path) = crate::config::config_dir().map(|d| d.join("tether.lock")) else { return Ok(None) };
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    let mut o = std::fs::OpenOptions::new();
    o.write(true).create(true).truncate(false);
    #[cfg(windows)]
    std::os::windows::fs::OpenOptionsExt::share_mode(&mut o, 0);
    match o.open(&path) {
        Ok(f) => Ok(Some(f)),
        // ERROR_SHARING_VIOLATION: another window holds it
        Err(e) if e.raw_os_error() == Some(32) => Err(
            "Tethered capture is already on in another LightCraft window: stop it there (or close that window) first".into(),
        ),
        Err(e) => {
            log::warn!("tether: {}: {e}", path.display());
            Ok(None)
        }
    }
}

/// The folder the Sony SDK is in: beside the executable (the SDK looks for `CrAdapter\` there).
pub fn sdk_dir() -> Result<PathBuf, String> {
    std::env::current_exe()
        .ok()
        .and_then(|p| p.parent().map(Path::to_path_buf))
        .ok_or_else(|| "tethered capture: can't tell where LightCraft is installed".to_string())
}

impl TetherState {
    /// The settings (read from `tether.json` the first time).
    pub fn settings(&mut self) -> &TetherSettings {
        self.settings.get_or_insert_with(|| {
            settings_path()
                .and_then(|p| std::fs::read_to_string(p).ok())
                .and_then(|s| serde_json::from_str(&s).ok())
                .unwrap_or_default()
        })
    }

    /// Change the settings and save them. Errors only when the file can't be written.
    pub fn update(&mut self, change: impl FnOnce(&mut TetherSettings)) -> Result<(), String> {
        self.settings();
        let Some(s) = self.settings.as_mut() else { return Ok(()) };
        change(s);
        let Some(path) = settings_path() else { return Ok(()) };
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
        }
        let text = serde_json::to_string_pretty(s).map_err(|e| e.to_string())?;
        std::fs::write(&path, text).map_err(|e| format!("{}: {e}", path.display()))
    }

    pub fn is_running(&self) -> bool {
        self.running.is_some()
    }

    /// The day's folder: `<folder or Pictures\Tethering>\YYYY-MM-DD`.
    fn day_dir(&mut self, today: &str) -> PathBuf {
        let base = self.settings().folder.clone().map(PathBuf::from).or_else(|| {
            std::env::var_os("USERPROFILE").or_else(|| std::env::var_os("HOME")).map(|h| PathBuf::from(h).join("Pictures").join("Tethering"))
        });
        base.unwrap_or_else(|| PathBuf::from("Tethering")).join(today)
    }

    /// Start looking for the camera. `today` is `YYYY-MM-DD` (the day's folder and album).
    pub fn start(&mut self, today: &str) -> Result<(), String> {
        if self.running.is_some() {
            return Ok(());
        }
        let lock = take_lock()?;
        let save_dir = self.day_dir(today);
        let s = self.settings().clone();
        let tether = Tether::start(lightcraft_tether::Options {
            sdk_dir: sdk_dir()?,
            save_dir: save_dir.clone(),
            pairing: s.pairing(),
            choice: s.choice(),
            wake: self.waker.clone(),
            transfer: s.remote_transfer,
            direct: !s.sdk_only,
            wifi: s.wifi.clone(),
        })?;
        self.running = Some(tether);
        self.lock = lock;
        self.save_dir = Some(save_dir);
        let name = format!("Tethering {today}");
        if name != self.album_name {
            self.album = None;
        }
        self.album_name = name;
        self.counted.clear();
        self.status = TetherStatus { state: "searching".into(), message: "Looking for the camera…".into(), ..Default::default() };
        Ok(())
    }

    pub fn stop(&mut self) {
        if let Some(mut t) = self.running.take() {
            t.stop();
        }
        self.lock = None;
        self.status.state = "off".into();
        self.status.camera.clear();
        self.status.message.clear();
    }

    /// Switch what the camera sends (saved for next time; applied at once when connected).
    pub fn set_choice(&mut self, mode: Option<Mode>, size: Option<Size>) -> Result<(), String> {
        self.update(|s| {
            if let Some(m) = mode {
                s.mode = m.id().to_string();
            }
            if let Some(z) = size {
                s.size = z.id().to_string();
            }
        })?;
        let choice = self.settings().choice();
        log::info!("tether: send {} (preview size {})", choice.mode.label(), choice.size.label());
        if let Some(t) = &self.running {
            t.set_choice(choice);
        }
        Ok(())
    }

    /// Take in what the tether reported (call every frame).
    pub fn poll(&mut self) {
        let Some(t) = &self.running else { return };
        let mut network = None;
        for e in t.poll() {
            // in the log too: during a session the computer is on the camera's Wi-Fi, without internet,
            // and the bar's messages are gone afterwards
            match &e {
                Event::Downloaded { path, bytes, seconds, preview } => {
                    let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
                    let mb = bytes.map(|b| b as f64 / 1_000_000.0);
                    let what = if *preview { "preview" } else { "file" };
                    match (mb, seconds) {
                        (Some(mb), Some(s)) if *s > 0.05 => log::info!("tether: {what} {name} {mb:.2} MB, {s:.2} s after the shutter"),
                        (Some(mb), _) => log::info!("tether: {what} {name} {mb:.2} MB"),
                        _ => log::info!("tether: {what} {name}"),
                    }
                }
                Event::Transfer { .. } | Event::Network { .. } => {}
                Event::Pending { message } | Event::Warning(message) | Event::Disconnected(message) | Event::Error(message) => {
                    log::warn!("tether: {message}")
                }
                Event::Ready { message } | Event::Info(message) => log::info!("tether: {message}"),
                Event::Connected { model } => log::info!("tether: {model} connected"),
                Event::Searching => log::info!("tether: looking for the camera"),
            }
            let st = &mut self.status;
            match e {
                Event::Searching => {
                    st.state = "searching".into();
                    st.camera.clear();
                    st.message = "Looking for the camera: connect this computer to the camera's Wi-Fi and turn on remote shooting".into();
                }
                Event::Connected { model } => {
                    st.state = "connecting".into();
                    st.message = format!("{model} connected");
                    st.camera = model;
                }
                Event::Ready { message } => {
                    st.state = "ready".into();
                    st.message = message;
                }
                Event::Pending { message } => {
                    st.state = "pending".into();
                    st.message = message;
                }
                Event::Downloaded { path, bytes, seconds, preview } => {
                    let stem = path.file_stem().map(|s| s.to_string_lossy().to_lowercase()).unwrap_or_default();
                    if self.counted.insert(stem) {
                        st.received = st.received.saturating_add(1);
                    }
                    if preview {
                        st.last_preview_seconds = seconds;
                    } else {
                        st.last = path.file_name().map(|n| n.to_string_lossy().into_owned());
                        st.last_mb = bytes.map(|b| b as f64 / 1_000_000.0);
                        st.last_seconds = seconds;
                        st.last_rate = match (st.last_mb, seconds) {
                            (Some(mb), Some(s)) if s > 0.05 => Some(mb / s),
                            _ => None,
                        };
                        st.transfer = None;
                    }
                    self.arrived.push(path);
                }
                Event::Transfer { name, percent } => st.transfer = Some(format!("{name} {percent} %")),
                Event::Network { profile } => network = Some(profile),
                Event::Info(m) => st.message = m,
                Event::Warning(m) => {
                    st.message = m.clone();
                    self.notices.push(m);
                }
                Event::Disconnected(m) => {
                    st.state = "searching".into();
                    st.camera.clear();
                    st.message = format!("Camera disconnected ({m}): looking for it again");
                    self.notices.push(st.message.clone());
                }
                Event::Error(m) => {
                    st.state = "error".into();
                    if st.message != m {
                        self.notices.push(m.clone());
                    }
                    st.message = m;
                }
            }
        }
        // the camera's Wi-Fi, remembered for the next sessions too
        if let Some(p) = network
            && self.settings().wifi.as_deref() != Some(p.as_str())
            && let Err(e) = self.update(|s| s.wifi = Some(p))
        {
            log::warn!("tether: couldn't save the camera's Wi-Fi: {e}");
        }
    }

    /// A shot as if the camera had sent it (tests and agents: `tether.simulateShot`).
    pub fn simulate_arrival(&mut self, path: PathBuf) {
        let stem = path.file_stem().map(|s| s.to_string_lossy().to_lowercase()).unwrap_or_default();
        if self.counted.insert(stem) {
            self.status.received = self.status.received.saturating_add(1);
        }
        self.status.last = path.file_name().map(|n| n.to_string_lossy().into_owned());
        self.status.last_mb = std::fs::metadata(&path).ok().map(|m| m.len() as f64 / 1_000_000.0);
        self.status.last_seconds = None;
        self.status.last_rate = None;
        self.arrived.push(path);
    }

    /// The shots that arrived since the last call (to import).
    pub fn take_arrived(&mut self) -> Vec<PathBuf> {
        std::mem::take(&mut self.arrived)
    }

    /// Messages to show once (warnings, errors).
    pub fn take_notices(&mut self) -> Vec<String> {
        std::mem::take(&mut self.notices)
    }

    /// `library.import` params (without `paths`) for the shots: in place, the preset, the album.
    pub fn import_params(&mut self) -> Value {
        let preset = self.settings().preset.clone();
        let mut p = json!({"mode": "add"});
        if let Some(id) = preset.filter(|id| !id.is_empty()) {
            p["preset"] = json!(id);
        }
        match self.album {
            Some(id) => p["album"] = json!(id),
            None if !self.album_name.is_empty() => p["albumName"] = json!(self.album_name),
            None => {}
        }
        p
    }

    /// `tether.status`: the status plus the settings (without the password).
    pub fn to_json(&mut self) -> Value {
        let s = self.settings().clone();
        json!({
            "running": self.running.is_some(),
            "state": if self.running.is_some() { self.status.state.as_str() } else { "off" },
            "camera": self.status.camera,
            "message": self.status.message,
            "received": self.status.received,
            "last": self.status.last,
            "lastMB": self.status.last_mb,
            "lastSeconds": self.status.last_seconds,
            "lastRate": self.status.last_rate,
            "lastPreviewSeconds": self.status.last_preview_seconds,
            "transfer": self.status.transfer,
            "folder": self.save_dir.as_ref().map(|p| p.to_string_lossy().into_owned()),
            "album": self.album_name,
            "mode": s.mode().id(),
            "size": s.size().id(),
            "preset": s.preset,
            "paired": s.paired(),
            "direct": !s.sdk_only,
            "pairedCamera": s.camera,
        })
    }
}
