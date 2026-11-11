// Minimal Ogg/Opus muxer with page geometry byte-identical to sphn's
// OpusStreamWriter (one packet per page, granulepos in 24k stream units,
// OpusHead preskip 3840 / input-rate field 24000) — the only shape the
// PersonaPlex server's sphn 0.1.12 reader accepts reliably over live WS
// (browser opus-recorder pages pass in offline probes but poison the
// server's reader channel statefully; verified 2026-11-11).

export const SR = 24000;
export const FRAME = 960; // 40 ms @24k — matches sphn writer frames

const CRC_TABLE = (() => {
  const t = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n << 24;
    for (let k = 0; k < 8; k++) c = (c & 0x80000000) ? ((c << 1) ^ 0x04c11db7) : (c << 1);
    t[n] = c >>> 0;
  }
  return t;
})();
function crc32_ogg(bytes) {
  let c = 0;
  for (let i = 0; i < bytes.length; i++) c = ((c << 8) ^ CRC_TABLE[((c >>> 24) ^ bytes[i]) & 0xff]) >>> 0;
  return c >>> 0;
}

const OPUS_HEAD = new Uint8Array([
  0x4f, 0x70, 0x75, 0x73, 0x48, 0x65, 0x61, 0x64, // OpusHead
  0x01,                   // version
  0x01,                   // channels
  0x00, 0x0f,             // pre-skip 3840 (LE)
  0xc0, 0x5d, 0x00, 0x00, // input sample rate 24000 (informational)
  0x00, 0x00,             // output gain
  0x00,                   // channel mapping family
]);
const VENDOR = new TextEncoder().encode('max-headroom');
const OPUS_TAGS = (() => {
  const id = new TextEncoder().encode('OpusTags');
  const out = new Uint8Array(8 + 4 + VENDOR.length + 4);
  out.set(id, 0);
  out[8] = VENDOR.length; // LE u32, vendor < 256
  out.set(VENDOR, 12);
  // comment count = 0 already
  return out;
})();

export class OggOpusMuxer {
  constructor(onPage) {
    this.onPage = onPage;
    this.serial = (Math.random() * 0xffffffff) >>> 0;
    this.seq = 0;
    this.granule = 0;
  }

  _page(payload, flags) {
    const n = payload.length;
    const nseg = Math.floor(n / 255) + 1;
    const body = new Uint8Array(27 + nseg + n);
    body.set([0x4f, 0x67, 0x67, 0x53, 0, flags]); // OggS ver hdr-type
    const dv = new DataView(body.buffer);
    dv.setBigUint64(6, BigInt(this.granule), true);
    dv.setUint32(14, this.serial, true);
    dv.setUint32(18, this.seq++, true);
    dv.setUint32(22, 0, true); // crc placeholder
    body[26] = nseg;
    for (let i = 0; i < nseg - 1; i++) body[27 + i] = 255;
    body[27 + nseg - 1] = n % 255;
    body.set(payload, 27 + nseg);
    dv.setUint32(22, crc32_ogg(body), true);
    return body;
  }

  start() {
    const h = this._page(OPUS_HEAD, 0x02); // BOS
    this.onPage(h);
    this.onPage(this._page(OPUS_TAGS, 0x00));
  }

  addPacket(opusPacket) {
    // granule accumulates in 24k samples, sphn-style
    this.granule += FRAME;
    this.onPage(this._page(opusPacket, 0x00));
  }
}
