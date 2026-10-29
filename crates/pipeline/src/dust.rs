//! Dust-spot detection: sensor dust shows as small, soft, darker-than-surroundings round spots
//! on smooth areas (sky, walls). Classical: a blurred copy gives the surroundings, the darkening
//! is compared with the local texture so detail doesn't trigger it, and each candidate blob
//! must be small and roughly round. Dust is a shadow on the sensor, which tells it from the
//! scene's own small dark things: it darkens by a few percent (a bird or a leaf by far more), it
//! darkens every colour alike (it has no colour of its own), and its edge is soft (a dark object's
//! is sharp). It is looked for where it shows and nothing else looks like it: on grey or blue
//! surfaces (sky, walls, a backdrop), not on skin or foliage, whose own pores, freckles and
//! shadows are small soft dark spots too.

use lightcraft_raster::{Plane, Rgba8, blur::gaussian};

/// A found spot: centre (0..1 of the image's width / height) and radius (fraction of the long
/// edge), with how much darker it is (0..1).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct DustSpot {
    pub x: f64,
    pub y: f64,
    pub radius: f64,
    pub strength: f32,
}

/// The darkest a dust shadow gets, relative to its surroundings (a darker spot is the scene's).
const MAX_DARKENING: f32 = 0.25;
/// The most colourful a surface dust is looked for on may be (but a blue sky, however deep).
const MAX_SURFACE_SATURATION: f32 = 0.09;

/// Dust spots in a rendered image; `sensitivity` 0..100 (higher finds fainter spots).
pub fn detect(img: &Rgba8, sensitivity: f32) -> Vec<DustSpot> {
    let (w, h) = (img.width, img.height);
    if w < 32 || h < 32 {
        return Vec::new();
    }
    let long = w.max(h) as f32;
    let channel = |k: usize| Plane::from_fn(w, h, |x, y| img.data[y * w + x][k] as f32 / 255.0);
    let (r, g, b) = (channel(0), channel(1), channel(2));
    let l = Plane::from_fn(w, h, |x, y| {
        let i = y * w + x;
        0.2126 * r.data[i] + 0.7152 * g.data[i] + 0.0722 * b.data[i]
    });
    let sigma = (0.012 * long).max(2.0);
    // the surroundings without what is brighter than them (a highlight, a crystal, a lamp): beside
    // a bright thing the plain surface would otherwise look darker than its surroundings
    let first = gaussian(&l, sigma);
    let below = Plane::from_fn(w, h, |x, y| {
        let i = y * w + x;
        l.data[i].min(first.data[i] * 1.03)
    });
    let around = gaussian(&below, sigma);
    // texture: local mean of the fine detail (what isn't explained by the surroundings)
    let detail = Plane::from_fn(w, h, |x, y| (l.data[y * w + x] - around.data[y * w + x]).abs());
    let texture = gaussian(&detail, (0.02 * long).max(3.0));
    let s = (sensitivity / 100.0).clamp(0.0, 1.0);
    // the faintest darkening taken, relative to the surroundings: 4.5 % … 1.2 %
    let min_rel = 0.045 - 0.033 * s;
    let rel: Vec<f32> = (0..w * h).map(|i| ((around.data[i] - l.data[i]) / around.data[i].max(0.04)).max(0.0)).collect();
    let candidate = |i: usize| rel[i] > min_rel && (around.data[i] - l.data[i]) > 3.0 * texture.data[i] && l.data[i] > 0.06;
    // the surroundings of each colour (made once, when the first blob is measured)
    let mut tint: Option<[Plane; 3]> = None;
    // blobs of candidate pixels (4-connected)
    let mut seen = vec![false; w * h];
    let mut out = Vec::new();
    let (rmin, rmax) = (0.0012 * long, 0.02 * long);
    for start in 0..w * h {
        if seen[start] || !candidate(start) {
            continue;
        }
        let mut stack = vec![start];
        seen[start] = true;
        let mut pixels = Vec::new();
        let (mut sx, mut sy, mut peak, mut sum) = (0.0f64, 0.0f64, 0.0f32, 0.0f32);
        let (mut x0, mut x1, mut y0, mut y1) = (w, 0, h, 0);
        let mut too_big = false;
        while let Some(i) = stack.pop() {
            let (x, y) = (i % w, i / w);
            pixels.push(i);
            sx += x as f64;
            sy += y as f64;
            peak = peak.max(rel[i]);
            sum += rel[i];
            (x0, x1, y0, y1) = (x0.min(x), x1.max(x), y0.min(y), y1.max(y));
            if pixels.len() > (rmax * rmax * 4.0) as usize {
                too_big = true;
                break; // too big to be dust: stop growing
            }
            for j in [i.wrapping_sub(1), i + 1, i.wrapping_sub(w), i + w] {
                let ok = j < w * h && !seen[j] && ((j % w).abs_diff(x) <= 1);
                if ok && candidate(j) {
                    seen[j] = true;
                    stack.push(j);
                }
            }
        }
        let n = pixels.len();
        let (bw, bh) = ((x1 - x0 + 1) as f32, (y1 - y0 + 1) as f32);
        let radius = (bw.max(bh)) / 2.0;
        let round = bw.max(bh) / bw.min(bh) <= 1.8 && n as f32 >= 0.45 * bw * bh;
        if too_big || radius < rmin || radius > rmax || !round || peak > MAX_DARKENING {
            continue;
        }
        // soft: a shadow fades from its middle out, a dark object is about as dark all over
        if n >= 6 && sum / n as f32 > 0.8 * peak {
            continue;
        }
        // grey: each colour darkened alike (a red or green dot is the scene's)
        let t = tint.get_or_insert_with(|| [gaussian(&r, sigma), gaussian(&g, sigma), gaussian(&b, sigma)]);
        let mut loss = [0.0f32; 3];
        for &i in &pixels {
            for (k, c) in [&r, &g, &b].into_iter().enumerate() {
                loss[k] += (t[k].data[i] - c.data[i]) / t[k].data[i].max(0.04);
            }
        }
        let mean = (loss[0] + loss[1] + loss[2]) / 3.0;
        let spread = loss.iter().fold(f32::MIN, |a, v| a.max(*v)) - loss.iter().fold(f32::MAX, |a, v| a.min(*v));
        if mean <= 0.0 || spread > 0.6 * mean + 0.004 * n as f32 {
            continue;
        }
        // the blob's middle
        let c = (sy / n as f64).round() as usize * w + (sx / n as f64).round() as usize;
        // not beside something bright (a crystal's dark facet, a lamp's fitting)
        if first.data[c] > around.data[c] * 1.015 {
            continue;
        }
        // on a grey or blue surface
        let (sr, sg, sb) = (t[0].data[c], t[1].data[c], t[2].data[c]);
        let (hi, lo) = (sr.max(sg).max(sb), sr.min(sg).min(sb));
        let saturation = if hi > 0.0 { (hi - lo) / hi } else { 0.0 };
        let blue = sb >= hi - 1e-4 || (sb > sr && sg > sr && saturation > 0.0);
        if saturation > MAX_SURFACE_SATURATION && !blue {
            continue;
        }
        out.push(DustSpot {
            x: (sx / n as f64 + 0.5) / w as f64,
            y: (sy / n as f64 + 0.5) / h as f64,
            radius: (radius / long) as f64 * 1.6,
            strength: peak,
        });
    }
    out.sort_by(|a, b| b.strength.total_cmp(&a.strength));
    out.truncate(40);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A picture of `w × h` from the colour at each pixel (0..1).
    fn picture(w: usize, h: usize, v: impl Fn(f32, f32) -> [f32; 3]) -> Rgba8 {
        let data = (0..w * h)
            .map(|i| {
                let (x, y) = ((i % w) as f32, (i / w) as f32);
                let c = v(x, y);
                let e = |k: usize| (c[k].clamp(0.0, 1.0) * 255.0) as u8;
                [e(0), e(1), e(2), 255]
            })
            .collect();
        Rgba8 { width: w, height: h, data }
    }

    /// A smooth sky gradient with three soft dark spots: all found, nothing else.
    #[test]
    fn finds_spots_on_smooth_areas() {
        let (w, h) = (600usize, 400usize);
        let spots = [(120.0f32, 90.0f32, 4.0f32), (400.0, 200.0, 6.0), (500.0, 330.0, 3.0)];
        let img = picture(w, h, |x, y| {
            let mut v = 0.55 + 0.25 * (y / h as f32) + 0.05 * (x / w as f32);
            for (cx, cy, r) in spots {
                let d2 = (x - cx).powi(2) + (y - cy).powi(2);
                v -= 0.06 * (-d2 / (2.0 * r * r)).exp();
            }
            [v, v, v * 1.1]
        });
        let found = detect(&img, 50.0);
        assert_eq!(found.len(), 3, "{found:?}");
        for (cx, cy, _) in spots {
            assert!(
                found.iter().any(|s| (s.x * w as f64 - cx as f64).abs() < 3.0 && (s.y * h as f64 - cy as f64).abs() < 3.0),
                "{cx},{cy}: {found:?}"
            );
        }
    }

    /// The scene's own small dark things on a sky: a bird (dark, sharp-edged), a red balloon, a
    /// green leaf. None is dust; the one real dust spot beside them is.
    #[test]
    fn birds_and_coloured_dots_are_not_dust() {
        let (w, h) = (600usize, 400usize);
        let img = picture(w, h, |x, y| {
            let base = 0.6 + 0.2 * (y / h as f32);
            let mut c = [base, base, base * 1.1];
            let d = |cx: f32, cy: f32| ((x - cx).powi(2) + (y - cy).powi(2)).sqrt();
            // a bird: half the light, a hard edge
            if d(100.0, 80.0) < 4.0 {
                c = c.map(|v| v * 0.45);
            }
            // a red balloon: the green and blue go, the red stays
            let k = (-d(300.0, 100.0).powi(2) / 18.0).exp();
            c[1] -= 0.12 * k;
            c[2] -= 0.12 * k;
            // a green leaf
            let k = (-d(450.0, 120.0).powi(2) / 18.0).exp();
            c[0] -= 0.1 * k;
            c[2] -= 0.1 * k;
            // dust
            let k = (-d(250.0, 300.0).powi(2) / 32.0).exp();
            c.map(|v| v * (1.0 - 0.07 * k))
        });
        let found = detect(&img, 60.0);
        assert_eq!(found.len(), 1, "{found:?}");
        assert!((found[0].x * w as f64 - 250.0).abs() < 3.0 && (found[0].y * h as f64 - 300.0).abs() < 3.0, "{found:?}");
    }

    /// Skin with its freckles and a pendant's soft shadow: no dust.
    #[test]
    fn skin_is_not_searched() {
        let (w, h) = (600usize, 400usize);
        let img = picture(w, h, |x, y| {
            let mut c = [0.86, 0.66, 0.55];
            let d = |cx: f32, cy: f32| ((x - cx).powi(2) + (y - cy).powi(2)).sqrt();
            for (cx, cy) in [(120.0, 100.0), (300.0, 220.0), (480.0, 300.0), (200.0, 320.0)] {
                let k = (-d(cx, cy).powi(2) / 20.0).exp();
                c = c.map(|v| v * (1.0 - 0.08 * k));
            }
            let _ = y;
            c
        });
        assert!(detect(&img, 70.0).is_empty());
    }

    #[test]
    fn textured_scenes_give_few_false_spots() {
        let img = lightcraft_scenes::demo_library()[2].render(600, 400);
        let data = img
            .data
            .iter()
            .map(|c| {
                let e = |v: f32| (lightcraft_color::transfer::linear_to_srgb(v.clamp(0.0, 1.0)) * 255.0) as u8;
                [e(c[0]), e(c[1]), e(c[2]), 255]
            })
            .collect();
        let found = detect(&Rgba8 { width: 600, height: 400, data }, 50.0);
        assert!(found.len() <= 3, "{} false spots", found.len());
    }
}
