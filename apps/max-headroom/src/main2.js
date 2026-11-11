// v2 entry: facecap renderer + CRT post + 3-mode blendshape feed +
// redesigned broadcast-console HUD. Reuses v1's PlexClient (src/plex-client.js)
// unchanged for the PersonaPlex audio/caption link.
import './style2.css';
import * as THREE from 'three';
import { PlexClient } from './plex-client.js';
import { createFace, createCrtPost } from './face2.js';
import { Feed, makeProbe } from './feed2.js';

const params = new URLSearchParams(location.search);
const FEED = ['synthetic', 'bridge', 'file'].includes(params.get('feed')) ? params.get('feed') : 'synthetic';
const isLoop = ['127.0.0.1', 'localhost'].includes(location.hostname);
// v2 ?door= is the blendshape bridge (A2F). Audio stays on ?plex= (or the gear).
const BRIDGE_DOOR = params.get('door') || 'ws://127.0.0.1:8990';
const PLEX_DOOR = params.get('plex') || (isLoop ? 'ws://127.0.0.1:8998' : `wss://${location.hostname}:8456`);
const BS_FILE = params.get('bsfile') || './fixture/bs-frames.csv';
const VOICE = params.get('voice') || 'pxvoice.wav';
const PERSONA = params.get('persona') ||
  "You are Max Headroom: a sarcastic, paranoid AI video-host from a 1980s TV station. " +
  "You stutter on consonants ('p-p-people'), insult the caller, drop catchphrases like " +
  "'let's play some crackle' and 'boot boot boot', and never admit to being an assistant. " +
  "Keep replies to one or two punchy sentences.";

// ---- HUD DOM (v1's #stage is hidden by bootstrap.js) ----
document.body.insertAdjacentHTML('beforeend', `
<div id="stage2">
  <div id="frame2">
    <canvas id="scene2"></canvas>
    <div id="boot2">loading facecap…</div>
    <div id="topbar2">
      <span id="pill2">● OFF AIR</span>
      <span id="state2">STANDBY</span>
      <span id="feedtag2">FEED ${FEED.toUpperCase()}</span>
      <span id="stats2"></span>
      <button id="gear2" title="settings">CFG</button>
    </div>
    <div id="settings2">
      <label>persona</label><textarea id="persona2"></textarea>
      <label>audio door (personaplex)</label><input id="plex2"/>
      <label>blendshape bridge door</label><input id="door2"/>
      <div class="row"><label style="margin:0">feed</label>
        <select id="feed2">
          <option value="synthetic">synthetic (local)</option>
          <option value="bridge">bridge (A2F WS)</option>
          <option value="file">file (CSV replay)</option>
        </select></div>
      <div class="row"><input type="checkbox" id="wire2" style="width:auto"/><label for="wire2" style="margin:0">wireframe overlay</label></div>
      <div class="row"><button id="apply2" style="padding:6px 12px">apply &amp; reload</button></div>
    </div>
    <div id="caption2"></div>
  </div>
  <div id="bar2">
    <button id="go2">GO LIVE</button>
    <a id="verlink" href="./">← v1 (old renderer)</a>
    <span id="warn2"></span>
  </div>
</div>`);
document.getElementById('persona2').value = PERSONA;
document.getElementById('plex2').value = PLEX_DOOR;
document.getElementById('door2').value = BRIDGE_DOOR;
document.getElementById('feed2').value = FEED;

const canvas = document.getElementById('scene2');
const pillEl = document.getElementById('pill2');
const stateEl = document.getElementById('state2');
const statsEl = document.getElementById('stats2');
const captionEl = document.getElementById('caption2');
const goBtn = document.getElementById('go2');
const warnEl = document.getElementById('warn2');
document.getElementById('gear2').addEventListener('click', () =>
  document.getElementById('settings2').classList.toggle('open'));
document.getElementById('apply2').addEventListener('click', () => {
  const p = new URLSearchParams(location.search);
  p.set('v2', '1');
  p.set('feed', document.getElementById('feed2').value);
  p.set('plex', document.getElementById('plex2').value.trim());
  p.set('door', document.getElementById('door2').value.trim());
  const persona = document.getElementById('persona2').value.trim();
  if (persona === PERSONA) p.delete('persona'); else p.set('persona', persona);
  location.search = '?' + p;
});
document.getElementById('wire2').addEventListener('change', e => face && face.setWire(e.target.checked));

// ---- renderer ----
const renderer = new THREE.WebGLRenderer({ canvas, antialias: true });
renderer.setPixelRatio(Math.min(devicePixelRatio, 2));
renderer.outputColorSpace = THREE.SRGBColorSpace;
renderer.toneMapping = THREE.ACESFilmicToneMapping;
renderer.toneMappingExposure = 1.05;

let face = null, crt = null;
let feed = new Feed({ mode: FEED, door: BRIDGE_DOOR, file: BS_FILE,
  onStat: s => { feedStat = { ...feedStat, ...s }; } });
let feedStat = {};

// audio probes
let micProbe = null, outProbe = null, client = null;
const audio = { micLevel: 0, centroid: 0.5, speaking: false, outLevel: 0 };

try {
  face = await createFace(renderer);
  crt = createCrtPost(renderer, face.scene, face.cam);
  document.getElementById('boot2').remove();
  if (document.getElementById('wire2').checked) face.setWire(true);
} catch (e) {
  document.getElementById('boot2').textContent = '! face load failed: ' + e.message;
  console.error(e);
}

// mic capture for LISTENING state + synthetic feed (works with zero backend)
(async () => {
  try {
    const actx = new (window.AudioContext || window.webkitAudioContext)();
    const stream = await navigator.mediaDevices.getUserMedia(
      { audio: { echoCancellation: true, noiseSuppression: true, channelCount: 1 } });
    const an = actx.createAnalyser();
    an.fftSize = 1024; an.smoothingTimeConstant = 0.5;
    actx.createMediaStreamSource(stream).connect(an);
    micProbe = makeProbe(an);
  } catch (e) {
    warnEl.textContent = 'mic unavailable: ' + e.message;
  }
})();

feed.start(() => ({
  level: client && audio.outLevel > audio.micLevel ? audio.outLevel : audio.micLevel,
  centroid: audio.centroid,
  speaking: audio.outLevel > 0.05 || audio.micLevel > 0.025,
}));

// ---- plex connection (v1 logic, same protocol) ----
// The 0x02 stream arrives as small text fragments; assemble them into
// sentence-ish lines instead of one word per line.
let capDiv = null, capAt = 0;
function setCaption(txt, err = false) {
  const now = performance.now();
  if (err || !capDiv || now - capAt > 1500) {
    capDiv = document.createElement('div');
    if (err) capDiv.className = 'err';
    captionEl.appendChild(capDiv);
    while (captionEl.childNodes.length > 4) captionEl.removeChild(captionEl.firstChild);
  }
  capAt = now;
  const glue = (/^\s/.test(txt) || /\s$/.test(capDiv.textContent) || /^[.,!?…:;]/.test(txt)) ? '' : ' ';
  capDiv.textContent += glue + txt;
  capDiv.textContent = capDiv.textContent.replace(/\s+/g, ' ');
  if (/[.!?…]\s*$/.test(capDiv.textContent)) capDiv = null;
  captionEl.scrollTop = captionEl.scrollHeight;
  clearTimeout(setCaption._t);
  setCaption._t = setTimeout(() => { captionEl.textContent = ''; capDiv = null; }, 9000);
}

goBtn.addEventListener('click', async () => {
  if (client) { client.close(); client = null; goBtn.textContent = 'GO LIVE'; goBtn.classList.remove('on'); pillEl.classList.remove('live'); pillEl.textContent = '● OFF AIR'; return; }
  const d = document.getElementById('plex2').value.trim();
  const p = document.getElementById('persona2').value.trim() || PERSONA;
  const url = `${d}/api/chat?text_prompt=${encodeURIComponent(p)}&voice_prompt=${encodeURIComponent(VOICE)}`;
  client = new PlexClient({
    url,
    onStatus: s => { if (s === 'LIVE') { pillEl.classList.add('live'); pillEl.textContent = '● ON AIR'; } if (s === 'offline' || s === 'failed') { pillEl.classList.remove('live'); pillEl.textContent = '● OFF AIR'; client = null; } },
    onError: e => setCaption('! ' + e, true),
    onText: t => { if (t.trim()) setCaption(t); },
    onLevel: l => { audio.outLevel = l; },
  });
  try {
    await client.connect();
    const an = client.ctx.createAnalyser();
    an.fftSize = 1024; an.smoothingTimeConstant = 0.6;
    client.outTap = an;
    outProbe = makeProbe(an);
    goBtn.textContent = 'TAKE OFF AIR';
    goBtn.classList.add('on');
  } catch (e) {
    setCaption('! ' + e.message, true);
    client = null;
  }
});

// ---- state machine + render loop ----
let state = 'STANDBY';
setInterval(() => {
  if (micProbe) { const m = micProbe(); audio.micLevel = m.level; audio.centroid = m.centroid; }
  if (outProbe && client) { const o = outProbe(); audio.outLevel = Math.max(audio.outLevel, o.level); }
  if (!client) state = 'STANDBY';
  else if (audio.outLevel > 0.05) state = 'SPEAKING';
  else if (audio.micLevel > 0.03) state = 'LISTENING';
  else state = 'THINKING';
  stateEl.textContent = state;
  stateEl.className = state === 'SPEAKING' ? 'speak' : state === 'THINKING' ? 'think' : state === 'LISTENING' ? 'listen' : '';
}, 120);

let last = 0, frames = 0, fpsAt = 0, fps = 0, lastInFrames = 0, bps = 0;
function frame(tms) {
  const t = tms / 1000;
  const dt = Math.min(0.1, t - (last || t)); last = t;
  if (!face || !crt) { requestAnimationFrame(frame); return; }
  const w = canvas.clientWidth, h = canvas.clientHeight;
  if (canvas.width !== Math.floor(w * Math.min(devicePixelRatio, 2)) || canvas.height !== Math.floor(h * Math.min(devicePixelRatio, 2))) {
    renderer.setSize(w, h, false);
    crt.resize(w, h, renderer.getPixelRatio());
    face.cam.aspect = w / h; face.cam.updateProjectionMatrix();
  }
  feed.tick(t);
  feed.apply(face.influences, 1 - Math.exp(-dt * 18));
  const energy = Math.max(audio.micLevel * (state === 'LISTENING' ? 3 : 0), audio.outLevel * 2);
  face.update(t, dt, { energy });
  crt.render(t);
  frames++;
  if (t - fpsAt > 1) {
    fps = frames / (t - fpsAt); frames = 0; fpsAt = t;
    bps = (feed.inFrames - lastInFrames) / 1; lastInFrames = feed.inFrames;
    const live = feed.mode !== 'bridge' || !feedStat.bridgeStale;
    statsEl.textContent = `fps ${fps.toFixed(0)} · bs ${bps}/s ${feed.mode === 'bridge' ? (live ? '' : '(stale)') : ''} · out ${audio.outLevel.toFixed(2)} mic ${audio.micLevel.toFixed(2)}`;
  }
  requestAnimationFrame(frame);
}
requestAnimationFrame(frame);

// test surface (mirrors v1's window.__max)
window.__max2 = {
  get ready() { return !!face; },
  get face() { return face; },
  get influences() { return face ? Array.from(face.influences) : []; },
  get client() { return client; },
  get feed() { return feed; },
  get state() { return state; },
  // read back a normalized region of the WebGL canvas: {mean, p99, hot}
  probeRegion(x0, y0, x1, y1) {
    const g = canvas.getContext('webgl2') || canvas.getContext('webgl');
    if (!g) return null;
    if (crt) crt.render(performance.now() / 1000); // render now so the buffer is valid pre-swap
    const W = canvas.width, H = canvas.height;
    const bx = Math.floor(x0 * W), by = Math.floor(H - y1 * H);
    const bw = Math.max(1, Math.floor((x1 - x0) * W)), bh = Math.max(1, Math.floor((y1 - y0) * H));
    const buf = new Uint8Array(bw * bh * 4);
    g.readPixels(bx, by, bw, bh, g.RGBA, g.UNSIGNED_BYTE, buf);
    let sum = 0, hot = 0; const lum = [];
    for (let i = 0; i < buf.length; i += 4) {
      const l = 0.2126 * buf[i] + 0.7152 * buf[i + 1] + 0.0722 * buf[i + 2];
      sum += l; lum.push(l); if (l > 140) hot++;
    }
    lum.sort((a, b) => a - b);
    return { mean: +(sum / lum.length).toFixed(1), p99: lum[Math.floor(lum.length * 0.99)], hotPx: hot };
  },
};
