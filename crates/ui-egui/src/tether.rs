//! Tethered capture (fork): the Tethered Capture strip under the top bar while a Sony camera is linked
//! (camera and state, Preview / Full Size, the preset, the shots so far, Settings, Stop), the
//! Tethered Capture window (pairing with the camera, what it sends, the preset, the folder), and the
//! per-frame work: take in what the camera reported, import each shot into the day's album with the
//! preset, and show it large. State and settings are the engine's (`lightcraft_engine::tether`,
//! the `tether.*` commands).

use std::collections::HashMap;
use std::path::Path;
use std::sync::mpsc::{Receiver, TryRecvError, channel};

use egui::{Align2, Color32, Id, Margin, RichText, Stroke};
use lightcraft_tether::{Choice, Found, Mode, Pairing, Size};
use serde_json::{Value, json};

use crate::LightcraftApp;
use crate::i18n::tr;
use crate::theme::Tokens;

/// The Tethered Capture window's state (not saved).
#[derive(Default)]
pub struct TetherUi {
    /// The window is open (File ▸ Tethered Capture ▸ Tethered Capture Settings…, or the bar).
    pub open: bool,
    /// A search for the camera in progress.
    search: Option<Receiver<Result<Found, String>>>,
    /// What the search found.
    found: Option<Found>,
    /// A pairing (test connection) in progress.
    pairing: Option<Receiver<Result<Pairing, String>>>,
    user: String,
    password: String,
    /// The fingerprint shown matches the camera's screen.
    matches: bool,
    /// The last outcome of a search or pairing: (is an error, text).
    message: Option<(bool, String)>,
    /// Each shot of the session in the library: file stem (`dsc08745`) → its photo and how complete
    /// that file is ([`rank`]); a more complete file of the shot takes the photo's place.
    shown: HashMap<String, (u64, u8)>,
    /// The photo on show when the running tethered import started (the import selects what it adds).
    active_at_import: Option<u64>,
    /// What the loupe keeps showing while a tethered shot it has just switched to has no picture
    /// of its own yet (see [`StandIn`]).
    pub(crate) stand_in: Option<StandIn>,
    /// Each tethered photo's file stem, kept after a fuller file of its shot replaced it.
    stems: HashMap<u64, String>,
}

/// The loupe switched to `new` while `old`'s render was on screen: until `new` is rendered, the
/// loupe's last render stays up instead of a blank frame or a thumbnail. When that render is of the
/// same shot (its preview before its raw: same file stem) it goes before any quick stand-in of
/// `new` too, so the switch doesn't show.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct StandIn {
    /// The photo switched to, or [`ANY`] while the import that adds it runs.
    pub new: u64,
    /// The photo whose render was on screen then.
    pub old: u64,
}

/// [`StandIn::new`] before the import has said which photo it added: whichever photo but `old`.
pub(crate) const ANY: u64 = 0;

impl StandIn {
    /// Whether it stands in for photo `id`.
    pub(crate) fn covers(&self, id: u64) -> bool {
        self.new == id || (self.new == ANY && id != self.old)
    }
}

const OK_GREEN: Color32 = Color32::from_rgb(0x3c, 0xb3, 0x71);

/// Take in what the camera reported and import the shots that arrived (called every frame).
pub fn tick(app: &mut LightcraftApp, ctx: &egui::Context) {
    poll_jobs(app, ctx);
    if app.session.tether.waker.is_none() {
        // the camera's thread wakes the window as soon as a shot lands, instead of the next frame
        let ctx = ctx.clone();
        app.session.tether.waker = Some(lightcraft_tether::Waker(std::sync::Arc::new(move || ctx.request_repaint())));
    }
    if !app.session.tether.is_running() {
        return;
    }
    app.session.tether.poll();
    for n in app.session.tether.take_notices() {
        app.toast_for(ctx, n, 6.0);
    }
    // one import at a time: shots that arrive meanwhile wait for the next one
    if app.import.is_none() {
        let arrived = app.session.tether.take_arrived();
        if !arrived.is_empty() {
            let paths = arrived.iter().map(|p| p.to_string_lossy().into_owned()).collect();
            let params = app.session.tether.import_params();
            let undo0 = app.session.undo.len();
            app.tether_ui.active_at_import = app.session.active().map(|p| p.0);
            // the import selects what it adds as it goes: from the first frame on, what is on screen
            // stands in for it
            start_stand_in(app, ANY);
            app.import = Some(crate::import::ImportTask::new(paths, params, undo0, false).tethered());
        }
    }
    ctx.request_repaint_after(std::time::Duration::from_millis(250));
}

const RAW_EXTENSIONS: [&str; 2] = ["arw", "dng"];

/// A library photo's file: its stem (lower case) and whether it is a raw.
fn shot_of(app: &LightcraftApp, id: u64) -> Option<(String, bool, String)> {
    let photo = app.session.catalog.photo(lightcraft_catalog::PhotoId(id))?;
    let path = lightcraft_engine::cmd::missing::checked_path(photo)?.to_string();
    let p = Path::new(&path);
    let stem = p.file_stem()?.to_string_lossy().to_lowercase();
    let raw = p.extension().is_some_and(|e| RAW_EXTENSIONS.contains(&e.to_string_lossy().to_lowercase().as_str()));
    Some((stem, raw, path))
}

/// Whether a file is an instant preview pulled from the card (they are saved in `previews\`).
fn in_previews(path: &str) -> bool {
    Path::new(path).parent().and_then(Path::file_name).is_some_and(|n| n.eq_ignore_ascii_case("previews"))
}

/// The render on screen stands in for `new` (or [`ANY`] photo the import adds) until it has its own.
fn start_stand_in(app: &mut LightcraftApp, new: u64) {
    // what is on screen is the loupe's render, whichever photo (and however the loupe got there)
    let old = app.renderer.textures.get(&crate::render::Slot::Main).map(|t| t.photo.0);
    app.tether_ui.stand_in = old.filter(|old| *old != new).map(|old| StandIn { new, old });
}

/// A tethered photo's file stem (also once it left the library for a fuller file of its shot).
fn stem_of(app: &LightcraftApp, id: u64) -> Option<String> {
    app.tether_ui.stems.get(&id).cloned().or_else(|| shot_of(app, id).map(|s| s.0))
}

/// What the loupe shows for tethered photo `id` while it has no picture of its own: the render that
/// was on screen, and whether that is the same shot (then it goes before `id`'s quick stand-ins).
pub(crate) fn stand_in_for(app: &LightcraftApp, id: u64) -> Option<(&crate::render::Tex, bool)> {
    app.tether_ui.stand_in.filter(|s| s.covers(id))?;
    // the loupe's last render, whichever photo it is of (a raw that landed meanwhile included)
    let tex = app.renderer.textures.get(&crate::render::Slot::Main).filter(|t| t.photo.0 != id)?;
    let same = stem_of(app, tex.photo.0).is_some_and(|stem| stem_of(app, id).is_some_and(|s| s == stem));
    Some((tex, same))
}

/// How complete a shot's file is: 0 the instant preview, 1 the camera's JPEG, 2 the raw.
fn rank(path: &str, raw: bool) -> u8 {
    if raw {
        2
    } else if in_previews(path) {
        0
    } else {
        1
    }
}

/// A preview a fuller file has replaced: out of the library (the file stays, in `previews\` beside
/// the shots so the day's folder holds the camera's files only).
fn retire_preview(app: &mut LightcraftApp, id: u64) {
    let file = shot_of(app, id).map(|(_, _, path)| path);
    if let Err(e) = app.run("photo.deletePermanently", json!({"ids": [id]})) {
        log::warn!("tether: couldn't take the preview out of the library: {e}");
        return;
    }
    if let Some(path) = file.filter(|p| !in_previews(p)) {
        let p = Path::new(&path);
        if let (Some(dir), Some(name)) = (p.parent(), p.file_name()) {
            let aside = dir.join("previews");
            if std::fs::create_dir_all(&aside).is_ok() {
                let _ = std::fs::rename(p, aside.join(name));
            }
        }
    }
}

/// The fuller file takes the preview's place: its rating, flag and colour label, then the preview leaves.
fn replace_preview(app: &mut LightcraftApp, preview: u64, raw: u64) {
    if let Some(p) = app.session.catalog.photo(lightcraft_catalog::PhotoId(preview)) {
        let (rating, flag, label) = (p.rating, p.flag, p.label);
        if rating > 0 {
            let _ = app.run("photo.rate", json!({"rating": rating, "ids": [raw]}));
        }
        let flag = match flag {
            lightcraft_catalog::Flag::Pick => Some("pick"),
            lightcraft_catalog::Flag::Reject => Some("reject"),
            lightcraft_catalog::Flag::None => None,
        };
        if let Some(f) = flag {
            let _ = app.run("photo.flag", json!({"flag": f, "ids": [raw]}));
        }
        if let Some(l) = label {
            let name = format!("{l:?}").to_lowercase();
            let _ = app.run("photo.label", json!({"label": name, "ids": [raw]}));
        }
    }
    retire_preview(app, preview);
}

/// After a tethered import (`ids` = the photos it added, in order): a fuller file of a shot (the
/// raw after its instant preview) takes the preview's place, staying on screen if the preview was,
/// and the newest new shot is shown large in the day's album.
pub fn imported(app: &mut LightcraftApp, ids: &[u64], album: Option<u64>) {
    let active_before = app.tether_ui.active_at_import.take().or_else(|| app.session.active().map(|p| p.0));
    let mut newest: Option<u64> = None;
    let mut follow: Option<u64> = None;
    for &id in ids {
        let Some((stem, raw, path)) = shot_of(app, id) else { continue };
        app.tether_ui.stems.insert(id, stem.clone());
        let r = rank(&path, raw);
        match app.tether_ui.shown.get(&stem).copied() {
            Some((before, was)) if was < r => {
                if active_before == Some(before) {
                    follow = Some(id);
                }
                replace_preview(app, before, id);
                app.tether_ui.shown.insert(stem.clone(), (id, r));
                log::info!("tether: {stem} {} replaced its preview", if raw { "raw" } else { "JPEG" });
            }
            Some((_, was)) if was > r || (r == 0 && was == 0) => {
                // a fuller file (or this very preview) came first: not needed
                retire_preview(app, id);
            }
            _ => {
                app.tether_ui.shown.insert(stem, (id, r));
                newest = Some(id);
            }
        }
    }
    let Some(show) = newest.or(follow) else {
        // only previews that weren't needed: the photo on show stays
        app.tether_ui.stand_in = None;
        if let Some(a) = active_before
            && app.session.active().map(|p| p.0) != Some(a)
            && app.session.catalog.photo(lightcraft_catalog::PhotoId(a)).is_some()
        {
            let _ = app.run("library.select", json!({"ids": [a], "active": a}));
        }
        return;
    };
    if !app.session.visible().contains(&lightcraft_catalog::PhotoId(show)) {
        let source = match album {
            Some(a) => json!({"kind": "album", "id": a}),
            None => json!({"kind": "all"}),
        };
        let _ = app.run("library.source", source);
    }
    // what is on screen stays there until the new photo has a picture
    start_stand_in(app, show);
    let _ = app.run("library.select", json!({"ids": [show], "active": show}));
    let _ = app.run("view.detail", json!({}));
}

/// Finish the window's background jobs (search, pairing).
fn poll_jobs(app: &mut LightcraftApp, ctx: &egui::Context) {
    let w = &mut app.tether_ui;
    if let Some(rx) = &w.search {
        match rx.try_recv() {
            Ok(r) => {
                w.search = None;
                w.matches = false;
                match r {
                    Ok(f) => {
                        w.message = None;
                        w.found = Some(f);
                    }
                    Err(e) => {
                        w.found = None;
                        w.message = Some((true, e));
                    }
                }
            }
            Err(TryRecvError::Empty) => ctx.request_repaint_after(std::time::Duration::from_millis(200)),
            Err(TryRecvError::Disconnected) => w.search = None,
        }
    }
    if let Some(rx) = &w.pairing {
        match rx.try_recv() {
            Ok(r) => {
                w.pairing = None;
                match r {
                    Ok(p) => {
                        let camera = w.found.as_ref().map(|f| f.model.clone()).unwrap_or_default();
                        let params = json!({
                            "camera": camera, "user": p.user, "password": p.password,
                            "fingerprint": p.fingerprint, "ip": p.ip, "mac": p.mac,
                        });
                        let saved = app.run("tether.pairing", params);
                        let w = &mut app.tether_ui;
                        w.message = Some(match saved {
                            Ok(_) => (false, format!("Paired with {camera}. Start Tethered Capture whenever you like.", camera = camera)),
                            Err(e) => (true, e),
                        });
                        w.password.clear();
                    }
                    Err(e) => w.message = Some((true, e)),
                }
            }
            Err(TryRecvError::Empty) => ctx.request_repaint_after(std::time::Duration::from_millis(200)),
            Err(TryRecvError::Disconnected) => w.pairing = None,
        }
    }
}

/// Run `work` on a worker thread; its result arrives on the returned channel.
fn background<T: Send + 'static>(ctx: &egui::Context, work: impl FnOnce() -> T + Send + 'static) -> Option<Receiver<T>> {
    let (tx, rx) = channel();
    let ctx = ctx.clone();
    let spawned = std::thread::Builder::new().name("lc-tether-pair".into()).spawn(move || {
        let _ = tx.send(work());
        ctx.request_repaint();
    });
    spawned.ok().map(|_| rx)
}

/// The Tethered Capture window (called every frame, after the panels; the strip is [`strip`]).
pub fn show(app: &mut LightcraftApp, ctx: &egui::Context) {
    window(app, ctx);
}

fn preset_name(app: &LightcraftApp, id: Option<&str>) -> String {
    id.and_then(|id| app.session.presets.iter().find(|p| p.id == id))
        .map(|p| crate::i18n::builtin_label(&p.name, p.builtin).to_string())
        .unwrap_or_else(|| tr("No preset").to_string())
}

/// Preset menu entries: `Some(Some(id))` = that preset, `Some(None)` = none.
fn preset_combo(app: &LightcraftApp, ui: &mut egui::Ui, salt: &str, current: Option<&str>) -> Option<Option<String>> {
    let mut chosen = None;
    crate::widgets::combo_box(salt).selected_text(preset_name(app, current)).height(300.0).show_ui(ui, |ui| {
        if ui.selectable_label(current.is_none(), tr("No preset")).clicked() {
            chosen = Some(None);
        }
        if let Some(pid) = crate::panels::presets::picker_rows(ui, salt, &app.session.presets, current) {
            chosen = Some(Some(pid));
        }
    });
    chosen
}

/// What the camera can send, as the bar's buttons and the window's choices: (button, mode, preview
/// size, explanation).
fn sends() -> [(&'static str, Mode, Size, &'static str); 4] {
    [
        ("2 MP", Mode::Preview, Size::Mp2, "Preview: a 2 MP JPEG of every shot, about half a second after it (also with RAW only)"),
        ("8 MP", Mode::Preview, Size::Mp8, "Preview: the camera's 8 MP JPEG (size S), about a second after the shot; needs RAW & JPEG"),
        ("14 MP", Mode::Preview, Size::Mp14, "Preview: the camera's 14 MP JPEG (size M), about a second after the shot; needs RAW & JPEG"),
        (
            "RAW",
            Mode::Full,
            Size::Mp8,
            "RAW: every shot shows at full size as soon as the start of its raw lands (the camera's JPEG inside the raw), then the raw takes its place a few seconds later",
        ),
    ]
}

fn is_current(choice: Choice, mode: Mode, size: Size) -> bool {
    choice.mode == mode && (mode == Mode::Full || choice.size == size)
}

/// `tether.mode` params for a choice (the preview's size is kept when switching to RAW).
fn mode_params(mode: Mode, size: Size) -> Value {
    match mode {
        Mode::Full => json!({"mode": "full"}),
        Mode::Preview => json!({"mode": "preview", "size": size.id()}),
    }
}

/// The new preset at once on the photo on show, when it is a shot of this tethered session: it
/// replaces the earlier preset when the photo has no edits of its own (only presets in its history),
/// else goes on top of the edits. "No preset" takes the preset off an unedited shot.
fn apply_preset_now(app: &mut LightcraftApp, preset: Option<&str>) -> Result<(), String> {
    let Some(pid) = app.session.active() else { return Ok(()) };
    let Some(day) = app.session.tether.save_dir.clone() else { return Ok(()) };
    let base = day.parent().map(std::path::Path::to_path_buf).unwrap_or(day);
    let tethered = app
        .session
        .catalog
        .photo(pid)
        .and_then(|p| lightcraft_engine::cmd::missing::checked_path(p))
        .is_some_and(|p| std::path::Path::new(p).starts_with(&base));
    if !tethered {
        return Ok(());
    }
    let history: Vec<String> = app
        .run("history.list", json!({"id": pid.0}))?
        .get("history")
        .and_then(Value::as_array)
        .map(|a| a.iter().filter_map(|v| v.as_str().map(str::to_string)).collect())
        .unwrap_or_default();
    let untouched = history.iter().all(|h| h.starts_with("Preset: ") || h == "Reset");
    let had_preset = history.iter().any(|h| h.starts_with("Preset: "));
    if untouched && had_preset {
        app.run("develop.reset", json!({"ids": [pid.0]}))?;
    }
    if let Some(id) = preset {
        app.run("preset.apply", json!({"id": id, "ids": [pid.0]}))?;
    }
    Ok(())
}

/// While tethering: a thin strip the width of the window under the top bar (it takes its own room,
/// the photo isn't covered): the camera and its state, what it sends, the preset, the shots so far,
/// Settings and Stop. Called with the top panels, before the central area.
pub fn strip(app: &mut LightcraftApp, ui: &mut egui::Ui) {
    if !app.session.tether.is_running() {
        return;
    }
    let ctx = ui.ctx().clone();
    let t = Tokens::get(&ctx);
    let st = app.session.tether.status.clone();
    let current = app.session.tether.settings().choice();
    let preset = app.session.tether.settings().preset.clone();
    // ready: the camera's name; otherwise what is going on (searching, an error…) in its place
    let (dot, title, note) = match st.state.as_str() {
        "ready" => (OK_GREEN, st.camera.clone(), None),
        "connecting" => (t.caution, st.camera.clone(), None),
        "pending" => (t.caution, st.camera.clone(), Some(st.message.clone())),
        "error" => (t.reject, tr("Tethered Capture").to_string(), Some(st.message.clone())),
        _ => (t.text_dim, tr("Looking for the camera…").to_string(), None),
    };
    let mut action: Option<(&str, Value)> = None;
    let mut new_preset: Option<Option<String>> = None;
    let mut open_settings = false;
    egui::Panel::top("tether-strip")
        .exact_size(30.0)
        .frame(egui::Frame::NONE.fill(t.chrome).inner_margin(Margin::symmetric(12, 0)))
        .show(ui, |ui| {
            let full = ui.max_rect();
            ui.painter().hline(full.x_range(), full.bottom() - 0.5, Stroke::new(1.0, t.divider));
            crate::widgets::register(ui.ctx(), "panel:tetherStrip", full);
            ui.horizontal_centered(|ui| {
                ui.spacing_mut().item_spacing.x = 6.0;
                let (r, _) = ui.allocate_exact_size(egui::vec2(10.0, 10.0), egui::Sense::hover());
                ui.painter().circle_filled(r.center(), 4.5, dot);
                ui.label(RichText::new(title).font(t.semibold(12.5)).color(t.text));
                if let Some(n) = note.filter(|n| !n.is_empty()) {
                    // one line: as much as fits, all of it on hover
                    let r = ui.add(egui::Label::new(RichText::new(&n).size(11.5).color(t.text_dim)).truncate());
                    r.on_hover_text(n);
                }
                ui.separator();
                for (label, m, size, help) in sends() {
                    let on = is_current(current, m, size);
                    let r = ui.selectable_label(on, tr(label));
                    crate::widgets::register(ui.ctx(), format!("button:tether-{}", label.replace(' ', "").to_lowercase()), r.rect);
                    if r.on_hover_text(tr(help)).clicked() && !on {
                        action = Some(("tether.mode", mode_params(m, size)));
                    }
                }
                ui.separator();
                if let Some(choice) = preset_combo(app, ui, "tether-bar-preset", preset.as_deref()) {
                    new_preset = Some(choice);
                }
                ui.separator();
                let plural = if st.received == 1 { "" } else { "s" };
                let mut shots = match (st.received, st.last_mb, st.last_seconds) {
                    (0, ..) => tr("No shots yet").to_string(),
                    (n, Some(mb), Some(s)) => format!("{n} shot{plural} · last {mb:.1} MB at {s:.1} s"),
                    (n, Some(mb), _) => format!("{n} shot{plural} · last {mb:.1} MB"),
                    (n, ..) => format!("{n} shot{plural}"),
                };
                if let Some(s) = st.last_preview_seconds {
                    shots.push_str(&format!(" · preview at {s:.1} s"));
                }
                if let Some(t) = &st.transfer {
                    shots.push_str(&format!(" · ⬇ {t}"));
                }
                ui.label(RichText::new(shots).color(t.text_dim));
                // Settings and Stop at the right end
                ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                    let r = ui.button(tr("Stop"));
                    crate::widgets::register(ui.ctx(), "button:tether-stop", r.rect);
                    if r.clicked() {
                        action = Some(("tether.stop", json!({})));
                    }
                    if ui.button(tr("Settings…")).clicked() {
                        open_settings = true;
                    }
                });
            });
        });
    if open_settings {
        app.tether_ui.open = true;
    }
    if let Some((id, p)) = action
        && let Err(e) = app.run(id, p)
    {
        app.toast(&ctx, e);
    }
    if let Some(choice) = new_preset {
        set_preset(app, &ctx, choice);
    }
}

/// The tether preset: for the next shots, and at once on the shot on show.
fn set_preset(app: &mut LightcraftApp, ctx: &egui::Context, choice: Option<String>) {
    if let Err(e) = preset_now(app, choice) {
        app.toast(ctx, e);
    }
}

fn preset_now(app: &mut LightcraftApp, choice: Option<String>) -> Result<Value, String> {
    let status = app.run("tether.settings", json!({"preset": choice}))?;
    apply_preset_now(app, choice.as_deref())?;
    Ok(status)
}

/// `tether.setPreset {preset: id | null}`: what choosing in the bar's preset menu does (agents, tests).
pub fn set_preset_command(app: &mut LightcraftApp, p: &Value) -> Result<Value, String> {
    let choice = match p.get("preset") {
        Some(Value::String(id)) if !id.is_empty() => Some(id.clone()),
        Some(Value::Null) | Some(Value::String(_)) => None,
        _ => return Err("tether.setPreset: `preset` must be a preset id or null".into()),
    };
    preset_now(app, choice)
}

fn window(app: &mut LightcraftApp, ctx: &egui::Context) {
    if !app.tether_ui.open {
        return;
    }
    let t = Tokens::get(ctx);
    let running = app.session.tether.is_running();
    let status = app.session.tether.status.clone();
    let settings = app.session.tether.settings().clone();
    let folder_now = app.session.tether.save_dir.clone();
    let mut open = true;
    let mut actions: Vec<(&str, Value)> = Vec::new();
    let mut search = false;
    let mut pair = false;
    let mut pick_folder = false;
    let mut new_preset: Option<Option<String>> = None;
    // first shown in the middle of the photo area (then where the user leaves it)
    let center = app.canvas_rect.map_or(egui::pos2(600.0, 300.0), |r| egui::pos2(r.center().x, r.top() + 120.0));
    egui::Window::new(tr("Tethered Capture"))
        .id(Id::new("tether-window"))
        .open(&mut open)
        .collapsible(false)
        .resizable(false)
        .default_width(470.0)
        .pivot(Align2::CENTER_TOP)
        .default_pos(center)
        .show(ctx, |ui| {
            ui.spacing_mut().item_spacing.y = 6.0;
            // --- on / off
            if running {
                ui.label(RichText::new(tr("On")).font(t.semibold(13.0)).color(OK_GREEN));
                ui.label(RichText::new(&status.message).color(t.text_dim));
            } else {
                ui.label(RichText::new(tr("Off")).font(t.semibold(13.0)).color(t.text_dim));
            }
            ui.horizontal(|ui| {
                if running {
                    if ui.button(tr("Stop Tethered Capture")).clicked() {
                        actions.push(("tether.stop", json!({})));
                    }
                } else {
                    let r = ui.button(tr("Start Tethered Capture"));
                    crate::widgets::register(ui.ctx(), "button:tether-start", r.rect);
                    if r.clicked() {
                        actions.push(("tether.start", json!({})));
                    }
                }
            });
            ui.separator();

            // --- the camera
            ui.label(RichText::new(tr("Camera")).font(t.semibold(13.0)).color(t.text));
            if settings.user.is_empty() {
                ui.label(RichText::new(tr("Not paired yet.")).color(t.text_dim));
            } else {
                ui.horizontal(|ui| {
                    ui.label(format!("Paired with {camera}", camera = settings.camera));
                    if ui.small_button(tr("Forget")).clicked() {
                        actions.push(("tether.pairing", json!({"forget": true})));
                    }
                });
            }
            let w = &mut app.tether_ui;
            ui.label(
                RichText::new(tr(
                    "On the camera turn on remote shooting from the computer with Wi-Fi Direct, then connect this computer to the camera's Wi-Fi (DIRECT-…, name and password in the camera's Wi-Fi Direct info).",
                ))
                .size(11.5)
                .color(t.text_dim),
            );
            ui.horizontal(|ui| {
                let busy = w.search.is_some() || w.pairing.is_some();
                let can = !running && !busy;
                let r = ui.add_enabled(can, egui::Button::new(tr("Search for the Camera")));
                crate::widgets::register(ui.ctx(), "button:tether-search", r.rect);
                if r.clicked() {
                    search = true;
                }
                if busy {
                    ui.spinner();
                }
                if running {
                    ui.label(RichText::new(tr("Stop tethered capture to pair.")).size(11.5).color(t.text_dim));
                }
            });
            if let Some(f) = w.found.clone() {
                ui.label(format!("Found: {model} ({ip})", model = f.model, ip = f.ip));
                if let Some(fp) = &f.fingerprint {
                    ui.label(RichText::new(tr("The camera's fingerprint (access authentication):")).size(11.5).color(t.text_dim));
                    ui.label(RichText::new(fp).monospace().color(t.text));
                    ui.checkbox(
                        &mut w.matches,
                        tr("It matches the one on the camera (Network ▸ Network Option ▸ Access Auth. Info)"),
                    );
                    egui::Grid::new("tether-auth").num_columns(2).spacing([8.0, 4.0]).show(ui, |ui| {
                        ui.label(tr("User"));
                        ui.add(egui::TextEdit::singleline(&mut w.user).desired_width(220.0));
                        ui.end_row();
                        ui.label(tr("Password"));
                        ui.add(egui::TextEdit::singleline(&mut w.password).password(true).desired_width(220.0));
                        ui.end_row();
                    });
                }
                let ready = f.fingerprint.is_none() || (w.matches && !w.user.trim().is_empty() && !w.password.is_empty());
                let r = ui.add_enabled(ready && w.pairing.is_none() && !running, egui::Button::new(tr("Pair")));
                crate::widgets::register(ui.ctx(), "button:tether-pair", r.rect);
                if r.clicked() {
                    pair = true;
                }
            }
            if let Some((error, text)) = &w.message {
                ui.label(RichText::new(text).color(if *error { t.reject } else { OK_GREEN }));
            }
            ui.separator();

            // --- the shots
            ui.label(RichText::new(tr("Shots")).font(t.semibold(13.0)).color(t.text));
            let current = settings.choice();
            for (_, m, size, help) in sends() {
                let on = is_current(current, m, size);
                if ui.radio(on, tr(help)).clicked() && !on {
                    actions.push(("tether.mode", mode_params(m, size)));
                }
            }
            ui.label(
                RichText::new(tr(
                    "With RAW the camera can shoot RAW only: every shot shows at full size from the start of its raw, then the raw takes its place (8 and 14 MP need RAW & JPEG). On the camera, Network ▸ Wi-Fi ▸ Wi-Fi Frequency Band ▸ 5GHz makes every transfer faster.",
                ))
                .size(11.5)
                .color(t.text_dim),
            );
            let mut direct = !settings.sdk_only;
            if ui
                .checkbox(&mut direct, tr("Direct connection: a raw shows at full size from its first 2 MB (off: Sony's SDK; from the next start)"))
                .changed()
            {
                actions.push(("tether.settings", json!({"direct": direct})));
            }
            ui.horizontal(|ui| {
                ui.label(tr("Preset"));
                if let Some(choice) = preset_combo(app, ui, "tether-window-preset", settings.preset.as_deref()) {
                    new_preset = Some(choice);
                }
            });
            ui.horizontal(|ui| {
                ui.label(tr("Folder"));
                let shown = settings.folder.clone().unwrap_or_else(|| tr("Pictures\\Tethering (a folder per day)").to_string());
                ui.label(RichText::new(shown).color(t.text_dim));
                if ui.small_button(tr("Choose…")).clicked() {
                    pick_folder = true;
                }
                if settings.folder.is_some() && ui.small_button(tr("Default")).clicked() {
                    actions.push(("tether.settings", json!({"folder": null})));
                }
            });
            if let Some(dir) = &folder_now {
                ui.label(RichText::new(format!("Today: {dir}", dir = dir.display())).size(11.5).color(t.text_dim));
            }
        });
    if !open {
        app.tether_ui.open = false;
    }
    if pick_folder && let Some(f) = app.services.pick_folder.as_mut().and_then(|f| f()) {
        actions.push(("tether.settings", json!({"folder": f})));
    }
    if search {
        let w = &mut app.tether_ui;
        w.found = None;
        w.message = None;
        match lightcraft_engine::tether::sdk_dir() {
            Ok(dir) => w.search = background(ctx, move || lightcraft_tether::find(&dir)),
            Err(e) => w.message = Some((true, e)),
        }
    }
    if pair {
        let w = &mut app.tether_ui;
        if let (Some(found), Ok(dir)) = (w.found.clone(), lightcraft_engine::tether::sdk_dir()) {
            let (user, password) = (w.user.trim().to_string(), w.password.clone());
            w.message = None;
            w.pairing = background(ctx, move || lightcraft_tether::pair(&dir, &found, &user, &password));
        }
    }
    if let Some(choice) = new_preset {
        set_preset(app, ctx, choice);
    }
    for (id, p) in actions {
        if let Err(e) = app.run(id, p) {
            app.toast(ctx, e);
        }
    }
}
