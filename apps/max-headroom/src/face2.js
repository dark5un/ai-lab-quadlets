// v2 renderer module: loads the vendored facecap.glb (Meshopt + KTX2), applies
// a designed "CRT mannequin-chrome" material in a cyan-phosphor palette with a
// fresnel rim, adds an optional subtle wireframe overlay, and runs procedural
// idle motion + gaze (A2F-style feeds won't animate eyes/head for us).
import * as THREE from 'three';
import { GLTFLoader } from 'three/addons/loaders/GLTFLoader.js';
import { KTX2Loader } from 'three/addons/loaders/KTX2Loader.js';
import { MeshoptDecoder } from 'three/addons/libs/meshopt_decoder.module.js';
import { RoomEnvironment } from 'three/addons/environments/RoomEnvironment.js';
import { noise } from './synth2.js';
import { MORPH_COUNT, FACECAP_INDEX } from './morph-map.js';

// ---- CRT cyan-phosphor palette (FRIENDLIER pass 2026-11-12: owner said
// Max read as scary — lifted the void, softened the chrome, dimmed glow) ----
export const PAL = {
  bg: 0x16212e,       // void lift (was 0x04090d, then 0x0c1520 — still read black)
  rim: 0x2ee6ff,      // single accent
  skin: 0x9db9c6,     // was 0x6fa8bd — brighter, less liquid-metal
  eye: 0x0a1a22,
  eyeGlow: 0x35e6ff,
  teeth: 0xbfd8e0,
};

function fresnelPatch(color, strength, power) {
  return (shader) => {
    shader.uniforms.uRimColor = { value: new THREE.Color(color) };
    shader.uniforms.uRimStr = { value: strength };
    shader.uniforms.uRimPow = { value: power };
    shader.fragmentShader = `uniform vec3 uRimColor; uniform float uRimStr; uniform float uRimPow;\n` +
      shader.fragmentShader.replace('#include <opaque_fragment>',
        `outgoingLight += uRimColor * uRimStr * pow(saturate(1.0 - dot(normal, normalize(vViewPosition))), uRimPow);
         #include <opaque_fragment>`);
  };
}

export async function createFace(renderer, { modelUrl = './facecap.glb', transcoderPath = './basis/' } = {}) {
  const ktx2 = new KTX2Loader().setTranscoderPath(transcoderPath).detectSupport(renderer);
  const gltf = await new Promise((res, rej) => {
    const l = new GLTFLoader();
    l.setMeshoptDecoder(MeshoptDecoder);
    l.setKTX2Loader(ktx2);
    l.load(modelUrl, res, undefined, rej);
  });

  const root = gltf.scene;

  // find parts
  let headMesh = null, teethMesh = null;
  const eyeGroups = [];       // grp_eyeLeft / grp_eyeRight (gaze bones)
  const eyeMeshes = [];
  root.traverse(o => {
    if (o.isMesh) {
      if (o.morphTargetInfluences && o.morphTargetInfluences.length >= MORPH_COUNT) headMesh = o;
      else if (/teeth/i.test(o.name || '') || /teeth/i.test(o.parent?.name || '')) teethMesh = o;
      else eyeMeshes.push(o);
    }
    if (/^grp_eye/.test(o.name || '')) eyeGroups.push(o);
  });
  if (!headMesh) throw new Error('face2: head mesh with ' + MORPH_COUNT + ' morphs not found in ' + modelUrl);

  // ---- materials: glossy chrome mannequin, cyan phosphor ----
  const map = headMesh.material?.map || null;

  // mouth dimmer in HEAD-MESH LOCAL space (follows rig rotation + jaw morphs):
  // the scan carries real tooth geometry inside the mouth; on chrome it
  // sparkles as a bead row — suppress lighting inside a sphere there.
  // (sphere center/radius computed after rig normalization below)
  const mouthU = { value: new THREE.Vector3() };
  const mouthRadU = { value: 1 };

  const skin = new THREE.MeshPhysicalMaterial({
    color: PAL.skin, map: map || undefined,
    metalness: 0.4, roughness: 0.55,          // was 0.7/0.38 — wet chrome
    clearcoat: 0.3, clearcoatRoughness: 0.5,  // was 0.6/0.4
    envMapIntensity: 1.0,
    emissive: 0x062b38, emissiveIntensity: 0.35,  // was 0.55; 0.25 made the face dead
  });
  skin.onBeforeCompile = ((rim) => (sh) => {
    rim(sh);
    sh.uniforms.uMouthP = mouthU;
    sh.uniforms.uMouthR = mouthRadU;
    sh.vertexShader = 'varying vec3 vObjPosS;\n' +
      sh.vertexShader.replace('#include <project_vertex>',
        'vObjPosS = transformed;\n#include <project_vertex>');
    sh.fragmentShader = 'varying vec3 vObjPosS;\nuniform vec3 uMouthP;\nuniform float uMouthR;\n' +
      sh.fragmentShader;
    // the facecap texture has white teeth painted into the mouth region —
    // soft-clamp near-white map pixels so they read as dark cavity, not beads
    sh.fragmentShader = sh.fragmentShader.replace('diffuseColor *= sampledDiffuseColor;',
      `{ vec3 sc = sampledDiffuseColor.rgb;
         float scL = dot(sc, vec3(0.2126, 0.7152, 0.0722));
         // ONLY crush near-white (painted teeth) — was smoothstep(0.22,0.65)+0.09
         // which turned the entire lit face into a black mask (round-3, 2026-11-12)
         float knee = smoothstep(0.62, 0.95, scL);
         sc = mix(sc, vec3(0.22, 0.26, 0.28), knee);
         diffuseColor *= vec4(sc, sampledDiffuseColor.a); }`);
    // and dim all lighting inside the (local-space) mouth sphere
    // mouth dimmer: SMALLER sphere, GENTLER crush — the old 0.8*dim over a
    // 0.4r sphere shadowed the entire lower face into a black mask
    sh.fragmentShader = sh.fragmentShader.replace('#include <opaque_fragment>',
      `float dM = distance(vObjPosS, uMouthP);
       float mMask = 1.0 - smoothstep(0.15 * uMouthR, uMouthR, dM);
       outgoingLight *= (1.0 - 0.45 * mMask);
       #include <opaque_fragment>`);
  })(fresnelPatch(PAL.rim, 0.55, 2.8));
  headMesh.material = skin;
  headMesh.frustumCulled = false; // morphs move verts past the static bounds

  // inner shell: the facecap is a closed scan, so the open jaw reveals the
  // inside of the shell. Render backfaces dark + matte (no chrome sparkle,
  // no beaded lip-rim speculars) -> reads as a shadowed cavity.
  const innerSkin = new THREE.MeshStandardMaterial({
    color: 0x04070a, roughness: 1.0, metalness: 0.0,
    side: THREE.BackSide, envMapIntensity: 0.02,
    emissive: 0x000000, emissiveIntensity: 0.0,
    polygonOffset: true, polygonOffsetFactor: 2, polygonOffsetUnits: 2,
  });
  const innerMesh = new THREE.Mesh(headMesh.geometry, innerSkin);
  innerMesh.morphTargetInfluences = headMesh.morphTargetInfluences; // shared
  innerMesh.frustumCulled = false;
  // shrink along normals a hair so the rim never coincides with the front
  // shell (z-fighting sparkles along the lip line)
  innerSkin.onBeforeCompile = (sh) => {
    sh.vertexShader = sh.vertexShader.replace('#include <begin_vertex>',
      '#include <begin_vertex>\ntransformed -= normalize(objectNormal) * 300.0;'); // raw scan units (~12k tall head): ~2.5% inset
  };
  headMesh.add(innerMesh);

  // eyes: painted iris/sclera from the facecap texture + a tight wet
  // specular (catchlight) so they read as eyes, not drilled holes
  const eyeMat = new THREE.MeshPhysicalMaterial({
    color: 0x9fb4bd, map: map || undefined,   // was 0xcfe0e6 — white decal eyes
    metalness: 0.1, roughness: 0.12,
    clearcoat: 1, clearcoatRoughness: 0.04, envMapIntensity: 1.0,
    emissive: PAL.eyeGlow, emissiveIntensity: 0.02,   // was 0.06
  });
  eyeMat.onBeforeCompile = fresnelPatch(PAL.eyeGlow, 0.14, 2.4);  // was 0.35/2.0 — glowing wedges -> quiet eyes with catchlights
  eyeMeshes.forEach(m => { m.material = eyeMat; m.frustumCulled = false; });

  const teethMat = new THREE.MeshStandardMaterial({
    color: 0x4a5a60, metalness: 0.3, roughness: 0.6,
    emissive: PAL.rim, emissiveIntensity: 0.0,
  });
  if (teethMesh) { teethMesh.material = teethMat; teethMesh.frustumCulled = false; }
  // facecap's teeth read as a zipper of glowing pills on a chrome face;
  // a mannequin has none — hide them, keep the dark double-sided mouth.
  const SHOW_TEETH = new URLSearchParams(location.search).has('teeth');
  if (teethMesh) teethMesh.visible = SHOW_TEETH;

  // eye catchlights: tiny always-bright dots sell "wet glass" on a chrome face
  {
    const gl = new THREE.MeshBasicMaterial({ color: 0xdcecf2, toneMapped: false });
    eyeMeshes.forEach(em => {
      em.updateWorldMatrix(true, false);
      const b = new THREE.Box3().setFromObject(em);
      const sz = b.getSize(new THREE.Vector3());
      const c = b.getCenter(new THREE.Vector3());
      const r = Math.max(...sz) / 2;
      const u0 = em.worldToLocal(c.clone());
      const u1 = em.worldToLocal(c.clone().add(new THREE.Vector3(0, 1, 0)));
      const unit = u1.distanceTo(u0) || 1;
      const dot = new THREE.Mesh(new THREE.SphereGeometry(r * 0.10 * unit, 10, 10), gl);  // was 0.22 — big glowing blob
      dot.position.copy(em.worldToLocal(
        c.clone().add(new THREE.Vector3(-r * 0.05, r * 0.24, r * 1.15))));
      em.add(dot);
    });
  }

  // facecap's teeth mesh has no morphs: drop it with jawOpen so it doesn't
  // hang in the open mouth. (local->world scale measured after rig
  // normalization below.)
  let teethBaseY = 0, teethUnit = 1;
  const JAW = FACECAP_INDEX.jawOpen;

  // optional subtle wire overlay (NOT the primary look)
  let wire = null;
  function setWire(on) {
    if (on && !wire) {
      wire = new THREE.Mesh(headMesh.geometry, new THREE.MeshBasicMaterial({
        color: PAL.rim, wireframe: true, transparent: true, opacity: 0.07, depthWrite: false,
      }));
      wire.morphTargetInfluences = headMesh.morphTargetInfluences; // shared
      wire.frustumCulled = false;
      headMesh.add(wire);
    } else if (!on && wire) { headMesh.remove(wire); wire.geometry = null; wire = null; }
  }

  // ---- normalize size/center: head ~1.0 unit tall at origin-ish ----
  const box = new THREE.Box3().setFromObject(headMesh);
  const size = box.getSize(new THREE.Vector3());
  const center = box.getCenter(new THREE.Vector3());
  const k = 1.0 / Math.max(size.y, 1e-6);
  const rig = new THREE.Group();            // animated pivot
  root.scale.setScalar(k);
  root.position.set(-center.x * k, -center.y * k, -center.z * k);
  rig.add(root);
  if (teethMesh) {
    root.updateMatrixWorld(true);
    teethBaseY = teethMesh.position.y;
    const p0 = teethMesh.localToWorld(new THREE.Vector3(0, 0, 0));
    const p1 = teethMesh.localToWorld(new THREE.Vector3(0, 1, 0));
    teethUnit = p1.distanceTo(p0) || 1;
  }
  // mouth-dimmer sphere: rig-space point -> headMesh local (rig is identity now)
  {
    headMesh.updateWorldMatrix(true, false);
    const mw = new THREE.Vector3(0, -0.26, 0.28);
    const a = headMesh.worldToLocal(mw.clone());
    const b = headMesh.worldToLocal(mw.clone().add(new THREE.Vector3(0, 0.26, 0)));
    mouthU.value.copy(a);
    mouthRadU.value = b.distanceTo(a);
  }
  const scene = new THREE.Scene();
  scene.background = new THREE.Color(PAL.bg);
  // soft studio env (blurred + dimmed panels so RoomEnvironment's ceiling
  // lights don't read as hard rectangles on the chrome)
  const envScene = new RoomEnvironment();
  envScene.traverse(o => {
    if (o.isMesh && o.material && o.material.emissive &&
        o.material.emissiveIntensity >= 1) {
      o.material = new THREE.MeshBasicMaterial({ color: 0x7f97a3 });
    }
  });
  scene.environment = new THREE.PMREMGenerator(renderer)
    .fromScene(envScene, 0.15).texture;
  scene.add(rig);

  // interior light: faint fill so the cavity isn't pure black
  const inner = new THREE.PointLight(0x1a3c48, 0.25, 0.9, 1.6);
  inner.position.set(0, -0.14, 0.16);
  rig.add(inner);

  // ---- Suit bust (owner 2026-11-12: "a guy in a suit like Max Headroom") ----
  // The pedestal cone + glowing ring read as a severed head on a bust stand
  // (scary). Head now sits on a fabric neck inside a jacketed newscaster
  // bust: shoulders, shirt V, collar wings, teal tie. Stylized chrome face
  // kept on purpose — character, not uncanny human.
  const neck = new THREE.Mesh(
    new THREE.CylinderGeometry(0.16, 0.185, 0.26, 24),
    new THREE.MeshPhysicalMaterial({
      color: 0x8fb0be, metalness: 0.45, roughness: 0.5, envMapIntensity: 0.9,
    }));
  neck.position.set(0, -0.46, 0.02);

  const jacketMat = new THREE.MeshStandardMaterial({ color: 0x2a3446, roughness: 0.9, metalness: 0.05 });
  const js = new THREE.Shape();
  js.moveTo(-0.92, -1.10);
  js.quadraticCurveTo(-0.90, -0.52, -0.55, -0.44);   // left shoulder slope
  js.quadraticCurveTo(-0.30, -0.40, -0.20, -0.42);   // in to the collar
  js.lineTo(0.20, -0.42);                            // collar line (under chin)
  js.quadraticCurveTo(0.30, -0.40, 0.55, -0.44);     // right shoulder
  js.quadraticCurveTo(0.90, -0.52, 0.92, -1.10);
  js.lineTo(-0.92, -1.10);
  const jacket = new THREE.Mesh(
    new THREE.ExtrudeGeometry(js, { depth: 0.36, bevelEnabled: true,
      bevelThickness: 0.05, bevelSize: 0.06, bevelSegments: 3 }),
    jacketMat);
  jacket.position.set(0, 0, -0.20);

  const shirtMat = new THREE.MeshStandardMaterial({ color: 0xe6edf2, roughness: 0.75 });
  const ss = new THREE.Shape();
  ss.moveTo(-0.19, -0.42); ss.lineTo(0.19, -0.42); ss.lineTo(0, -0.80); ss.closePath();
  const shirt = new THREE.Mesh(new THREE.ShapeGeometry(ss), shirtMat);
  shirt.position.set(0, 0, 0.215);

  // collar wings flanking the tie knot
  const cL = new THREE.Mesh(new THREE.BoxGeometry(0.16, 0.05, 0.03), shirtMat);
  cL.position.set(-0.14, -0.415, 0.23); cL.rotation.z = 0.42;
  const cR = cL.clone(); cR.position.x = 0.14; cR.rotation.z = -0.42;

  const tieMat = new THREE.MeshStandardMaterial({ color: 0x0b6a80, roughness: 0.6 });
  const knot = new THREE.Mesh(new THREE.BoxGeometry(0.09, 0.07, 0.03), tieMat);
  knot.position.set(0, -0.47, 0.245);
  const ts = new THREE.Shape();
  ts.moveTo(-0.05, -0.51); ts.lineTo(0.05, -0.51);
  ts.lineTo(0.032, -0.84); ts.lineTo(-0.032, -0.84); ts.closePath();
  const tie = new THREE.Mesh(new THREE.ShapeGeometry(ts), tieMat);
  tie.position.set(0, 0, 0.235);

  rig.add(neck, jacket, shirt, cL, cR, knot, tie);

  // ---- humanizers: brows + slicked hair, both fitted to the head bbox ----
  // (brows from eye-mesh bbox failed: eye meshes too small/deep -> boxes ended
  // up buried inside the face. Head-bbox ratios are deterministic.)
  headMesh.updateWorldMatrix(true, false);
  const hb = new THREE.Box3().setFromObject(headMesh);
  const hc = hb.getCenter(new THREE.Vector3());
  const hs = hb.getSize(new THREE.Vector3());
  const browMat = new THREE.MeshStandardMaterial({ color: 0x14222b, roughness: 0.8 });
  for (const side of [-1, 1]) {
    const br = new THREE.Mesh(new THREE.BoxGeometry(hs.x * 0.21, hs.y * 0.024, hs.z * 0.10), browMat);
    br.position.set(hc.x + side * hs.x * 0.19, hc.y + hs.y * 0.14, hc.z + hs.z * 0.42);
    br.rotation.z = side * -0.18;   // gentle outer lift = friendly
    rig.add(br);
  }
  {
    const hair = new THREE.Mesh(
      new THREE.SphereGeometry(0.5, 28, 20, 0, Math.PI * 2, 0, Math.PI * 0.50),  // slick cap, edge above the brows
      new THREE.MeshStandardMaterial({ color: 0x101c24, roughness: 0.45, metalness: 0.35 }));
    hair.scale.set(hs.x * 0.99, hs.y * 0.72, hs.z * 1.0);   // ~head-sized: intersects scalp, no floating gap
    hair.position.set(hc.x, hc.y + hs.y * 0.04, hc.z - hs.z * 0.10);
    rig.add(hair);
  }

  const key = new THREE.DirectionalLight(0xeae6dc, 1.35); key.position.set(0.8, 1.4, 4.2); scene.add(key);   // softer, warmer, more frontal
  const fill = new THREE.DirectionalLight(0x2a7f9c, 1.2); fill.position.set(-2.5, -0.5, 1.5); scene.add(fill);
  const back = new THREE.DirectionalLight(PAL.rim, 0.8); back.position.set(-1.2, 1.6, -3.0); scene.add(back);
  // flat-on soft front light: kills the hollow-eyed mask look from one-sided rig lighting
  const front = new THREE.DirectionalLight(0xf0f4f2, 1.2); front.position.set(0, 0.5, 5.0); scene.add(front);
  scene.add(new THREE.HemisphereLight(0x3d5872, 0x16202c, 1.5));

  const cam = new THREE.PerspectiveCamera(27, 1, 0.05, 60);
  cam.position.set(0, 0.0, 2.52);
  cam.lookAt(0, -0.13, 0);

  // gaze bones start with baked rotations — compose gaze on top of that,
  // never overwrite .rotation directly.
  const gazeQ = new THREE.Quaternion(), gazeE = new THREE.Euler();
  eyeGroups.forEach(eg => { eg.userData.baseQ = eg.quaternion.clone(); });

  const influences = headMesh.morphTargetInfluences;

  // ---- procedural idle: Max-like restless micro-motion + occasional turns ----
  let gazeX = 0, gazeY = 0, gazeTargetX = 0, gazeTargetY = 0;
  let nextSaccade = 0.6, nextTurn = 2.5, yawT = 0, pitchT = 0, rollT = 0;
  let glitchAt = -1, glitchSeed = 0;
  // friendliness layer state (blink / smile / brow) — ARKit morph indices
  const BLINK_L = FACECAP_INDEX.eyeBlink_L, BLINK_R = FACECAP_INDEX.eyeBlink_R;
  const SMILE_L = FACECAP_INDEX.mouthSmile_L, SMILE_R = FACECAP_INDEX.mouthSmile_R;
  const BROW_UP = FACECAP_INDEX.browInnerUp;
  let nextBlink = 1.2, blinkAt = -10, nextBrow = 4.0, browAt = -10, smile = 0;

  function update(t, dt, { energy = 0 } = {}) {
    // head turn scheduler: a new pose every ~2.5-6s
    if (t > nextTurn) {
      nextTurn = t + 2.5 + 3.5 * noise(t * 0.31, 41);
      yawT = (noise(nextTurn * 0.97, 43) - 0.5) * 0.7;   // up to ±20 deg
      pitchT = (noise(nextTurn * 1.13, 44) - 0.5) * 0.22;
      rollT = (noise(nextTurn * 1.31, 45) - 0.5) * 0.10;
    }
    // restless micro-jitter (2-3 deg band) — faster while energetic
    const jit = 0.020 + 0.022 * Math.min(energy * 2, 1);
    const mx = Math.sin(t * 2.3) * jit * 0.7 + Math.sin(t * 5.7 + 1.3) * jit * 0.3 + (noise(t * 14, 47) - 0.5) * jit;
    const my = Math.sin(t * 1.9 + 0.7) * jit * 0.8 + (noise(t * 12, 49) - 0.5) * jit;

    // saccades for the gaze
    if (t > nextSaccade) {
      nextSaccade = t + 0.45 + 2.2 * noise(t * 0.77, 51);
      gazeTargetX = (noise(t * 3.1, 53) - 0.5) * 0.55;
      gazeTargetY = (noise(t * 3.7, 55) - 0.5) * 0.35;
    }
    const approach = 1 - Math.exp(-dt * (8 + energy * 10));
    gazeX += (gazeTargetX - gazeX) * approach;
    gazeY += (gazeTargetY - gazeY) * approach;

    rig.rotation.y = yawT + mx;
    rig.rotation.x = pitchT + my;
    rig.rotation.z = rollT + Math.sin(t * 1.3) * 0.01;
    rig.position.y = Math.sin(t * 1.6) * 0.012 + (noise(t * 9.3, 57) - 0.5) * 0.006;

    // occasional hard glitch snap (Max channel-hopping twitch)
    if (t > glitchAt + 0.18) {
      if (energy > 0.10 && noise(t * 1.7, 59) > 0.90) {
        glitchAt = t; glitchSeed = noise(t, 61);
      }
    }
    if (t < glitchAt + 0.18) {
      const g = (glitchAt + 0.18 - t) / 0.18;
      rig.rotation.y += (glitchSeed - 0.5) * 0.5 * g;
      rig.position.x += (glitchSeed - 0.5) * 0.05 * g;
    }

    eyeGroups.forEach(eg => {
      gazeE.set(gazeY * 0.25, gazeX * 0.35, 0);
      gazeQ.setFromEuler(gazeE);
      eg.quaternion.copy(eg.userData.baseQ).multiply(gazeQ);
    });

    // ---- friendliness layer: blink, resting smile, occasional brow ----
    // overlaid after feed.apply (Math.max) so bridge-driven A2F values win
    if (t > nextBlink) { blinkAt = t; nextBlink = t + 2.4 + 3.6 * noise(t * 0.71, 71); }
    let blink = 0;
    { const e = t - blinkAt;
      if (e >= 0 && e < 0.26) {
        blink = e < 0.07 ? e / 0.07 : e < 0.12 ? 1 : 1 - (e - 0.12) / 0.14;
      } }
    influences[BLINK_L] = Math.max(influences[BLINK_L], blink, 0.22);   // resting half-lid: calm, not startled
    influences[BLINK_R] = Math.max(influences[BLINK_R], blink, 0.22);

    // resting smile fades in while quiet, out while the jaw moves
    const talking = influences[JAW] > 0.05;
    smile += ((talking ? 0.0 : 0.24) - smile) * (1 - Math.exp(-dt * 2.2));
    if (smile > 0.01) {
      influences[SMILE_L] = Math.min(1, influences[SMILE_L] + smile);
      influences[SMILE_R] = Math.min(1, influences[SMILE_R] + smile);
    }

    // slow brow raise every ~5-14 s: an 'interested' pulse, small amplitude
    if (t > nextBrow) { browAt = t; nextBrow = t + 5 + 9 * noise(t * 0.53, 73); }
    let brow = 0;
    { const e = t - browAt;
      if (e >= 0 && e < 1.1) brow = Math.sin((e / 1.1) * Math.PI) * 0.18; }
    influences[BROW_UP] = Math.max(influences[BROW_UP], brow);

    // teeth follow the jaw (they have no morphs of their own)
    if (teethMesh) teethMesh.position.y = teethBaseY - (influences[JAW] * 0.08) / teethUnit;
  }

  return {
    scene, cam, rig, root, headMesh, innerMesh, eyeMeshes, teethMesh,
    influences, update, setWire,
    morphCount: influences.length,
  };
}

// CRT post: scene -> RT -> fullscreen quad with scanlines/vignette/aberration.
// Effect lives entirely in the WebGL canvas, never over DOM text.
export function createCrtPost(renderer, scene, cam) {
  let rt = null;
  const quadScene = new THREE.Scene();
  const quadCam = new THREE.OrthographicCamera(-1, 1, 1, -1, 0, 1);
  const mat = new THREE.ShaderMaterial({
    uniforms: {
      tDiffuse: { value: null },
      uRes: { value: new THREE.Vector2(1, 1) },
      uTime: { value: 0 },
      uScan: { value: 0.14 },   // was 0.28 — half the haunted-TV grain
      uCurve: { value: 0.030 },
      uAberr: { value: 0.6 },
      uVig: { value: 0.28 },   // was 0.55 — corners no longer crushed to black
      uGlow: { value: 0.05 },
    },
    vertexShader: `varying vec2 vUv; void main(){ vUv = uv; gl_Position = vec4(position.xy, 0., 1.); }`,
    fragmentShader: `
      uniform sampler2D tDiffuse; uniform vec2 uRes; uniform float uTime;
      uniform float uScan, uCurve, uAberr, uVig, uGlow;
      varying vec2 vUv;
      void main() {
        vec2 c = vUv - 0.5;
        float r2 = dot(c, c);
        vec2 uv = c * (1.0 + r2 * uCurve) + 0.5;   // gentle barrel
        if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) { gl_FragColor = vec4(0.,0.,0.,1.); return; }
        float ab = uAberr / uRes.x;
        vec3 col;
        col.r = texture2D(tDiffuse, uv + vec2(ab, 0.0)).r;
        col.g = texture2D(tDiffuse, uv).g;
        col.b = texture2D(tDiffuse, uv - vec2(ab, 0.0)).b;
        // phosphor bloom: cheap soft copy
        vec3 soft = texture2D(tDiffuse, uv + vec2(2.0*ab, 0.0)).rgb
                  + texture2D(tDiffuse, uv - vec2(2.0*ab, 0.0)).rgb
                  + texture2D(tDiffuse, uv + vec2(0.0, 2.0*ab)).rgb
                  + texture2D(tDiffuse, uv - vec2(0.0, 2.0*ab)).rgb;
        col += soft * 0.25 * uGlow;
        // scanlines from device pixels (mask, not multiply-to-black)
        float sl = 0.5 + 0.5 * sin(uv.y * uRes.y * 3.14159265);
        col *= 1.0 - uScan * sl;
        // slow rolling refresh band
        float band = smoothstep(0.0, 0.25, abs(fract(uv.y * 0.5 + uTime * 0.05) - 0.5));
        col *= 0.96 + 0.04 * band;
        // vignette
        col *= 1.0 - uVig * r2 * 1.8;
        gl_FragColor = vec4(col, 1.0);
      }`,
    depthTest: false, depthWrite: false,
  });
  quadScene.add(new THREE.Mesh(new THREE.PlaneGeometry(2, 2), mat));

  return {
    uniforms: mat.uniforms,
    resize(w, h, dpr) {
      if (rt) rt.dispose();
      rt = new THREE.WebGLRenderTarget(Math.floor(w * dpr), Math.floor(h * dpr), {
        minFilter: THREE.LinearFilter, magFilter: THREE.LinearFilter,
      });
      mat.uniforms.uRes.value.set(rt.width, rt.height);
    },
    render(time) {
      mat.uniforms.uTime.value = time;
      renderer.setRenderTarget(rt);
      renderer.render(scene, cam);
      renderer.setRenderTarget(null);
      mat.uniforms.tDiffuse.value = rt.texture;
      renderer.render(quadScene, quadCam);
    },
  };
}
