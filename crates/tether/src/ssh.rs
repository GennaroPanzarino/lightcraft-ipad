//! The camera's SSH server (Access Authentication), through the libssh2 Sony ships in `CrAdapter\`
//! (the library the Camera Remote SDK itself uses), loaded at run time. With Access Authentication
//! on, the camera closes its PTP/IP port and only lets an authenticated SSH session forward to it
//! (`direct-tcpip` to `localhost:15740`); [`Ssh`] is that session and [`Channel`] one forwarded
//! connection, read and written like a socket.
//!
//! Like `sdk`, this module is allowed `unsafe` and offers a safe API: the session and its channels
//! are freed on drop, and libssh2 allocates through our own functions (so the answers we hand its
//! keyboard-interactive callback are freed by the allocator that made them). One thread uses a
//! session and its channels at a time.
#![allow(unsafe_code)]

use std::ffi::{CString, c_char, c_int, c_uint, c_void};
use std::io::{Read, Write};
use std::net::{SocketAddr, TcpStream};
use std::os::windows::io::AsRawSocket;
use std::path::Path;
use std::sync::OnceLock;
use std::time::Duration;

use libloading::os::windows::{LOAD_WITH_ALTERED_SEARCH_PATH, Library};

type AllocFn = unsafe extern "C" fn(usize, *mut *mut c_void) -> *mut c_void;
type FreeFn = unsafe extern "C" fn(*mut c_void, *mut *mut c_void);
type ReallocFn = unsafe extern "C" fn(*mut c_void, usize, *mut *mut c_void) -> *mut c_void;
type KbdFn = unsafe extern "C" fn(*const c_char, c_int, *const c_char, c_int, c_int, *const c_void, *mut KbdResponse, *mut *mut c_void);

/// `LIBSSH2_USERAUTH_KBDINT_RESPONSE` (the same in libssh2 1.9 to 1.11).
#[repr(C)]
struct KbdResponse {
    text: *mut c_char,
    length: c_uint,
}

struct Lib {
    _lib: Library,
    version: String,
    session_init: unsafe extern "C" fn(Option<AllocFn>, Option<FreeFn>, Option<ReallocFn>, *mut c_void) -> *mut c_void,
    set_timeout: unsafe extern "C" fn(*mut c_void, std::ffi::c_long),
    set_blocking: unsafe extern "C" fn(*mut c_void, c_int),
    method_pref: unsafe extern "C" fn(*mut c_void, c_int, *const c_char) -> c_int,
    handshake: unsafe extern "C" fn(*mut c_void, usize) -> c_int,
    hostkey_hash: unsafe extern "C" fn(*mut c_void, c_int) -> *const u8,
    userauth_list: unsafe extern "C" fn(*mut c_void, *const c_char, c_uint) -> *const c_char,
    userauth_password: unsafe extern "C" fn(*mut c_void, *const c_char, c_uint, *const c_char, c_uint, *const c_void) -> c_int,
    userauth_kbd: unsafe extern "C" fn(*mut c_void, *const c_char, c_uint, KbdFn) -> c_int,
    last_error: unsafe extern "C" fn(*mut c_void, *mut *mut c_char, *mut c_int, c_int) -> c_int,
    direct_tcpip: unsafe extern "C" fn(*mut c_void, *const c_char, c_int, *const c_char, c_int) -> *mut c_void,
    read: unsafe extern "C" fn(*mut c_void, c_int, *mut u8, usize) -> isize,
    write: unsafe extern "C" fn(*mut c_void, c_int, *const u8, usize) -> isize,
    channel_free: unsafe extern "C" fn(*mut c_void) -> c_int,
    disconnect: unsafe extern "C" fn(*mut c_void, c_int, *const c_char, *const c_char) -> c_int,
    session_free: unsafe extern "C" fn(*mut c_void) -> c_int,
}

static LIB: OnceLock<Result<Lib, String>> = OnceLock::new();

/// Sony's libssh2 from `<sdk_dir>\CrAdapter` (the original when a tracing stand-in sits in its place).
fn lib(sdk_dir: &Path) -> Result<&'static Lib, String> {
    LIB.get_or_init(|| load(sdk_dir)).as_ref().map_err(Clone::clone)
}

fn load(sdk_dir: &Path) -> Result<Lib, String> {
    let dir = sdk_dir.join("CrAdapter");
    let path = [dir.join("libssh2_sony.dll"), dir.join("libssh2.dll")].into_iter().find(|p| p.is_file()).ok_or("libssh2 not found in CrAdapter")?;
    // SAFETY: Sony's libssh2 build, installed with the SDK; its initialization only sets up OpenSSL.
    let lib = unsafe { Library::load_with_flags(&path, LOAD_WITH_ALTERED_SEARCH_PATH) }.map_err(|e| format!("libssh2: {e}"))?;
    // SAFETY: each symbol is a libssh2 1.x export with exactly this C signature (libssh2.h); the
    // pointers are copied out and stay valid because `Lib` keeps the library loaded.
    unsafe {
        macro_rules! sym {
            ($name:literal) => {
                *lib.get(concat!($name, "\0").as_bytes()).map_err(|e| format!("libssh2: {} missing: {e}", $name))?
            };
        }
        let init: unsafe extern "C" fn(c_int) -> c_int = sym!("libssh2_init");
        let version: unsafe extern "C" fn(c_int) -> *const c_char = sym!("libssh2_version");
        if init(0) != 0 {
            return Err("libssh2 didn't start".into());
        }
        let v = version(0);
        let version = if v.is_null() { String::new() } else { std::ffi::CStr::from_ptr(v).to_string_lossy().into_owned() };
        Ok(Lib {
            version,
            session_init: sym!("libssh2_session_init_ex"),
            set_timeout: sym!("libssh2_session_set_timeout"),
            set_blocking: sym!("libssh2_session_set_blocking"),
            method_pref: sym!("libssh2_session_method_pref"),
            handshake: sym!("libssh2_session_handshake"),
            hostkey_hash: sym!("libssh2_hostkey_hash"),
            userauth_list: sym!("libssh2_userauth_list"),
            userauth_password: sym!("libssh2_userauth_password_ex"),
            userauth_kbd: sym!("libssh2_userauth_keyboard_interactive_ex"),
            last_error: sym!("libssh2_session_last_error"),
            direct_tcpip: sym!("libssh2_channel_direct_tcpip_ex"),
            read: sym!("libssh2_channel_read_ex"),
            write: sym!("libssh2_channel_write_ex"),
            channel_free: sym!("libssh2_channel_free"),
            disconnect: sym!("libssh2_session_disconnect_ex"),
            session_free: sym!("libssh2_session_free"),
            _lib: lib,
        })
    }
}

// libssh2 allocates through these: a 16-byte header keeps each block's size for `dealloc`.
const HEADER: usize = 16;

fn layout(size: usize) -> Option<std::alloc::Layout> {
    std::alloc::Layout::from_size_align(size.checked_add(HEADER)?, HEADER).ok()
}

unsafe extern "C" fn ssh_alloc(count: usize, _: *mut *mut c_void) -> *mut c_void {
    let Some(l) = layout(count) else { return std::ptr::null_mut() };
    // SAFETY: `l` has a non-zero size; the header is written inside the block.
    unsafe {
        let base = std::alloc::alloc(l);
        if base.is_null() {
            return std::ptr::null_mut();
        }
        (base as *mut usize).write(count);
        base.add(HEADER) as *mut c_void
    }
}

unsafe extern "C" fn ssh_free(ptr: *mut c_void, _: *mut *mut c_void) {
    if ptr.is_null() {
        return;
    }
    // SAFETY: `ptr` came from ssh_alloc / ssh_realloc, so its header holds the size it was made with.
    unsafe {
        let base = (ptr as *mut u8).sub(HEADER);
        if let Some(l) = layout((base as *const usize).read()) {
            std::alloc::dealloc(base, l);
        }
    }
}

unsafe extern "C" fn ssh_realloc(ptr: *mut c_void, count: usize, a: *mut *mut c_void) -> *mut c_void {
    if ptr.is_null() {
        // SAFETY: as ssh_alloc.
        return unsafe { ssh_alloc(count, a) };
    }
    // SAFETY: as ssh_free; the new block gets the new size in its header.
    unsafe {
        let base = (ptr as *mut u8).sub(HEADER);
        let (Some(old), Some(_)) = (layout((base as *const usize).read()), layout(count)) else { return std::ptr::null_mut() };
        let new = std::alloc::realloc(base, old, count + HEADER);
        if new.is_null() {
            return std::ptr::null_mut();
        }
        (new as *mut usize).write(count);
        new.add(HEADER) as *mut c_void
    }
}

/// What the keyboard-interactive callback answers (the session's "abstract" pointer).
struct Context {
    password: Vec<u8>,
}

/// Answers every prompt with the password (the camera asks for it once).
unsafe extern "C" fn kbd_answer(
    _name: *const c_char,
    _name_len: c_int,
    _instruction: *const c_char,
    _instruction_len: c_int,
    prompts: c_int,
    _prompt: *const c_void,
    responses: *mut KbdResponse,
    abstract_: *mut *mut c_void,
) {
    // SAFETY: libssh2 passes `prompts` response slots and the abstract pointer given to
    // session_init (a live `Context`); each answer is a block from ssh_alloc, freed by libssh2.
    unsafe {
        let ctx = (*abstract_) as *const Context;
        if ctx.is_null() || responses.is_null() {
            return;
        }
        let pw = &(*ctx).password;
        for i in 0..prompts.max(0) as usize {
            let p = ssh_alloc(pw.len().max(1), std::ptr::null_mut()) as *mut u8;
            if p.is_null() {
                continue;
            }
            std::ptr::copy_nonoverlapping(pw.as_ptr(), p, pw.len());
            let r = &mut *responses.add(i);
            r.text = p as *mut c_char;
            r.length = pw.len() as c_uint;
        }
    }
}

const ERROR_EAGAIN: isize = -37;
const ERROR_TIMEOUT: isize = -9;
const ERROR_AUTHENTICATION_FAILED: c_int = -18;
const HOSTKEY_HASH_SHA256: c_int = 3;
const METHOD_HOSTKEY: c_int = 1;
const METHOD_CRYPT_CS: c_int = 2;
const METHOD_CRYPT_SC: c_int = 3;
const METHOD_MAC_CS: c_int = 4;
const METHOD_MAC_SC: c_int = 5;

/// An authenticated SSH session with the camera.
pub struct Ssh {
    lib: &'static Lib,
    session: *mut c_void,
    _ctx: Box<Context>,
    _sock: TcpStream,
}

/// Why connecting failed.
#[derive(Debug)]
pub enum SshError {
    /// Nothing answers on the camera's SSH port.
    Unreachable(String),
    /// The host key isn't the paired camera's.
    Fingerprint { got: String },
    /// User or password refused.
    Auth(String),
    Other(String),
}

/// Standard base64 with padding (how the SDK and the pairing write the fingerprint).
pub fn base64(b: &[u8]) -> String {
    const A: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut s = String::with_capacity(b.len().div_ceil(3) * 4);
    for c in b.chunks(3) {
        let n = (u32::from(c[0]) << 16) | (u32::from(*c.get(1).unwrap_or(&0)) << 8) | u32::from(*c.get(2).unwrap_or(&0));
        for (i, shift) in [18, 12, 6, 0].into_iter().enumerate() {
            if i <= c.len() {
                s.push(char::from(A[((n >> shift) & 63) as usize]));
            } else {
                s.push('=');
            }
        }
    }
    s
}

fn norm_fingerprint(s: &str) -> String {
    s.trim().trim_start_matches("SHA256:").trim_end_matches('=').to_string()
}

impl Ssh {
    /// Connect to the camera's SSH server at `addr`, check its host key against `fingerprint`
    /// (base64 SHA-256, as the camera shows it) before sending anything, and log in.
    pub fn connect(sdk_dir: &Path, addr: SocketAddr, user: &str, password: &str, fingerprint: &str) -> Result<Ssh, SshError> {
        let lib = lib(sdk_dir).map_err(SshError::Other)?;
        let sock = TcpStream::connect_timeout(&addr, Duration::from_secs(4)).map_err(|e| SshError::Unreachable(e.to_string()))?;
        let _ = sock.set_nodelay(true);
        let mut ctx = Box::new(Context { password: password.as_bytes().to_vec() });
        // SAFETY: our allocation functions and a context that outlives the session (kept in `Ssh`).
        let session = unsafe { (lib.session_init)(Some(ssh_alloc), Some(ssh_free), Some(ssh_realloc), &mut *ctx as *mut Context as *mut c_void) };
        if session.is_null() {
            return Err(SshError::Other("libssh2 couldn't make a session".into()));
        }
        let ssh = Ssh { lib, session, _ctx: ctx, _sock: sock };
        // SAFETY: a live session; the strings are NUL-terminated literals.
        unsafe {
            (lib.set_timeout)(session, 25_000);
            // what Sony's SDK asks for (the camera's own choices: AES-128-CTR is cheap for it)
            (lib.method_pref)(session, METHOD_HOSTKEY, c"ecdsa-sha2-nistp256,ssh-ed25519,rsa-sha2-256,ssh-rsa".as_ptr());
            for t in [METHOD_CRYPT_CS, METHOD_CRYPT_SC] {
                (lib.method_pref)(session, t, c"aes128-ctr,aes128-cbc,aes256-ctr".as_ptr());
            }
            for t in [METHOD_MAC_CS, METHOD_MAC_SC] {
                (lib.method_pref)(session, t, c"hmac-sha2-256,hmac-sha1".as_ptr());
            }
        }
        // SAFETY: the socket stays open in `ssh` for the session's life.
        let r = unsafe { (lib.handshake)(session, ssh._sock.as_raw_socket() as usize) };
        if r != 0 {
            return Err(SshError::Other(format!("SSH handshake failed: {}", ssh.last_error())));
        }
        // SAFETY: libssh2 returns 32 bytes for SHA-256 (or NULL), owned by the session.
        let got = unsafe {
            let h = (lib.hostkey_hash)(session, HOSTKEY_HASH_SHA256);
            if h.is_null() {
                return Err(SshError::Other("the camera's SSH key couldn't be read".into()));
            }
            base64(std::slice::from_raw_parts(h, 32))
        };
        if norm_fingerprint(&got) != norm_fingerprint(fingerprint) {
            return Err(SshError::Fingerprint { got });
        }
        let u = CString::new(user).map_err(|_| SshError::Auth("bad user name".into()))?;
        // SAFETY: NUL-terminated user and the password bytes, read during the calls.
        unsafe {
            let list = (lib.userauth_list)(session, u.as_ptr(), user.len() as c_uint);
            let methods = if list.is_null() { String::new() } else { std::ffi::CStr::from_ptr(list).to_string_lossy().into_owned() };
            log::info!("tether: camera SSH (libssh2 {}) offers {methods}", lib.version);
            let mut ok = false;
            if methods.contains("password") {
                ok = (lib.userauth_password)(session, u.as_ptr(), user.len() as c_uint, password.as_ptr() as *const c_char, password.len() as c_uint, std::ptr::null()) == 0;
            }
            if !ok && methods.contains("keyboard-interactive") {
                ok = (lib.userauth_kbd)(session, u.as_ptr(), user.len() as c_uint, kbd_answer) == 0;
            }
            if !ok {
                // only a refusal is about the user and password; a timeout or a dropped link while
                // logging in is a connection that failed (tried again at once)
                let (code, text) = ssh.error();
                return Err(if code == ERROR_AUTHENTICATION_FAILED { SshError::Auth(text) } else { SshError::Other(format!("SSH login: {text}")) });
            }
        }
        Ok(ssh)
    }

    fn last_error(&self) -> String {
        self.error().1
    }

    /// libssh2's last error: its code, and the code with its message.
    fn error(&self) -> (c_int, String) {
        let mut msg: *mut c_char = std::ptr::null_mut();
        let mut len: c_int = 0;
        // SAFETY: want_buf 0: libssh2 points `msg` at its own buffer, valid until the next call.
        unsafe {
            let code = (self.lib.last_error)(self.session, &mut msg, &mut len, 0);
            let text = if msg.is_null() { String::new() } else { std::ffi::CStr::from_ptr(msg).to_string_lossy().into_owned() };
            (code, format!("{text} ({code})"))
        }
    }

    /// A forwarded connection to `host:port` as the camera sees it (`localhost:15740`).
    pub fn channel(&self, host: &str, port: u16) -> Result<Channel<'_>, String> {
        let h = CString::new(host).map_err(|e| e.to_string())?;
        // SAFETY: a live session; NUL-terminated strings read during the call.
        let ch = unsafe { (self.lib.direct_tcpip)(self.session, h.as_ptr(), c_int::from(port), c"127.0.0.1".as_ptr(), 0) };
        if ch.is_null() {
            return Err(format!("the camera refused the tunnel to {host}:{port}: {}", self.last_error()));
        }
        Ok(Channel { ssh: self, ch })
    }

    fn blocking(&self, on: bool) {
        // SAFETY: a live session.
        unsafe { (self.lib.set_blocking)(self.session, c_int::from(on)) }
    }
}

impl Drop for Ssh {
    fn drop(&mut self) {
        // SAFETY: the channels borrow `self`, so they are gone; the session is freed once.
        unsafe {
            self.blocking(true);
            (self.lib.disconnect)(self.session, 11, c"LightCraft".as_ptr(), c"".as_ptr());
            (self.lib.session_free)(self.session);
        }
    }
}

/// One forwarded connection (blocking reads and writes, with the session's 25 s timeout: a weak
/// Wi-Fi pauses a transfer for seconds at a time, and giving up on the connection then would lose
/// the shots queued in the camera, which forgets them with the session).
pub struct Channel<'a> {
    ssh: &'a Ssh,
    ch: *mut c_void,
}

impl Channel<'_> {
    /// Whatever has arrived, without waiting (`Ok(0)`: nothing yet).
    pub fn read_now(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        self.ssh.blocking(false);
        // SAFETY: a live channel and a writable buffer of `buf.len()` bytes.
        let n = unsafe { (self.ssh.lib.read)(self.ch, 0, buf.as_mut_ptr(), buf.len()) };
        self.ssh.blocking(true);
        match n {
            n if n >= 0 => Ok(n as usize),
            ERROR_EAGAIN => Ok(0),
            e => Err(std::io::Error::other(format!("SSH read failed ({e})"))),
        }
    }
}

impl Read for Channel<'_> {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        // SAFETY: a live channel and a writable buffer of `buf.len()` bytes.
        let n = unsafe { (self.ssh.lib.read)(self.ch, 0, buf.as_mut_ptr(), buf.len()) };
        match n {
            n if n >= 0 => Ok(n as usize),
            ERROR_TIMEOUT => Err(std::io::Error::new(std::io::ErrorKind::TimedOut, "the camera stopped answering")),
            e => Err(std::io::Error::other(format!("SSH read failed ({e})"))),
        }
    }
}

impl Write for Channel<'_> {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        // SAFETY: a live channel and `buf.len()` readable bytes.
        let n = unsafe { (self.ssh.lib.write)(self.ch, 0, buf.as_ptr(), buf.len()) };
        match n {
            n if n >= 0 => Ok(n as usize),
            ERROR_TIMEOUT => Err(std::io::Error::new(std::io::ErrorKind::TimedOut, "the camera stopped answering")),
            e => Err(std::io::Error::other(format!("SSH write failed ({e})"))),
        }
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

impl Drop for Channel<'_> {
    fn drop(&mut self) {
        // SAFETY: a channel of a live session, freed once.
        unsafe {
            (self.ssh.lib.channel_free)(self.ch);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn base64_matches_the_standard() {
        assert_eq!(base64(b""), "");
        assert_eq!(base64(b"f"), "Zg==");
        assert_eq!(base64(b"fo"), "Zm8=");
        assert_eq!(base64(b"foo"), "Zm9v");
        assert_eq!(base64(&[0xF6, 0x8D, 0x74, 0x46, 0x6A, 0x23]), "9o10Rmoj");
    }

    #[test]
    fn fingerprints_compare_without_prefix_or_padding() {
        assert_eq!(norm_fingerprint("SHA256:9o10Rmoj="), norm_fingerprint("9o10Rmoj"));
    }

    #[test]
    fn the_allocator_round_trips() {
        // SAFETY: blocks from our own allocator, freed by it.
        unsafe {
            let p = ssh_alloc(10, std::ptr::null_mut()) as *mut u8;
            assert!(!p.is_null());
            p.write_bytes(7, 10);
            let q = ssh_realloc(p as *mut c_void, 1000, std::ptr::null_mut()) as *mut u8;
            assert_eq!(*q.add(9), 7);
            ssh_free(q as *mut c_void, std::ptr::null_mut());
            ssh_free(std::ptr::null_mut(), std::ptr::null_mut());
        }
    }
}
