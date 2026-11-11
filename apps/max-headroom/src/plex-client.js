// PersonaPlex full-duplex WS client (protocol mirrors the live-validated
// duplex-bus harness bus/fdb_personaplex.py, cookertron-ppx/client/src/protocol):
//   on open: server sends 0x00 (handshake ack)
//   both directions: 0x01 + <Ogg Opus bytes> (arbitrary-size Ogg fragments)
//   0x02 + utf8 = text/monologue stream (drives our captions)
//   uplink: WebCodecs AudioEncoder(opus) + our Ogg muxer (sphn-exact geometry)
//   downlink: hand-rolled Ogg demux -> WebCodecs AudioDecoder -> scheduled playback

import { OggOpusMuxer, SR, FRAME } from './ogg-muxer.js';

export class PlexClient {
  constructor({ url, onText, onLevel, onStatus, onError }) {
    this.url = url; this.onText = onText; this.onLevel = onLevel;
    this.onStatus = onStatus; this.onError = onError;
    this.ws = null; this.rec = null; this.decoder = null;
    this.ctx = new (window.AudioContext || window.webkitAudioContext)({ sampleRate: SR });
    this.nextPlayTime = 0;
    this.oggBuf = new Uint8Array(0);
    this._handshakeOk = false;
  }

  async connect() {
    if (this.ws) return;
    this.onStatus('dialing…');
    this.ws = new WebSocket(this.url);
    this.ws.binaryType = 'arraybuffer';

    this.decoder = new AudioDecoder({
      output: (ad) => this._playAudioData(ad),
      error: (e) => this.onError('decoder: ' + e.message),
    });
    this.decoder.configure({ codec: 'opus', sampleRate: SR, numberOfChannels: 1 });

    this.ws.onopen = () => this.onStatus('handshake…');
    this.ws.onmessage = (ev) => this._onFrame(new Uint8Array(ev.data));
    this.ws.onclose = (ev) => { this.onStatus('offline'); this._teardown(); };
    this.ws.onerror = () => this.onError('ws error');
    await new Promise((res, rej) => {
      const t = setTimeout(() => rej(new Error('connect timeout')), 10000);
      const int = setInterval(() => {
        if (this.ws && this.ws.readyState === 1) { clearTimeout(t); clearInterval(int); res(); }
      }, 50);
    });
    await this._startMic();
  }

  async _startMic() {
    try {
      await this.ctx.resume();
      const stream = await navigator.mediaDevices.getUserMedia(
        { audio: { echoCancellation: true, noiseSuppression: true, channelCount: 1 } });
      this.micStream = stream;
      this.muxer = new OggOpusMuxer((page) => {
        if (!this.ws || this.ws.readyState !== 1) return;
        // The server's pre-handshake is_alive() probe consumes (and drops)
        // inbound messages; if we uplink before the 0x00 handshake the Ogg
        // header pages are lost and the reader dies. Queue until handshake.
        if (!this._handshakeOk) {
          this._pend = this._pend || [];
          if (this._pend.length < 500) this._pend.push(page);
          return;
        }
        const f = new Uint8Array(page.length + 1);
        f[0] = 0x01; f.set(page, 1);
        this.ws.send(f);
        this.upPages = (this.upPages || 0) + 1;
      });
      this.muxer.start();
      this.encoder = new AudioEncoder({
        output: (chunk) => {
          this._encOut = (this._encOut || 0) + 1;
          const buf = new Uint8Array(chunk.byteLength);
          chunk.copyTo(buf);
          this.muxer.addPacket(buf);
        },
        error: (e) => this.onError('encoder: ' + e.message),
      });
      this.encoder.configure({ codec: 'opus', sampleRate: SR, numberOfChannels: 1, bitrate: 32000 });
      const track = stream.getAudioTracks()[0];
      const reader = new MediaStreamTrackProcessor({ track }).readable.getReader();
      let acc = new Float32Array(0), ts = 0;
      (async () => {
        for (;;) {
          const { value: af, done } = await reader.read();
          if (done) break;
          this._pumpFrames = (this._pumpFrames || 0) + 1;
          const n0 = af.numberOfFrames;
          const rate = af.sampleRate;
          if (!Number.isFinite(rate) || rate <= 0 || !Number.isFinite(n0) || n0 <= 0) {
            af.close();
            this._badFrames = (this._badFrames || 0) + 1;
            continue;
          }
          let src = new Float32Array(n0);
          af.copyTo(src, { planeIndex: 0, format: 'f32-planar' });
          af.close();
          let data, n;
          if (rate !== SR) {
            n = Math.round(n0 * SR / rate);
            data = new Float32Array(n);
            for (let k = 0; k < n; k++) data[k] = src[Math.min(n0 - 1, Math.round(k * rate / SR))];
          } else {
            data = src; n = n0;
          }
          const m = new Float32Array(acc.length + n);
          m.set(acc); m.set(data, acc.length); acc = m;
          while (acc.length >= FRAME) {
            const frame = acc.slice(0, FRAME);
            acc = acc.subarray(FRAME);
            this.encoder.encode(new AudioData({
              format: 'f32-planar', sampleRate: SR, numberOfFrames: FRAME,
              numberOfChannels: 1, timestamp: ts, data: frame,
            }));
            ts += (FRAME * 1e6) / SR;
          }
        }
      })().catch((e) => this.onError('mic pump: ' + e.message));
      this.onStatus('LIVE');
    } catch (e) {
      this.onError('mic: ' + (e && e.message || e));
      this.onStatus('failed');
    }
  }

  _onFrame(f) {
    if (!f.length) return;
    const t = f[0], payload = f.subarray(1);
    if (t === 0x00) {
      this.onStatus('streaming');
      if (!this._handshakeOk) {
        this._handshakeOk = true;
        if (this._pend) {
          for (const page of this._pend) {
            const f = new Uint8Array(page.length + 1);
            f[0] = 0x01; f.set(page, 1);
            this.ws.send(f);
          }
          this.upPages = (this.upPages || 0) + this._pend.length;
          this._pend = null;
        }
      }
      return;
    }
    if (t === 0x01) { this.downBytes = (this.downBytes || 0) + payload.length; this._feedOgg(payload); return; }
    if (t === 0x02) {
      try { this.onText(new TextDecoder().decode(payload)); } catch (_) {}
      return;
    }
    // 0x03 control / 0x04 metadata / 0x05 error / 0x06 ping: minimal handling
    if (t === 0x05) this.onError('server: ' + new TextDecoder().decode(payload));
  }

  // ---- Ogg demux (server stream: OpusHead BOS + OpusTags + audio pages) ----
  _feedOgg(bytes) {
    const nb = new Uint8Array(this.oggBuf.length + bytes.length);
    nb.set(this.oggBuf); nb.set(bytes, this.oggBuf.length);
    this.oggBuf = nb;
    // find page boundaries
    for (;;) {
      const start = indexOfSeq(this.oggBuf, 0, [0x4f, 0x67, 0x67, 0x53]); // OggS
      if (start < 0) break;
      const end = indexOfSeq(this.oggBuf, start + 4, [0x4f, 0x67, 0x67, 0x53]);
      const page = this.oggBuf.subarray(start, end < 0 ? this.oggBuf.length : end);
      if (end < 0) break; // incomplete page
      this._parsePage(page);
      this.oggBuf = this.oggBuf.subarray(end);
    }
  }

  _parsePage(page) {
    if (page.length < 27) return;
    const nSeg = page[26];
    let pos = 27;
    const sizes = [];
    for (let i = 0; i < nSeg; i++) sizes.push(page[pos++]);
    let body = new Uint8Array(0);
    for (const s of sizes) {
      const chunk = page.subarray(pos, pos + s); pos += s;
      const nb = new Uint8Array(body.length + chunk.length);
      nb.set(body); nb.set(chunk, body.length); body = nb;
      if (s < 255) { this._emitPacket(body); body = new Uint8Array(0); }
    }
    if (body.length) { // laced continuation across pages — keep it
      if (!this._carry) this._carry = new Uint8Array(0);
      const nb = new Uint8Array(this._carry.length + body.length);
      nb.set(this._carry); nb.set(body, this._carry.length);
      this._carry = nb;
    }
  }

  _emitPacket(p) {
    if (this._carry && this._carry.length) {
      p = concat(this._carry, p); this._carry = new Uint8Array(0);
    }
    if (p.length >= 8 && strEq(p, 0, 'OpusHead')) { this._sentConfig = true; return; }
    if (p.length >= 8 && strEq(p, 0, 'OpusTags')) return;
    if (!this._sentConfig) return;
    const now = performance.now();
    this.decoder.decode(new EncodedAudioChunk({
      type: 'key', timestamp: now, data: p,
    }));
  }

  // ---- playback: schedule decoded PCM back-to-back ----
  _playAudioData(ad) {
    const n = ad.numberOfFrames, ch = ad.numberOfChannels;
    const buf = this.ctx.createBuffer(ch, n, ad.sampleRate);
    let dstLast = null;
    for (let c = 0; c < ch; c++) {
      const dst = buf.getChannelData(c);
      ad.copyTo(dst, { planeIndex: c, format: 'f32-planar' });
      dstLast = dst;
    }
    ad.close();
    const node = this.ctx.createBufferSource();
    node.buffer = buf;
    node.connect(this.ctx.destination);
    if (this.outTap) node.connect(this.outTap);
    const t = Math.max(this.ctx.currentTime + 0.02, this.nextPlayTime);
    node.start(t);
    this.nextPlayTime = t + buf.duration;
    this._latestLevel = rms(dstLast);
    if (this.onLevel) this.onLevel(this._latestLevel);
  }

  get level() { return this._latestLevel || 0; }

  close() {
    this._teardown();
    if (this.rec) { try { this.rec.stop(); } catch (_) {} }
    if (this.micStream) this.micStream.getTracks().forEach(t => t.stop());
    this.ctx.close();
  }

  _teardown() {
    if (this.decoder) { try { this.decoder.close(); } catch (_) {} this.decoder = null; }
    if (this.ws && this.ws.readyState <= 1) this.ws.close();
    this.ws = null;
  }
}

function indexOfSeq(arr, from, seq) {
  outer: for (let i = from; i <= arr.length - seq.length; i++) {
    for (let j = 0; j < seq.length; j++) if (arr[i + j] !== seq[j]) continue outer;
    return i;
  }
  return -1;
}
function concat(a, b) { const r = new Uint8Array(a.length + b.length); r.set(a); r.set(b, a.length); return r; }
function strEq(bytes, off, s) {
  for (let i = 0; i < s.length; i++) if (bytes[off + i] !== s.charCodeAt(i)) return false;
  return true;
}
function rms(f) {
  let s = 0; for (let i = 0; i < f.length; i += 4) s += f[i] * f[i];
  return Math.sqrt(s / (f.length / 4 + 1));
}
