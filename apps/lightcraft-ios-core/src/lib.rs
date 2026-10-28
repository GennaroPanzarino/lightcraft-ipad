//! LightCraft for the iPad app, as a C library Swift calls (`lightcraft.h`):
//!
//! - the engine (`lc_open`… `lc_export_jpeg`): the same core the Android app runs, JSON in and out,
//!   renders written into a buffer the app owns;
//! - the tether (`lc_tether_*`): the camera link in Rust (SSH, PTP/IP, Sony), its events polled as
//!   JSON.
//!
//! Strings returned are the caller's to free with `lc_free`. Nothing panics across the boundary.

use std::ffi::{CStr, CString, c_char, c_void};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::{Mutex, PoisonError};

use lightcraft_android::Core;
use serde_json::{Value, json};

#[allow(dead_code)]
#[path = "../../../crates/tether/src/peek.rs"]
mod peek;
#[allow(dead_code)]
#[path = "../../../crates/tether/src/ptp.rs"]
mod ptp;
pub mod tether;

fn guarded(f: impl FnOnce() -> Result<Value, String>) -> String {
    match catch_unwind(AssertUnwindSafe(f)) {
        Ok(Ok(v)) => v.to_string(),
        Ok(Err(e)) => json!({"ok": false, "error": e}).to_string(),
        Err(p) => {
            let what = p.downcast_ref::<String>().cloned().or_else(|| p.downcast_ref::<&str>().map(|s| s.to_string())).unwrap_or_default();
            json!({"ok": false, "error": format!("internal error: {what}")}).to_string()
        }
    }
}

/// # Safety
/// `s` is null or a NUL-terminated string.
unsafe fn text(s: *const c_char) -> String {
    if s.is_null() {
        return String::new();
    }
    // SAFETY: the caller passes a NUL-terminated string.
    unsafe { CStr::from_ptr(s) }.to_string_lossy().into_owned()
}

fn out(s: String) -> *mut c_char {
    CString::new(s.replace('\0', "")).map(CString::into_raw).unwrap_or(std::ptr::null_mut())
}

/// # Safety
/// `h` is null or a handle from `lc_open` not yet closed.
unsafe fn core<'a>(h: *mut c_void) -> Option<&'a Mutex<Core>> {
    // SAFETY: the handle is the box `lc_open` leaked.
    (!h.is_null()).then(|| unsafe { &*(h as *const Mutex<Core>) })
}

fn with_core(h: *mut c_void, f: impl FnOnce(&mut Core) -> Result<Value, String> + Send) -> *mut c_char {
    out(guarded(|| {
        // SAFETY: see `core`.
        let c = unsafe { core(h) }.ok_or("LightCraft isn't open")?;
        let mut c = c.lock().unwrap_or_else(PoisonError::into_inner);
        c.on_pool(f)
    }))
}

/// Free a string this library returned.
///
/// # Safety
/// `s` is null or a string returned by this library, freed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lc_free(s: *mut c_char) {
    if !s.is_null() {
        // SAFETY: made by `CString::into_raw` here.
        drop(unsafe { CString::from_raw(s) });
    }
}

/// Open the library in `dir` (created on first use). `nice`: how much its worker threads give way;
/// `previews`: a core for the camera's small JPEGs only. Null on failure.
///
/// # Safety
/// `dir` is a NUL-terminated path.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lc_open(dir: *const c_char, nice: i32, previews: bool) -> *mut c_void {
    // SAFETY: as documented.
    let dir = unsafe { text(dir) };
    // An app has no settings folder of its own and a read-only temporary folder: both go next to
    // the library. Rendering runs on the GPU through Metal (the engine falls back to the CPU by
    // itself when there is none, as in a simulator without one); the app sets LIGHTCRAFT_GPU=0 to
    // keep it on the CPU.
    if let Some(parent) = std::path::Path::new(&dir).parent() {
        for (var, sub) in [("LIGHTCRAFT_CONFIG_DIR", "config"), ("TMPDIR", "tmp")] {
            if std::env::var_os(var).is_none() {
                let p = parent.join(sub);
                let _ = std::fs::create_dir_all(&p);
                // SAFETY: called at start-up, before the engine starts threads that read the environment.
                unsafe { std::env::set_var(var, &p) };
            }
        }
    }
    if std::env::var_os("LIGHTCRAFT_GPU_BACKEND").is_none() {
        // SAFETY: as above.
        unsafe { std::env::set_var("LIGHTCRAFT_GPU_BACKEND", "metal") };
    }
    match catch_unwind(|| Core::open(&dir, nice, previews)) {
        Ok(Ok(c)) => Box::into_raw(Box::new(Mutex::new(c))) as *mut c_void,
        _ => std::ptr::null_mut(),
    }
}

/// # Safety
/// `h` is a handle from `lc_open`, closed once, after its last use.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lc_close(h: *mut c_void) {
    if !h.is_null() {
        // SAFETY: the box `lc_open` leaked.
        drop(unsafe { Box::from_raw(h as *mut Mutex<Core>) });
    }
}

/// One command of LightCraft's API: `{"ok": true, "result": …}` or `{"ok": false, "error": …}`.
///
/// # Safety
/// `h` from `lc_open`; `command` and `params` NUL-terminated.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lc_execute(h: *mut c_void, command: *const c_char, params: *const c_char) -> *mut c_char {
    // SAFETY: as documented.
    let (command, params) = unsafe { (text(command), text(params)) };
    with_core(h, move |c| Ok(c.execute(&command, &params)))
}

/// # Safety
/// `buf` holds `cap` writable bytes for the duration of the call.
unsafe fn buffer<'a>(buf: *mut u8, cap: usize) -> &'a mut [u8] {
    if buf.is_null() || cap == 0 {
        return &mut [];
    }
    // SAFETY: as documented.
    unsafe { std::slice::from_raw_parts_mut(buf, cap) }
}

/// The photo with its edits fitted into `w × h`, RGBA into `buf`: `{"width", "height", "ms"}`.
///
/// # Safety
/// `h` from `lc_open`; `buf` holds `cap` bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lc_render(h: *mut c_void, photo: u64, w: u32, hh: u32, draft: bool, buf: *mut u8, cap: usize) -> *mut c_char {
    // SAFETY: as documented.
    let b = unsafe { buffer(buf, cap) };
    with_core(h, move |c| c.render(photo, w.max(1) as usize, hh.max(1) as usize, draft, b))
}

/// # Safety
/// As `lc_render`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lc_render_before(h: *mut c_void, photo: u64, w: u32, hh: u32, buf: *mut u8, cap: usize) -> *mut c_char {
    // SAFETY: as documented.
    let b = unsafe { buffer(buf, cap) };
    with_core(h, move |c| c.render_before(photo, w.max(1) as usize, hh.max(1) as usize, b))
}

/// One window of the photo as drawn whole at `full_w × full_h` (the zoomed-in viewer).
///
/// # Safety
/// As `lc_render`.
#[unsafe(no_mangle)]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn lc_render_region(h: *mut c_void, photo: u64, full_w: u32, full_h: u32, x: u32, y: u32, w: u32, hh: u32, buf: *mut u8, cap: usize) -> *mut c_char {
    // SAFETY: as documented.
    let b = unsafe { buffer(buf, cap) };
    with_core(h, move |c| c.render_region(photo, full_w as usize, full_h as usize, x as usize, y as usize, w as usize, hh as usize, b))
}

/// Where layer `mask` acts, white on black (the app's mask overlay).
///
/// # Safety
/// As `lc_render`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lc_render_mask(h: *mut c_void, photo: u64, mask: u64, w: u32, hh: u32, buf: *mut u8, cap: usize) -> *mut c_char {
    // SAFETY: as documented.
    let b = unsafe { buffer(buf, cap) };
    with_core(h, move |c| c.render_mask(photo, mask, w.max(1) as usize, hh.max(1) as usize, b))
}

/// The photo without its crop and straightening (the crop tool's picture).
///
/// # Safety
/// As `lc_render`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lc_render_uncropped(h: *mut c_void, photo: u64, w: u32, hh: u32, draft: bool, buf: *mut u8, cap: usize) -> *mut c_char {
    // SAFETY: as documented.
    let b = unsafe { buffer(buf, cap) };
    with_core(h, move |c| c.render_uncropped(photo, w.max(1) as usize, hh.max(1) as usize, draft, b))
}

/// # Safety
/// As `lc_render`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lc_thumb(h: *mut c_void, photo: u64, edge: u32, buf: *mut u8, cap: usize) -> *mut c_char {
    // SAFETY: as documented.
    let b = unsafe { buffer(buf, cap) };
    with_core(h, move |c| c.thumb(photo, edge.max(16) as usize, b))
}

/// The photo with preset `preset` (empty: none) at `amount` percent over its edits, long edge `edge`.
///
/// # Safety
/// As `lc_render`; `preset` NUL-terminated.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lc_render_variant(h: *mut c_void, photo: u64, preset: *const c_char, amount: i32, edge: u32, buf: *mut u8, cap: usize) -> *mut c_char {
    // SAFETY: as documented.
    let (preset, b) = unsafe { (text(preset), buffer(buf, cap)) };
    with_core(h, move |c| c.render_variant(photo, &preset, f64::from(amount.clamp(0, 200)) / 100.0, edge.max(16) as usize, b))
}

/// The photo as a JPEG at `path` (`long_edge` 0: full size).
///
/// # Safety
/// `h` from `lc_open`; `path` NUL-terminated.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lc_export_jpeg(h: *mut c_void, photo: u64, path: *const c_char, quality: i32, long_edge: u32) -> *mut c_char {
    // SAFETY: as documented.
    let path = unsafe { text(path) };
    let long = (long_edge > 0).then_some(u64::from(long_edge));
    with_core(h, move |c| c.export_jpeg(photo, &path, quality.clamp(1, 100) as u8, long))
}

/// The photo as a file at `path`, `params` the engine's export options as JSON (format, quality,
/// bitDepth, longEdge…).
///
/// # Safety
/// `h` from `lc_open`; `path` and `params` NUL-terminated.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lc_export(h: *mut c_void, photo: u64, path: *const c_char, params: *const c_char) -> *mut c_char {
    // SAFETY: as documented.
    let (path, params) = unsafe { (text(path), text(params)) };
    let params: Value = serde_json::from_str(&params).unwrap_or(json!({}));
    with_core(h, move |c| c.export(photo, &path, &params))
}

/// Start the camera link (`config`: `{host?, user, password, fingerprint?, plain?, saveDir, raw}`).
///
/// # Safety
/// `config` NUL-terminated.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lc_tether_start(config: *const c_char) -> *mut c_void {
    // SAFETY: as documented.
    let config = unsafe { text(config) };
    let v: Value = serde_json::from_str(&config).unwrap_or(json!({}));
    match catch_unwind(|| tether::Tether::start(tether::Config::from_json(&v))) {
        Ok(t) => Box::into_raw(Box::new(t)) as *mut c_void,
        Err(_) => std::ptr::null_mut(),
    }
}

/// What the link did since the last call: a JSON array of events.
///
/// # Safety
/// `t` from `lc_tether_start`, not yet stopped.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lc_tether_poll(t: *mut c_void) -> *mut c_char {
    if t.is_null() {
        return out("[]".into());
    }
    // SAFETY: the box `lc_tether_start` leaked.
    let t = unsafe { &*(t as *const tether::Tether) };
    out(Value::Array(t.poll()).to_string())
}

/// RAW (true) or the camera's 2 MP JPEG (false).
///
/// # Safety
/// As `lc_tether_poll`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lc_tether_set_raw(t: *mut c_void, raw: bool) {
    if !t.is_null() {
        // SAFETY: as documented.
        unsafe { &*(t as *const tether::Tether) }.set_raw(raw);
    }
}

/// Stop the link and free it.
///
/// # Safety
/// `t` from `lc_tether_start`, stopped once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lc_tether_stop(t: *mut c_void) {
    if !t.is_null() {
        // SAFETY: the box `lc_tether_start` leaked.
        drop(unsafe { Box::from_raw(t as *mut tether::Tether) });
    }
}
