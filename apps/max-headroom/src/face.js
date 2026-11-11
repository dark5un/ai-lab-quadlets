// MVP face tier: procedural wireframe head + 8 viseme morph targets driven by
// client-side FFT analysis of the downlink audio (polerix/headroom pattern,
// 0 VRAM server-side). No fan-made model assets: the head is generated.

import * as THREE from 'three';

export const VISEMES = ['aa', 'ee', 'oh', 'oo', 'mm', 'ss', 'ff', 'sil'];

// per-viseme lip parameters: open (jaw), purse (rounding), widen, protrude
const SHAPE = {
  aa: { open: 0.34, purse: -0.04, widen: 0.12, protrude: 0.00 },
  ee: { open: 0.12, purse: -0.02, widen: 0.24, protrude: 0.00 },
  oh: { open: 0.24, purse: 0.10, widen: 0.00, protrude: 0.02 },
  oo: { open: 0.10, purse: 0.32, widen: -0.06, protrude: 0.08 },
  mm: { open: 0.01, purse: 0.10, widen: 0.02, protrude: 0.00 },
  ss: { open: 0.05, purse: 0.02, widen: 0.16, protrude: 0.00 },
  ff: { open: 0.07, purse: 0.06, widen: 0.06, protrude: -0.03 },
  sil: { open: 0, purse: 0, widen: 0, protrude: 0 },
};

const MOUTH = new THREE.Vector3(0, -0.30, 0.93);
const SIGMA2 = 2 * 0.42 * 0.42;

function mouthWeight(p) {
  const dx = p.x - MOUTH.x, dy = p.y - MOUTH.y, dz = p.z - MOUTH.z;
  return Math.exp(-(dx * dx + dy * dy + dz * dz) / SIGMA2);
}

function deformPos(base, key) {
  const s = SHAPE[key];
  const out = base.clone();
  for (let i = 0; i < base.count; i++) {
    const p = new THREE.Vector3().fromBufferAttribute(base, 'position', i);
    const w = mouthWeight(p);
    if (w < 0.02) { out.setXYZ(i, p.x, p.y, p.z); continue; }
    // jaw opens downward below mouth center, upper lip barely moves
    let y = p.y - s.open * w * (p.y < MOUTH.y ? 1.0 : 0.25) + s.open * w * 0.06;
    let x = p.x * (1 + s.purse * w) + (p.x > 0 ? s.widen : -s.widen) * w * 0.3;
    let z = p.z + s.protrude * w;
    out.setXYZ(i, x, y, z);
  }
  return out;
}

export function buildHead() {
  const geo = new THREE.IcosahedronGeometry(1, 4);
  geo.scale(0.85, 1.05, 0.92);
  // slight cranial taper
  const pos = geo.attributes.position;
  for (let i = 0; i < pos.count; i++) {
    const y = pos.getY(i);
    const k = 1 - Math.max(0, y - 0.4) * 0.25;
    pos.setXYZ(i, pos.getX(i) * k, y, pos.getZ(i) * (1 - Math.max(0, y - 0.4) * 0.15));
  }
  const morphs = [];
  for (const v of VISEMES) {
    if (v === 'sil') continue;
    morphs.push(deformPos(geo, v).attributes.position);
  }
  geo.morphAttributes.position = morphs;

  const skin = new THREE.MeshStandardMaterial({
    color: 0x0a1626, emissive: 0x114477, roughness: 0.4, metalness: 0.6,
    flatShading: true,
  });
  const mesh = new THREE.Mesh(geo, skin);
  const wire = new THREE.Mesh(geo, new THREE.MeshBasicMaterial({
    color: 0x33ddff, wireframe: true, transparent: true, opacity: 0.28,
  }));
  mesh.morphTargetInfluences = new Array(morphs.length).fill(0);
  wire.morphTargetInfluences = mesh.morphTargetInfluences;

  // eyes
  const eyeGeo = new THREE.SphereGeometry(0.10, 16, 12);
  const eyeMat = new THREE.MeshStandardMaterial({ color: 0x001122, emissive: 0x66eeff, emissiveIntensity: 1.6 });
  const eyeL = new THREE.Mesh(eyeGeo, eyeMat); eyeL.position.set(-0.27, 0.16, 0.80);
  const eyeR = new THREE.Mesh(eyeGeo, eyeMat); eyeR.position.set(0.27, 0.16, 0.80);

  // shades (toggle with 's')
  const shades = new THREE.Mesh(
    new THREE.BoxGeometry(0.78, 0.16, 0.10),
    new THREE.MeshStandardMaterial({ color: 0x020202, metalness: 0.9, roughness: 0.2 }));
  shades.position.set(0, 0.16, 0.88);

  const neck = new THREE.Mesh(
    new THREE.CylinderGeometry(0.28, 0.34, 0.5, 12, 1, true),
    new THREE.MeshBasicMaterial({ color: 0x33ddff, wireframe: true, transparent: true, opacity: 0.25 }));
  neck.position.set(0, -1.25, 0);

  const group = new THREE.Group();
  group.add(mesh, wire, eyeL, eyeR, shades, neck);
  return { group, influences: mesh.morphTargetInfluences, morphNames: VISEMES.filter(v => v !== 'sil'), eyeL, eyeR, shades, mesh, wire };
}

// FFT band-energy -> viseme selection (MVP heuristic)
export function makeClassifier(analyser) {
  const freq = new Uint8Array(analyser.frequencyBinCount);
  const time = new Uint8Array(analyser.fftSize);
  const sr = analyser.context.sampleRate;
  const binHz = sr / analyser.fftSize;
  function band(lo, hi) {
    let s = 0, n = 0;
    for (let i = Math.floor(lo / binHz); i <= Math.ceil(hi / binHz) && i < freq.length; i++) { s += freq[i] * freq[i]; n++; }
    return n ? Math.sqrt(s / n) / 255 : 0;
  }
  return function classify() {
    analyser.getByteFrequencyData(freq);
    analyser.getByteTimeDomainData(time);
    let zc = 0;
    for (let i = 1; i < time.length; i++) if ((time[i - 1] - 128) * (time[i] - 128) < 0) zc++;
    const zcr = zc / time.length;
    const lo = band(80, 400), mid = band(400, 1500), hi = band(1500, 6000);
    const level = (lo + mid + hi) / 3;
    if (level < 0.06) return 'sil';
    const hiRatio = hi / (level + 1e-6);
    const zcRatio = zcr / 0.2;
    if (hiRatio > 1.1 || (hiRatio > 0.85 && zcRatio > 0.5)) return hi > mid ? 'ss' : 'ff';
    if (hiRatio > 0.7) return 'ee';
    if (level > 0.30 && lo > hi * 1.4) return 'aa';
    if (lo > hi * 1.8) return 'mm';
    const centroid = (lo * 200 + mid * 900 + hi * 3000) / (lo + mid + hi + 1e-6);
    return centroid < 900 ? 'oo' : 'oh';
  };
}
