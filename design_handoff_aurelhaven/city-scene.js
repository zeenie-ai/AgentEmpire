import * as THREE from 'https://unpkg.com/three@0.160.0/build/three.module.js';

const RINGS = [5.5, 11, 17, 24];
const clamp = (v, a, b) => Math.max(a, Math.min(b, v));
const ss = (a, b, v) => { const t = clamp((v - a) / (b - a), 0, 1); return t * t * (3 - 2 * t); };
const ease = t => 1 - Math.pow(1 - t, 3);
const riverZ = x => Math.sin(x * 0.13) * 3.5 + 2;

export const DISTRICTS = [
  { ring: 0, a0: 0, a1: Math.PI * 2 },
  { ring: 1, a0: 0.2, a1: 1.8 },
  { ring: 1, a0: 3.4, a1: 5.2 },
  { ring: 2, a0: 1.9, a1: 3.3 },
  { ring: 2, a0: 4.6, a1: 6.1 },
  { ring: 3, a0: 0.4, a1: 2.6 },
];

export function mount(canvas, o = {}) {
  let eraOv = o.era ?? null, nightOv = o.nightFixed ?? null;
  const renderer = new THREE.WebGLRenderer({ canvas, antialias: true });
  renderer.setPixelRatio(Math.min(devicePixelRatio, 2));
  renderer.toneMapping = THREE.ACESFilmicToneMapping;
  renderer.shadowMap.enabled = true;
  renderer.shadowMap.type = THREE.PCFSoftShadowMap;
  const scene = new THREE.Scene();
  const camera = new THREE.PerspectiveCamera(42, 1, 0.1, 400);
  const dawn = new THREE.Color(o.day || '#f2b98c'), night = new THREE.Color(o.night || '#0d1230');
  scene.fog = new THREE.Fog(dawn.clone(), 40, 140);
  scene.background = dawn.clone();

  const hemi = new THREE.HemisphereLight('#ffe9cf', '#5a4a36', 0.9);
  const sun = new THREE.DirectionalLight('#ffc78f', 2.4);
  sun.position.set(-30, 26, 18); sun.castShadow = true;
  sun.shadow.mapSize.set(2048, 2048);
  Object.assign(sun.shadow.camera, { left: -32, right: 32, top: 32, bottom: -32, far: 120 });
  scene.add(hemi, sun);

  const ground = new THREE.Mesh(new THREE.CircleGeometry(160, 64), new THREE.MeshStandardMaterial({ color: o.ground || '#8d9a5b', roughness: 1 }));
  ground.rotation.x = -Math.PI / 2; ground.receiveShadow = true; scene.add(ground);
  const plaza = new THREE.Mesh(new THREE.CircleGeometry(25, 64), new THREE.MeshStandardMaterial({ color: '#b8a17c', roughness: 1 }));
  plaza.rotation.x = -Math.PI / 2; plaza.position.y = 0.02; plaza.receiveShadow = true; scene.add(plaza);

  const pts = []; for (let x = -70; x <= 70; x += 2) pts.push(new THREE.Vector3(x, 0.05, riverZ(x)));
  const river = new THREE.Mesh(new THREE.TubeGeometry(new THREE.CatmullRomCurve3(pts), 200, 1.3, 6), new THREE.MeshStandardMaterial({ color: '#3f7f9c', emissive: '#1b4d6b', emissiveIntensity: 0.3, roughness: 0.2, metalness: 0.3 }));
  river.scale.y = 0.08; scene.add(river);

  const stoneMat = new THREE.MeshStandardMaterial({ color: '#cdbb9a', roughness: 0.9 });
  const roofMat = new THREE.MeshStandardMaterial({ color: '#a8472b', roughness: 0.8 });
  const wallGroups = RINGS.map((r, k) => {
    const g = new THREE.Group();
    const h = 1.2 + k * 0.5;
    const wall = new THREE.Mesh(new THREE.CylinderGeometry(r, r, h, 96, 1, true), stoneMat);
    wall.material.side = THREE.DoubleSide; wall.position.y = h / 2; wall.castShadow = wall.receiveShadow = true; g.add(wall);
    const n = 6 + k * 4;
    for (let i = 0; i < n; i++) {
      const a = (i / n) * Math.PI * 2, x = Math.cos(a) * r, z = Math.sin(a) * r;
      const t = new THREE.Mesh(new THREE.CylinderGeometry(0.6 + k * 0.1, 0.7 + k * 0.1, h * 1.7, 10), stoneMat);
      t.position.set(x, h * 0.85, z); t.castShadow = true; g.add(t);
      const c = new THREE.Mesh(new THREE.ConeGeometry(0.85 + k * 0.1, 1.4, 10), roofMat);
      c.position.set(x, h * 1.7 + 0.7, z); c.castShadow = true; g.add(c);
    }
    g.userData.h = h; scene.add(g); return g;
  });

  const castle = new THREE.Group();
  [[0, 0, 1.8, 8], [2.2, 1.4, 0.8, 5], [-2, 1.6, 0.8, 5.5], [0.4, -2.3, 0.9, 6], [-1.6, -1.4, 0.6, 4.2]].forEach(([x, z, r, h]) => {
    const t = new THREE.Mesh(new THREE.CylinderGeometry(r, r * 1.1, h, 14), stoneMat); t.position.set(x, h / 2, z); t.castShadow = true; castle.add(t);
    const c = new THREE.Mesh(new THREE.ConeGeometry(r * 1.35, r * 2.6, 14), new THREE.MeshStandardMaterial({ color: '#2f4d7a', roughness: 0.5, metalness: 0.4 })); c.position.set(x, h + r * 1.3, z); c.castShadow = true; castle.add(c);
  });
  const font = new THREE.Mesh(new THREE.TorusGeometry(1.2, 0.08, 8, 48), new THREE.MeshBasicMaterial({ color: '#ffd27a' }));
  font.position.y = 11.5; castle.add(font); scene.add(castle);

  const houses = [];
  for (let k = 0; k < 4; k++) {
    const r0 = k === 0 ? 3.4 : RINGS[k - 1] + 1.2, r1 = RINGS[k] - 1;
    const count = [40, 260, 420, 620][k];
    for (let i = 0; i < count; i++) {
      const a = Math.random() * Math.PI * 2, r = Math.sqrt(r0 * r0 + Math.random() * (r1 * r1 - r0 * r0));
      const x = Math.cos(a) * r, z = Math.sin(a) * r;
      if (Math.abs(z - riverZ(x)) < 1.9) continue;
      houses.push({ x, z, a, r, ring: k, w: 0.6 + Math.random() * 0.6, d: 0.6 + Math.random() * 0.6, h: 0.5 + Math.random() * (k < 2 ? 1.4 : 0.9), rot: -a, delay: Math.random(), bob: Math.random() * 6 });
    }
  }
  const N = houses.length;
  const houseMat = new THREE.MeshStandardMaterial({ color: '#efe2c6', roughness: 0.9, emissive: '#ffb14a', emissiveIntensity: 0 });
  const bodyI = new THREE.InstancedMesh(new THREE.BoxGeometry(1, 1, 1), houseMat, N);
  const roofG = new THREE.ConeGeometry(0.78, 0.7, 4); roofG.rotateY(Math.PI / 4);
  const roofI = new THREE.InstancedMesh(roofG, roofMat, N);
  bodyI.castShadow = roofI.castShadow = bodyI.receiveShadow = true;
  const roofCols = (o.roofs || ['#a8472b', '#b8593a', '#8f3b25', '#c26a3f', '#6f4a3a']).map(c => new THREE.Color(c));
  houses.forEach((h, i) => roofI.setColorAt(i, roofCols[i % 5]));
  scene.add(bodyI, roofI);

  const isl = [];
  const NI = o.islands ?? 5;
  if (o.hex) {
    const hx = [], cols = ['#7f9a52', '#6d8a45', '#9aa564', '#b9a26a', '#4f6f3a', '#8a8f86'].map(c => new THREE.Color(c));
    const R = 2.4, W = R * Math.sqrt(3);
    for (let q = -18; q <= 18; q++) for (let r = -18; r <= 18; r++) {
      const x = W * (q + r / 2), z = 1.5 * R * r, d = Math.hypot(x, z);
      if (d < 27 || d > 75) continue;
      hx.push({ x, z, h: 0.3 + Math.random() * (d > 50 ? 3 : 1), c: cols[(Math.random() * 6) | 0] });
    }
    const hm = new THREE.InstancedMesh(new THREE.CylinderGeometry(R * 0.96, R * 0.96, 1, 6), new THREE.MeshStandardMaterial({ roughness: 1 }), hx.length);
    const mm = new THREE.Matrix4();
    hx.forEach((h, i) => { mm.makeScale(1, h.h, 1); mm.setPosition(h.x, h.h / 2 - 0.2, h.z); hm.setMatrixAt(i, mm); hm.setColorAt(i, h.c); });
    hm.receiveShadow = hm.castShadow = true; scene.add(hm);
  }
  for (let i = 0; i < NI; i++) {
    const g = new THREE.Group();
    const rock = new THREE.Mesh(new THREE.ConeGeometry(2 + Math.random() * 1.5, 4 + Math.random() * 3, 7), new THREE.MeshStandardMaterial({ color: '#7d6a55', roughness: 1 }));
    rock.rotation.x = Math.PI; rock.position.y = -2; g.add(rock);
    const top = new THREE.Mesh(new THREE.CylinderGeometry(2.2, 2.2, 0.4, 7), new THREE.MeshStandardMaterial({ color: '#86a05a' })); g.add(top);
    const hut = new THREE.Mesh(new THREE.BoxGeometry(1, 0.9, 1), houseMat); hut.position.y = 0.65; g.add(hut);
    const rf = new THREE.Mesh(roofG, roofMat); rf.position.y = 1.4; g.add(rf);
    g.userData = { a: (i / NI) * Math.PI * 2, r: 32 + i * 4, y: 16 + i * 3 };
    scene.add(g); isl.push(g);
  }

  const P = 1400, pg = new THREE.BufferGeometry(), pp = new Float32Array(P * 3);
  for (let i = 0; i < P; i++) { const a = Math.random() * 6.28, r = Math.random() * 30; pp.set([Math.cos(a) * r, Math.random() * 24, Math.sin(a) * r], i * 3); }
  pg.setAttribute('position', new THREE.BufferAttribute(pp, 3));
  const motes = new THREE.Points(pg, new THREE.PointsMaterial({ color: '#ffd98a', size: 0.18, transparent: true, opacity: 0.7, blending: THREE.AdditiveBlending, depthWrite: false }));
  scene.add(motes);

  const sg = new THREE.BufferGeometry(), sp = new Float32Array(2000 * 3);
  for (let i = 0; i < 2000; i++) { const v = new THREE.Vector3().randomDirection().multiplyScalar(180); v.y = Math.abs(v.y) + 10; sp.set([v.x, v.y, v.z], i * 3); }
  sg.setAttribute('position', new THREE.BufferAttribute(sp, 3));
  const stars = new THREE.Points(sg, new THREE.PointsMaterial({ color: '#fff', size: 0.6, transparent: true, opacity: 0, fog: false }));
  scene.add(stars);

  const auroraMat = new THREE.ShaderMaterial({
    transparent: true, depthWrite: false, blending: THREE.AdditiveBlending, side: THREE.DoubleSide, fog: false,
    uniforms: { t: { value: 0 }, o: { value: 0 } },
    vertexShader: 'varying vec2 vU; uniform float t; void main(){ vU=uv; vec3 p=position; p.z+=sin(p.x*0.05+t*0.4)*8.0; gl_Position=projectionMatrix*modelViewMatrix*vec4(p,1.0);}',
    fragmentShader: 'varying vec2 vU; uniform float t; uniform float o; void main(){ float b=sin(vU.x*18.0+t*0.7)*0.5+0.5; float f=smoothstep(0.0,0.35,vU.y)*smoothstep(1.0,0.4,vU.y); vec3 c=mix(vec3(0.2,1.0,0.6),vec3(0.6,0.3,1.0),vU.y); gl_FragColor=vec4(c,f*b*o*0.55);}'
  });
  [0, 1].forEach(i => { const m = new THREE.Mesh(new THREE.PlaneGeometry(260, 40, 80, 1), auroraMat); m.position.set(0, 60 + i * 12, -90 - i * 20); m.rotation.x = -0.25; scene.add(m); });

  const hl = new THREE.Mesh(new THREE.RingGeometry(1, 2, 64), new THREE.MeshBasicMaterial({ color: '#ffcf6b', transparent: true, opacity: 0, side: THREE.DoubleSide, depthWrite: false }));
  hl.rotation.x = -Math.PI / 2; hl.position.y = 0.3; scene.add(hl);
  let hlTarget = 0;
  const setHighlight = i => {
    if (i == null || i < 0) { hlTarget = 0; return; }
    const d = DISTRICTS[i], r0 = d.ring === 0 ? 0.5 : RINGS[d.ring - 1], r1 = RINGS[d.ring];
    hl.geometry.dispose(); hl.geometry = new THREE.RingGeometry(r0, r1, 64, 1, d.a0, d.a1 - d.a0); hlTarget = 0.45;
  };

  const KF = o.kf || [
    { s: 0, r: 52, y: 34, a: 0.5 }, { s: 1, r: 42, y: 24, a: 0.9 }, { s: 4.6, r: 34, y: 17, a: 2.6 },
    { s: 5.3, r: 4, y: 64, a: 3.1 }, { s: 6.6, r: 4, y: 60, a: 3.3 }, { s: 7.5, r: 24, y: 6, a: 4.4 }, { s: 9, r: 22, y: 5, a: 5 },
  ];
  const camAt = s => {
    let i = 0; while (i < KF.length - 2 && s > KF[i + 1].s) i++;
    const A = KF[i], B = KF[i + 1], t = ss(A.s, B.s, s);
    return { r: A.r + (B.r - A.r) * t, y: A.y + (B.y - A.y) * t, a: A.a + (B.a - A.a) * t };
  };

  let S = 0, sCur = 0, raf, running = true;
  const m4 = new THREE.Matrix4(), q = new THREE.Quaternion(), v3 = new THREE.Vector3(), sc = new THREE.Vector3(), up = new THREE.Vector3(0, 1, 0);
  const clock = new THREE.Clock();
  const resize = () => { const w = canvas.clientWidth, h = canvas.clientHeight; renderer.setSize(w, h, false); camera.aspect = w / h; camera.updateProjectionMatrix(); };
  addEventListener('resize', resize); resize();

  const tick = () => {
    if (!running) return;
    const t = clock.getElapsedTime();
    sCur += (S - sCur) * 0.06;
    const s = sCur, e = eraOv ?? clamp(s - 0.4, 0, 4), n = nightOv ?? ss(6.7, 7.5, s);
    const c = camAt(s), a = c.a + t * 0.015;
    camera.position.set(Math.cos(a) * c.r, c.y, Math.sin(a) * c.r);
    camera.lookAt(0, o.kf ? (o.lookY ?? 2) : (s > 5 && s < 6.8 ? 0 : 2), 0);

    scene.background.copy(dawn).lerp(night, n); scene.fog.color.copy(scene.background);
    sun.color.set('#ffc78f').lerp(new THREE.Color('#7f95ff'), n); sun.intensity = 2.4 - n * 1.9;
    hemi.intensity = 0.9 - n * 0.6;
    houseMat.emissiveIntensity = n * 1.1; stars.material.opacity = n; auroraMat.uniforms.o.value = n; auroraMat.uniforms.t.value = t;
    motes.material.color.set(n > 0.5 ? '#9fe8ff' : '#ffd98a');
    const pa = motes.geometry.attributes.position;
    for (let i = 0; i < P; i++) { let y = pa.getY(i) + 0.012 + (i % 7) * 0.002; if (y > 24) y = 0; pa.setY(i, y); }
    pa.needsUpdate = true;

    wallGroups.forEach((g, k) => { const w = ease(clamp(e - k, 0, 1)); g.scale.set(1, Math.max(w, 0.001), 1); g.visible = w > 0.001; });
    const cw = ease(clamp(e * 1.3, 0, 1)); castle.scale.set(1, Math.max(cw, 0.001), 1); font.rotation.x = t * 0.8; font.rotation.y = t * 0.5;

    for (let i = 0; i < N; i++) {
      const h = houses[i];
      const vis = clamp((e - h.ring + 0.7) / 0.3, 0, 1);
      const land = ease(clamp((e - h.ring) * 1.5 - h.delay * 0.5, 0, 1));
      const lift = (1 - land) * (10 + h.delay * 12) + (1 - land) * Math.sin(t * 1.3 + h.bob) * 0.6;
      const k = Math.max(vis, 0.0001);
      q.setFromAxisAngle(up, h.rot + (1 - land) * t * 0.6);
      m4.compose(v3.set(h.x, h.h / 2 + lift, h.z), q, sc.set(h.w * k, h.h * k, h.d * k)); bodyI.setMatrixAt(i, m4);
      m4.compose(v3.set(h.x, h.h + 0.35 + lift, h.z), q, sc.set(h.w * k, k, h.d * k)); roofI.setMatrixAt(i, m4);
    }
    bodyI.instanceMatrix.needsUpdate = roofI.instanceMatrix.needsUpdate = true;

    isl.forEach((g, i) => { const u = g.userData, aa = u.a + t * 0.03; g.position.set(Math.cos(aa) * u.r, u.y + Math.sin(t * 0.5 + i) * 1.2, Math.sin(aa) * u.r); g.rotation.y = t * 0.1; });
    hl.material.opacity += (hlTarget * (0.75 + Math.sin(t * 3) * 0.25) - hl.material.opacity) * 0.1;

    renderer.render(scene, camera);
    raf = requestAnimationFrame(tick);
  };
  tick();

  return {
    setScroll: v => { S = v; },
    setEra: v => { eraOv = v; },
    setNight: v => { nightOv = v; },
    highlight: setHighlight,
    dispose: () => { running = false; cancelAnimationFrame(raf); removeEventListener('resize', resize); renderer.dispose(); },
  };
}
