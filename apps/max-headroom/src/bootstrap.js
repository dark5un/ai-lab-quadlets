// v2 bootstrap: picks v1 or v2 without touching v1 files.
// ?v2=1 -> new face/HUD; everything else stays exactly v1.
const params = new URLSearchParams(location.search);
const useV2 = params.has('v2') && params.get('v2') !== '0';

if (useV2) {
  document.body.dataset.app = 'v2';
  document.getElementById('stage').style.display = 'none';
  import('./main2.js');
} else {
  import('./main.js');
  const a = document.createElement('a');
  a.id = 'v2link';
  a.textContent = 'V2 // new face →';
  a.style.cssText = 'margin-left:auto;color:#9df;text-decoration:underline;';
  // carry v1's plex door over as v2's audio door (v2's ?door= is the bs bridge)
  const p = new URLSearchParams();
  p.set('v2', '1');
  const d = params.get('door');
  if (d) p.set('plex', d);
  a.href = `${location.pathname}?${p}`;
  document.getElementById('controls').appendChild(a);
}
