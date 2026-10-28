//! LightCraft's engine for the Android tethering app. The app (Kotlin) holds one [`Core`] — a
//! [`Session`] with its library in the app's storage — and drives it through JNI:
//!
//! - `execute(command, params)`: the whole command API (`library.import`, `develop.set`,
//!   `preset.apply`, `photo.rate`, `develop.get`, `preset.list`…), JSON in and out, as on the desktop;
//! - `render(photo, maxW, maxH, draft, buffer)`: the loupe's picture of a photo with its edits,
//!   RGBA written into a direct `ByteBuffer` the app turns into a bitmap. Renders of the same photo
//!   share a stage cache, so dragging a slider only redoes what that setting feeds;
//! - `renderBefore`, `thumb`, `renderVariant`: the Before side, the grid thumbnail (cached on disk),
//!   and the photo with a preset over its edits (the preset browser's thumbnails);
//! - `exportJpeg(photo, path, quality, longEdge)`: the full-size (or `longEdge`) JPEG.
//!
//! Every entry point catches panics and reports errors as JSON (`{"error": …}`): nothing unwinds into
//! the JVM.

use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::Arc;
use std::time::Instant;

use lightcraft_engine::Session;
use lightcraft_engine::catalog::PhotoId;
use lightcraft_engine::media::RenderJob;
use lightcraft_engine::pipeline::StageCache;
use serde_json::{Value, json};

/// A session and the loupe's stage cache (dropped when another photo is rendered).
pub struct Core {
    session: Session,
    stages: Option<(u64, Arc<StageCache>)>,
    /// Its own worker threads: the app runs two cores (the camera's previews, the raws), and on one
    /// shared pool a raw being developed would hold up the next preview until it is done.
    pool: Option<rayon::ThreadPool>,
}

impl Core {
    /// The library in `dir` (created on first use). `nice`: how much its worker threads give way to
    /// others (Linux nice, 0 = as the app): the raws' core yields to the previews'. `previews`: a
    /// core for the camera's small JPEGs, whose import probes don't queue at the process's memory
    /// gate (a raw being decoded holds it for as long as that takes).
    pub fn open(dir: &str, nice: i32, previews: bool) -> Result<Core, String> {
        let mut session = Session::new().with_fs().with_system_clock();
        if previews {
            let probe: lightcraft_engine::media::FileProbe = Arc::new(|path: &str| {
                let bytes = std::fs::read(path).map_err(|e| format!("{path}: {e}"))?;
                lightcraft_engine::files::probe_bytes(path, &bytes)
            });
            session.media.file_probe = Some(probe);
        }
        std::fs::create_dir_all(dir).map_err(|e| format!("{dir}: {e}"))?;
        session.open_library(dir, false).map_err(|e| format!("{dir}: {e}"))?;
        let threads = std::thread::available_parallelism().map_or(4, |n| n.get());
        let pool = rayon::ThreadPoolBuilder::new()
            .num_threads(threads)
            .thread_name(|i| format!("lc-core-{i}"))
            .start_handler(move |_| be_nice(nice))
            .build()
            .ok();
        Ok(Core { session, stages: None, pool })
    }

    /// `f` on this core's worker threads.
    pub fn on_pool<T: Send>(&mut self, f: impl FnOnce(&mut Self) -> T + Send) -> T {
        match self.pool.take() {
            Some(pool) => {
                let r = pool.install(|| f(self));
                self.pool = Some(pool);
                r
            }
            None => f(self),
        }
    }

    /// One command: `{"ok": true, "result": …}` or `{"ok": false, "error": …}`.
    pub fn execute(&mut self, command: &str, params: &str) -> Value {
        let p: Value = if params.trim().is_empty() { json!({}) } else { serde_json::from_str(params).unwrap_or(json!({})) };
        match self.session.execute(command, &p) {
            Ok(r) => json!({"ok": true, "result": r}),
            Err(e) => json!({"ok": false, "error": e.to_string()}),
        }
    }

    /// The photo with its edits, fitted into `max_w × max_h` (crop applied), into `out` (RGBA, rows
    /// packed). Returns `{"width", "height", "ms"}`.
    pub fn render(&mut self, id: u64, max_w: usize, max_h: usize, draft: bool, out: &mut [u8]) -> Result<Value, String> {
        let t0 = Instant::now();
        let photo = PhotoId(id);
        let stages = match &self.stages {
            Some((p, s)) if *p == id => s.clone(),
            _ => {
                let s: Arc<StageCache> = Default::default();
                self.stages = Some((id, s.clone()));
                s
            }
        };
        let job = self.session.loupe_job(photo, max_w.max(8), max_h.max(8), true).ok_or("no such photo")?;
        let job = job.with_stages(stages);
        let job = if draft { job.draft() } else { job };
        self.run_into(job, out, t0)
    }

    /// The photo without its edits (the Before side), fitted into `max_w × max_h`.
    pub fn render_before(&mut self, id: u64, max_w: usize, max_h: usize, out: &mut [u8]) -> Result<Value, String> {
        let t0 = Instant::now();
        let job = self.session.render_job(PhotoId(id), max_w.max(8), max_h.max(8), true, true).ok_or("no such photo")?;
        self.run_into(job, out, t0)
    }

    /// The grid thumbnail (long edge `edge`, from the library's thumbnail cache when it has it).
    pub fn thumb(&mut self, id: u64, edge: usize, out: &mut [u8]) -> Result<Value, String> {
        let t0 = Instant::now();
        let job = self.session.thumb_job(PhotoId(id), edge.max(16)).ok_or("no such photo")?;
        self.run_into(job, out, t0)
    }

    /// The photo as it would look with preset `preset` at `amount` (1 = 100 %) over its edits, long
    /// edge `edge` (≤ 512): the preset browser's thumbnails, cached like the desktop's. An empty
    /// `preset` is the photo as it is.
    pub fn render_variant(&mut self, id: u64, preset: &str, amount: f64, edge: usize, out: &mut [u8]) -> Result<Value, String> {
        let t0 = Instant::now();
        let photo = PhotoId(id);
        let d = self.session.develop_of(photo).ok_or("no such photo")?;
        let settings = if preset.is_empty() {
            (*d).clone()
        } else {
            let p = self.session.presets.iter().find(|p| p.id == preset).ok_or_else(|| format!("unknown preset `{preset}`"))?;
            p.apply(&d, amount)
        };
        let job = self.session.variant_job(photo, &settings, edge).ok_or("no such photo")?;
        self.run_into(job, out, t0)
    }

    /// Run `job` and copy its picture into `out` (RGBA, rows packed): `{"width", "height", "ms"}`.
    fn run_into(&mut self, job: RenderJob, out: &mut [u8], t0: Instant) -> Result<Value, String> {
        let r = job.run();
        self.session.accept(&r);
        let img = r.rendered?.image;
        let bytes = img.width * img.height * 4;
        if out.len() < bytes {
            return Err(format!("buffer too small: {} < {bytes}", out.len()));
        }
        for (dst, px) in out.chunks_exact_mut(4).zip(img.data.iter()) {
            dst.copy_from_slice(px);
        }
        Ok(json!({"width": img.width, "height": img.height, "ms": t0.elapsed().as_secs_f64() * 1000.0, "gpuFallback": r.gpu_fallback}))
    }

    /// One window of the photo as the viewer would draw it whole at `full_w × full_h` (a zoomed-in
    /// view: only what is on screen, at the screen's resolution).
    #[allow(clippy::too_many_arguments)]
    pub fn render_region(&mut self, id: u64, full_w: usize, full_h: usize, x: usize, y: usize, w: usize, h: usize, out: &mut [u8]) -> Result<Value, String> {
        let t0 = Instant::now();
        let window = lightcraft_pipeline::PixelWindow { x, y, w: w.max(1), h: h.max(1) };
        let job = self.session.region_job(PhotoId(id), full_w.max(8), full_h.max(8), window, true).ok_or("region not available")?;
        self.run_into(job, out, t0)
    }

    /// The photo with its edits but not its crop and straightening (what the crop tool shows: the
    /// crop is drawn over it), fitted into `max_w × max_h`.
    pub fn render_uncropped(&mut self, id: u64, max_w: usize, max_h: usize, draft: bool, out: &mut [u8]) -> Result<Value, String> {
        let t0 = Instant::now();
        let job = self.session.loupe_job(PhotoId(id), max_w.max(8), max_h.max(8), false).ok_or("no such photo")?;
        let job = if draft { job.draft() } else { job };
        self.run_into(job, out, t0)
    }

    /// The photo as a file at `path`, the export options as the engine takes them (`format`: jpg |
    /// tiff | png…, `quality`, `bitDepth`, `longEdge`, `colorSpace`, `tiffCompression`…).
    pub fn export(&mut self, id: u64, path: &str, params: &Value) -> Result<Value, String> {
        use lightcraft_engine::export::{ExportOptions, export_photo, write_file};
        let t0 = Instant::now();
        let mut p = params.clone();
        if let Some(o) = p.as_object_mut() {
            // where the file goes is `path`'s business, not the options'
            for k in ["path", "dir", "addToPhotos", "id", "ids"] {
                o.remove(k);
            }
        }
        let o = ExportOptions::from_params(&p).map_err(|e| e.to_string())?;
        let e = export_photo(&mut self.session, PhotoId(id), &o, 1)?;
        write_file(path, &e.bytes)?;
        Ok(json!({"path": path, "width": e.width, "height": e.height, "bytes": e.bytes.len(), "ms": t0.elapsed().as_secs_f64() * 1000.0}))
    }

    /// The photo as a JPEG at `path` (its long edge `long_edge` pixels, or full size).
    pub fn export_jpeg(&mut self, id: u64, path: &str, quality: u8, long_edge: Option<u64>) -> Result<Value, String> {
        use lightcraft_engine::export::{ExportOptions, export_photo, write_file};
        let t0 = Instant::now();
        let mut p = json!({"format": "jpg", "quality": quality.clamp(1, 100)});
        if let Some(n) = long_edge {
            p["longEdge"] = json!(n);
        }
        let o = ExportOptions::from_params(&p).map_err(|e| e.to_string())?;
        let e = export_photo(&mut self.session, PhotoId(id), &o, 1)?;
        write_file(path, &e.bytes)?;
        Ok(json!({"path": path, "width": e.width, "height": e.height, "bytes": e.bytes.len(), "ms": t0.elapsed().as_secs_f64() * 1000.0}))
    }
}

/// This thread's priority, `nice` steps below the app's (Linux: a thread is its own "process" here).
#[allow(unsafe_code)]
fn be_nice(nice: i32) {
    #[cfg(target_os = "android")]
    if nice > 0 {
        // SAFETY: a plain system call on the calling thread; raising one's own nice value is always allowed.
        unsafe { libc::setpriority(libc::PRIO_PROCESS, 0, nice) };
    }
    #[cfg(not(target_os = "android"))]
    let _ = nice;
}

/// `f`'s result as JSON, panics included.
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

/// The JNI entry points: `com.lightcraft.tether.core.Native`.
#[allow(unsafe_code)]
mod jvm {
    use std::sync::Mutex;

    use jni::JNIEnv;
    use jni::objects::{JByteBuffer, JClass, JString};
    use jni::sys::{jboolean, jint, jlong, jstring};
    use serde_json::json;

    use super::{Core, guarded};

    fn text(env: &mut JNIEnv, s: &JString) -> String {
        env.get_string(s).map(Into::into).unwrap_or_default()
    }

    fn out(env: &mut JNIEnv, s: String) -> jstring {
        env.new_string(s).map(|s| s.into_raw()).unwrap_or(std::ptr::null_mut())
    }

    /// The core behind a handle from `open` (0: none).
    fn core<'a>(handle: jlong) -> Option<&'a Mutex<Core>> {
        // SAFETY: a handle is a `Box<Mutex<Core>>` leaked by `open` and freed only by `close`, which
        // the app calls once, after its last use.
        (handle != 0).then(|| unsafe { &*(handle as *const Mutex<Core>) })
    }

    fn with_core(handle: jlong, f: impl FnOnce(&mut Core) -> Result<serde_json::Value, String> + Send) -> String {
        guarded(|| {
            let c = core(handle).ok_or("LightCraft isn't open")?;
            let mut c = c.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            c.on_pool(f)
        })
    }

    #[unsafe(no_mangle)]
    pub extern "system" fn Java_com_lightcraft_tether_core_Native_open(mut env: JNIEnv, _: JClass, dir: JString, nice: jint, previews: jboolean) -> jlong {
        #[cfg(target_os = "android")]
        android_logger::init_once(android_logger::Config::default().with_max_level(log::LevelFilter::Info).with_tag("lightcraft"));
        let dir = text(&mut env, &dir);
        // An app has no HOME and can't write /data/local/tmp: its settings (presets of its own) and
        // scratch files go next to the library, in its private storage. Rendering stays on the CPU:
        // probing a phone's Vulkan driver costs seconds at start-up, and a bad driver crashes the app.
        if std::env::var_os("LIGHTCRAFT_GPU").is_none() {
            // SAFETY: as below — start-up, before any engine thread.
            unsafe { std::env::set_var("LIGHTCRAFT_GPU", "0") };
        }
        if let Some(parent) = std::path::Path::new(&dir).parent() {
            for (var, sub) in [("LIGHTCRAFT_CONFIG_DIR", "config"), ("TMPDIR", "tmp")] {
                if std::env::var_os(var).is_none() {
                    let p = parent.join(sub);
                    let _ = std::fs::create_dir_all(&p);
                    // SAFETY: called once at start-up, before the engine starts any thread that reads
                    // the environment.
                    unsafe { std::env::set_var(var, &p) };
                }
            }
        }
        match std::panic::catch_unwind(|| Core::open(&dir, nice, previews != 0)) {
            Ok(Ok(c)) => Box::into_raw(Box::new(Mutex::new(c))) as jlong,
            Ok(Err(e)) => {
                log::error!("open {dir}: {e}");
                0
            }
            Err(_) => 0,
        }
    }

    #[unsafe(no_mangle)]
    pub extern "system" fn Java_com_lightcraft_tether_core_Native_close(_: JNIEnv, _: JClass, handle: jlong) {
        if handle != 0 {
            // SAFETY: the box `open` leaked; the app calls `close` once, after its last use.
            drop(unsafe { Box::from_raw(handle as *mut Mutex<Core>) });
        }
    }

    #[unsafe(no_mangle)]
    pub extern "system" fn Java_com_lightcraft_tether_core_Native_execute(
        mut env: JNIEnv,
        _: JClass,
        handle: jlong,
        command: JString,
        params: JString,
    ) -> jstring {
        let (command, params) = (text(&mut env, &command), text(&mut env, &params));
        let r = with_core(handle, |c| Ok(c.execute(&command, &params)));
        out(&mut env, r)
    }

    /// `f` with the bytes of a direct `ByteBuffer`.
    fn with_buffer(env: &mut JNIEnv, buffer: &JByteBuffer, f: impl FnOnce(&mut [u8]) -> String) -> String {
        match (env.get_direct_buffer_address(buffer), env.get_direct_buffer_capacity(buffer)) {
            // SAFETY: a direct buffer of `n` bytes the app keeps alive for this call and doesn't
            // touch from another thread meanwhile.
            (Ok(p), Ok(n)) if !p.is_null() => f(unsafe { std::slice::from_raw_parts_mut(p, n) }),
            _ => json!({"ok": false, "error": "not a direct buffer"}).to_string(),
        }
    }

    #[unsafe(no_mangle)]
    pub extern "system" fn Java_com_lightcraft_tether_core_Native_renderBefore(
        mut env: JNIEnv,
        _: JClass,
        handle: jlong,
        photo: jlong,
        max_w: jint,
        max_h: jint,
        buffer: JByteBuffer,
    ) -> jstring {
        let r = with_buffer(&mut env, &buffer, |buf| with_core(handle, |c| c.render_before(photo as u64, max_w.max(1) as usize, max_h.max(1) as usize, buf)));
        out(&mut env, r)
    }

    #[unsafe(no_mangle)]
    pub extern "system" fn Java_com_lightcraft_tether_core_Native_thumb(mut env: JNIEnv, _: JClass, handle: jlong, photo: jlong, edge: jint, buffer: JByteBuffer) -> jstring {
        let r = with_buffer(&mut env, &buffer, |buf| with_core(handle, |c| c.thumb(photo as u64, edge.max(16) as usize, buf)));
        out(&mut env, r)
    }

    #[unsafe(no_mangle)]
    pub extern "system" fn Java_com_lightcraft_tether_core_Native_renderVariant(
        mut env: JNIEnv,
        _: JClass,
        handle: jlong,
        photo: jlong,
        preset: JString,
        amount: jint,
        edge: jint,
        buffer: JByteBuffer,
    ) -> jstring {
        let preset = text(&mut env, &preset);
        let r = with_buffer(&mut env, &buffer, |buf| {
            with_core(handle, |c| c.render_variant(photo as u64, &preset, f64::from(amount.clamp(0, 200)) / 100.0, edge.max(16) as usize, buf))
        });
        out(&mut env, r)
    }

    #[unsafe(no_mangle)]
    pub extern "system" fn Java_com_lightcraft_tether_core_Native_render(
        mut env: JNIEnv,
        _: JClass,
        handle: jlong,
        photo: jlong,
        max_w: jint,
        max_h: jint,
        draft: jboolean,
        buffer: JByteBuffer,
    ) -> jstring {
        let r = with_buffer(&mut env, &buffer, |buf| {
            with_core(handle, |c| c.render(photo as u64, max_w.max(1) as usize, max_h.max(1) as usize, draft != 0, buf))
        });
        out(&mut env, r)
    }

    #[unsafe(no_mangle)]
    pub extern "system" fn Java_com_lightcraft_tether_core_Native_exportJpeg(
        mut env: JNIEnv,
        _: JClass,
        handle: jlong,
        photo: jlong,
        path: JString,
        quality: jint,
        long_edge: jint,
    ) -> jstring {
        let path = text(&mut env, &path);
        let long = (long_edge > 0).then_some(long_edge as u64);
        let r = with_core(handle, |c| c.export_jpeg(photo as u64, &path, quality.clamp(1, 100) as u8, long));
        out(&mut env, r)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The user presets of a desktop library's `presets.json` (`LC_PRESETS_FROM`), copied into a
    /// throwaway library, written as one .lcpreset file (`LC_PRESETS_TO`) for the phone.
    #[test]
    fn desktop_presets_to_a_file() {
        let (Ok(from), Ok(to)) = (std::env::var("LC_PRESETS_FROM"), std::env::var("LC_PRESETS_TO")) else { return };
        let dir = std::env::temp_dir().join(format!("lc-presets-copy-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::copy(&from, dir.join("presets.json")).unwrap();
        let mut c = Core::open(&dir.to_string_lossy(), 0, false).unwrap();
        let r = c.execute("preset.export", &json!({"path": to}).to_string());
        eprintln!("{r}");
        assert_eq!(r["ok"], true);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Two cores at once (`LC_TEST_ARWS=raw;…`, `LC_TEST_JPEG=…`): a JPEG imported into one while
    /// the other develops raws — does the import wait for the raw?
    #[test]
    fn an_import_while_another_core_develops() {
        let (Ok(list), Ok(jpeg)) = (std::env::var("LC_TEST_ARWS"), std::env::var("LC_TEST_JPEG")) else { return };
        let base = std::env::temp_dir().join(format!("lc-android-core3-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&base);
        let mut raws = Core::open(&base.join("raws").to_string_lossy(), 4, false).unwrap();
        let mut previews = Core::open(&base.join("previews").to_string_lossy(), 0, true).unwrap();
        let t0 = Instant::now();
        let a = std::thread::spawn(move || {
            let mut buf = vec![0u8; 1620 * 1620 * 4];
            for raw in list.split(';') {
                let r = raws.on_pool(|c| c.execute("library.import", &json!({"paths": [raw]}).to_string()));
                let id = r["result"]["imported"][0].as_u64().expect("imported");
                let t = Instant::now();
                raws.on_pool(|c| c.render(id, 1620, 1620, false, &mut buf)).unwrap();
                eprintln!("[{:6.0} ms] raw developed in {:.0} ms", t0.elapsed().as_secs_f64() * 1000.0, t.elapsed().as_secs_f64() * 1000.0);
            }
        });
        std::thread::sleep(std::time::Duration::from_millis(300));
        for i in 0..6 {
            let copy = base.join(format!("p{i}.jpg"));
            std::fs::copy(&jpeg, &copy).unwrap();
            let t = Instant::now();
            let r = previews.on_pool(|c| c.execute("library.import", &json!({"paths": [copy.to_string_lossy()]}).to_string()));
            eprintln!("[{:6.0} ms] import {i}: {:.0} ms ({})", t0.elapsed().as_secs_f64() * 1000.0, t.elapsed().as_secs_f64() * 1000.0, r["ok"]);
            std::thread::sleep(std::time::Duration::from_millis(400));
        }
        a.join().unwrap();
        let _ = std::fs::remove_dir_all(&base);
    }

    /// Two raws in a row (`LC_TEST_ARWS=a;b`): what the first render costs, and the next.
    #[test]
    fn first_and_second_raw_renders() {
        let Ok(list) = std::env::var("LC_TEST_ARWS") else { return };
        let dir = std::env::temp_dir().join(format!("lc-android-core2-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let mut c = Core::open(&dir.to_string_lossy(), 0, false).unwrap();
        let mut buf = vec![0u8; 1620 * 1620 * 4];
        for raw in list.split(';') {
            let t0 = Instant::now();
            let r = c.execute("library.import", &json!({"paths": [raw]}).to_string());
            let id = r["result"]["imported"][0].as_u64().expect("imported");
            let imported = t0.elapsed().as_secs_f64() * 1000.0;
            let v = c.render(id, 1620, 1620, false, &mut buf).unwrap();
            eprintln!("{raw}: import {imported:.0} ms, render {}", v["ms"]);
            let v = c.render(id, 1620, 1620, false, &mut buf).unwrap();
            eprintln!("   again {}", v["ms"]);
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_raw_imports_renders_takes_a_preset_and_exports() {
        let Some(raw) = std::env::var_os("LC_TEST_ARW") else { return };
        let dir = std::env::temp_dir().join(format!("lc-android-core-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let mut c = Core::open(&dir.to_string_lossy(), 0, false).unwrap();
        let r = c.execute("library.import", &json!({"paths": [raw.to_string_lossy()]}).to_string());
        let id = r["result"]["imported"][0].as_u64().expect("imported");
        let mut buf = vec![0u8; 1600 * 1600 * 4];
        let v = c.render(id, 1600, 1600, false, &mut buf).unwrap();
        eprintln!("render {v}");
        assert!(v["width"].as_u64().unwrap() > 1000);
        // a slider drag (draft) after the first render: the stage cache makes it quicker
        let set = c.execute("develop.set", &json!({"ids": [id], "values": {"light.exposure": 0.5}}).to_string());
        assert_eq!(set["ok"], true, "{set}");
        let v2 = c.render(id, 1600, 1600, true, &mut buf).unwrap();
        eprintln!("draft after exposure {v2}");
        let presets = c.execute("presets.list", "{}");
        assert_eq!(presets["ok"], true, "{presets}");
        if let Ok(d) = std::env::var("LC_TEST_DUMP") {
            let _ = std::fs::write(format!("{d}/presets.json"), presets.to_string());
            let _ = std::fs::write(format!("{d}/controls.json"), c.execute("develop.controls", "{}").to_string());
            let _ = std::fs::write(format!("{d}/develop.json"), c.execute("develop.get", &json!({"id": id}).to_string()).to_string());
            let _ = std::fs::write(format!("{d}/profiles.json"), c.execute("profiles.list", "{}").to_string());
            let _ = std::fs::write(format!("{d}/query.json"), c.execute("catalog.query", "{}").to_string());
        }
        let v3 = c.render_variant(id, "lc.warm-film", 1.0, 256, &mut buf).unwrap();
        eprintln!("variant {v3}");
        let v4 = c.thumb(id, 320, &mut buf).unwrap();
        eprintln!("thumb {v4}");
        let v5 = c.render_before(id, 800, 800, &mut buf).unwrap();
        eprintln!("before {v5}");
        let out = dir.join("out.jpg");
        let e = c.export_jpeg(id, &out.to_string_lossy(), 90, Some(2000)).unwrap();
        eprintln!("export {e}");
        assert!(out.is_file());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
