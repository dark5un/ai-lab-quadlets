/* max-call injector (both roles; auto-detects by presence of __maxRole).
 * Driver sets window.__maxRole = 'call' | 'app' via evaluateOnNewDocument
 * per page before scripts run.
 *
 * CALL role:
 *   getUserMedia -> video: window.__maxCanvas (driver paints mirrored app
 *                  frames); audio: AudioContext sink fed by __maxPushAudio
 *   RTCPeerConnection track handler -> remote audio -> __maxPopRemoteAudio
 * APP role:
 *   WebSocket wrapper -> binary messages (plex downlink ogg pages) are
 *                  siphoned into __maxPopDownlink (originals still delivered)
 *   getUserMedia audio -> mic stream fed by __maxPushMic (call far-end pcm)
 */
(() => {
  const outQ = [];   // call: remote audio b64 chunks (48k s16)
  const micQ = [];   // app: mic-in chunks (24k s16 -> fed as 48k upsampled)
  const dlQ = [];    // app: downlink ogg page b64
  const audioIn = []; // call: Max voice chunks (24k s16)

  window.__maxPushAudio = (b64) => { audioIn.push(b64); };
  window.__maxPushMic = (b64) => { micQ.push(b64); };
  window.__maxPopRemoteAudio = () => outQ.splice(0, outQ.length);
  window.__maxPopDownlink = () => dlQ.splice(0, dlQ.length);

  const canvas = document.createElement('canvas');
  canvas.width = 640; canvas.height = 480;
  canvas.getContext('2d').fillStyle = '#000';
  canvas.getContext('2d').fillRect(0, 0, 640, 480);
  window.__maxCanvas = canvas;

  let actx = null;
  function ctx48() {
    if (!actx) actx = new (window.AudioContext || window.webkitAudioContext)
      ({ sampleRate: 48000 });
    if (actx.state === 'suspended') actx.resume();
    return actx;
  }
  function b64toInt16(b64) {
    const bin = atob(b64); const u8 = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) u8[i] = bin.charCodeAt(i);
    return new Int16Array(u8.buffer, 0, u8.length >> 1);
  }
  function int16ToB64(i16) {
    const u8 = new Uint8Array(i16.buffer);
    let s = '';
    for (let i = 0; i < u8.length; i += 0x8000)
      s += String.fromCharCode.apply(null, u8.subarray(i, i + 0x8000));
    return btoa(s);
  }
  window.__maxInt16ToB64 = int16ToB64;

  // generic queue-fed mono source node (upsample 24k queue items to 48k)
  function queueSource(ac, queue) {
    const proc = ac.createScriptProcessor(512, 1, 1); // 10 ms @48k
    let cur = new Float32Array(0), idx = 0;
    proc.onaudioprocess = (e) => {
      const o = e.outputBuffer.getChannelData(0);
      let p = 0;
      while (p < o.length) {
        if (idx >= cur.length) {
          if (!queue.length) { o.fill(0, p); return; }
          const i16 = b64toInt16(queue.shift());
          const up = new Float32Array(i16.length * 2);
          for (let i = 0; i < i16.length; i++) {
            up[2 * i] = i16[i] / 32768;
            up[2 * i + 1] = (i + 1 < i16.length ? (i16[i] + i16[i + 1]) / 2 : i16[i]) / 32768;
          }
          cur = up; idx = 0;
        }
        o[p++] = cur[idx++];
      }
    };
    return proc;
  }

  const md = navigator.mediaDevices;
  const realGUM = md.getUserMedia.bind(md);
  let videoTrack = null;

  // device spoofing (call role): Meet's prejoin gates on enumerateDevices
  if (window.__maxRole === 'call' && md.enumerateDevices) {
    const realEnum = md.enumerateDevices.bind(md);
    md.enumerateDevices = async () => {
      const devs = await realEnum();
      return devs.concat([
        { kind: 'videoinput', deviceId: 'max-cam', label: 'Max Headroom Camera', groupId: 'maxcam' },
        { kind: 'audioinput', deviceId: 'max-mic', label: 'Max Headroom Microphone', groupId: 'maxmic' },
        { kind: 'audiooutput', deviceId: 'max-out', label: 'Max Headroom Speakers', groupId: 'maxmic' },
      ]);
    };
  }

  md.getUserMedia = async (constraints) => {
    const c = constraints || {};
    const role = window.__maxRole;
    if (!c.video && !c.audio) return realGUM(c);
    const stream = new MediaStream();
    if (c.video && role === 'call') {
      if (!videoTrack) videoTrack = canvas.captureStream(30).getVideoTracks()[0];
      stream.addTrack(videoTrack);
    } else if (c.video) {
      // app role: video not required; Meet-like pages only on call role
    }
    if (c.audio) {
      const ac = ctx48();
      const dest = ac.createMediaStreamDestination();
      const src = queueSource(ac, role === 'call' ? audioIn : micQ);
      src.connect(dest);
      src.connect(ac.destination); // ScriptProcessor needs a sink path to run
      for (const t of dest.stream.getAudioTracks()) stream.addTrack(t);
    }
    return stream;
  };

  function role_is_call_page() { return window.__maxRole === 'call'; }
  // remote audio tap (call role): Proxy-wrap RTCPeerConnection
  // (Proxy keeps Function.prototype.toString() === 'function () { [native code] }')
  if (role_is_call_page() && !window.__maxNoPc) {
    const RealPC = window.RTCPeerConnection;
    window.RTCPeerConnection = new Proxy(RealPC, {
      construct(target, args, newT) {
        const pc = Reflect.construct(target, args, newT);
        try {
          pc.addEventListener('track', (ev) => {
            if (ev.track.kind !== 'audio') return;
            const ac = ctx48();
            const src = ac.createMediaStreamSource(new MediaStream([ev.track]));
            const chunks = [];
            const proc = ac.createScriptProcessor(512, 1, 1);
            proc.onaudioprocess = (e) => {
              const inp = e.inputBuffer.getChannelData(0);
              const i16 = new Int16Array(inp.length);
              for (let k = 0; k < inp.length; k++)
                i16[k] = Math.max(-32768, Math.min(32767, inp[k] * 32767)) | 0;
              chunks.push(i16);
              if (chunks.length >= 4) {
                let n = 0; chunks.forEach(x => n += x.length);
                const all = new Int16Array(n); let o = 0;
                chunks.forEach(x => { all.set(x, o); o += x.length; });
                outQ.push(int16ToB64(all)); chunks.length = 0;
              }
            };
            src.connect(proc);
            const sink = ac.createGain(); sink.gain.value = 0;
            proc.connect(sink); sink.connect(ac.destination);
          });
        } catch (e) { /* ignore */ }
        return pc;
      },
    });
  }


  // WebSocket siphon (app role) via Proxy (native toString preserved)
  if (window.__maxRole === 'app' && !window.__maxNoWs) {
    const RealWS = window.WebSocket;
    window.WebSocket = new Proxy(RealWS, {
      construct(target, args) {
        const ws = Reflect.construct(target, args);
        ws.addEventListener('message', (ev) => {
          if (typeof ev.data !== 'string' && dlQ.length < 600) {
            const buf = new Uint8Array(ev.data);
            let s2 = '';
            for (let i2 = 0; i2 < buf.length; i2 += 0x8000)
              s2 += String.fromCharCode.apply(null, buf.subarray(i2, i2 + 0x8000));
            dlQ.push(btoa(s2));
          }
        });
        return ws;
      },
    });
  }
})();
