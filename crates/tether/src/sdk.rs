//! Sony's Camera Remote SDK (`Cr_Core.dll`, version 2.02) through its C ABI, loaded at run time.
//!
//! This is the crate's only module allowed `unsafe`. Its API is safe: SDK objects are wrapped in
//! owners that release them on drop, strings are copied out, and the callback object the SDK calls
//! into is a `#[repr(C)]` struct whose first field is a table of `extern "C"` functions laid out
//! like `SCRSDK::IDeviceCallback`'s virtual table (MSVC x64: `this` first, declaration order except
//! that overloads sit together in reverse order, no destructor slot). Layouts and indices were
//! checked against the SDK 2.02 headers (compiled with MSVC) and, from a prototype, against an
//! ILCE-7M4 over Wi-Fi Direct.
//!
//! The SDK looks for its network and USB modules (`CrAdapter\`) beside the running executable,
//! not beside `Cr_Core.dll`, so the SDK files must sit next to `lightcraft.exe`.
//!
//! Remote transfer (connect mode 2): the camera keeps each shot on its card and the computer pulls
//! what it wants from there (a screen-size preview, then the original), one transfer at a time,
//! each reported through `OnNotifyRemoteTransferResult`.
#![allow(unsafe_code)]

use std::ffi::{CString, c_void};
use std::path::Path;
use std::sync::{Arc, OnceLock};

use libloading::os::windows::{LOAD_WITH_ALTERED_SEARCH_PATH, Library};

/// `SCRSDK::CrDeviceProperty` on x64 (64 bytes; no virtual functions).
#[repr(C)]
#[derive(Clone, Copy)]
pub struct CrDeviceProperty {
    pub code: u32,
    pub value_type: u32,
    pub enable_flag: i16,
    pub variable_flag: u16,
    pub current_value: u64,
    pub current_str: *mut u16,
    pub values_size: u32,
    pub values: *mut u8,
    pub get_set_values_size: u32,
    pub get_set_values: *mut u8,
}

impl CrDeviceProperty {
    fn with(code: u32, value_type: u32, value: u64) -> CrDeviceProperty {
        CrDeviceProperty {
            code,
            value_type,
            enable_flag: 0,
            variable_flag: 0,
            current_value: value,
            current_str: std::ptr::null_mut(),
            values_size: 0,
            values: std::ptr::null_mut(),
            get_set_values_size: 0,
            get_set_values: std::ptr::null_mut(),
        }
    }
}

type FnInit = unsafe extern "C" fn(u32) -> bool;
type FnVersion = unsafe extern "C" fn() -> u32;
type FnEnum = unsafe extern "C" fn(*mut *mut c_void, u8) -> i32;
type FnCreateEth = unsafe extern "C" fn(*mut *mut c_void, u32, u32, *const u8, u32) -> i32;
type FnFingerprint = unsafe extern "C" fn(*mut c_void, *mut u8, *mut u32) -> i32;
type FnConnect =
    unsafe extern "C" fn(*mut c_void, *mut c_void, *mut i64, u32, u32, *const u8, *const u8, *const u8, u32, *const u16) -> i32;
type FnHandle = unsafe extern "C" fn(i64) -> i32;
type FnSaveInfo = unsafe extern "C" fn(i64, *const u16, *const u16, i32) -> i32;
type FnGetProps = unsafe extern "C" fn(i64, u32, *const u32, *mut *mut CrDeviceProperty, *mut i32) -> i32;
type FnReleaseProps = unsafe extern "C" fn(i64, *mut CrDeviceProperty) -> i32;
type FnSetProp = unsafe extern "C" fn(i64, *const CrDeviceProperty) -> i32;
type FnSetSetting = unsafe extern "C" fn(i64, u32, u32) -> i32;
type FnContents = unsafe extern "C" fn(i64, u32, u8, *const CaptureDate, u32, *mut *mut ContentsInfo, *mut u32) -> i32;
type FnReleaseContents = unsafe extern "C" fn(i64, *mut ContentsInfo) -> i32;
type FnPullFile = unsafe extern "C" fn(i64, u32, u32, u32, u32, *const u16, *const u16) -> i32;
type FnControlPull = unsafe extern "C" fn(i64, u8) -> i32;

/// `SCRSDK::CrCaptureDate` (14 bytes; its constructors only zero it).
#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct CaptureDate {
    pub year: u16,
    pub month: u16,
    pub day: u16,
    pub hour: u16,
    pub minute: u16,
    pub sec: u16,
    pub msec: u16,
}

/// `SCRSDK::CrContentsInfo` on x64 (120 bytes; checked against the SDK 2.02 headers with MSVC).
#[repr(C)]
struct ContentsInfo {
    content_type: u32,
    content_id: u32,
    dir_number: u32,
    file_number: u32,
    group_type: u32,
    group_id: u32,
    representative: u8,
    creation_utc: CaptureDate,
    modification_utc: CaptureDate,
    creation_local: CaptureDate,
    modification_local: CaptureDate,
    rating: u32,
    protection: u8,
    dummy: u8,
    shot_mark_num: u32,
    shot_mark: *mut u8,
    files_num: u32,
    files: *mut ContentsFile,
}

/// The first fields of `SCRSDK::CrContentsFile` on x64 (176 bytes; image, video and audio details follow).
#[repr(C)]
struct ContentsFile {
    file_id: u16,
    file_path_length: u32,
    file_path: *const u8,
    file_format: u32,
    file_size: u64,
    _rest: [u64; 18],
}

/// A shot (or clip) on the camera's card, as remote transfer lists it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Content {
    /// The SDK's id for it during this connection.
    pub id: u32,
    /// The card's folder and file numbers (`100MSDCF`, `DSC08822` → 100, 8822): the same across connections.
    pub dir: u32,
    pub number: u32,
    pub files: Vec<ContentFile>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ContentFile {
    pub id: u32,
    /// The file's name on the card (`DSC08822.ARW`).
    pub name: String,
    /// `CrContentsFile_FileFormat`: 0x3801 JPEG, 0xB101 RAW, 0xB110 HEIF, 0xB982 MP4…
    pub format: u32,
    pub size: u64,
}

pub const FORMAT_JPEG: u32 = 0x3801;
pub const FORMAT_RAW: u32 = 0xB101;
pub const FORMAT_HEIF: u32 = 0xB110;

/// The loaded and initialized SDK (once per process: `Init` is never undone, the system frees it on exit).
pub struct Api {
    _lib: Library,
    version: u32,
    enum_cameras: FnEnum,
    create_eth: FnCreateEth,
    fingerprint: FnFingerprint,
    connect: FnConnect,
    disconnect: FnHandle,
    release_device: FnHandle,
    set_save_info: FnSaveInfo,
    get_props: FnGetProps,
    release_props: FnReleaseProps,
    set_prop: FnSetProp,
    set_setting: FnSetSetting,
    contents: FnContents,
    release_contents: FnReleaseContents,
    pull_file: FnPullFile,
    pull_compressed: FnPullFile,
    control_pull: FnControlPull,
}

static API: OnceLock<Result<Api, String>> = OnceLock::new();

/// The SDK from `dir` (the folder of `lightcraft.exe`), loaded and initialized on first use.
pub fn api(dir: &Path) -> Result<&'static Api, String> {
    API.get_or_init(|| load(dir)).as_ref().map_err(Clone::clone)
}

/// When the app quits with everything saved: if the SDK was loaded, shut it down and end the
/// process at once. Left to the normal exit, its threads deadlock the unloading of its DLLs and the
/// process stays behind, windowless, holding the files it had open.
pub fn end_process_if_loaded() {
    let Some(Ok(api)) = API.get() else { return };
    unsafe extern "system" {
        fn GetCurrentProcess() -> *mut c_void;
        fn TerminateProcess(process: *mut c_void, code: u32) -> i32;
    }
    // SAFETY: `Release` is the SDK's own shutdown (`bool Release()`, CameraRemote_SDK.h); after it
    // nothing calls the SDK again, as the process ends right away (kernel32, always loaded).
    unsafe {
        if let Ok(release) = api._lib.get::<unsafe extern "C" fn() -> bool>(b"Release\0") {
            release();
        }
        TerminateProcess(GetCurrentProcess(), 0);
    }
}

fn load(dir: &Path) -> Result<Api, String> {
    let core = dir.join("Cr_Core.dll");
    if !core.is_file() {
        return Err(format!("Sony Camera Remote SDK not found: {} is missing", core.display()));
    }
    if !dir.join("CrAdapter").is_dir() {
        return Err(format!("Sony Camera Remote SDK incomplete: the CrAdapter folder is missing in {}", dir.display()));
    }
    // SAFETY: loading a DLL runs its initialization code. Cr_Core.dll is Sony's SDK, which the user
    // installed next to the executable on purpose; LOAD_WITH_ALTERED_SEARCH_PATH makes its own
    // dependencies (monitor_protocol.dll) resolve from the same folder.
    let lib = unsafe { Library::load_with_flags(&core, LOAD_WITH_ALTERED_SEARCH_PATH) }.map_err(|e| format!("Sony SDK: {e}"))?;
    // SAFETY: each symbol is an `extern "C"` function exported by Cr_Core.dll with exactly this
    // signature (CameraRemote_SDK.h, SDK 2.02). The pointers are copied out of the `Symbol`s and
    // stay valid because `Api` keeps `lib` loaded for the rest of the process.
    let api = unsafe {
        macro_rules! sym {
            ($name:literal, $t:ty) => {
                *lib.get::<$t>(concat!($name, "\0").as_bytes()).map_err(|e| format!("Sony SDK: {} missing: {e}", $name))?
            };
        }
        let init: FnInit = sym!("Init", FnInit);
        let version: FnVersion = sym!("GetSDKVersion", FnVersion);
        let a = Api {
            version: version(),
            enum_cameras: sym!("EnumCameraObjects", FnEnum),
            create_eth: sym!("CreateCameraObjectInfoEthernetConnection", FnCreateEth),
            fingerprint: sym!("GetFingerprint", FnFingerprint),
            connect: sym!("Connect", FnConnect),
            disconnect: sym!("Disconnect", FnHandle),
            release_device: sym!("ReleaseDevice", FnHandle),
            set_save_info: sym!("SetSaveInfo", FnSaveInfo),
            get_props: sym!("GetSelectDeviceProperties", FnGetProps),
            release_props: sym!("ReleaseDeviceProperties", FnReleaseProps),
            set_prop: sym!("SetDeviceProperty", FnSetProp),
            set_setting: sym!("SetDeviceSetting", FnSetSetting),
            contents: sym!("GetRemoteTransferContentsInfoList", FnContents),
            release_contents: sym!("ReleaseRemoteTransferContentsInfoList", FnReleaseContents),
            pull_file: sym!("GetRemoteTransferContentsDataFile", FnPullFile),
            pull_compressed: sym!("GetRemoteTransferContentsCompressedDataFile", FnPullFile),
            control_pull: sym!("ControlGetRemoteTransferContentsDataFile", FnControlPull),
            _lib: lib,
        };
        if !init(0) {
            return Err("the Sony SDK did not start (Init failed)".into());
        }
        a
    };
    Ok(api)
}

/// Read a NUL-terminated UTF-16 string the SDK owns (at most 4096 units).
fn wide(p: *const u16) -> String {
    if p.is_null() {
        return String::new();
    }
    let mut units = Vec::new();
    for i in 0..4096 {
        // SAFETY: the SDK returns NUL-terminated strings; we stop at the NUL (or after 4096 units).
        let u = unsafe { *p.add(i) };
        if u == 0 {
            break;
        }
        units.push(u);
    }
    String::from_utf16_lossy(&units)
}

fn wide_z(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

/// Virtual function `index` of an SDK C++ object (its first word points to the table).
///
/// # Safety
/// `obj` must be a live SDK object whose virtual table has more than `index` entries.
unsafe fn slot(obj: *mut c_void, index: usize) -> *const c_void {
    // SAFETY: guaranteed by the caller.
    unsafe {
        let table = *(obj as *const *const *const c_void);
        *table.add(index)
    }
}

/// What the SDK says about a camera it found.
#[derive(Clone, Debug, Default)]
pub struct CameraInfo {
    pub model: String,
    pub kind: String,
    pub ssh: bool,
    pub ip: String,
    pub mac: String,
}

/// An `ICrCameraObjectInfo`, released when dropped (through its enumerator when it came from one).
pub struct Camera {
    obj: *mut c_void,
    owner: *mut c_void,
}

impl Camera {
    pub fn info(&self) -> CameraInfo {
        // SAFETY: `obj` is a live ICrCameraObjectInfo (23 virtual functions, ICrCameraObjectInfo.h):
        // 3 GetModel, 10 GetConnectionTypeName, 17 GetIPAddressChar, 21 GetMACAddressChar return
        // UTF-16 strings the object owns (copied at once); 15 GetSSHsupport returns a CrInt32u.
        unsafe {
            let text = |i: usize| {
                let f: unsafe extern "C" fn(*mut c_void) -> *const u16 = std::mem::transmute(slot(self.obj, i));
                wide(f(self.obj))
            };
            let ssh: unsafe extern "C" fn(*mut c_void) -> u32 = std::mem::transmute(slot(self.obj, 15));
            CameraInfo { model: text(3), kind: text(10), ssh: ssh(self.obj) != 0, ip: text(17), mac: text(21) }
        }
    }
}

impl Drop for Camera {
    fn drop(&mut self) {
        // SAFETY: an enumerator owns the objects it lists (ICrEnumCameraObjectInfo::Release, slot 2);
        // an object made by CreateCameraObjectInfoEthernetConnection is released itself (slot 0).
        unsafe {
            if !self.owner.is_null() {
                let release: unsafe extern "C" fn(*mut c_void) = std::mem::transmute(slot(self.owner, 2));
                release(self.owner);
            } else if !self.obj.is_null() {
                let release: unsafe extern "C" fn(*mut c_void) = std::mem::transmute(slot(self.obj, 0));
                release(self.obj);
            }
        }
    }
}

impl Api {
    pub fn version(&self) -> String {
        let v = self.version;
        format!("{}.{:02}.{:02}", v >> 24, (v >> 16) & 0xFF, (v >> 8) & 0xFF)
    }

    /// The first camera the SDK finds (an ILCE-7M4 when there are several), if any.
    pub fn enumerate(&self) -> Option<Camera> {
        let mut e: *mut c_void = std::ptr::null_mut();
        // SAFETY: EnumCameraObjects writes an enumerator (or leaves NULL); timeInSec is ignored.
        unsafe { (self.enum_cameras)(&mut e, 3) };
        if e.is_null() {
            return None;
        }
        // SAFETY: `e` is a live ICrEnumCameraObjectInfo: 0 GetCount, 1 GetCameraObjectInfo(index).
        unsafe {
            let count: unsafe extern "C" fn(*mut c_void) -> u32 = std::mem::transmute(slot(e, 0));
            let get: unsafe extern "C" fn(*mut c_void, u32) -> *mut c_void = std::mem::transmute(slot(e, 1));
            let n = count(e);
            let mut best = None;
            for i in 0..n {
                let obj = get(e, i);
                if obj.is_null() {
                    continue;
                }
                let probe = Camera { obj, owner: std::ptr::null_mut() };
                let is_7m4 = probe.info().model.contains("7M4");
                std::mem::forget(probe); // owned by the enumerator
                if best.is_none() || is_7m4 {
                    best = Some(obj);
                }
                if is_7m4 {
                    break;
                }
            }
            match best {
                Some(obj) => Some(Camera { obj, owner: e }),
                None => {
                    let release: unsafe extern "C" fn(*mut c_void) = std::mem::transmute(slot(e, 2));
                    release(e);
                    None
                }
            }
        }
    }

    /// A camera object for a known address (when the SDK's search doesn't see the camera).
    pub fn camera_at(&self, model: u32, ip: [u8; 4], mac: [u8; 6], ssh: bool) -> Option<Camera> {
        let mut obj: *mut c_void = std::ptr::null_mut();
        // SAFETY: the SDK copies the 6-byte MAC; the IP is the address bytes read little-endian.
        let err = unsafe { (self.create_eth)(&mut obj, model, u32::from_le_bytes(ip), mac.as_ptr(), u32::from(ssh)) };
        (err == 0 && !obj.is_null()).then_some(Camera { obj, owner: std::ptr::null_mut() })
    }

    pub fn fingerprint(&self, cam: &Camera) -> Result<String, u32> {
        let mut buf = [0u8; 512];
        let mut len = 0u32;
        // SAFETY: the SDK writes at most its fingerprint (well under 512 bytes) and its length.
        let err = unsafe { (self.fingerprint)(cam.obj, buf.as_mut_ptr(), &mut len) };
        if err != 0 {
            return Err(err as u32);
        }
        let len = (len as usize).min(buf.len());
        Ok(String::from_utf8_lossy(buf.get(..len).unwrap_or_default()).into_owned())
    }

    /// Start connecting (asynchronous: the callbacks report the outcome). Returns the SDK error.
    /// `transfer`: remote transfer (shots stay on the card, the computer pulls them) instead of
    /// remote control (the camera sends each shot).
    pub fn connect(
        &self,
        cam: &Camera,
        callbacks: &CallbackObject,
        handle: &mut i64,
        auth: Option<(&str, &str, &str)>,
        transfer: bool,
    ) -> u32 {
        let c = |s: &str| CString::new(s).unwrap_or_default();
        let (user, pass, fp) = match auth {
            Some((u, p, f)) => (Some(c(u)), Some(c(p)), Some(f.as_bytes().to_vec())),
            None => (None, None, None),
        };
        let ptr = |s: &Option<CString>| s.as_ref().map_or(std::ptr::null(), |s| s.as_ptr() as *const u8);
        let fp_len = fp.as_ref().map_or(0, |f| f.len() as u32);
        let fp_ptr = fp.as_ref().map_or(std::ptr::null(), |f| f.as_ptr());
        *handle = 0;
        // the SDK reconnects by itself in remote control only
        let (mode, reconnect) = if transfer { (2, 0) } else { (0, 1) };
        // SAFETY: the strings outlive the call (the SDK copies them); `callbacks` stays alive and
        // pinned in its Box until after ReleaseDevice (the receiver keeps it); mode 0 = remote
        // control, 2 = remote transfer; reconnect 1 = on.
        let err = unsafe {
            (self.connect)(cam.obj, callbacks.as_ptr(), handle, mode, reconnect, ptr(&user), ptr(&pass), fp_ptr, fp_len, std::ptr::null())
        };
        err as u32
    }

    /// Change one of the SDK's settings for this connection (`Setting_Key_*`: 0 live view, 9 post
    /// view…). Returns the SDK error.
    pub fn set_setting(&self, handle: i64, key: u32, value: u32) -> u32 {
        // SAFETY: plain values.
        unsafe { (self.set_setting)(handle, key, value) as u32 }
    }

    /// Everything on the card in `slot` (1 or 2), as the SDK knows it (remote transfer only).
    pub fn contents(&self, handle: i64, slot: u32) -> Result<Vec<Content>, u32> {
        let date = CaptureDate::default();
        let mut list: *mut ContentsInfo = std::ptr::null_mut();
        let mut n = 0u32;
        // SAFETY: type 0 = all contents (the date is then ignored, but must point somewhere), no
        // limit; the SDK allocates `n` CrContentsInfo, each with `files_num` CrContentsFile, which
        // we copy out before handing the list back.
        unsafe {
            let err = (self.contents)(handle, slot, 0, &date, 0, &mut list, &mut n);
            if err != 0 {
                return Err(err as u32);
            }
            if list.is_null() {
                return Ok(Vec::new());
            }
            let mut out = Vec::with_capacity(n as usize);
            for i in 0..n as usize {
                let c = &*list.add(i);
                let mut files = Vec::new();
                if !c.files.is_null() {
                    for j in 0..c.files_num as usize {
                        let f = &*c.files.add(j);
                        let path = if f.file_path.is_null() {
                            Vec::new()
                        } else {
                            let len = (f.file_path_length as usize).min(1024);
                            std::slice::from_raw_parts(f.file_path, len).iter().copied().take_while(|b| *b != 0).collect()
                        };
                        let path = String::from_utf8_lossy(&path).into_owned();
                        let name = path.rsplit(['/', '\\']).next().unwrap_or_default().to_string();
                        files.push(ContentFile { id: u32::from(f.file_id), name, format: f.file_format, size: f.file_size });
                    }
                }
                out.push(Content { id: c.content_id, dir: c.dir_number, number: c.file_number, files });
            }
            (self.release_contents)(handle, list);
            Ok(out)
        }
    }

    /// Start pulling a file from the card into `dir` (as `name`, else under its own name): the
    /// original, or with `screennail` the camera's screen-size JPEG of it. Asynchronous: the result
    /// (and progress) comes through [`Sink::transferred`]. One transfer at a time. Returns the SDK error.
    #[allow(clippy::too_many_arguments)]
    pub fn pull(&self, handle: i64, slot: u32, content: u32, file: u32, dir: &Path, name: Option<&str>, screennail: bool) -> u32 {
        let path = wide_z(&dir.to_string_lossy());
        let name = name.map(wide_z);
        let name_ptr = name.as_ref().map_or(std::ptr::null(), |n| n.as_ptr());
        // SAFETY: NUL-terminated UTF-16 strings the SDK copies during the call. For originals the
        // fifth argument is the size of each piece the camera sends (80 MB, as Sony's sample on
        // Windows: a raw comes in one piece); for previews it is the kind, 2 = screennail.
        unsafe {
            if screennail {
                (self.pull_compressed)(handle, slot, content, file, 2, path.as_ptr(), name_ptr) as u32
            } else {
                (self.pull_file)(handle, slot, content, file, 0x500_0000, path.as_ptr(), name_ptr) as u32
            }
        }
    }

    /// Cancel the original being pulled (its result then reports the cancel).
    pub fn cancel_pull(&self, handle: i64) -> u32 {
        // SAFETY: 2 = CrGetContentsDataControlType_Cancel.
        unsafe { (self.control_pull)(handle, 2) as u32 }
    }

    pub fn disconnect(&self, handle: i64) -> u32 {
        // SAFETY: a handle Connect returned.
        unsafe { (self.disconnect)(handle) as u32 }
    }

    pub fn release_device(&self, handle: i64) -> u32 {
        // SAFETY: a handle Connect returned; after this the SDK no longer calls the callbacks.
        unsafe { (self.release_device)(handle) as u32 }
    }

    /// Where the SDK saves the photos it receives (camera file names).
    pub fn set_save_dir(&self, handle: i64, dir: &Path) -> u32 {
        let path = wide_z(&dir.to_string_lossy());
        let prefix = wide_z("");
        // SAFETY: two NUL-terminated UTF-16 strings that outlive the call; -1 = the camera's names.
        unsafe { (self.set_save_info)(handle, path.as_ptr(), prefix.as_ptr(), -1) as u32 }
    }

    /// The current value of a camera property, if the camera has it.
    pub fn property(&self, handle: i64, code: u32) -> Option<u64> {
        self.read(handle, code).map(|(_, value)| value)
    }

    fn read(&self, handle: i64, code: u32) -> Option<(u32, u64)> {
        let codes = [code];
        let mut props: *mut CrDeviceProperty = std::ptr::null_mut();
        let mut n = 0i32;
        // SAFETY: the SDK allocates `n` properties; we copy what we need out of the first one and
        // hand the array back with ReleaseDeviceProperties.
        unsafe {
            let err = (self.get_props)(handle, 1, codes.as_ptr(), &mut props, &mut n);
            if err != 0 || n < 1 || props.is_null() {
                return None;
            }
            let p = *props;
            (self.release_props)(handle, props);
            (p.code == code).then_some((p.value_type, p.current_value))
        }
    }

    /// Set a camera property (reading its type first). 0 = done or already so; `u32::MAX` = the
    /// camera doesn't report this property.
    pub fn set_property(&self, handle: i64, code: u32, value: u64) -> u32 {
        let Some((value_type, current)) = self.read(handle, code) else { return u32::MAX };
        if current == value {
            return 0;
        }
        let prop = CrDeviceProperty::with(code, value_type, value);
        // SAFETY: a property value the SDK only reads during the call.
        unsafe { (self.set_prop)(handle, &prop) as u32 }
    }
}

/// What the camera connection reports (called on SDK threads; must not panic or block long).
pub trait Sink: Send + Sync {
    fn connected(&self);
    fn disconnected(&self, error: u32);
    fn downloaded(&self, path: String);
    fn warning(&self, code: u32);
    fn error(&self, error: u32);
    /// A pull from the card progressed (`percent`) or ended (`notify`: 0x20093 done, else failed or
    /// canceled), with the saved file's full path when done.
    fn transferred(&self, notify: u32, percent: u32, path: String);
    /// The card's contents changed (`notify`: 0x20096 all, 0x20097 added, 0x20098 cleared) in `slot`.
    fn contents_changed(&self, notify: u32, slot: u32, added: u32);
}

/// `SCRSDK::IDeviceCallback`'s virtual table (21 functions, IDeviceCallback.h order; MSVC puts the
/// two `OnNotifyRemoteTransferResult` overloads the other way round: in-memory data first, file second).
#[repr(C)]
struct VTable {
    on_connected: extern "C" fn(*mut CallbackObject, u32),
    on_disconnected: extern "C" fn(*mut CallbackObject, u32),
    on_property_changed: extern "C" fn(*mut CallbackObject),
    on_property_changed_codes: extern "C" fn(*mut CallbackObject),
    on_lv_property_changed: extern "C" fn(*mut CallbackObject),
    on_lv_property_changed_codes: extern "C" fn(*mut CallbackObject),
    on_complete_download: extern "C" fn(*mut CallbackObject, *const u16, u32),
    on_complete_operation: extern "C" fn(*mut CallbackObject),
    on_notify_contents_transfer: extern "C" fn(*mut CallbackObject),
    on_warning: extern "C" fn(*mut CallbackObject, u32),
    on_warning_ext: extern "C" fn(*mut CallbackObject),
    on_error: extern "C" fn(*mut CallbackObject, u32),
    on_ftp_transfer_result: extern "C" fn(*mut CallbackObject),
    on_remote_transfer_data: extern "C" fn(*mut CallbackObject),
    on_remote_transfer_file: extern "C" fn(*mut CallbackObject, u32, u32, *const u16),
    on_remote_transfer_list_changed: extern "C" fn(*mut CallbackObject, u32, u32, u32),
    rest: [extern "C" fn(*mut CallbackObject); 5],
}

// The unused callbacks take more arguments than `noop` declares: on Windows x64 the caller passes
// them in registers / its own stack area and cleans up, so a callee that ignores them is fine.
extern "C" fn noop(_: *mut CallbackObject) {}

fn sink_of<'a>(this: *mut CallbackObject) -> Option<&'a dyn Sink> {
    // SAFETY: `this` is the CallbackObject we passed to Connect, alive (in its Box) until after
    // ReleaseDevice, which is the last time the SDK may call it.
    unsafe { this.as_ref() }.map(|o| &*o.sink)
}

extern "C" fn on_connected(this: *mut CallbackObject, _version: u32) {
    if let Some(s) = sink_of(this) {
        s.connected();
    }
}
extern "C" fn on_disconnected(this: *mut CallbackObject, error: u32) {
    if let Some(s) = sink_of(this) {
        s.disconnected(error);
    }
}
extern "C" fn on_complete_download(this: *mut CallbackObject, filename: *const u16, _kind: u32) {
    if let Some(s) = sink_of(this) {
        s.downloaded(wide(filename));
    }
}
extern "C" fn on_warning(this: *mut CallbackObject, code: u32) {
    if let Some(s) = sink_of(this) {
        s.warning(code);
    }
}
extern "C" fn on_error(this: *mut CallbackObject, error: u32) {
    if let Some(s) = sink_of(this) {
        s.error(error);
    }
}
extern "C" fn on_remote_transfer_file(this: *mut CallbackObject, notify: u32, percent: u32, filename: *const u16) {
    if let Some(s) = sink_of(this) {
        s.transferred(notify, percent, wide(filename));
    }
}
extern "C" fn on_remote_transfer_list_changed(this: *mut CallbackObject, notify: u32, slot: u32, added: u32) {
    if let Some(s) = sink_of(this) {
        s.contents_changed(notify, slot, added);
    }
}

static VTABLE: VTable = VTable {
    on_connected,
    on_disconnected,
    on_property_changed: noop,
    on_property_changed_codes: noop,
    on_lv_property_changed: noop,
    on_lv_property_changed_codes: noop,
    on_complete_download,
    on_complete_operation: noop,
    on_notify_contents_transfer: noop,
    on_warning,
    on_warning_ext: noop,
    on_error,
    on_ftp_transfer_result: noop,
    on_remote_transfer_data: noop,
    on_remote_transfer_file,
    on_remote_transfer_list_changed,
    rest: [noop as extern "C" fn(*mut CallbackObject); 5],
};

/// The object the SDK calls back: what a C++ `IDeviceCallback` subclass looks like in memory
/// (the table pointer first), plus the sink it forwards to.
#[repr(C)]
pub struct CallbackObject {
    vtable: &'static VTable,
    sink: Arc<dyn Sink>,
}

impl CallbackObject {
    pub fn new(sink: Arc<dyn Sink>) -> Box<CallbackObject> {
        Box::new(CallbackObject { vtable: &VTABLE, sink })
    }

    fn as_ptr(&self) -> *mut c_void {
        self as *const CallbackObject as *mut c_void
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn device_property_layout_matches_the_sdk() {
        assert_eq!(std::mem::size_of::<CrDeviceProperty>(), 64);
        assert_eq!(std::mem::offset_of!(CrDeviceProperty, current_value), 16);
        assert_eq!(std::mem::offset_of!(CrDeviceProperty, values), 40);
    }

    #[test]
    fn callback_table_has_the_sdks_21_slots() {
        assert_eq!(std::mem::size_of::<VTable>(), 21 * std::mem::size_of::<usize>());
        assert_eq!(std::mem::offset_of!(VTable, on_complete_download), 6 * std::mem::size_of::<usize>());
        assert_eq!(std::mem::offset_of!(VTable, on_warning), 9 * std::mem::size_of::<usize>());
        assert_eq!(std::mem::offset_of!(VTable, on_error), 11 * std::mem::size_of::<usize>());
        // checked by calling through an MSVC-built subclass: slot 13 is the data overload, 14 the file one
        assert_eq!(std::mem::offset_of!(VTable, on_remote_transfer_file), 14 * std::mem::size_of::<usize>());
        assert_eq!(std::mem::offset_of!(VTable, on_remote_transfer_list_changed), 15 * std::mem::size_of::<usize>());
        assert_eq!(std::mem::offset_of!(CallbackObject, vtable), 0);
    }

    #[test]
    fn contents_layouts_match_the_sdk() {
        // sizes and offsets printed by an MSVC x64 build against the SDK 2.02 headers
        assert_eq!(std::mem::size_of::<CaptureDate>(), 14);
        assert_eq!(std::mem::size_of::<ContentsInfo>(), 120);
        assert_eq!(std::mem::offset_of!(ContentsInfo, content_id), 4);
        assert_eq!(std::mem::offset_of!(ContentsInfo, file_number), 12);
        assert_eq!(std::mem::offset_of!(ContentsInfo, creation_utc), 26);
        assert_eq!(std::mem::offset_of!(ContentsInfo, modification_local), 68);
        assert_eq!(std::mem::offset_of!(ContentsInfo, rating), 84);
        assert_eq!(std::mem::offset_of!(ContentsInfo, shot_mark_num), 92);
        assert_eq!(std::mem::offset_of!(ContentsInfo, files_num), 104);
        assert_eq!(std::mem::offset_of!(ContentsInfo, files), 112);
        assert_eq!(std::mem::size_of::<ContentsFile>(), 176);
        assert_eq!(std::mem::offset_of!(ContentsFile, file_path_length), 4);
        assert_eq!(std::mem::offset_of!(ContentsFile, file_path), 8);
        assert_eq!(std::mem::offset_of!(ContentsFile, file_format), 16);
        assert_eq!(std::mem::offset_of!(ContentsFile, file_size), 24);
    }

    #[test]
    fn wide_strings_stop_at_nul() {
        let s: Vec<u16> = "ILCE-7M4\0junk".encode_utf16().collect();
        assert_eq!(wide(s.as_ptr()), "ILCE-7M4");
        assert_eq!(wide(std::ptr::null()), "");
    }
}
