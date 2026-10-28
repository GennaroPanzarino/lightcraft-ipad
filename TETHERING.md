# Tethered capture (personal fork)

This branch (`tethering`, based on `v0.13.0`) adds tethered capture from a Sony camera over the
camera's own Wi-Fi (Wi-Fi Direct, remote shooting from the computer), through Sony's Camera Remote
SDK. Each shot is kept on the card, sent to the computer, imported into the day's album
(`Tethering YYYY-MM-DD`) with the tether preset, and shown large. Tested camera: ILCE-7M4 (α7 IV).

It is not part of LightCraft: it uses a C/C++ SDK (`unsafe` FFI), which the upstream project rules
out (`AGENTS.md`: pure Rust, `unsafe` only in `crates/sysmem`). Personal use only; Sony's SDK has
its own licence and is not committed here.

## What it adds

| Where | What |
|---|---|
| `crates/tether` (L0) | The SDK through its C ABI, loaded at run time (`sdk.rs`, the crate's only `unsafe`), and the safe worker: find the camera (SDK search, else 192.168.122.1 + ARP), connect with the access authentication (user, password, SSH fingerprint), keep shots on card + computer, Preview (2 MP JPEG) / Full Size (raw), retry after drops |
| `crates/engine/src/tether.rs`, `cmd/tether.rs` | Settings in `%APPDATA%\LightCraft\tether.json`, the running tether, and the commands `tether.start`, `tether.stop`, `tether.status`, `tether.mode`, `tether.settings`, `tether.pairing` |
| `crates/ui-egui/src/tether.rs` | The Tethered Capture bar over the photo and the Tethered Capture window (pairing, mode, preset, folder); imports the shots as they arrive |
| `crates/ui-egui/src/import.rs` | `ImportTask::tethered`: the newest shot becomes the active photo, in Detail view |
| `crates/ui-egui/src/menus.rs` | File ▸ Tethered Capture ▸ Tethered Capture Settings… |

Menus: File ▸ Tethered Capture ▸ Start / Stop Tethered Capture, Tethered Capture Settings….

## Build and install

Needs Rust (MSVC toolchain) and the Visual Studio Build Tools (C++).

    cargo build --release -p lightcraft

The Sony SDK looks for its modules (`CrAdapter\`) beside the running executable, so the install
folder holds `lightcraft.exe` with `Cr_Core.dll`, `monitor_protocol.dll`, `monitor_protocol_pf.dll`
and `CrAdapter\` from the SDK's `external\crsdk` folder. `install-tethering.ps1` builds that folder
and the desktop shortcut.

## Updating to a new LightCraft release

    git fetch origin --tags
    git rebase vX.Y.Z        # or: git merge vX.Y.Z
    cargo build --release -p lightcraft

The changes to upstream files are small (a field and two calls in `ui-egui/src/lib.rs`, the
tethered branch in `import.rs`, one menu entry, the `tether` field and module in the engine), so
conflicts, if any, are local.
