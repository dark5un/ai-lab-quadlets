import * as THREE from 'three';
import { PlexClient } from './plex-client.js';
import { buildHead, makeClassifier, VISEMES } from './face.js';

// ---- defaults (overridable in UI) ----
const params = new URLSearchParams(location.search);
// Personaplex door: tailscale https listener on this node's hostname.
const door = params.get('door') || `wss://${location.hostname}:8456`;
const PERSONA = params.get('persona') ||
  "You are Max Headroom: a sarcastic, paranoid AI video-host from a 1980s TV station. " +
  "You stutter on consonants ('p-p-people'), insult the caller, drop catchphrases like " +
  "'let's play some crackle' and 'boot boot boot', and never admit to being an assistant. " +
  "Keep replies to one or two punchy sentences.";
const voice = params.get('voice') || 'pxvoice.wav';
const wsUrl = `${door}/api/chat?text_prompt=${encodeURIComponent(PERSONA)}&voice_prompt=${encodeURIComponent(voice)}`;

// ---- three.js scene ----
const canvas = document.getElementById('scene');
const renderer = new THREE.WebGLRenderer({ canvas, antialias: true, alpha: true });
renderer.setPixelRatio(Math.min(devicePixelRatio, 2));
const scene = new THREE.Scene();
const cam = new THREE.PerspectiveCamera(32, 1, 0.1, 50);
cam.position.set(0, -0.05, 4.2);
scene.add(new THREE.AmbientLight(0x224466, 1.2));
const key = new THREE.PointLight(0x66ccff, 40, 20); key.position.set(2, 2, 4); scene.add(key);
const rim = new THREE.PointLight(0xff4488, 18, 20); rim.position.set(-3, -1, -2); scene.add(rim);

const head = buildHead();
head.group.rotation.y = -0.15;
scene.add(head.group);

function resize() {
  const w = canvas.clientWidth, h = canvas.clientHeight;
  if (canvas.width !== w || canvas.height !== h) {
    renderer.setSize(w, h, false);
    cam.aspect = w / h; cam.updateProjectionMatrix();
  }
}

const idx = {}; VISEMES.forEach((v, i) => idx[v] = i);
const targets = new Array(head.influences.length).fill(0);

// glitch effect: occasional y-jerk + hue pop when speaking loud
let nextGlitch = 0;

function frame(t) {
  resize();
  // viseme smoothing
  for (let i = 0; i < targets.length; i++)
    head.influences[i] += (targets[i] - head.influences[i]) * 0.35;
  // eye jitter (Max's twitchy gaze)
  const jx = Math.sin(t * 0.0021) * 0.02 + (Math.random() - 0.5) * 0.006;
  const jy = Math.cos(t * 0.0013) * 0.015 + (Math.random() - 0.5) * 0.006;
  head.eyeL.position.x = -0.27 + jx; head.eyeL.position.y = 0.16 + jy;
  head.eyeR.position.x = 0.27 + jx; head.eyeR.position.y = 0.16 + jy;
  // head sway
  head.group.rotation.y = -0.15 + Math.sin(t * 0.0007) * 0.06;
  head.group.rotation.x = Math.sin(t * 0.0011) * 0.03;
  // glitch
  if (t > nextGlitch && client && client.level > 0.12 && Math.random() < 0.02) {
    head.group.position.y = (Math.random() - 0.5) * 0.08;
    rim.intensity = 40;
    nextGlitch = t + 120;
  } else if (t > nextGlitch) {
    head.group.position.y = 0; rim.intensity = 18;
  }
  renderer.render(scene, cam);
  requestAnimationFrame(frame);
}
requestAnimationFrame(frame);

// ---- audio analysis wiring ----
let analyser = null, classify = null;
let client = null;

document.getElementById('door').value = door;
document.getElementById('persona').value = PERSONA;
const statusEl = document.getElementById('status');
const captionEl = document.getElementById('caption');
const statsEl = document.getElementById('stats');
const goBtn = document.getElementById('go');

addEventListener('keydown', (e) => {
  if (e.key === 's' && e.target.tagName !== 'INPUT') head.shades.visible = !head.shades.visible;
});

let captionTimer = null;
function setCaption(txt) {
  captionEl.textContent = txt;
  clearTimeout(captionTimer);
  captionTimer = setTimeout(() => { captionEl.textContent = ''; }, 6000);
}

goBtn.addEventListener('click', async () => {
  if (client) { client.close(); client = null; goBtn.textContent = 'GO LIVE'; goBtn.classList.remove('on'); statusEl.textContent = 'standby'; return; }
  const d = document.getElementById('door').value.trim();
  const p = document.getElementById('persona').value.trim();
  const url = `${d}/api/chat?text_prompt=${encodeURIComponent(p)}&voice_prompt=${encodeURIComponent(voice)}`;
  client = new PlexClient({
    url,
    onStatus: s => statusEl.textContent = s,
    onError: e => setCaption('! ' + e),
    onText: t => { if (t.trim()) setCaption(t); },
  });
  // analyser tap on the client's AudioContext
  analyser = client.ctx.createAnalyser();
  analyser.fftSize = 1024;
  analyser.smoothingTimeConstant = 0.6;
  client.outTap = analyser;
  classify = makeClassifier(analyser);
  try {
    await client.connect();
    goBtn.textContent = 'OFF AIR';
    goBtn.classList.add('on');
  } catch (e) {
    setCaption('! ' + e.message);
    statusEl.textContent = 'failed';
    client = null;
  }
});

// viseme update loop (independent of render rate)
window.__max = { head, get client() { return client; } };
setInterval(() => {
  if (!classify || !client) { targets.fill(0); return; }
  const v = classify();
  targets.fill(0);
  const i = idx[v];
  if (i !== undefined && v !== 'sil') targets[i] = 1;
  statsEl.textContent = `viseme:${v} level:${client ? client.level.toFixed(2) : '-'}`;
}, 40);
