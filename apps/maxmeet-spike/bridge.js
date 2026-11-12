// ISOLATED world: ships the bundled voice wav bytes to the MAIN-world script
// (MediaStream objects can't cross worlds; raw bytes can), and draws the kill switch.
(async () => {
  try {
    const r = await fetch(chrome.runtime.getURL('voice.wav'));
    const buf = await r.arrayBuffer();
    const post = () => window.postMessage({ type: 'max-voice-pcm', buf: buf.slice(0) }, '*');
    post();
    // MAIN script may not be up yet at document_start; one retry after DOM ready.
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', post);
  } catch (_) {}

  const btn = document.createElement('button');
  const paint = () => {
    const on = localStorage.getItem('maxSpike') !== 'off';
    btn.textContent = on ? 'MAX SPIKE: ON' : 'MAX SPIKE: OFF';
    btn.style.cssText = 'position:fixed;z-index:2147483647;bottom:16px;left:16px;padding:8px 12px;' +
      'font:13px monospace;cursor:pointer;border-radius:6px;border:1px solid #555;' +
      'background:' + (on ? '#0a3d2e' : '#3d0a0a') + ';color:#eee;';
  };
  btn.addEventListener('click', () => {
    const on = localStorage.getItem('maxSpike') !== 'off';
    localStorage.setItem('maxSpike', on ? 'off' : 'on');
    paint();
  });
  paint();
  (document.body || document.documentElement).appendChild(btn);
})();
