// v2 blendshape feed: three selectable sources, all landing in one
// Float32Array indexed by facecap morph order (see src/morph-map.js).
//
//   ?feed=synthetic  local: mic level + speech state -> synth2.synthFrame
//   ?feed=bridge     live WS door (default ws://127.0.0.1:8990, ?door=):
//                    JSON frames {t: unix_seconds, bs: {ARKitName: 0..1}} @30Hz
//   ?feed=file       replay a CSV fixture (header: t + ARKit names)
import { synthFrame, centroidFrom } from './synth2.js';
import { NORM_TO_FACECAP, FACECAP_INDEX, MORPH_COUNT, normKey } from './morph-map.js';

const KEY_CACHE = new Map();
export function resolveShape(name) {
  let idx = KEY_CACHE.get(name);
  if (idx === undefined) {
    const target = NORM_TO_FACECAP[normKey(name)];
    idx = target !== undefined ? FACECAP_INDEX[target] : -1;
    KEY_CACHE.set(name, idx);
  }
  return idx;
}

export class Feed {
  constructor({ mode = 'synthetic', door = 'ws://127.0.0.1:8990', file = './fixture/bs-frames.csv', onStat } = {}) {
    this.mode = mode;
    this.door = door;
    this.file = file;
    this.onStat = onStat || (() => {});
    this.targets = new Float32Array(MORPH_COUNT); // desired values, facecap index
    this.ws = null;
    this.frames = null;        // file mode: array of Float32Array
    this.frameCursor = 0;
    this.frameHz = 30;
    this.lastFrameAt = 0;      // bridge liveness watchdog
    this.inFrames = 0;
    this.unknownKeys = new Set();
    this._sample = { level: 0, centroid: 0.5, speaking: false };
  }

  start(getAudio) { // getAudio() -> {mic:{level,lo,mid,hi}, speaking, level, centroid}
    this.getAudio = getAudio;
    if (this.mode === 'bridge') this._connectBridge();
    if (this.mode === 'file') this._loadFile();
  }

  stop() {
    if (this.ws) { try { this.ws.close(); } catch (_) {} this.ws = null; }
  }

  _connectBridge() {
    this.onStat({ bridge: 'dialing ' });
    this.ws = new WebSocket(this.door);
    this.ws.onopen = () => this.onStat({ bridge: 'connected' });
    this.ws.onclose = () => { this.onStat({ bridge: 'closed — retry 2s' }); setTimeout(() => this._connectBridge(), 2000); };
    this.ws.onerror = () => this.onStat({ bridge: 'error' });
    this.ws.onmessage = (ev) => {
      let m; try { m = JSON.parse(ev.data); } catch (_) { return; }
      if (!m || typeof m !== 'object' || !m.bs) return;
      for (const [k, v] of Object.entries(m.bs)) {
        const idx = resolveShape(k);
        if (idx < 0) { if (this.unknownKeys.size < 30) this.unknownKeys.add(k); continue; }
        this.targets[idx] = Math.min(1, Math.max(0, +v || 0));
      }
      this.inFrames++;
      this.lastFrameAt = performance.now();
    };
  }

  async _loadFile() {
    try {
      const txt = await (await fetch(this.file)).text();
      const lines = txt.trim().split('\n');
      const names = lines[0].split(',');
      this.frames = lines.slice(1).map(l => {
        const c = l.split(',');
        const arr = new Float32Array(MORPH_COUNT);
        for (let i = 1; i < names.length; i++) {
          const idx = resolveShape(names[i]);
          if (idx >= 0) arr[idx] = +c[i] || 0;
        }
        return arr;
      });
      this.frameCursor = 0;
      this.onStat({ file: `${this.frames.length} frames` });
    } catch (e) { this.onStat({ file: '! ' + e.message }); }
  }

  /** call once per render frame with elapsed seconds */
  tick(t) {
    if (this.mode === 'synthetic') {
      const a = (this.getAudio && this.getAudio()) || { level: 0 };
      // 30 Hz-ish stepping: regenerate when we cross a step boundary
      const step = Math.floor(t * 30);
      if (step !== this._step) {
        this._step = step;
        const fr = synthFrame({ t, level: a.level, centroid: a.centroid ?? 0.5, speaking: a.speaking });
        for (let i = 0; i < this.targets.length; i++) this.targets[i] = 0;
        for (const [k, v] of Object.entries(fr)) {
          const idx = resolveShape(k);
          if (idx >= 0) this.targets[idx] = v;
        }
        this.inFrames = step;
      }
    } else if (this.mode === 'file' && this.frames) {
      const step = Math.floor(t * this.frameHz);
      if (step !== this._step) {
        this._step = step;
        const f = this.frames[this.frameCursor % this.frames.length];
        this.targets.set(f);
        this.frameCursor++;
        this.inFrames = this.frameCursor;
      }
    } else if (this.mode === 'bridge') {
      // watchdog: if the door goes silent, hold values (A2F streams can gap)
      const stale = this.lastFrameAt && performance.now() - this.lastFrameAt > 1500;
      this.onStat({ bridgeStale: stale });
    }
  }

  /** exponential smoothing into a morphTargetInfluences array */
  apply(influences, k = 0.35) {
    for (let i = 0; i < influences.length; i++) {
      influences[i] += (this.targets[i] - influences[i]) * k;
    }
  }
}

// ---- audio probe: level + crude bands from an AnalyserNode ----
export function makeProbe(analyser) {
  const freq = new Uint8Array(analyser.frequencyBinCount);
  const sr = analyser.context.sampleRate;
  const binHz = sr / analyser.fftSize;
  function band(lo, hi) {
    let s = 0, n = 0;
    for (let i = Math.floor(lo / binHz); i <= Math.ceil(hi / binHz) && i < freq.length; i++) { s += freq[i] * freq[i]; n++; }
    return n ? Math.sqrt(s / n) / 255 : 0;
  }
  return function probe() {
    analyser.getByteFrequencyData(freq);
    const lo = band(80, 400), mid = band(400, 1500), hi = band(1500, 6000);
    return { level: (lo + mid + hi) / 3, lo, mid, hi, centroid: centroidFrom(lo, mid, hi) };
  };
}
