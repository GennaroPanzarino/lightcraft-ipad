//! A raw on its way into the save folder already holds the shot as a JPEG: Sony's ARW starts with
//! the camera's own full-size JPEG of it (an ILCE-7M4 ARW: 7008×4672 in its first ~1.77 MB, the
//! sensor data in the next ~33 MB). [`Peeker`] watches the folder while the SDK writes a raw and
//! takes that JPEG out as soon as it has landed, so the shot shows long before its raw is complete.
//!
//! The SDK must never be in the way: the folder is watched through file names and sizes only
//! (which open nothing for reading), and a raw is read twice at most — its first 256 KB, to find
//! where the JPEG is, then the JPEG itself once the file is long enough — each time opened, read
//! and closed at once. If a shot fails to arrive soon after such a read, the peeking stops for good
//! ([`Peeker::suspect`]).

use std::collections::{HashMap, HashSet};
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

/// The start of a raw read to find its JPEG (an ILCE-7M4's directories end at ~140 KB).
const HEAD: usize = 256 * 1024;
/// A raw that doesn't give its JPEG in this long is left alone.
const PATIENCE: Duration = Duration::from_secs(30);
/// A file this long when first seen arrived whole (or had its space set aside): not peeked.
const WHOLE: u64 = 16 * 1024 * 1024;
/// Reads that found the JPEG not written yet: tried again this many times, this far apart.
const RETRIES: u32 = 5;
const RETRY_EVERY: Duration = Duration::from_millis(200);

/// A JPEG taken out of a raw being written.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Peeked {
    /// The preview saved as `<previews>\<stem>.JPG`.
    pub path: PathBuf,
    pub width: u32,
    pub height: u32,
    pub bytes: u64,
    /// The file it came from as the SDK was writing it, and how long it was then.
    pub from: String,
    pub at: u64,
}

enum Stage {
    /// Waiting for the file's first 256 KB.
    Head,
    /// Waiting for the file to reach the end of its JPEG (offset, length, width, height, and the
    /// raw's orientation).
    Jpeg(usize, usize, u32, u32, Option<u16>),
    Done,
}

struct Watch {
    since: Instant,
    stage: Stage,
    /// Don't look into the file before this (after a read that came too early).
    next: Instant,
    tries: u32,
}

/// Watches a folder for raws being written.
pub struct Peeker {
    dir: PathBuf,
    previews: PathBuf,
    /// Files that were there before, or that the SDK reported complete: never looked into.
    known: HashSet<PathBuf>,
    watching: HashMap<PathBuf, Watch>,
    /// When a file being written was last read.
    last_read: Option<Instant>,
    /// Turned off after a shot failed to arrive right after a read.
    off: bool,
}

/// Where the largest JPEG is in the beginning of a raw.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum Located {
    /// Offset, length, width, height.
    At(usize, usize, u32, u32),
    /// The raw's directories go beyond the bytes given.
    Wait,
    /// Not a TIFF-based raw (or one without a JPEG).
    Not,
}

impl Peeker {
    /// Watch `dir`; previews go to `previews`. What is in `dir` now is left alone.
    pub fn new(dir: &Path, previews: &Path) -> Peeker {
        let known = std::fs::read_dir(dir).map(|rd| rd.flatten().map(|e| e.path()).collect()).unwrap_or_default();
        Peeker { dir: dir.to_path_buf(), previews: previews.to_path_buf(), known, watching: HashMap::new(), last_read: None, off: false }
    }

    /// A file the SDK reported complete (it is imported as it is).
    pub fn finished(&mut self, path: &Path) {
        if let Some(w) = self.watching.remove(path)
            && !matches!(w.stage, Stage::Done)
        {
            log::info!("tether: {} complete before its preview was taken out", path.display());
        }
        self.known.insert(path.to_path_buf());
    }

    /// The SDK says a shot didn't arrive: if a raw was read shortly before, stop peeking for good.
    pub fn suspect(&mut self) {
        if !self.off && self.last_read.is_some_and(|t| t.elapsed() < Duration::from_secs(15)) {
            self.off = true;
            log::warn!("tether: a shot failed right after LightCraft read a raw being written: no more early previews");
        }
    }

    pub fn is_off(&self) -> bool {
        self.off
    }

    /// Look at the folder once: the JPEGs of raws being written that have landed since the last look.
    pub fn scan(&mut self) -> Vec<Peeked> {
        if self.off {
            return Vec::new();
        }
        let Ok(rd) = std::fs::read_dir(&self.dir) else { return Vec::new() };
        let mut present = HashSet::new();
        let mut out = Vec::new();
        for entry in rd.flatten() {
            let path = entry.path();
            present.insert(path.clone());
            if self.known.contains(&path) || !entry.file_type().is_ok_and(|t| t.is_file()) {
                continue;
            }
            let name = entry.file_name().to_string_lossy().into_owned();
            // the SDK's raws (also under a temporary name such as DSC08824.ARW.temp): nothing else is touched
            if !name.to_ascii_lowercase().contains(".arw") {
                continue;
            }
            if self.watching.get(&path).is_some_and(|w| matches!(w.stage, Stage::Done) || Instant::now() < w.next) {
                continue;
            }
            // the length, without opening the file for reading
            let Ok(len) = std::fs::metadata(&path).map(|m| m.len()) else { continue };
            let w = self.watching.entry(path.clone()).or_insert_with(|| {
                log::info!("tether: {name} appeared, {len} bytes");
                let stage = if len >= WHOLE { Stage::Done } else { Stage::Head };
                Watch { since: Instant::now(), stage, next: Instant::now(), tries: 0 }
            });
            if matches!(w.stage, Stage::Done) || Instant::now() < w.next {
                continue;
            }
            if w.since.elapsed() > PATIENCE {
                log::info!("tether: no preview out of {name} while it was written");
                w.stage = Stage::Done;
                continue;
            }
            match w.stage {
                Stage::Head if len >= HEAD as u64 => {
                    self.last_read = Some(Instant::now());
                    match read_range(&path, 0, HEAD).map(|head| (locate(&head), orientation(&head))) {
                        Ok((Located::At(o, l, wd, ht), turn)) => w.stage = Stage::Jpeg(o, l, wd, ht, turn),
                        Ok((Located::Not, _)) => {
                            log::info!("tether: no full-size JPEG at the start of {name}");
                            w.stage = Stage::Done;
                        }
                        Ok((Located::Wait, _)) | Err(_) => retry(w, &name),
                    }
                }
                Stage::Jpeg(o, l, wd, ht, turn) if len >= (o + l) as u64 => {
                    self.last_read = Some(Instant::now());
                    match read_range(&path, o, l) {
                        Ok(jpeg) if jpeg.starts_with(&[0xFF, 0xD8]) && jpeg.ends_with(&[0xFF, 0xD9]) => {
                            w.stage = Stage::Done;
                            match self.save(&name, &with_orientation(&jpeg, turn)) {
                                Ok(saved) => {
                                    out.push(Peeked { path: saved, width: wd, height: ht, bytes: l as u64, from: name, at: len })
                                }
                                Err(e) => log::warn!("tether: couldn't save the preview of {name}: {e}"),
                            }
                        }
                        // space set aside but not written yet, or the file is busy
                        _ => retry(w, &name),
                    }
                }
                _ => {}
            }
        }
        // a temporary name renamed away, or a file deleted
        self.watching.retain(|p, _| present.contains(p));
        out
    }

    fn save(&self, name: &str, jpeg: &[u8]) -> std::io::Result<PathBuf> {
        std::fs::create_dir_all(&self.previews)?;
        let path = self.previews.join(format!("{}.JPG", shot_stem(name)));
        let part = path.with_extension("JPG.part");
        std::fs::write(&part, jpeg)?;
        let _ = std::fs::remove_file(&path);
        std::fs::rename(&part, &path)?;
        Ok(path)
    }
}

/// A read that came too early: tried again a little later, a few times at most.
fn retry(w: &mut Watch, name: &str) {
    w.tries += 1;
    if w.tries > RETRIES {
        log::info!("tether: gave up reading the start of {name}");
        w.stage = Stage::Done;
    } else {
        w.next = Instant::now() + RETRY_EVERY;
    }
}

/// `len` bytes of a file from `offset`: opened, read and closed at once.
fn read_range(path: &Path, offset: usize, len: usize) -> std::io::Result<Vec<u8>> {
    let mut f = std::fs::File::open(path)?;
    f.seek(SeekFrom::Start(offset as u64))?;
    let mut b = vec![0u8; len];
    f.read_exact(&mut b)?;
    Ok(b)
}

/// A shot's name from the file the SDK is writing (`DSC08824.ARW`, or a temporary name such as
/// `DSC08824.ARW.temp` / `DSC08824.ARW.1a2b3c4d.tmp`): `DSC08824`.
pub(crate) fn shot_stem(name: &str) -> String {
    let name = name.trim_start_matches('~');
    name.split('.').next().filter(|s| !s.is_empty()).unwrap_or(name).to_string()
}

/// The raw's EXIF orientation (IFD0 tag 0x0112: 1 as shot, 6 / 8 turned for a vertical shot…),
/// from its beginning `b`.
pub(crate) fn orientation(b: &[u8]) -> Option<u16> {
    let le = match b.get(..4)? {
        [0x49, 0x49, 0x2A, 0x00] => true,
        [0x4D, 0x4D, 0x00, 0x2A] => false,
        _ => return None,
    };
    let u16_at = |o: usize| b.get(o..o + 2).map(|s| if le { u16::from_le_bytes([s[0], s[1]]) } else { u16::from_be_bytes([s[0], s[1]]) });
    let u32_at = |o: usize| b.get(o..o + 4).map(|s| if le { u32::from_le_bytes([s[0], s[1], s[2], s[3]]) } else { u32::from_be_bytes([s[0], s[1], s[2], s[3]]) });
    let ifd = u32_at(4)? as usize;
    let n = usize::from(u16_at(ifd)?);
    (0..n).map(|i| ifd + 2 + 12 * i).find(|&e| u16_at(e) == Some(0x0112)).and_then(|e| u16_at(e + 8)).filter(|o| (1..=8).contains(o))
}

/// A raw's JPEG made to show the way the shot was held: an ARW's embedded JPEG has no EXIF of its
/// own (a vertical shot's is stored on its side), so an EXIF block with the raw's orientation goes
/// right after its start-of-image marker. Orientation 1 (or none) leaves it as it is.
pub(crate) fn with_orientation(jpeg: &[u8], orientation: Option<u16>) -> std::borrow::Cow<'_, [u8]> {
    let Some(o) = orientation.filter(|o| (2..=8).contains(o)) else { return jpeg.into() };
    if !jpeg.starts_with(&[0xFF, 0xD8]) {
        return jpeg.into();
    }
    // APP1 "Exif\0\0" + a little-endian TIFF with one IFD entry: Orientation (SHORT) = o
    let mut tiff = vec![0x49, 0x49, 0x2A, 0x00, 8, 0, 0, 0, 1, 0];
    tiff.extend_from_slice(&0x0112u16.to_le_bytes());
    tiff.extend_from_slice(&3u16.to_le_bytes());
    tiff.extend_from_slice(&1u32.to_le_bytes());
    tiff.extend_from_slice(&o.to_le_bytes());
    tiff.extend_from_slice(&[0, 0, 0, 0, 0, 0]); // value padding, then no next IFD
    let len = (2 + 6 + tiff.len()) as u16;
    let mut out = Vec::with_capacity(jpeg.len() + 4 + 6 + tiff.len());
    out.extend_from_slice(&[0xFF, 0xD8, 0xFF, 0xE1]);
    out.extend_from_slice(&len.to_be_bytes());
    out.extend_from_slice(b"Exif\0\0");
    out.extend_from_slice(&tiff);
    out.extend_from_slice(&jpeg[2..]);
    out.into()
}

/// Where the largest JPEG is, from the beginning `b` of a TIFF-based raw (IFD0 and the IFDs
/// chained after it: an ARW's thumbnail, screen preview and full-size JPEG).
pub(crate) fn locate(b: &[u8]) -> Located {
    if b.len() < 8 {
        return Located::Wait;
    }
    let le = match &b[..4] {
        [0x49, 0x49, 0x2A, 0x00] => true,
        [0x4D, 0x4D, 0x00, 0x2A] => false,
        [0, 0, 0, 0] => return Located::Wait, // space set aside, not written yet
        _ => return Located::Not,
    };
    let u16_at = |o: usize| b.get(o..o + 2).map(|s| if le { u16::from_le_bytes([s[0], s[1]]) } else { u16::from_be_bytes([s[0], s[1]]) });
    let u32_at = |o: usize| {
        b.get(o..o + 4).map(|s| if le { u32::from_le_bytes([s[0], s[1], s[2], s[3]]) } else { u32::from_be_bytes([s[0], s[1], s[2], s[3]]) })
    };
    let Some(mut ifd) = u32_at(4).map(|v| v as usize) else { return Located::Wait };
    let mut best: Option<(usize, usize, u32, u32)> = None;
    for _ in 0..8 {
        if ifd == 0 {
            break;
        }
        let Some(n) = u16_at(ifd) else { return Located::Wait };
        let end = ifd + 2 + 12 * usize::from(n) + 4;
        if b.len() < end {
            return Located::Wait;
        }
        let (mut off, mut len, mut w, mut h) = (None, None, 0u32, 0u32);
        for i in 0..usize::from(n) {
            let e = ifd + 2 + 12 * i;
            let (Some(tag), Some(typ)) = (u16_at(e), u16_at(e + 2)) else { return Located::Wait };
            let value = if typ == 3 { u16_at(e + 8).map(u32::from) } else { u32_at(e + 8) };
            let Some(value) = value else { return Located::Wait };
            match tag {
                0x100 => w = value,
                0x101 => h = value,
                0x201 => off = Some(value as usize),
                0x202 => len = Some(value as usize),
                _ => {}
            }
        }
        if let (Some(o), Some(l)) = (off, len)
            && l > best.map_or(0, |b| b.1)
        {
            best = Some((o, l, w, h));
        }
        let Some(next) = u32_at(end - 4) else { return Located::Wait };
        ifd = next as usize;
    }
    match best {
        Some((o, l, w, h)) => Located::At(o, l, w, h),
        None => Located::Not,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A small TIFF like an ARW: IFD0 with a 4-byte "thumbnail", then IFD2 with a full-size "JPEG"
    /// of `big` bytes at `jpeg_at`, then "sensor data".
    fn fake_arw(jpeg_at: usize, big: usize) -> Vec<u8> {
        let mut b = vec![0u8; jpeg_at];
        b[..8].copy_from_slice(&[0x49, 0x49, 0x2A, 0x00, 8, 0, 0, 0]);
        let entry = |b: &mut Vec<u8>, at: usize, tag: u16, typ: u16, v: u32| {
            b[at..at + 2].copy_from_slice(&tag.to_le_bytes());
            b[at + 2..at + 4].copy_from_slice(&typ.to_le_bytes());
            b[at + 4..at + 8].copy_from_slice(&1u32.to_le_bytes());
            b[at + 8..at + 12].copy_from_slice(&v.to_le_bytes());
        };
        // IFD0 at 8: thumbnail at 300 (4 bytes), next IFD at 100
        b[8..10].copy_from_slice(&2u16.to_le_bytes());
        entry(&mut b, 10, 0x201, 4, 300);
        entry(&mut b, 22, 0x202, 4, 4);
        b[34..38].copy_from_slice(&100u32.to_le_bytes());
        // IFD2 at 100: the full-size JPEG
        b[100..102].copy_from_slice(&4u16.to_le_bytes());
        entry(&mut b, 102, 0x100, 3, 7008);
        entry(&mut b, 114, 0x101, 3, 4672);
        entry(&mut b, 126, 0x201, 4, jpeg_at as u32);
        entry(&mut b, 138, 0x202, 4, big as u32);
        b[300..304].copy_from_slice(&[0xFF, 0xD8, 0xFF, 0xD9]);
        b.resize(jpeg_at + big, 0x11);
        b[jpeg_at..jpeg_at + 2].copy_from_slice(&[0xFF, 0xD8]);
        b[jpeg_at + big - 2..].copy_from_slice(&[0xFF, 0xD9]);
        b.resize(jpeg_at + big + 2 * 1024 * 1024, 0x55); // the sensor data
        b
    }

    #[test]
    fn the_full_size_jpeg_is_located_from_the_start_of_the_raw() {
        let arw = fake_arw(HEAD + 1000, 10_000);
        assert_eq!(locate(&arw[..6]), Located::Wait);
        assert_eq!(locate(&arw[..120]), Located::Wait, "IFD2 not all there");
        assert_eq!(locate(&arw[..HEAD]), Located::At(HEAD + 1000, 10_000, 7008, 4672));
        assert_eq!(locate(b"\xFF\xD8\xFF\xE0 a JPEG"), Located::Not);
        assert_eq!(locate(&[0u8; 64]), Located::Wait);
    }

    #[test]
    fn a_vertical_shots_preview_gets_the_raws_orientation() {
        let mut arw = fake_arw(HEAD + 64, 1000);
        // no orientation in the fake: none read, the JPEG left as it is
        assert_eq!(orientation(&arw), None);
        let jpeg = arw[HEAD + 64..HEAD + 64 + 1000].to_vec();
        assert_eq!(with_orientation(&jpeg, None).as_ref(), jpeg.as_slice());
        assert_eq!(with_orientation(&jpeg, Some(1)).as_ref(), jpeg.as_slice());
        // IFD0 gets a third entry: Orientation = 8 (turned left)
        arw[8] = 3;
        arw[34..46].copy_from_slice(&[0x12, 0x01, 3, 0, 1, 0, 0, 0, 8, 0, 0, 0]);
        arw[46..50].copy_from_slice(&100u32.to_le_bytes());
        assert_eq!(orientation(&arw), Some(8));
        let turned = with_orientation(&jpeg, Some(8));
        assert!(turned.starts_with(&[0xFF, 0xD8, 0xFF, 0xE1]));
        assert_eq!(&turned[6..12], b"Exif\0\0");
        let len = usize::from(u16::from_be_bytes([turned[4], turned[5]]));
        let tiff = &turned[12..4 + len];
        assert_eq!(orientation(tiff), Some(8), "the EXIF block reads back");
        assert_eq!(&turned[4 + len..], &jpeg[2..], "then the JPEG as it was");
    }

    /// With a real vertical raw (`LC_TEST_ARW_VERTICAL=…\DSC08932.ARW`).
    #[test]
    fn a_real_vertical_raw_reads_turned() {
        let Some(path) = std::env::var_os("LC_TEST_ARW_VERTICAL") else { return };
        let arw = std::fs::read(path).unwrap();
        let o = orientation(&arw[..HEAD]);
        eprintln!("orientation {o:?}");
        assert!(matches!(o, Some(6 | 8)));
    }

    #[test]
    fn shot_names_survive_temporary_names() {
        assert_eq!(shot_stem("DSC08824.ARW"), "DSC08824");
        assert_eq!(shot_stem("DSC08824.ARW.temp"), "DSC08824");
        assert_eq!(shot_stem("~DSC08824.ARW.1a2b3c4d.tmp"), "DSC08824");
    }

    /// With a real raw (`LC_TEST_ARW=…\DSC08822.ARW`): where its full-size JPEG is.
    #[test]
    fn a_real_raw_has_its_full_size_jpeg_in_its_first_megabytes() {
        let Some(path) = std::env::var_os("LC_TEST_ARW") else { return };
        let arw = std::fs::read(path).unwrap();
        let Located::At(o, l, w, h) = locate(&arw[..HEAD]) else { panic!("not located") };
        eprintln!("preview {w}×{h} ({l} bytes) ends at {} of {} bytes", o + l, arw.len());
        assert!(o + l < 4_000_000);
        assert!(arw[o..o + l].starts_with(&[0xFF, 0xD8]) && arw[o..o + l].ends_with(&[0xFF, 0xD9]));
    }

    #[test]
    fn a_raw_written_bit_by_bit_gives_its_preview_early_with_two_reads() {
        let dir = std::env::temp_dir().join(format!("lc-peek-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("DSC00001.ARW"), fake_arw(HEAD + 100, 100)).unwrap(); // there before: left alone
        std::fs::write(dir.join("DSC00003.JPG"), b"a JPEG the camera sent").unwrap(); // never touched
        let previews = dir.join("previews");
        let mut p = Peeker::new(&dir, &previews);
        let arw = fake_arw(HEAD + 4096, 50_000);
        let target = dir.join("DSC00002.ARW.temp");
        let mut got = Vec::new();
        for n in (0..=arw.len()).step_by(16384).chain([arw.len()]) {
            std::fs::write(&target, &arw[..n]).unwrap();
            got.extend(p.scan());
        }
        assert_eq!(got.len(), 1, "{got:?}");
        assert_eq!(got[0].path, previews.join("DSC00002.JPG"));
        assert_eq!((got[0].width, got[0].height, got[0].bytes), (7008, 4672, 50_000));
        assert!(got[0].at < arw.len() as u64 / 2, "taken out long before the raw was complete");
        assert_eq!(std::fs::read(&got[0].path).unwrap(), arw[HEAD + 4096..HEAD + 4096 + 50_000]);
        // the SDK renames it when complete: nothing more
        std::fs::rename(&target, dir.join("DSC00002.ARW")).unwrap();
        p.finished(&dir.join("DSC00002.ARW"));
        assert!(p.scan().is_empty());
        // a raw that arrives whole is left to the SDK
        std::fs::write(dir.join("DSC00004.ARW"), vec![0x49u8; WHOLE as usize]).unwrap();
        assert!(p.scan().is_empty());
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Watching a raw the SDK holds open for itself alone neither fails nor gets in its way.
    #[cfg(windows)]
    #[test]
    fn watching_doesnt_disturb_a_writer_that_shares_nothing() {
        use std::io::Write;
        use std::os::windows::fs::OpenOptionsExt;
        let dir = std::env::temp_dir().join(format!("lc-peek-excl-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let mut p = Peeker::new(&dir, &dir.join("previews"));
        let path = dir.join("DSC00006.ARW");
        let arw = fake_arw(HEAD + 4096, 50_000);
        // a writer that reopens the file for each piece and lets no one else open it meanwhile
        for (i, piece) in arw.chunks(64 * 1024).enumerate() {
            let mut f = std::fs::OpenOptions::new().create(true).append(true).share_mode(0).open(&path).unwrap_or_else(|e| panic!("piece {i}: {e}"));
            f.write_all(piece).unwrap();
            let _ = p.scan(); // while the writer holds it: the length is read, the content can't be
            drop(f);
            let _ = p.scan();
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_failed_shot_right_after_a_read_turns_peeking_off() {
        let dir = std::env::temp_dir().join(format!("lc-peek-off-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let mut p = Peeker::new(&dir, &dir.join("previews"));
        p.suspect();
        assert!(!p.off, "no read yet: not LightCraft's fault");
        std::fs::write(dir.join("DSC00005.ARW"), &fake_arw(HEAD + 64, 1000)[..HEAD + 10]).unwrap();
        let _ = p.scan();
        p.suspect();
        assert!(p.off);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
