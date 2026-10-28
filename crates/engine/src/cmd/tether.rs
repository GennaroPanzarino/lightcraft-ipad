//! `tether.*` (fork): tethered capture from a Sony camera over its own Wi-Fi. The state and the
//! settings are [`crate::tether`]; the app imports the shots and shows the Tethered Capture bar.

use serde_json::{Value, json};

use super::{CommandSpec, always, bad, cmd, str_param};
use crate::{Result, Session};

fn running(s: &Session) -> std::result::Result<(), String> {
    if s.tether.is_running() { Ok(()) } else { Err("tethered capture is not running".into()) }
}

fn stopped(s: &Session) -> std::result::Result<(), String> {
    if s.tether.is_running() { Err("tethered capture is already running".into()) } else { Ok(()) }
}

/// Today as `YYYY-MM-DD` (the day's folder and album).
fn today() -> String {
    let now = crate::import::system_clock();
    now.get(..10).unwrap_or("today").to_string()
}

fn start(s: &mut Session, _: &Value) -> Result<Value> {
    s.tether.start(&today()).map_err(|e| bad("tether.start", e))?;
    Ok(s.tether.to_json())
}

fn stop(s: &mut Session, _: &Value) -> Result<Value> {
    s.tether.stop();
    Ok(s.tether.to_json())
}

fn status(s: &mut Session, _: &Value) -> Result<Value> {
    Ok(s.tether.to_json())
}

fn mode(s: &mut Session, p: &Value) -> Result<Value> {
    let m = match str_param(p, "mode") {
        None => None,
        Some(id) => Some(lightcraft_tether::Mode::from_id(id).ok_or_else(|| bad("tether.mode", "`mode` must be preview or full"))?),
    };
    let size = match str_param(p, "size") {
        None => None,
        Some(id) => Some(lightcraft_tether::Size::from_id(id).ok_or_else(|| bad("tether.mode", "`size` must be 2mp, 8mp or 14mp"))?),
    };
    if m.is_none() && size.is_none() {
        return Err(bad("tether.mode", "give `mode` and/or `size`"));
    }
    s.tether.set_choice(m, size).map_err(|e| bad("tether.mode", e))?;
    Ok(s.tether.to_json())
}

fn settings(s: &mut Session, p: &Value) -> Result<Value> {
    let preset = match p.get("preset") {
        None => None,
        Some(Value::Null) => Some(None),
        Some(Value::String(id)) if id.is_empty() => Some(None),
        Some(Value::String(id)) => Some(Some(id.clone())),
        Some(_) => return Err(bad("tether.settings", "`preset` must be a preset id or null")),
    };
    let folder = match p.get("folder") {
        None => None,
        Some(Value::Null) => Some(None),
        Some(Value::String(f)) if f.is_empty() => Some(None),
        Some(Value::String(f)) => Some(Some(f.clone())),
        Some(_) => return Err(bad("tether.settings", "`folder` must be a path or null")),
    };
    let direct = match p.get("direct") {
        None => None,
        Some(Value::Bool(b)) => Some(*b),
        Some(_) => return Err(bad("tether.settings", "`direct` must be true or false")),
    };
    s.tether
        .update(|t| {
            if let Some(v) = preset {
                t.preset = v;
            }
            if let Some(v) = folder {
                t.folder = v;
            }
            if let Some(v) = direct {
                t.sdk_only = !v;
            }
        })
        .map_err(|e| bad("tether.settings", e))?;
    Ok(s.tether.to_json())
}

fn pairing(s: &mut Session, p: &Value) -> Result<Value> {
    let forget = p.get("forget").and_then(Value::as_bool).unwrap_or(false);
    let text = |k: &str| str_param(p, k).unwrap_or_default().to_string();
    let (camera, user, password, fingerprint, ip, mac) = (text("camera"), text("user"), text("password"), text("fingerprint"), text("ip"), text("mac"));
    if !forget && camera.is_empty() {
        return Err(bad("tether.pairing", "`camera` is required (or `forget: true`)"));
    }
    s.tether
        .update(|t| {
            t.camera = camera;
            t.user = user;
            t.password = password;
            t.fingerprint = fingerprint;
            t.ip = ip;
            t.mac = mac;
        })
        .map_err(|e| bad("tether.pairing", e))?;
    Ok(json!({"paired": !forget}))
}

fn simulate(s: &mut Session, p: &Value) -> Result<Value> {
    let path = str_param(p, "path").ok_or_else(|| bad("tether.simulateShot", "missing `path`"))?;
    if !std::path::Path::new(path).is_file() {
        return Err(bad("tether.simulateShot", format!("`{path}` is not a file")));
    }
    s.tether.simulate_arrival(path.into());
    Ok(s.tether.to_json())
}

pub fn specs() -> Vec<CommandSpec> {
    vec![
        cmd!(
            query "tether.start",
            "Start Tethered Capture",
            ["File", "Tethered Capture"],
            None,
            "{} — look for the Sony camera on its own Wi-Fi (remote shooting on) and import every shot it sends into the album Tethering YYYY-MM-DD, with the tether preset → tether.status",
            stopped,
            start
        ),
        cmd!(query "tether.stop", "Stop Tethered Capture", ["File", "Tethered Capture"], None, "{} → tether.status", running, stop),
        cmd!(
            query "tether.status",
            "Tethered Capture Status",
            [],
            None,
            "{} → {running, state: off|searching|connecting|ready|pending|error, camera, message, received, last, lastMB, lastSeconds, lastRate (MB/s), folder, album, mode, size, preset, paired, pairedCamera}",
            always,
            status
        ),
        cmd!(
            query "tether.mode",
            "Tethered Capture Mode",
            [],
            None,
            "{mode?: preview|full, size?: 2mp|8mp|14mp} — what the camera sends: a preview JPEG (2 MP; 8 or 14 MP = the camera's JPEG at size S or M, with RAW+JPEG only) a second or two after the shot, or the full file (the raw when shooting RAW+JPEG) in about ten seconds; saved for next time → tether.status",
            always,
            mode
        ),
        cmd!(
            query "tether.settings",
            "Tethered Capture Settings",
            [],
            None,
            "{preset?: presetId | null (applied to every shot as it is imported), folder?: path | null (where shots are saved, a subfolder per day; null = Pictures\\Tethering), direct?: bool (LightCraft's own connection: a raw shows from its first 2 MB; false = Sony's SDK; from the next start)} → tether.status",
            always,
            settings
        ),
        cmd!(
            query "tether.pairing",
            "Save Camera Pairing",
            [],
            None,
            "{camera, user, password, fingerprint, ip?, mac?} — the camera's access authentication, checked by the pairing dialog | {forget: true} → {paired}",
            always,
            pairing
        ),
        cmd!(
            query "tether.simulateShot",
            "Simulate Tethered Shot",
            [],
            None,
            "{path} — while tethered capture runs, treat this file as a shot the camera just sent (tests without a camera) → tether.status",
            running,
            simulate
        ),
    ]
}
