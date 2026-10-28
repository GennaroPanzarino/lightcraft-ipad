//! A PTP/IP initiator (CIPA DC-005 / ISO 15740) and the Sony extensions a tether needs, over any
//! byte stream (here: the SSH tunnels of [`crate::ssh`]). All integers are little-endian; every
//! packet is `u32 length (header included), u32 type, payload`.
//!
//! The data phase of a transaction is handed to a sink as it arrives, piece by piece, so a 35 MB
//! raw can be written (and its preview taken out) while it is still on its way.

use std::io::{Read, Write};

pub const INIT_COMMAND_REQUEST: u32 = 1;
pub const INIT_COMMAND_ACK: u32 = 2;
pub const INIT_EVENT_REQUEST: u32 = 3;
pub const INIT_EVENT_ACK: u32 = 4;
pub const INIT_FAIL: u32 = 5;
pub const OPERATION_REQUEST: u32 = 6;
pub const OPERATION_RESPONSE: u32 = 7;
pub const EVENT: u32 = 8;
pub const START_DATA: u32 = 9;
pub const DATA: u32 = 10;
pub const CANCEL: u32 = 11;
pub const END_DATA: u32 = 12;
pub const PROBE_REQUEST: u32 = 13;
pub const PROBE_RESPONSE: u32 = 14;

pub const OP_GET_DEVICE_INFO: u16 = 0x1001;
pub const OP_OPEN_SESSION: u16 = 0x1002;
pub const OP_GET_OBJECT_INFO: u16 = 0x1008;
pub const OP_GET_OBJECT: u16 = 0x1009;
pub const OP_SONY_SDIO_CONNECT: u16 = 0x9201;
pub const OP_SONY_GET_EXT_DEVICE_INFO: u16 = 0x9202;
pub const OP_SONY_SET_PROP: u16 = 0x9205;
pub const OP_SONY_GET_ALL_PROPS: u16 = 0x9209;
pub const OP_SONY_GET_PROP: u16 = 0x9251;
pub const RESP_OK: u16 = 0x2001;

/// Packets above this are refused (a broken stream, not a camera).
const MAX_PACKET: u64 = 1 << 31;

#[derive(Debug)]
pub enum PtpError {
    Io(std::io::Error),
    /// The camera answered the operation with this response code.
    Response { op: u16, code: u16 },
    /// The camera refused the PTP/IP connection (InitFail reason).
    InitFail(u32),
    Protocol(String),
}

impl std::fmt::Display for PtpError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            PtpError::Io(e) => write!(f, "{e}"),
            PtpError::Response { op, code } => write!(f, "operation 0x{op:04X} answered 0x{code:04X}"),
            PtpError::InitFail(r) => write!(f, "the camera refused the PTP/IP connection (0x{r:X})"),
            PtpError::Protocol(m) => write!(f, "{m}"),
        }
    }
}

impl From<std::io::Error> for PtpError {
    fn from(e: std::io::Error) -> Self {
        PtpError::Io(e)
    }
}

pub type Result<T> = std::result::Result<T, PtpError>;

pub fn write_packet(w: &mut impl Write, typ: u32, payload: &[u8]) -> Result<()> {
    let mut b = Vec::with_capacity(8 + payload.len());
    b.extend_from_slice(&((8 + payload.len()) as u32).to_le_bytes());
    b.extend_from_slice(&typ.to_le_bytes());
    b.extend_from_slice(payload);
    w.write_all(&b)?;
    Ok(())
}

fn read_u32(r: &mut impl Read) -> Result<u32> {
    let mut b = [0u8; 4];
    r.read_exact(&mut b)?;
    Ok(u32::from_le_bytes(b))
}

/// A packet's header: (total length, type).
fn read_header(r: &mut impl Read) -> Result<(u64, u32)> {
    let len = u64::from(read_u32(r)?);
    let typ = read_u32(r)?;
    if !(8..=MAX_PACKET).contains(&len) {
        return Err(PtpError::Protocol(format!("bad PTP/IP packet length {len}")));
    }
    Ok((len, typ))
}

/// A whole (small) packet.
pub fn read_packet(r: &mut impl Read) -> Result<(u32, Vec<u8>)> {
    let (len, typ) = read_header(r)?;
    if len > 64 << 20 {
        return Err(PtpError::Protocol(format!("unexpected large packet ({len} bytes, type {typ})")));
    }
    let mut p = vec![0u8; (len - 8) as usize];
    r.read_exact(&mut p)?;
    Ok((typ, p))
}

/// UCS-2LE with a NUL (the init handshake's names).
fn ucs2z(s: &str) -> Vec<u8> {
    s.encode_utf16().chain(std::iter::once(0)).flat_map(u16::to_le_bytes).collect()
}

fn read_ucs2z(b: &[u8]) -> String {
    let units: Vec<u16> = b.chunks_exact(2).map(|c| u16::from_le_bytes([c[0], c[1]])).take_while(|&u| u != 0).collect();
    String::from_utf16_lossy(&units)
}

/// Open the command connection: (connection number, the camera's name).
pub fn init_command(c: &mut (impl Read + Write), guid: &[u8; 16], name: &str) -> Result<(u32, String)> {
    let mut p = guid.to_vec();
    p.extend(ucs2z(name));
    p.extend_from_slice(&0x0001_0000u32.to_le_bytes()); // protocol version 1.0
    write_packet(c, INIT_COMMAND_REQUEST, &p)?;
    let (typ, p) = read_packet(c)?;
    match typ {
        INIT_COMMAND_ACK if p.len() >= 20 => Ok((u32::from_le_bytes([p[0], p[1], p[2], p[3]]), read_ucs2z(&p[20..]))),
        INIT_FAIL => Err(PtpError::InitFail(p.get(..4).map_or(0, |b| u32::from_le_bytes([b[0], b[1], b[2], b[3]])))),
        _ => Err(PtpError::Protocol(format!("unexpected packet {typ} instead of InitCommandAck"))),
    }
}

/// Open the event connection for connection number `conn`.
pub fn init_event(e: &mut (impl Read + Write), conn: u32) -> Result<()> {
    write_packet(e, INIT_EVENT_REQUEST, &conn.to_le_bytes())?;
    let (typ, p) = read_packet(e)?;
    match typ {
        INIT_EVENT_ACK => Ok(()),
        INIT_FAIL => Err(PtpError::InitFail(p.get(..4).map_or(0, |b| u32::from_le_bytes([b[0], b[1], b[2], b[3]])))),
        _ => Err(PtpError::Protocol(format!("unexpected packet {typ} instead of InitEventAck"))),
    }
}

/// An event from the event connection: code and parameters.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Event {
    pub code: u16,
    pub params: Vec<u32>,
}

/// Events in `buf` (bytes read from the event connection so far); what is left of an incomplete
/// packet stays in `buf`. Probe requests are answered through `reply`.
pub fn take_events(buf: &mut Vec<u8>, mut reply: impl FnMut(u32)) -> Vec<Event> {
    let mut out = Vec::new();
    loop {
        if buf.len() < 8 {
            break;
        }
        let len = u32::from_le_bytes([buf[0], buf[1], buf[2], buf[3]]) as usize;
        let typ = u32::from_le_bytes([buf[4], buf[5], buf[6], buf[7]]);
        if len < 8 {
            buf.clear(); // out of step: drop what we have
            break;
        }
        if buf.len() < len {
            break;
        }
        let p: Vec<u8> = buf.drain(..len).skip(8).collect();
        match typ {
            EVENT if p.len() >= 6 => {
                let code = u16::from_le_bytes([p[0], p[1]]);
                let params = p[6..].chunks_exact(4).map(|c| u32::from_le_bytes([c[0], c[1], c[2], c[3]])).collect();
                out.push(Event { code, params });
            }
            PROBE_REQUEST => reply(PROBE_RESPONSE),
            _ => {}
        }
    }
    out
}

/// The command connection of an open PTP/IP session.
pub struct Session<C: Read + Write> {
    pub cmd: C,
    tid: u32,
}

impl<C: Read + Write> Session<C> {
    pub fn new(cmd: C) -> Self {
        Session { cmd, tid: 0 }
    }

    /// Run one operation: `send` is the data phase out (if any); data coming back is handed to
    /// `sink` as it arrives. Returns the response parameters.
    pub fn transaction(&mut self, op: u16, params: &[u32], send: Option<&[u8]>, sink: &mut dyn FnMut(&[u8]) -> std::io::Result<()>) -> Result<Vec<u32>> {
        let tid = if op == OP_OPEN_SESSION {
            self.tid = 0;
            0
        } else {
            self.tid = self.tid.wrapping_add(1);
            self.tid
        };
        let mut req = Vec::with_capacity(10 + 4 * params.len());
        req.extend_from_slice(&(if send.is_some() { 2u32 } else { 1u32 }).to_le_bytes());
        req.extend_from_slice(&op.to_le_bytes());
        req.extend_from_slice(&tid.to_le_bytes());
        for p in params {
            req.extend_from_slice(&p.to_le_bytes());
        }
        write_packet(&mut self.cmd, OPERATION_REQUEST, &req)?;
        if let Some(data) = send {
            let mut start = tid.to_le_bytes().to_vec();
            start.extend_from_slice(&(data.len() as u64).to_le_bytes());
            write_packet(&mut self.cmd, START_DATA, &start)?;
            let mut end = tid.to_le_bytes().to_vec();
            end.extend_from_slice(data);
            write_packet(&mut self.cmd, END_DATA, &end)?;
        }
        let mut buf = vec![0u8; 256 * 1024];
        let mut sink_failed: Option<std::io::Error> = None;
        loop {
            let (len, typ) = read_header(&mut self.cmd)?;
            let mut left = len - 8;
            match typ {
                DATA | END_DATA => {
                    if left < 4 {
                        return Err(PtpError::Protocol("short data packet".into()));
                    }
                    let _tid = read_u32(&mut self.cmd)?;
                    left -= 4;
                    // stream the payload: the sink sees each piece as soon as it is here
                    while left > 0 {
                        let want = left.min(buf.len() as u64) as usize;
                        let n = self.cmd.read(&mut buf[..want])?;
                        if n == 0 {
                            return Err(PtpError::Io(std::io::ErrorKind::UnexpectedEof.into()));
                        }
                        left -= n as u64;
                        if sink_failed.is_none()
                            && let Err(e) = sink(&buf[..n])
                        {
                            sink_failed = Some(e); // keep reading to stay in step with the camera
                        }
                    }
                }
                OPERATION_RESPONSE => {
                    let mut p = vec![0u8; left as usize];
                    self.cmd.read_exact(&mut p)?;
                    if p.len() < 6 {
                        return Err(PtpError::Protocol("short response".into()));
                    }
                    let code = u16::from_le_bytes([p[0], p[1]]);
                    let out = p[6..].chunks_exact(4).map(|c| u32::from_le_bytes([c[0], c[1], c[2], c[3]])).collect();
                    if let Some(e) = sink_failed {
                        return Err(PtpError::Io(e));
                    }
                    if code != RESP_OK {
                        return Err(PtpError::Response { op, code });
                    }
                    return Ok(out);
                }
                PROBE_REQUEST => {
                    skip(&mut self.cmd, left)?;
                    write_packet(&mut self.cmd, PROBE_RESPONSE, &[])?;
                }
                CANCEL => return Err(PtpError::Response { op, code: 0x201F }),
                _ => skip(&mut self.cmd, left)?, // StartData (total length) and anything else
            }
        }
    }

    /// An operation whose data phase (if any) is wanted whole.
    pub fn call(&mut self, op: u16, params: &[u32]) -> Result<(Vec<u32>, Vec<u8>)> {
        let mut data = Vec::new();
        let r = self.transaction(op, params, None, &mut |b| {
            data.extend_from_slice(b);
            Ok(())
        })?;
        Ok((r, data))
    }

    /// An operation sending `data`.
    pub fn send(&mut self, op: u16, params: &[u32], data: &[u8]) -> Result<Vec<u32>> {
        self.transaction(op, params, Some(data), &mut |_| Ok(()))
    }
}

fn skip(r: &mut impl Read, mut n: u64) -> Result<()> {
    let mut b = [0u8; 4096];
    while n > 0 {
        let k = n.min(b.len() as u64) as usize;
        r.read_exact(&mut b[..k])?;
        n -= k as u64;
    }
    Ok(())
}

/// Reads PTP datasets.
pub struct Reader<'a> {
    b: &'a [u8],
    pub off: usize,
    pub bad: bool,
}

impl<'a> Reader<'a> {
    pub fn new(b: &'a [u8]) -> Self {
        Reader { b, off: 0, bad: false }
    }
    fn take(&mut self, n: usize) -> &'a [u8] {
        match self.b.get(self.off..self.off + n) {
            Some(s) if !self.bad => {
                self.off += n;
                s
            }
            _ => {
                self.bad = true;
                &[]
            }
        }
    }
    pub fn u8(&mut self) -> u8 {
        self.take(1).first().copied().unwrap_or(0)
    }
    pub fn u16(&mut self) -> u16 {
        let s = self.take(2);
        if s.len() == 2 { u16::from_le_bytes([s[0], s[1]]) } else { 0 }
    }
    pub fn u32(&mut self) -> u32 {
        let s = self.take(4);
        if s.len() == 4 { u32::from_le_bytes([s[0], s[1], s[2], s[3]]) } else { 0 }
    }
    pub fn u64(&mut self) -> u64 {
        let s = self.take(8);
        if s.len() == 8 { u64::from_le_bytes([s[0], s[1], s[2], s[3], s[4], s[5], s[6], s[7]]) } else { 0 }
    }
    /// PTP string: u8 character count (with the NUL), UCS-2LE.
    pub fn string(&mut self) -> String {
        let n = usize::from(self.u8());
        let s = self.take(2 * n);
        read_ucs2z(s)
    }
    pub fn u16s(&mut self) -> Vec<u16> {
        let n = self.u32() as usize;
        if n > 1 << 20 {
            self.bad = true;
            return Vec::new();
        }
        (0..n).map(|_| self.u16()).collect()
    }
}

/// The parts of PTP DeviceInfo a tether uses.
#[derive(Clone, Debug, Default)]
pub struct DeviceInfo {
    pub vendor_extension: u32,
    pub operations: Vec<u16>,
    pub events: Vec<u16>,
    pub properties: Vec<u16>,
    pub manufacturer: String,
    pub model: String,
    pub version: String,
}

pub fn parse_device_info(b: &[u8]) -> DeviceInfo {
    let mut r = Reader::new(b);
    r.u16(); // standard version
    let vendor_extension = r.u32();
    r.u16(); // vendor extension version
    r.string(); // vendor extension description
    r.u16(); // functional mode
    let operations = r.u16s();
    let events = r.u16s();
    let properties = r.u16s();
    r.u16s(); // capture formats
    r.u16s(); // image formats
    DeviceInfo { vendor_extension, operations, events, properties, manufacturer: r.string(), model: r.string(), version: r.string() }
}

/// The parts of PTP ObjectInfo a tether uses.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ObjectInfo {
    pub format: u16,
    pub size: u32,
    pub filename: String,
}

pub fn parse_object_info(b: &[u8]) -> ObjectInfo {
    let mut r = Reader::new(b);
    r.u32(); // storage
    let format = r.u16();
    r.u16(); // protection
    let size = r.u32();
    r.u16(); // thumb format
    for _ in 0..6 {
        r.u32(); // thumb size, thumb w/h, image w/h, bit depth
    }
    r.u32(); // parent
    r.u16(); // association type
    r.u32(); // association desc
    r.u32(); // sequence number
    ObjectInfo { format, size, filename: r.string() }
}

/// One Sony extended device property: its code, data type, and current value (integers only:
/// strings and arrays are skipped).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SonyProp {
    pub code: u16,
    pub typ: u16,
    pub writable: bool,
    pub enabled: u8,
    pub current: i64,
}

fn scalar_size(t: u16) -> usize {
    match t {
        1 | 2 => 1,
        3 | 4 => 2,
        5 | 6 => 4,
        7 | 8 => 8,
        _ => 0,
    }
}

fn read_value(r: &mut Reader<'_>, t: u16) -> i64 {
    match t {
        0xFFFF => {
            r.string();
            0
        }
        t if t & 0x4000 != 0 && scalar_size(t & !0x4000) != 0 => {
            let n = r.u32() as usize;
            if n > 1 << 16 {
                r.bad = true;
                return 0;
            }
            for _ in 0..n {
                read_value(r, t & !0x4000);
            }
            0
        }
        1 => i64::from(r.u8() as i8),
        2 => i64::from(r.u8()),
        3 => i64::from(r.u16() as i16),
        4 => i64::from(r.u16()),
        5 => i64::from(r.u32() as i32),
        6 => i64::from(r.u32()),
        7 | 8 => r.u64() as i64,
        _ => {
            r.bad = true;
            0
        }
    }
}

fn read_prop(r: &mut Reader<'_>) -> SonyProp {
    let code = r.u16();
    let typ = r.u16();
    let writable = r.u8() == 1;
    let enabled = r.u8();
    read_value(r, typ); // default
    let current = read_value(r, typ);
    match r.u8() {
        1 => {
            for _ in 0..3 {
                read_value(r, typ); // min, max, step
            }
        }
        2 => {
            for _ in 0..2 {
                let m = r.u16();
                for _ in 0..m {
                    read_value(r, typ);
                }
            }
        }
        _ => {}
    }
    SonyProp { code, typ, writable, enabled, current }
}

/// The reply of 0x9209 (all properties, or with 1 the changed ones): u64 count, then entries.
pub fn parse_sony_props(b: &[u8]) -> Vec<SonyProp> {
    let mut r = Reader::new(b);
    let n = r.u64();
    let mut out = Vec::new();
    for _ in 0..n.min(4096) {
        let p = read_prop(&mut r);
        if r.bad {
            break;
        }
        out.push(p);
    }
    out
}

/// The reply of 0x9251 (one property).
pub fn parse_sony_prop(b: &[u8]) -> Option<SonyProp> {
    let mut r = Reader::new(b);
    let p = read_prop(&mut r);
    (!r.bad).then_some(p)
}

/// A property value as the data phase of 0x9205 carries it.
pub fn encode_scalar(t: u16, v: i64) -> Option<Vec<u8>> {
    Some(match scalar_size(t) {
        1 => vec![v as u8],
        2 => (v as u16).to_le_bytes().to_vec(),
        4 => (v as u32).to_le_bytes().to_vec(),
        8 => (v as u64).to_le_bytes().to_vec(),
        _ => return None,
    })
}

#[cfg(test)]
mod tests {
    use std::collections::VecDeque;

    use super::*;

    /// A camera that answers from a script: what it will send, and what it got.
    struct Fake {
        rx: VecDeque<u8>,
        tx: Vec<u8>,
        /// at most this many bytes per read (a slow link)
        step: usize,
    }

    impl Read for Fake {
        fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
            let n = buf.len().min(self.step).min(self.rx.len());
            for b in buf.iter_mut().take(n) {
                *b = self.rx.pop_front().unwrap_or(0);
            }
            Ok(n)
        }
    }
    impl Write for Fake {
        fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
            self.tx.extend_from_slice(buf);
            Ok(buf.len())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

    fn packet(typ: u32, payload: &[u8]) -> Vec<u8> {
        let mut v = Vec::new();
        write_packet(&mut v, typ, payload).unwrap();
        v
    }

    fn response(code: u16, tid: u32, params: &[u32]) -> Vec<u8> {
        let mut p = code.to_le_bytes().to_vec();
        p.extend_from_slice(&tid.to_le_bytes());
        for x in params {
            p.extend_from_slice(&x.to_le_bytes());
        }
        packet(OPERATION_RESPONSE, &p)
    }

    #[test]
    fn the_handshake_reads_the_cameras_name() {
        let mut ack = 7u32.to_le_bytes().to_vec();
        ack.extend_from_slice(&[0xAB; 16]);
        ack.extend(ucs2z("ILCE-7M4"));
        let mut cam = Fake { rx: packet(INIT_COMMAND_ACK, &ack).into(), tx: Vec::new(), step: 3 };
        let (conn, name) = init_command(&mut cam, &[1; 16], "LightCraft").unwrap();
        assert_eq!((conn, name.as_str()), (7, "ILCE-7M4"));
        assert_eq!(u32::from_le_bytes(cam.tx[4..8].try_into().unwrap()), INIT_COMMAND_REQUEST);
        let mut fail = Fake { rx: packet(INIT_FAIL, &1u32.to_le_bytes()).into(), tx: Vec::new(), step: 64 };
        assert!(matches!(init_command(&mut fail, &[1; 16], "x"), Err(PtpError::InitFail(1))));
    }

    #[test]
    fn data_is_streamed_to_the_sink_piece_by_piece() {
        let object: Vec<u8> = (0..300_000u32).map(|i| (i % 251) as u8).collect();
        let mut rx = packet(START_DATA, &[1, 0, 0, 0, 0xE0, 0x93, 4, 0, 0, 0, 0, 0]);
        let mut data = 1u32.to_le_bytes().to_vec();
        data.extend_from_slice(&object[..200_000]);
        rx.extend(packet(DATA, &data));
        let mut end = 1u32.to_le_bytes().to_vec();
        end.extend_from_slice(&object[200_000..]);
        rx.extend(packet(END_DATA, &end));
        rx.extend(response(RESP_OK, 1, &[]));
        let mut s = Session::new(Fake { rx: rx.into(), tx: Vec::new(), step: 10_000 });
        let mut got = Vec::new();
        let mut pieces = 0;
        s.transaction(OP_GET_OBJECT, &[0xFFFF_C001], None, &mut |b| {
            pieces += 1;
            got.extend_from_slice(b);
            Ok(())
        })
        .unwrap();
        assert_eq!(got, object);
        assert!(pieces >= 30, "the sink saw the data as it came, not at the end ({pieces} pieces)");
        // the request: one data-phase flag, the op, transaction 1, the handle
        let req = &s.cmd.tx;
        assert_eq!(u32::from_le_bytes(req[4..8].try_into().unwrap()), OPERATION_REQUEST);
        assert_eq!(u16::from_le_bytes(req[12..14].try_into().unwrap()), OP_GET_OBJECT);
        assert_eq!(u32::from_le_bytes(req[18..22].try_into().unwrap()), 0xFFFF_C001);
    }

    #[test]
    fn errors_and_probes() {
        let mut rx = packet(PROBE_REQUEST, &[]);
        rx.extend(response(0x2019, 1, &[]));
        let mut s = Session::new(Fake { rx: rx.into(), tx: Vec::new(), step: 64 });
        assert!(matches!(s.call(OP_SONY_GET_PROP, &[0xD215]), Err(PtpError::Response { op: OP_SONY_GET_PROP, code: 0x2019 })));
        assert!(s.cmd.tx.windows(4).any(|w| w == PROBE_RESPONSE.to_le_bytes()), "probe answered");
    }

    #[test]
    fn sending_a_value_has_a_data_phase() {
        let mut s = Session::new(Fake { rx: response(RESP_OK, 1, &[]).into(), tx: Vec::new(), step: 64 });
        s.send(OP_SONY_SET_PROP, &[0xD222], &encode_scalar(4, 0x11).unwrap()).unwrap();
        let tx = &s.cmd.tx;
        assert_eq!(u32::from_le_bytes(tx[8..12].try_into().unwrap()), 2, "data phase announced");
        let types: Vec<u32> = {
            let mut v = Vec::new();
            let mut i = 0;
            while i + 8 <= tx.len() {
                let len = u32::from_le_bytes(tx[i..i + 4].try_into().unwrap()) as usize;
                v.push(u32::from_le_bytes(tx[i + 4..i + 8].try_into().unwrap()));
                i += len;
            }
            v
        };
        assert_eq!(types, vec![OPERATION_REQUEST, START_DATA, END_DATA]);
        assert_eq!(&tx[tx.len() - 2..], &[0x11, 0x00]);
    }

    #[test]
    fn events_are_cut_out_of_the_stream() {
        let mut ev = 0xC203u16.to_le_bytes().to_vec();
        ev.extend_from_slice(&0u32.to_le_bytes());
        ev.extend_from_slice(&0xD215u32.to_le_bytes());
        let mut buf = packet(EVENT, &ev);
        buf.extend(packet(PROBE_REQUEST, &[]));
        buf.extend_from_slice(&packet(EVENT, &ev)[..5]); // half of the next one
        let mut probes = 0;
        let got = take_events(&mut buf, |_| probes += 1);
        assert_eq!(got, vec![Event { code: 0xC203, params: vec![0xD215] }]);
        assert_eq!((probes, buf.len()), (1, 5));
    }

    #[test]
    fn sony_properties_parse() {
        // count 2: 0xD215 u16 (default 0, current 0x8001, no form); 0xD222 u16 enum [1, 0x10, 0x11]
        let mut b = 2u64.to_le_bytes().to_vec();
        b.extend_from_slice(&0xD215u16.to_le_bytes());
        b.extend_from_slice(&4u16.to_le_bytes());
        b.extend_from_slice(&[0, 1]);
        b.extend_from_slice(&0u16.to_le_bytes());
        b.extend_from_slice(&0x8001u16.to_le_bytes());
        b.push(0);
        b.extend_from_slice(&0xD222u16.to_le_bytes());
        b.extend_from_slice(&4u16.to_le_bytes());
        b.extend_from_slice(&[1, 1]);
        b.extend_from_slice(&0x11u16.to_le_bytes());
        b.extend_from_slice(&0x10u16.to_le_bytes());
        b.push(2);
        for list in [[1u16, 0x10, 0x11], [1, 0x10, 0x11]] {
            b.extend_from_slice(&3u16.to_le_bytes());
            for v in list {
                b.extend_from_slice(&v.to_le_bytes());
            }
        }
        let props = parse_sony_props(&b);
        assert_eq!(props.len(), 2);
        assert_eq!((props[0].code, props[0].current), (0xD215, 0x8001));
        assert_eq!((props[1].code, props[1].current, props[1].writable), (0xD222, 0x10, true));
    }
}
