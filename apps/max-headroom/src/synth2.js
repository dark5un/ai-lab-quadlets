// v2 synthetic blendshape generator — pure functions, no DOM/browser deps so
// it runs in the browser (feed=synthetic), in Node (tools/gen-fixture.mjs) and
// produces identical frames for the CSV fixture (feed=file).
//
// Drives ARKit-standard names from: elapsed time, mic/output audio level and a
// crude spectral centroid. This is what makes the app fully testable without
// any Audio2Face backend.

// deterministic value noise: hash -> smooth interp
export function hash1(x, seed = 0) {
  const s = Math.sin(x * 127.1 + seed * 311.7) * 43758.5453;
  return s - Math.floor(s);
}
export function noise(x, seed = 0) {
  const i = Math.floor(x), f = x - i;
  const u = f * f * (3 - 2 * f);
  return hash1(i, seed) * (1 - u) + hash1(i + 1, seed) * u;
}
const clamp = (v, a = 0, b = 1) => Math.min(b, Math.max(a, v));

// ---- blink scheduler (deterministic in t) ----
// blink every ~2.4-5.6s of "noise time", duration ~140ms
function blinkAmount(t) {
  let next = 1.2, phase = -1, tt = 0;
  for (let k = 0; k < 400 && tt < t + 1; k++) {
    const start = next;
    const dur = 0.12 + 0.05 * hash1(k, 7);
    if (t >= start && t < start + dur) {
      const p = (t - start) / dur;
      return p < 0.5 ? p * 2 : (1 - p) * 2; // triangle close/open
    }
    tt = start;
    next = start + dur + 2.4 + 3.2 * hash1(k, 13);
  }
  return 0;
}

/**
 * @param state {
 *   t:        seconds (any monotonic clock)
 *   level:    0..~1 audio RMS (mic or downlink)
 *   centroid: 0..1 spectral centroid proxy (dark..bright)
 *   speaking: bool — currently producing speech
 *   idle:     bool — gentle rest poses while not speaking
 * }
 * @returns sparse { ARKitName: 0..1 } for this frame
 */
export function synthFrame(state) {
  const { t, level = 0, centroid = 0.5, speaking = false, idle = !speaking } = state;
  const e = clamp(level * 3.2);                 // speech envelope
  const out = {};
  const set = (k, v) => { if (v > 0.01) out[k] = clamp(v); };

  // ---- mouth (the visible money shapes) ----
  const wobble = 0.55 + 0.45 * noise(t * 8.5, 1);
  const open = speaking ? e * (0.45 + 0.55 * wobble) : 0.04 * noise(t * 1.3, 9);
  set('jawOpen', open * 0.95);
  set('mouthLowerDownLeft', open * 0.45);
  set('mouthLowerDownRight', open * 0.45);
  set('mouthUpperUpLeft', open * 0.22 * clamp(centroid * 1.6));
  set('mouthUpperUpRight', open * 0.22 * clamp(centroid * 1.6));

  // vowel-ish shape mix driven by spectral centroid + noise
  const bright = clamp((centroid - 0.42) * 3);
  const dark = clamp((0.42 - centroid) * 3);
  set('mouthSmileLeft', 0.10 + 0.34 * e * bright + 0.06 * idle * noise(t * 0.4, 2));
  set('mouthSmileRight', 0.10 + 0.34 * e * bright + 0.06 * idle * noise(t * 0.4, 3));
  set('mouthPucker', 0.5 * e * dark + 0.02);
  set('mouthFunnel', 0.32 * e * dark * noise(t * 6.1, 4));
  set('mouthStretchLeft', 0.30 * e * bright * noise(t * 7.7, 5));
  set('mouthStretchRight', 0.30 * e * bright * noise(t * 7.7, 6));
  set('mouthPressLeft', 0.35 * e * noise(t * 11, 8) * (1 - open));
  set('mouthPressRight', 0.35 * e * noise(t * 11.3, 9) * (1 - open));
  set('mouthDimpleLeft', 0.25 * (out.mouthSmileLeft || 0));
  set('mouthDimpleRight', 0.25 * (out.mouthSmileRight || 0));
  set('mouthClose', open > 0.5 ? 0 : 0.15 * e);
  set('mouthLeft', 0.12 * e * (noise(t * 3.1, 17) - 0.5));
  set('mouthRight', 0.12 * e * (noise(t * 3.1, 19) - 0.5));
  // rare Max-ism: tongue flick when loud
  set('tongueOut', (e > 0.8 && noise(t * 0.9, 21) > 0.93) ? 0.5 : 0);

  // ---- jaw steer while talking ----
  set('jawLeft', 0.18 * e * clamp(noise(t * 2.7, 11) - 0.55) * 2);
  set('jawRight', 0.18 * e * clamp(noise(t * 2.9, 12) - 0.55) * 2);
  set('jawForward', 0.10 * e * noise(t * 1.7, 13));

  // ---- brows (prosody) ----
  const surt = clamp(noise(t * 1.1, 23) * 0.9 + e * 0.5 - 0.25);
  set('browInnerUp', 0.35 * surt);
  set('browOuterUpLeft', 0.30 * surt * noise(t * 0.7, 24));
  set('browOuterUpRight', 0.30 * surt * noise(t * 0.7, 25));
  const snarl = clamp(e * 0.7 - 0.45);
  set('browDownLeft', 0.5 * snarl);
  set('browDownRight', 0.5 * snarl);

  // ---- cheeks / nose follow the smile ----
  const sm = out.mouthSmileLeft || 0;
  set('cheekSquintLeft', 0.5 * sm);
  set('cheekSquintRight', 0.5 * sm);
  set('cheekPuff', 0.3 * e * clamp(noise(t * 0.5, 27) - 0.8) * 5);
  set('noseSneerLeft', 0.25 * snarl);
  set('noseSneerRight', 0.25 * snarl);

  // ---- eyes: blink always; gaze handled by face rig (rotation) + small morphs ----
  const bl = blinkAmount(t);
  set('eyeBlinkLeft', bl);
  set('eyeBlinkRight', bl);
  set('eyeSquintLeft', 0.25 * (out.mouthSmileLeft || 0) + 0.10 * bl);
  set('eyeSquintRight', 0.25 * (out.mouthSmileRight || 0) + 0.10 * bl);
  set('eyeWideLeft', clamp(surt - 0.6) * 0.8);
  set('eyeWideRight', clamp(surt - 0.6) * 0.8);
  // morph-based gaze assist (small; the eye bones carry most of it)
  const gx = noise(t * 0.6, 31) - 0.5, gy = noise(t * 0.45, 33) - 0.5;
  set('eyeLookInLeft', clamp(gx * 0.8)); set('eyeLookInRight', clamp(-gx * 0.8));
  set('eyeLookOutLeft', clamp(-gx * 0.8)); set('eyeLookOutRight', clamp(gx * 0.8));
  set('eyeLookUpLeft', clamp(gy * 0.6)); set('eyeLookUpRight', clamp(gy * 0.6));
  set('eyeLookDownLeft', clamp(-gy * 0.6)); set('eyeLookDownRight', clamp(-gy * 0.6));

  return out;
}

// spectral centroid 0..1 from band energies (lo,mid,hi normalized 0..1)
export function centroidFrom(lo, mid, hi) {
  const tot = lo + mid + hi + 1e-6;
  return clamp((lo * 0.15 + mid * 0.5 + hi * 0.9) / tot);
}
