//! Noise reduction is resolution independent (issue #960): a preview looks like the full-size
//! render scaled down, whatever the preview's size and whichever source level it is drawn from.

use crate::local::{denoise, log_lum, noise_level, nr_params};
use crate::{RenderRequest, SourceInfo, plan, render};
use lightcraft_develop::DevelopSettings;
use lightcraft_raster::resample::{Filter, resize};
use lightcraft_raster::{Rgb32f, Rgba8};

const W: usize = 1536;
const H: usize = 1024;

/// Deterministic standard normal samples (xorshift + Box-Muller).
struct Rng(u64);

impl Rng {
    fn uniform(&mut self) -> f32 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        ((self.0 >> 40) as f32 + 0.5) / (1u64 << 24) as f32
    }
    fn normal(&mut self) -> f32 {
        let (u, v) = (self.uniform(), self.uniform());
        (-2.0 * u.ln()).sqrt() * (std::f32::consts::TAU * v).cos()
    }
}

/// A `W × H` linear scene: a gradient, an edge and texture from 3 to 750 px wavelength, with white
/// luminance noise of `noise` stops and colour noise.
fn noisy_scene(noise: f32) -> Rgb32f {
    let mut rng = Rng(0x9e37_79b9_7f4a_7c15);
    let n: Vec<[f32; 4]> = (0..W * H).map(|_| [rng.normal(), rng.normal(), rng.normal(), rng.normal()]).collect();
    Rgb32f::from_fn(W, H, |x, y| {
        let r = n[y * W + x];
        let (xf, yf) = (x as f32, y as f32);
        let tex = 0.25 * (xf / 120.0).sin() * (yf / 90.0).cos()
            + 0.12 * ((xf + yf) / 16.0).sin()
            + 0.08 * (xf / 6.0).sin() * (yf / 7.0).sin()
            + 0.05 * ((xf - 2.0 * yf) / 3.0).sin();
        let edge = if x > 900 { 1.2 } else { 0.0 };
        let y0 = 0.18 * (-1.5 + 1.5 * yf / H as f32 + tex + edge + noise * r[0]).exp2();
        let c = |v: f32| y0 * (1.0 + 0.3 * noise * v).max(0.05);
        [c(r[1]), c(r[2]), c(r[3])]
    })
}

fn scaled(img: &Rgb32f, s: f32) -> Rgb32f {
    resize(img, (W as f32 * s).round() as usize, (H as f32 * s).round() as usize, Filter::Mitchell)
}

/// RMS difference of log2 luminance (stops).
fn rms_log(a: &Rgb32f, b: &Rgb32f) -> f32 {
    let n = a.data.len() as f32;
    (a.data.iter().zip(&b.data).map(|(p, q)| (log_lum(*p) - log_lum(*q)).powi(2)).sum::<f32>() / n).sqrt()
}

/// RMS difference of chromaticity (r and b over r + g + b).
fn rms_chroma(a: &Rgb32f, b: &Rgb32f) -> f32 {
    let ch = |p: [f32; 3]| {
        let s = (p[0] + p[1] + p[2]).max(1e-6);
        [p[0] / s, p[2] / s]
    };
    let d = |p: [f32; 3], q: [f32; 3]| (ch(p)[0] - ch(q)[0]).powi(2) + (ch(p)[1] - ch(q)[1]).powi(2);
    (a.data.iter().zip(&b.data).map(|(p, q)| d(*p, *q)).sum::<f32>() / a.data.len() as f32).sqrt()
}

/// For each preview scale `k`: (k, how far the preview is from the full-size render scaled down,
/// how far it would be with noise reduction left off).
fn preview_error(s: &DevelopSettings, scales: &[f32], metric: fn(&Rgb32f, &Rgb32f) -> f32) -> Vec<(f32, f32, f32)> {
    let src = noisy_scene(0.15);
    let noise = noise_level(&src, None);
    let mut full = src.clone();
    denoise(&mut full, s, 1.0, noise);
    scales
        .iter()
        .map(|&k| {
            let reference = scaled(&full, k);
            let plain = scaled(&src, k);
            let mut preview = plain.clone();
            denoise(&mut preview, s, k, noise * k);
            (k, metric(&preview, &reference), metric(&plain, &reference))
        })
        .collect()
}

const SCALES: [f32; 6] = [0.5, 0.33, 0.25, 0.167, 0.1, 0.05];

#[test]
fn luminance_nr_preview_matches_full_size_scaled_down() {
    let mut s = DevelopSettings::default();
    s.detail.nr_luminance = 50.0;
    s.detail.nr_detail = 50.0;
    s.detail.nr_color = 0.0;
    for (k, err, off) in preview_error(&s, &SCALES, rms_log) {
        let ratio = err / off;
        eprintln!("luminance NR, preview at {k}: {err:.4} stops from the full-size render scaled down ({ratio:.2} of NR off)");
        // Before #960 the radius stopped shrinking at 0.4×: 2.3× (at 0.167) to 6× (at 0.05) further
        // off than no noise reduction at all, and 0.53 / 0.70 of it at 0.5 / 0.33.
        assert!(ratio <= 1.0, "preview at {k} is further off than no noise reduction: {err} vs {off}");
        assert!(err <= 0.01, "preview at {k} is {err} stops off");
        if k >= 0.33 {
            assert!(ratio <= 0.4, "preview at {k}: {ratio}");
        }
    }
}

#[test]
fn colour_nr_preview_matches_full_size_scaled_down() {
    let mut s = DevelopSettings::default();
    s.detail.nr_luminance = 0.0;
    s.detail.nr_color = 50.0;
    s.detail.nr_color_detail = 50.0;
    s.detail.nr_color_smoothness = 50.0;
    for (k, err, off) in preview_error(&s, &SCALES, rms_chroma) {
        let ratio = err / off;
        eprintln!("colour NR, preview at {k}: {err:.6} from the full-size render scaled down ({ratio:.2} of NR off)");
        // before #960: 0.00020 (0.31 of NR off) at 0.167, 0.00022 (0.75) at 0.1
        assert!(err <= 1.2e-4, "preview at {k} is {err} off");
        if k >= 0.1 {
            assert!(ratio <= 0.4, "preview at {k}: {ratio}");
        }
    }
}

#[test]
fn full_size_parameters() {
    // the luminance threshold is a multiple of the photo's own noise (square-root luminance)
    let mut s = DevelopSettings::default();
    s.detail.nr_luminance = 50.0;
    s.detail.nr_detail = 50.0;
    s.detail.nr_color = 25.0;
    s.detail.nr_color_detail = 50.0;
    s.detail.nr_color_smoothness = 50.0;
    let (l, c) = nr_params(&s, 1.0, 0.02);
    let (l, c) = (l.unwrap(), c.unwrap());
    assert_eq!(l.sigma, 1.5 + 3.0 * 0.5);
    assert!((l.eps - ((1.0 + 3.0 * 0.5 * (1.0 - 0.6 * 0.5)) * 0.02f32).powi(2)).abs() < 1e-9);
    assert_eq!(l.k, 0.5f32.sqrt());
    assert_eq!(c.sigma, (1.5 + 6.0 * 0.25) * 1.5);
    assert_eq!(c.t, 0.25 * (1.0 - 0.25));
}

#[test]
fn tiny_previews_skip_noise_reduction_and_hostile_scales_are_safe() {
    let mut s = DevelopSettings::default();
    s.detail.nr_luminance = 100.0;
    s.detail.nr_color = 100.0;
    // a 128-px thumbnail of a 6000-px photo: the luminance radius is a tenth of a pixel (it fades
    // to about 1 %), the colour radius (wider) a quarter of one, so that fades to a tenth
    let (l, c) = nr_params(&s, 128.0 / 6000.0, 0.001);
    assert!(l.is_none_or(|l| l.k < 0.02), "{l:?}");
    let (c, full) = (c.unwrap(), nr_params(&s, 1.0, 0.02).1.unwrap());
    assert!(c.t < full.t * 0.1 && c.t > 0.0, "{c:?}");
    assert_eq!(nr_params(&s, 0.0, 0.0), (None, None));
    for k in [f32::NAN, f32::INFINITY, -1.0, 7.0] {
        let (l, c) = nr_params(&s, k, k);
        let vals = [l.map(|l| [l.sigma, l.eps, l.k]), c.map(|c| [c.sigma, c.t, 1.0])];
        for v in vals.into_iter().flatten().flatten() {
            assert!(v.is_finite() && v >= 0.0, "{k}: {v}");
        }
    }
}

fn mean_abs_diff(a: &Rgba8, b: &Rgba8) -> f32 {
    let px = |p: &[u8; 4], q: &[u8; 4]| (0..3).map(|i| (f32::from(p[i]) - f32::from(q[i])).abs()).sum::<f32>() / 3.0;
    a.data.iter().zip(&b.data).map(|(p, q)| px(p, q)).sum::<f32>() / a.data.len() as f32
}

#[test]
fn preview_from_a_smaller_source_level_matches_one_from_the_original() {
    // The app draws a grid cell from the 512-px thumbnail level and the loupe from the 2560-px
    // preview level. Told the original's size, a render from the smaller copy denoises like one from
    // the original at the same output size; before #960 its radii were in the copy's pixels.
    let mut s = DevelopSettings::default();
    s.detail.nr_luminance = 60.0;
    s.detail.nr_color = 40.0;
    let original = noisy_scene(0.15);
    let thumb_level = scaled(&original, 512.0 / W as f32);
    let req = RenderRequest::fit(256, 256);
    let raw = SourceInfo { raw: true, ..Default::default() };
    let told = SourceInfo { native_long: Some(W), ..raw.clone() };
    assert!((plan(&thumb_level, &told, &s, &req).detail_scale - 256.0 / W as f32).abs() < 1e-4);
    assert!((plan(&original, &raw, &s, &req).detail_scale - 256.0 / W as f32).abs() < 1e-4);
    assert!((plan(&thumb_level, &raw, &s, &req).detail_scale - 0.5).abs() < 1e-4, "original unknown: the source's pixels");

    let mut plain = s.clone();
    plain.detail.nr_luminance = 0.0;
    plain.detail.nr_color = 0.0;
    let from_original = render(&original, &raw, &s, &req).image;
    let told_diff = mean_abs_diff(&render(&thumb_level, &told, &s, &req).image, &from_original);
    let untold_diff = mean_abs_diff(&render(&thumb_level, &raw, &s, &req).image, &from_original);
    // (the two sources differ a little anyway: the thumbnail level is resampled twice)
    let resampling = mean_abs_diff(&render(&thumb_level, &told, &plain, &req).image, &render(&original, &raw, &plain, &req).image);
    eprintln!("mean |Δ| (8-bit) from the original's render: told {told_diff:.3}, not told {untold_diff:.3}, NR off {resampling:.3}");
    assert!(told_diff <= resampling + 0.1, "{told_diff} vs {resampling}");
    assert!(untold_diff > told_diff + 0.25, "the copy's own pixels change the result: {untold_diff} vs {told_diff}");
}

#[test]
fn crop_does_not_change_the_noise_reduction_scale() {
    // a 1:1 render of a crop is at the original's pixels, like a 1:1 render of the whole photo
    let s = DevelopSettings::default();
    let src = Rgb32f::filled(400, 200, [0.2; 3]);
    let info = SourceInfo::default();
    assert!((plan(&src, &info, &s, &RenderRequest::fit(400, 200)).detail_scale - 1.0).abs() < 1e-6);
    let mut cropped = s.clone();
    cropped.crop.geometry.rect = lightcraft_geom::Rect::new(0.25, 0.25, 0.75, 0.75);
    let p = plan(&src, &info, &cropped, &RenderRequest::fit(200, 100));
    assert_eq!((p.w, p.h), (200, 100));
    assert!((p.detail_scale - 1.0).abs() < 1e-6, "{}", p.detail_scale);
}

#[test]
fn noise_level_reads_the_noise_not_the_scene() {
    // white noise of a known spread on a textured scene: the estimate is that spread
    let mut rng = Rng(7);
    for sigma in [0.005f32, 0.02, 0.06] {
        let n: Vec<f32> = (0..W * H).map(|_| rng.normal()).collect();
        let img = Rgb32f::from_fn(W, H, |x, y| {
            let s = 0.45 + 0.2 * (x as f32 / 40.0).sin() * (y as f32 / 55.0).cos() + sigma * n[y * W + x];
            let v = (s.max(0.0).powi(2) - crate::local::SQRT_LUM_OFFSET).max(0.0);
            [v, v, v]
        });
        let got = noise_level(&img, None);
        eprintln!("noise {sigma}: measured {got}");
        assert!((got / sigma - 1.0).abs() < 0.15, "{sigma}: {got}");
    }
}

#[test]
fn strong_noise_reduction_removes_most_of_the_noise() {
    // at 100 a flat noisy area keeps a small part of its noise, shadows as much as highlights
    let mut s = DevelopSettings::default();
    s.detail.nr_luminance = 100.0;
    s.detail.nr_detail = 50.0;
    s.detail.nr_color = 0.0;
    let mut rng = Rng(11);
    let sigma = 0.03f32;
    let n: Vec<f32> = (0..512 * 256).map(|_| rng.normal()).collect();
    let img = Rgb32f::from_fn(512, 256, |x, y| {
        let base = if x < 256 { 0.12f32 } else { 0.7 };
        let v = ((base + sigma * n[y * 512 + x]).max(0.0).powi(2) - crate::local::SQRT_LUM_OFFSET).max(0.0);
        [v, v, v]
    });
    let noise = noise_level(&img, None);
    let mut out = img.clone();
    denoise(&mut out, &s, 1.0, noise);
    let spread = |im: &Rgb32f, x0: usize| {
        let v: Vec<f32> = (16..240).flat_map(|y| (x0 + 16..x0 + 240).map(move |x| (y, x))).map(|(y, x)| crate::local::sqrt_lum(im.data[y * 512 + x])).collect();
        let m = v.iter().sum::<f32>() / v.len() as f32;
        (v.iter().map(|a| (a - m).powi(2)).sum::<f32>() / v.len() as f32).sqrt()
    };
    for x0 in [0, 256] {
        let (before, after) = (spread(&img, x0), spread(&out, x0));
        eprintln!("area at {x0}: noise {before:.4} -> {after:.4}");
        assert!(after < before * 0.2, "area at {x0}: {before} -> {after}");
    }
}

#[test]
fn sharpening_keeps_to_its_radius() {
    // a step edge sharpened at radius 1: the overshoot stays within a few pixels of the edge
    let mut s = DevelopSettings::default();
    s.detail.sharpen_amount = 150.0;
    s.detail.sharpen_radius = 0.5;
    s.detail.sharpen_detail = 25.0;
    let img = Rgb32f::from_fn(200, 8, |x, _| if x < 100 { [0.05; 3] } else { [0.5; 3] });
    let mut out = img.clone();
    crate::local::sharpen(&mut out, &s, 1.0);
    let changed: Vec<usize> = (0..200).filter(|&x| (out.data[4 * 200 + x][0] - img.data[4 * 200 + x][0]).abs() > 1e-4).collect();
    eprintln!("pixels changed: {changed:?}");
    assert!(!changed.is_empty());
    assert!(changed.iter().all(|&x| (96..104).contains(&x)), "{changed:?}");
}
