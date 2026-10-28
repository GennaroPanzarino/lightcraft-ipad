//! The computer's Wi-Fi, through Windows' `netsh` (run without a window): which network it is on,
//! and joining the camera's network again after the link dropped. Only ever when the Wi-Fi is on
//! no network at all: a computer the user put on another network stays there.

use std::os::windows::process::CommandExt;
use std::process::Command;

const NO_WINDOW: u32 = 0x0800_0000;

fn netsh(args: &[&str]) -> Option<String> {
    let out = Command::new("netsh").args(args).creation_flags(NO_WINDOW).output().ok()?;
    Some(String::from_utf8_lossy(&out.stdout).into_owned())
}

/// The network the Wi-Fi is on: its SSID and the saved profile it was joined with; `None` when it
/// isn't on any.
pub fn current() -> Option<(String, String)> {
    parse_interfaces(&netsh(&["wlan", "show", "interfaces"])?)
}

/// `netsh wlan show interfaces`, in any language: the SSID line (an SSID may hold colons) and the
/// profile line (Profile / Profilo / Profil / Perfil…).
pub(crate) fn parse_interfaces(text: &str) -> Option<(String, String)> {
    let mut ssid = None;
    let mut profile = None;
    for line in text.lines() {
        let Some((k, v)) = line.split_once(':') else { continue };
        let (k, v) = (k.trim(), v.trim());
        if v.is_empty() {
            continue;
        }
        if k == "SSID" && ssid.is_none() {
            ssid = Some(v.to_string());
        } else if (k.starts_with("Profil") || k.starts_with("Perfil")) && profile.is_none() {
            profile = Some(v.to_string());
        }
    }
    let ssid = ssid?;
    let profile = profile.unwrap_or_else(|| ssid.clone());
    Some((ssid, profile))
}

/// Whether Windows sees the network `ssid` around (its last scan: `netsh wlan show networks`).
pub fn visible(ssid: &str) -> bool {
    netsh(&["wlan", "show", "networks"]).is_some_and(|t| parse_visible(&t, ssid))
}

/// `SSID 1 : name` lines (any language: the key starts with "SSID", and an SSID may hold colons).
pub(crate) fn parse_visible(text: &str, ssid: &str) -> bool {
    text.lines().filter_map(|l| l.split_once(':')).any(|(k, v)| k.trim_start().starts_with("SSID") && v.trim() == ssid)
}

/// Ask Windows to join the network of a saved profile. `true` when netsh took the request.
pub fn join(profile: &str) -> bool {
    Command::new("netsh")
        .args(["wlan", "connect", &format!("name={profile}")])
        .creation_flags(NO_WINDOW)
        .output()
        .is_ok_and(|o| o.status.success())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_network_is_read_in_italian_and_english() {
        let it = "    Nome                   : Wi-Fi\n    Stato                  : connessa\n    SSID                   : DIRECT-F5U1:ILCE-7M4\n    BSSID AP               : de:fe:23:e9:dd:95\n    Profilo                : DIRECT-F5U1:ILCE-7M4 \n";
        assert_eq!(parse_interfaces(it), Some(("DIRECT-F5U1:ILCE-7M4".into(), "DIRECT-F5U1:ILCE-7M4".into())));
        let en = "    Name                   : Wi-Fi\n    State                  : connected\n    SSID                   : Home\n    BSSID                  : b0:95:75:a9:a6:0a\n    Profile                : Home 2\n";
        assert_eq!(parse_interfaces(en), Some(("Home".into(), "Home 2".into())));
        let off = "    Nome                   : Wi-Fi\n    Stato                  : disconnessa\n";
        assert_eq!(parse_interfaces(off), None);
    }

    #[test]
    fn the_cameras_network_is_found_among_those_around() {
        let t = "Nome interfaccia: Wi-Fi \n2 reti visibili. \n\nSSID 1 : Home&Life_EXT\n    Tipo di rete : Infrastruttura\nSSID 2 : DIRECT-F5U1:ILCE-7M4\n";
        assert!(parse_visible(t, "DIRECT-F5U1:ILCE-7M4"));
        assert!(!parse_visible(t, "DIRECT-XXXX:ILCE-7M4"));
    }
}
