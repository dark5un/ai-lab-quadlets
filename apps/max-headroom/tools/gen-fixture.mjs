#!/usr/bin/env node
// Build tests/fixtures/bs-frames.csv from the SAME synthetic generator the
// browser uses (src/synth2.js): 30 Hz, ~12 s, with two "speech" bursts and a
// quiet gap — so ?feed=file has a realistic replay to load.
import { writeFileSync, mkdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { synthFrame } from '../src/synth2.js';
import { ARKIT_TO_FACECAP } from '../src/morph-map.js';

const here = path.dirname(fileURLToPath(import.meta.url));
const NAMES = Object.keys(ARKIT_TO_FACECAP); // canonical ARKit 52
const HZ = 30, SECS = 12;
const rows = [t0('t', ...NAMES)];

function t0(...c) { return c.join(','); }

// scripted "speech" envelope: sentence bursts at 1.5-5.5s and 7.5-11s
function speech(t) {
  const in1 = t > 1.5 && t < 5.5, in2 = t > 7.5 && t < 11;
  if (!in1 && !in2) return { speaking: false, level: 0.02, centroid: 0.5 };
  const local = (in1 ? t - 1.5 : t - 7.5);
  const sent = Math.max(0, Math.sin(local * 2.4)) ; // syllable-ish
  const level = 0.10 + 0.22 * Math.max(0, sent) * (0.6 + 0.4 * Math.abs(Math.sin(local * 0.7)));
  const centroid = 0.35 + 0.4 * Math.abs(Math.sin(local * 1.9 + 1));
  return { speaking: true, level, centroid };
}

for (let i = 0; i <= SECS * HZ; i++) {
  const t = i / HZ;
  const s = speech(t);
  const fr = synthFrame({ t, ...s });
  const vals = NAMES.map(n => (fr[n] ?? 0).toFixed(4));
  rows.push([t.toFixed(4), ...vals].join(','));
}
const out = path.join(here, '..', 'tests', 'fixtures', 'bs-frames.csv');
mkdirSync(path.dirname(out), { recursive: true });
writeFileSync(out, rows.join('\n') + '\n');
console.log('wrote', out, `(${rows.length - 1} frames x ${NAMES.length} shapes @ ${HZ}Hz)`);
