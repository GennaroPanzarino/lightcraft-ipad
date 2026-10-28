//! Our presets → camera-raw-settings (`crs:`) XMP presets: the inverse of [`crate::crs::to_partial`]
//! for every field it maps, so a preset made here imports into Lightroom (Classic and the cloud
//! apps) and Camera Raw, and comes back here unchanged (`preset.import`).
//!
//! Only what a preset sets is written (presets are partial: Lightroom leaves the other sliders as
//! they are). Profiles, masks and spots are ours and stay out; a crop is written only when the
//! preset carries one.

use lightcraft_develop::{MIXER_BANDS, Preset};
use serde_json::Value;

/// Band names as they appear in `crs:` field names, in our mixer order.
const CRS_BANDS: [&str; 8] = ["Red", "Orange", "Yellow", "Green", "Aqua", "Blue", "Purple", "Magenta"];

/// How a value is written: Lightroom's sliders are whole numbers except a few.
#[derive(Clone, Copy)]
enum Fmt {
    /// −100..100 and the like: `+14`, `-7`, `0`.
    Signed,
    /// 0..100 and hues: `40`.
    Plain,
    /// Two decimals, signed (Exposure): `+0.65`.
    Exposure,
    /// One decimal, signed (Sharpen radius, perspective rotate / offsets): `+1.0`.
    Tenths,
}

/// (`crs:` field, our settings path, format) — the plain one-to-one fields of `to_partial`.
const FIELDS: &[(&str, &str, Fmt)] = &[
    ("Exposure2012", "light.exposure", Fmt::Exposure),
    ("Contrast2012", "light.contrast", Fmt::Signed),
    ("Highlights2012", "light.highlights", Fmt::Signed),
    ("Shadows2012", "light.shadows", Fmt::Signed),
    ("Whites2012", "light.whites", Fmt::Signed),
    ("Blacks2012", "light.blacks", Fmt::Signed),
    ("Texture", "effects.texture", Fmt::Signed),
    ("Clarity2012", "effects.clarity", Fmt::Signed),
    ("Dehaze", "effects.dehaze", Fmt::Signed),
    ("Vibrance", "color.vibrance", Fmt::Signed),
    ("Saturation", "color.saturation", Fmt::Signed),
    ("ParametricShadows", "curve.shadows", Fmt::Signed),
    ("ParametricDarks", "curve.darks", Fmt::Signed),
    ("ParametricLights", "curve.lights", Fmt::Signed),
    ("ParametricHighlights", "curve.highlights", Fmt::Signed),
    ("ParametricShadowSplit", "curve.split_shadows", Fmt::Plain),
    ("ParametricMidtoneSplit", "curve.split_mid", Fmt::Plain),
    ("ParametricHighlightSplit", "curve.split_highlights", Fmt::Plain),
    ("CurveRefineSaturation", "curve.refine_saturation", Fmt::Plain),
    ("SplitToningShadowHue", "grading.shadows.hue", Fmt::Plain),
    ("SplitToningShadowSaturation", "grading.shadows.sat", Fmt::Plain),
    ("ColorGradeShadowLum", "grading.shadows.lum", Fmt::Signed),
    ("SplitToningHighlightHue", "grading.highlights.hue", Fmt::Plain),
    ("SplitToningHighlightSaturation", "grading.highlights.sat", Fmt::Plain),
    ("ColorGradeHighlightLum", "grading.highlights.lum", Fmt::Signed),
    ("ColorGradeMidtoneHue", "grading.midtones.hue", Fmt::Plain),
    ("ColorGradeMidtoneSat", "grading.midtones.sat", Fmt::Plain),
    ("ColorGradeMidtoneLum", "grading.midtones.lum", Fmt::Signed),
    ("ColorGradeGlobalHue", "grading.global.hue", Fmt::Plain),
    ("ColorGradeGlobalSat", "grading.global.sat", Fmt::Plain),
    ("ColorGradeGlobalLum", "grading.global.lum", Fmt::Signed),
    ("ColorGradeBlending", "grading.blending", Fmt::Plain),
    ("SplitToningBalance", "grading.balance", Fmt::Signed),
    ("Sharpness", "detail.sharpen_amount", Fmt::Plain),
    ("SharpenRadius", "detail.sharpen_radius", Fmt::Tenths),
    ("SharpenDetail", "detail.sharpen_detail", Fmt::Plain),
    ("SharpenEdgeMasking", "detail.sharpen_masking", Fmt::Plain),
    ("LuminanceSmoothing", "detail.nr_luminance", Fmt::Plain),
    ("LuminanceNoiseReductionDetail", "detail.nr_detail", Fmt::Plain),
    ("LuminanceNoiseReductionContrast", "detail.nr_contrast", Fmt::Plain),
    ("ColorNoiseReduction", "detail.nr_color", Fmt::Plain),
    ("ColorNoiseReductionDetail", "detail.nr_color_detail", Fmt::Plain),
    ("ColorNoiseReductionSmoothness", "detail.nr_color_smoothness", Fmt::Plain),
    ("PostCropVignetteAmount", "vignette.amount", Fmt::Signed),
    ("PostCropVignetteMidpoint", "vignette.midpoint", Fmt::Plain),
    ("PostCropVignetteRoundness", "vignette.roundness", Fmt::Signed),
    ("PostCropVignetteFeather", "vignette.feather", Fmt::Plain),
    ("PostCropVignetteHighlightContrast", "vignette.highlights", Fmt::Plain),
    ("GrainAmount", "grain.amount", Fmt::Plain),
    ("GrainSize", "grain.size", Fmt::Plain),
    ("GrainFrequency", "grain.roughness", Fmt::Plain),
    ("LensManualDistortionAmount", "optics.distortion", Fmt::Signed),
    ("VignetteAmount", "optics.vignetting", Fmt::Signed),
    ("VignetteMidpoint", "optics.vignetting_midpoint", Fmt::Plain),
    ("DefringePurpleAmount", "optics.defringe_purple_amount", Fmt::Plain),
    ("DefringePurpleHueLo", "optics.defringe_purple_hue_lo", Fmt::Plain),
    ("DefringePurpleHueHi", "optics.defringe_purple_hue_hi", Fmt::Plain),
    ("DefringeGreenAmount", "optics.defringe_green_amount", Fmt::Plain),
    ("DefringeGreenHueLo", "optics.defringe_green_hue_lo", Fmt::Plain),
    ("DefringeGreenHueHi", "optics.defringe_green_hue_hi", Fmt::Plain),
    ("ShadowTint", "calibration.shadows_tint", Fmt::Signed),
    ("RedHue", "calibration.red_hue", Fmt::Signed),
    ("RedSaturation", "calibration.red_sat", Fmt::Signed),
    ("GreenHue", "calibration.green_hue", Fmt::Signed),
    ("GreenSaturation", "calibration.green_sat", Fmt::Signed),
    ("BlueHue", "calibration.blue_hue", Fmt::Signed),
    ("BlueSaturation", "calibration.blue_sat", Fmt::Signed),
    ("PerspectiveVertical", "geometry.vertical", Fmt::Signed),
    ("PerspectiveHorizontal", "geometry.horizontal", Fmt::Signed),
    ("PerspectiveRotate", "geometry.rotate", Fmt::Tenths),
    ("PerspectiveScale", "geometry.scale", Fmt::Plain),
    ("PerspectiveAspect", "geometry.aspect", Fmt::Signed),
    ("PerspectiveX", "geometry.offset_x", Fmt::Tenths),
    ("PerspectiveY", "geometry.offset_y", Fmt::Tenths),
];

fn at<'a>(v: &'a Value, path: &str) -> Option<&'a Value> {
    path.split('.').try_fold(v, |v, k| v.get(k))
}

fn num(v: &Value, path: &str) -> Option<f64> {
    at(v, path)?.as_f64().filter(|x| x.is_finite())
}

fn text<'a>(v: &'a Value, path: &str) -> Option<&'a str> {
    at(v, path)?.as_str()
}

fn format(v: f64, f: Fmt) -> String {
    let (s, signed) = match f {
        Fmt::Signed => (format!("{:.0}", v), true),
        Fmt::Plain => (format!("{:.0}", v), false),
        Fmt::Exposure => (format!("{:.2}", v), true),
        Fmt::Tenths => (format!("{:.1}", v), true),
    };
    // "-0", "-0.00": zero has no sign
    let zero = s.trim_start_matches('-').chars().all(|c| c == '0' || c == '.');
    let s = if zero { s.trim_start_matches('-').to_string() } else { s };
    if signed && !zero && !s.starts_with('-') { format!("+{s}") } else { s }
}

fn escape(s: &str) -> String {
    s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;")
}

/// A stable 32-hex-digit id from the preset's id (re-exporting gives Lightroom the same preset).
fn uuid(id: &str) -> String {
    let fnv = |seed: u64| id.bytes().fold(seed, |h, b| (h ^ u64::from(b)).wrapping_mul(0x0000_0100_0000_01B3));
    format!("{:016X}{:016X}", fnv(0xCBF2_9CE4_8422_2325), fnv(0x84222325_CBF29CE4))
}

/// A point curve as Lightroom stores it: `"x, y"` in 0..255, the identity when empty.
fn curve_seq(v: Option<&Value>) -> Vec<String> {
    let pts: Vec<(f64, f64)> = v
        .and_then(Value::as_array)
        .map(|a| {
            a.iter()
                .filter_map(|p| match p {
                    Value::Object(o) => Some((o.get("x")?.as_f64()?, o.get("y")?.as_f64()?)),
                    Value::Array(l) if l.len() >= 2 => Some((l[0].as_f64()?, l[1].as_f64()?)),
                    _ => None,
                })
                .collect()
        })
        .unwrap_or_default();
    let pts = if pts.len() < 2 { vec![(0.0, 0.0), (1.0, 1.0)] } else { pts };
    pts.iter().map(|(x, y)| format!("{}, {}", (x.clamp(0.0, 1.0) * 255.0).round(), (y.clamp(0.0, 1.0) * 255.0).round())).collect()
}

/// White balance: a named mode, else a custom Kelvin (raws) or a shift from as shot (the relative
/// scale, `Incremental*`, which `to_partial` reads back through `rel_to_kelvin`).
fn white_balance(s: &Value, attrs: &mut Vec<(String, String)>) {
    let Some(mode) = text(s, "wb.mode") else { return };
    let named = match mode {
        "asShot" => Some("As Shot"),
        "auto" => Some("Auto"),
        "daylight" => Some("Daylight"),
        "cloudy" => Some("Cloudy"),
        "shade" => Some("Shade"),
        "tungsten" => Some("Tungsten"),
        "fluorescent" => Some("Fluorescent"),
        "flash" => Some("Flash"),
        _ => None,
    };
    if let Some(n) = named {
        attrs.push(("WhiteBalance".into(), n.into()));
        return;
    }
    let Some(temp) = num(s, "wb.temp").filter(|t| *t > 0.0) else { return };
    let tint = num(s, "wb.tint");
    attrs.push(("WhiteBalance".into(), "Custom".into()));
    if text(s, "wb.scale").unwrap_or("kelvin") == "kelvin" {
        attrs.push(("Temperature".into(), format(temp, Fmt::Plain)));
        if let Some(t) = tint {
            attrs.push(("Tint".into(), format(t, Fmt::Signed)));
        }
    } else {
        let r = ((1e6 / 6500.0 - 1e6 / temp) / 0.8).clamp(-100.0, 100.0);
        attrs.push(("IncrementalTemperature".into(), format(r, Fmt::Signed)));
        if let Some(t) = tint {
            attrs.push(("IncrementalTint".into(), format(t, Fmt::Signed)));
        }
    }
}

/// The `crs:` attributes for a preset's partial settings, in a stable order.
pub fn attributes(s: &Value) -> Vec<(String, String)> {
    let mut a: Vec<(String, String)> = Vec::new();
    for (crs, path, f) in FIELDS {
        if let Some(v) = num(s, path) {
            a.push(((*crs).into(), format(v, *f)));
        }
    }
    for (band, crs) in MIXER_BANDS.iter().zip(CRS_BANDS) {
        for (field, key) in [("HueAdjustment", "hue"), ("SaturationAdjustment", "sat"), ("LuminanceAdjustment", "lum")] {
            if let Some(v) = num(s, &format!("mixer.{band}.{key}")) {
                a.push((format!("{field}{crs}"), format(v, Fmt::Signed)));
            }
        }
        if let Some(v) = num(s, &format!("bw_mix.{band}")) {
            a.push((format!("GrayMixer{crs}"), format(v, Fmt::Signed)));
        }
    }
    white_balance(s, &mut a);
    if let Some(t) = text(s, "treatment") {
        a.push(("ConvertToGrayscale".into(), if t == "bw" { "True" } else { "False" }.into()));
    }
    if let Some(st) = text(s, "vignette.style") {
        let n = match st {
            "colorPriority" => "2",
            "paintOverlay" => "3",
            _ => "1",
        };
        a.push(("PostCropVignetteStyle".into(), n.into()));
    }
    if let Some(on) = at(s, "optics.lens_profile").and_then(Value::as_bool) {
        a.push(("LensProfileEnable".into(), if on { "1" } else { "0" }.into()));
    }
    if let Some(on) = at(s, "optics.remove_ca").and_then(Value::as_bool) {
        a.push(("AutoLateralCA".into(), if on { "1" } else { "0" }.into()));
    }
    if let Some(u) = text(s, "geometry.upright") {
        let n = match u {
            "auto" => "1",
            "level" => "2",
            "vertical" => "3",
            "full" => "4",
            "guided" => "5",
            _ => "0",
        };
        a.push(("PerspectiveUpright".into(), n.into()));
    }
    if let Some(on) = at(s, "hdr.enabled").and_then(Value::as_bool) {
        a.push(("HDREditMode".into(), if on { "1" } else { "0" }.into()));
    }
    if let Some(g) = at(s, "crop.geometry") {
        let r = |k: &str, d: f64| g.get("rect").and_then(|r| r.get(k)).and_then(Value::as_f64).unwrap_or(d);
        let (x0, y0, x1, y1) = (r("x0", 0.0), r("y0", 0.0), r("x1", 1.0), r("y1", 1.0));
        let whole = x0 <= 0.0 && y0 <= 0.0 && x1 >= 1.0 && y1 >= 1.0 && g.get("angle").and_then(Value::as_f64).unwrap_or(0.0) == 0.0;
        if whole {
            a.push(("HasCrop".into(), "False".into()));
        } else {
            a.push(("HasCrop".into(), "True".into()));
            for (k, v) in [("CropTop", y0), ("CropLeft", x0), ("CropBottom", y1), ("CropRight", x1)] {
                a.push((k.into(), format!("{v:.6}")));
            }
            a.push(("CropAngle".into(), format!("{:.4}", g.get("angle").and_then(Value::as_f64).unwrap_or(0.0))));
        }
    }
    a
}

/// A preset as an XMP preset file Lightroom and Camera Raw import.
pub fn preset_to_xmp(p: &Preset) -> String {
    let s = &p.settings;
    let mut x = String::new();
    x.push_str("<x:xmpmeta xmlns:x=\"adobe:ns:meta/\" x:xmptk=\"LightCraft\">\n");
    x.push_str(" <rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">\n");
    x.push_str("  <rdf:Description rdf:about=\"\"\n    xmlns:crs=\"http://ns.adobe.com/camera-raw-settings/1.0/\"\n");
    let head = [
        ("PresetType", "Normal".to_string()),
        ("Cluster", String::new()),
        ("UUID", uuid(&p.id)),
        ("SupportsAmount", "False".into()),
        ("SupportsColor", "True".into()),
        ("SupportsMonochrome", "True".into()),
        ("SupportsHighDynamicRange", "True".into()),
        ("SupportsNormalDynamicRange", "True".into()),
        ("SupportsSceneReferred", "True".into()),
        ("SupportsOutputReferred", "True".into()),
        ("RequiresRGBTables", "False".into()),
        ("CameraModelRestriction", String::new()),
        ("Copyright", String::new()),
        ("ContactInfo", String::new()),
        ("Version", "15.0".into()),
        ("ProcessVersion", "11.0".into()),
    ];
    for (k, v) in head.iter().map(|(k, v)| ((*k).to_string(), v.clone())).chain(attributes(s)) {
        x.push_str(&format!("   crs:{k}=\"{}\"\n", escape(&v)));
    }
    x.push_str("   crs:HasSettings=\"True\">\n");
    let alt = |k: &str, v: &str| format!("   <crs:{k}>\n    <rdf:Alt>\n     <rdf:li xml:lang=\"x-default\">{}</rdf:li>\n    </rdf:Alt>\n   </crs:{k}>\n", escape(v));
    x.push_str(&alt("Name", &p.name));
    x.push_str(&alt("ShortName", ""));
    x.push_str(&alt("SortName", ""));
    x.push_str(&alt("Group", &p.group));
    x.push_str(&alt("Description", ""));
    // Lightroom reads the channel curves only next to the master one, all four present
    if ["master", "red", "green", "blue"].iter().any(|c| at(s, &format!("curve.{c}")).is_some()) {
        x.push_str("   <crs:ToneCurveName2012>Custom</crs:ToneCurveName2012>\n");
        for (crs, ch) in [("ToneCurvePV2012", "master"), ("ToneCurvePV2012Red", "red"), ("ToneCurvePV2012Green", "green"), ("ToneCurvePV2012Blue", "blue")] {
            x.push_str(&format!("   <crs:{crs}>\n    <rdf:Seq>\n"));
            for pt in curve_seq(at(s, &format!("curve.{ch}"))) {
                x.push_str(&format!("     <rdf:li>{pt}</rdf:li>\n"));
            }
            x.push_str(&format!("    </rdf:Seq>\n   </crs:{crs}>\n"));
        }
    }
    x.push_str("  </rdf:Description>\n </rdf:RDF>\n</x:xmpmeta>\n");
    x
}

/// A file name for the preset (`Group - Name.xmp` without characters file systems refuse).
pub fn file_name(p: &Preset) -> String {
    let clean = |s: &str| s.chars().map(|c| if "/\\:*?\"<>|".contains(c) || c.is_control() { '_' } else { c }).collect::<String>();
    let name = clean(p.name.trim());
    let name = if name.is_empty() { "Preset".to_string() } else { name };
    format!("{name}.xmp")
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn preset(settings: Value) -> Preset {
        Preset { id: "user.test-look".into(), name: "Concerto <caldo> & blu".into(), group: "User Presets".into(), settings, favorite: false, builtin: false }
    }

    /// Every field the writer knows comes back through the importer with the value it had.
    #[test]
    fn a_preset_survives_the_trip_through_lightroom_xmp() {
        let s = json!({
            "light": {"exposure": 0.65, "contrast": -14.0, "highlights": -58.0, "shadows": 41.0, "whites": 9.0, "blacks": -17.0},
            "effects": {"texture": 6.0, "clarity": 11.0, "dehaze": 4.0},
            "color": {"vibrance": 19.0, "saturation": -3.0},
            "wb": {"mode": "custom", "temp": 5150.0, "tint": 12.0, "scale": "kelvin"},
            "treatment": "color",
            "mixer": {"orange": {"hue": -7.0, "sat": 0.0, "lum": 3.0}, "blue": {"hue": 0.0, "sat": -22.0, "lum": 0.0}},
            "bw_mix": {"red": 10.0, "blue": -20.0},
            "curve": {"shadows": 5.0, "highlights": -8.0, "split_mid": 55.0, "refine_saturation": 40.0,
                      "master": [{"x": 0.0, "y": 0.0}, {"x": 64.0/255.0, "y": 52.0/255.0}, {"x": 1.0, "y": 1.0}],
                      "red": [{"x": 0.0, "y": 10.0/255.0}, {"x": 1.0, "y": 1.0}]},
            "grading": {"shadows": {"hue": 210.0, "sat": 14.0, "lum": -5.0}, "midtones": {"hue": 120.0, "sat": 6.0, "lum": 0.0},
                        "highlights": {"hue": 40.0, "sat": 9.0, "lum": 2.0}, "global": {"hue": 30.0, "sat": 4.0, "lum": 1.0},
                        "blending": 70.0, "balance": 20.0},
            "detail": {"sharpen_amount": 55.0, "sharpen_radius": 1.2, "sharpen_detail": 30.0, "sharpen_masking": 12.0,
                       "nr_luminance": 18.0, "nr_color": 25.0},
            "vignette": {"amount": -21.0, "midpoint": 40.0, "roundness": 10.0, "feather": 60.0, "highlights": 5.0, "style": "colorPriority"},
            "grain": {"amount": 15.0, "size": 30.0, "roughness": 60.0},
            "optics": {"lens_profile": true, "remove_ca": true, "distortion": -4.0, "vignetting": 12.0, "defringe_purple_amount": 3.0},
            "calibration": {"shadows_tint": -7.0, "red_hue": 12.0, "red_sat": 20.0, "blue_sat": 25.0},
            "geometry": {"vertical": -10.0, "rotate": 1.5, "upright": "level"},
        });
        let xmp = preset_to_xmp(&preset(s.clone()));
        let back = crate::crs::preset_from_xmp(&xmp, "fallback").expect("Lightroom XMP reads back");
        assert_eq!(back.name, "Concerto <caldo> & blu");
        assert_eq!(back.group, "User Presets");
        let b = &back.settings;
        for (_, path, _) in FIELDS {
            if let Some(v) = num(&s, path) {
                let got = num(b, path).unwrap_or_else(|| panic!("{path} lost in {xmp}"));
                assert!((got - v).abs() < 0.051, "{path}: {v} → {got}");
            }
        }
        for (band, key) in [("orange", "hue"), ("orange", "lum"), ("blue", "sat")] {
            let p = format!("mixer.{band}.{key}");
            assert_eq!(num(b, &p), num(&s, &p), "{p}");
        }
        assert_eq!(num(b, "bw_mix.red"), Some(10.0));
        assert_eq!(num(b, "bw_mix.blue"), Some(-20.0));
        assert_eq!(text(b, "wb.mode"), Some("custom"));
        assert_eq!(num(b, "wb.temp"), Some(5150.0));
        assert_eq!(num(b, "wb.tint"), Some(12.0));
        assert_eq!(text(b, "treatment"), Some("color"));
        assert_eq!(text(b, "vignette.style"), Some("colorPriority"));
        assert_eq!(at(b, "optics.lens_profile"), Some(&json!(true)));
        assert_eq!(at(b, "optics.remove_ca"), Some(&json!(true)));
        assert_eq!(text(b, "geometry.upright"), Some("level"));
        let master = at(b, "curve.master").and_then(Value::as_array).expect("master curve");
        assert_eq!(master.len(), 3);
        assert!((master[1]["y"].as_f64().unwrap() - 52.0 / 255.0).abs() < 1e-9);
        let red = at(b, "curve.red").and_then(Value::as_array).expect("red curve (all four written)");
        assert!((red[0]["y"].as_f64().unwrap() - 10.0 / 255.0).abs() < 1e-9);
        // green / blue were identities: they come back as "no curve"
        assert_eq!(at(b, "curve.green"), Some(&json!([])));
    }

    #[test]
    fn white_balance_modes_and_the_relative_scale() {
        let named = attributes(&json!({"wb": {"mode": "cloudy", "temp": 6500.0}}));
        assert_eq!(named, vec![("WhiteBalance".to_string(), "Cloudy".to_string())]);
        // a shift from as shot comes back as the same Kelvin on the relative scale
        let k = crate::crs::rel_to_kelvin(30.0);
        let xmp = preset_to_xmp(&preset(json!({"wb": {"mode": "custom", "temp": k, "tint": -4.0, "scale": "relative"}})));
        assert!(xmp.contains("crs:IncrementalTemperature=\"+30\""), "{xmp}");
        let back = crate::crs::preset_from_xmp(&xmp, "x").unwrap();
        assert!((num(&back.settings, "wb.temp").unwrap() - k).abs() < 1.0);
        assert_eq!(num(&back.settings, "wb.tint"), Some(-4.0));
    }

    #[test]
    fn numbers_as_lightroom_writes_them() {
        assert_eq!(format(0.654, Fmt::Exposure), "+0.65");
        assert_eq!(format(-0.001, Fmt::Exposure), "0.00");
        assert_eq!(format(-14.2, Fmt::Signed), "-14");
        assert_eq!(format(40.0, Fmt::Plain), "40");
        assert_eq!(format(1.0, Fmt::Tenths), "+1.0");
        assert_eq!(uuid("user.a").len(), 32);
        assert_ne!(uuid("user.a"), uuid("user.b"));
    }
}
