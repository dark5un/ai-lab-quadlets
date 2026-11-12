// Ticket 01 spike — MAIN world at document_start.
// Patches getUserMedia + enumerateDevices so Meet gets a WebAudio synthetic mic
// (keepalive tone + replayed voice buffer) and a canvas slate camera.
// Kill switch: floating button, state in localStorage (sync-readable here).
(() => {
  if (window.__maxSpike) return;
  window.__maxSpike = true;

  const enabled = () => localStorage.getItem('maxSpike') !== 'off';

  // ---- audio graph (lazy: first getUserMedia after the Join click = sticky activation)
  let ac = null, dest = null, voiceBuffer = null, replayTimer = null;

  function ensureAudio() {
    if (ac) return;
    ac = new AudioContext(); // never force sampleRate: mismatch killed renderers in the wild
    dest = ac.createMediaStreamDestination();

    // keepalive: 30 Hz tone at gain 2e-4 — below hearing, past the analyser.
    // Meet mutes/drops tracks carrying pure digital silence.
    const osc = ac.createOscillator();
    osc.frequency.value = 30;
    const kg = ac.createGain();
    kg.gain.value = 2e-4;
    osc.connect(kg).connect(dest);
    osc.start();

    if (voiceBuffer) scheduleVoice();
  }

  function playVoice() {
    if (!ac || !voiceBuffer || ac.state !== 'running') return;
    const src = ac.createBufferSource();
    src.buffer = voiceBuffer;
    src.connect(dest);
    src.start();
  }

  function scheduleVoice() {
    if (replayTimer) return;
    playVoice();
    replayTimer = setInterval(playVoice, 6000); // so the peer hears it repeatedly
  }

  window.addEventListener('message', (e) => {
    if (e.source !== window || !e.data || e.data.type !== 'max-voice-pcm') return;
    ensureAudio();
    ac.decodeAudioData(e.data.buf.slice(0)).then((b) => {
      voiceBuffer = b;
      if (enabled()) scheduleVoice();
    }).catch(() => {});
  });

  // ---- canvas slate (so the owner's real face never leaks into the test tile)
  let canvas = null, videoTrack = null;

  function draw() {
    const ctx = canvas.getContext('2d');
    ctx.fillStyle = '#101820';
    ctx.fillRect(0, 0, canvas.width, canvas.height);
    ctx.fillStyle = '#7fd0c0';
    ctx.font = '28px monospace';
    ctx.fillText('MAX SPIKE v0.1', 40, 220);
    ctx.fillStyle = '#889';
    ctx.font = '18px monospace';
    ctx.fillText('synthetic camera track', 40, 260);
    ctx.fillText(enabled() ? 'SPIKE ON' : 'SPIKE OFF', 40, 300);
  }

  function ensureVideo() {
    if (videoTrack) return videoTrack;
    canvas = document.createElement('canvas');
    canvas.width = 640; canvas.height = 480;
    canvas.style.position = 'fixed';
    canvas.style.left = '-10000px';
    document.documentElement.appendChild(canvas);
    draw();
    // captureStream(30) continuous — captureStream(0)+manual push reads as frozen and gets dropped.
    videoTrack = canvas.captureStream(30).getVideoTracks()[0];
    try { videoTrack.label = 'MAX Camera'; } catch (_) {}
    setInterval(draw, 1000);
    return videoTrack;
  }

  // ---- the overrides (triple converges in every prior-art repo)
  const md = navigator.mediaDevices;
  const _gum = md.getUserMedia.bind(md);
  const _enum = md.enumerateDevices.bind(md);

  md.getUserMedia = async (constraints) => {
    const c = constraints || {};
    if (!enabled() || (!c.video && !c.audio)) return _gum(c);
    const tracks = [];
    if (c.audio) {
      ensureAudio();
      if (ac.state === 'suspended') ac.resume().catch(() => {});
      scheduleVoice();
      const at = dest.stream.getAudioTracks()[0];
      try { at.label = 'MAX Microphone'; } catch (_) {}
      tracks.push(at);
    }
    if (c.video) tracks.push(ensureVideo());
    // new MediaStream per call sharing the same tracks — same object twice = Meet kills both consumers.
    return new MediaStream(tracks);
  };

  md.enumerateDevices = async () => {
    const devs = await _enum();
    if (!enabled()) return devs;
    const fakes = [
      { deviceId: 'max-spike-cam', kind: 'videoinput', label: 'MAX Camera', groupId: 'max-spike-g1' },
      { deviceId: 'max-spike-mic', kind: 'audioinput', label: 'MAX Microphone', groupId: 'max-spike-g2' },
    ];
    return fakes.concat(devs); // with no camera enumerated, Meet disables controls and never calls gUM
  };
})();
