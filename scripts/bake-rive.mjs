#!/usr/bin/env node
// Bakes the Rive state tracker (art_src/rive/state_tracker, written in RML) into sprite sheets
// for the client, with the free Rive CLI: no Rive account, no login, no watermark.
//
// Every artboard named in SETS has a view model with one enum property (TaskSeal: `state`,
// AgentSigil: `mood`), and a state machine that plays the LinearAnimation named after each enum
// key. For every key the script runs the real state machine headless (`--data=<prop>=<key>`),
// lets it settle, then captures one loop of the animation at FPS frames a second. Captures have
// no transparency, so each frame is taken twice, over a black and over a white matte (the view
// model's `matte` colour), and its alpha is solved from the two. The frames of a state are
// packed into client/art/rive/<set>/<key>.png, described by client/art/rive/rive_sprites.json,
// which RiveSprites reads.
//
//   node scripts/bake-rive.mjs                 bake every set (needs the Rive CLI)
//   node scripts/bake-rive.mjs --only=task_seal,agent_sigil:waiting
//                                              bake some sheets while drawing; it keeps the others,
//                                              and --check then asks for a full bake
//   node scripts/bake-rive.mjs --jobs=8        captures run in parallel (default: half the cores, at most 4,
//                                              so a bake leaves the GPU to a game that is running)
//   node scripts/bake-rive.mjs --check         exit 1 if the sheets are older than the RML (no CLI needed)
//
// The CLI is found as --rive=<path>, then RIVE_CLI, then `rive` on PATH, then ~/.rive/bin.
// Install it from https://rive.app/docs/cli/getting-started. After baking, import the client
// (`<godot> --headless --path client --import`) so Godot picks up new or changed sheets.
import { createHash } from 'node:crypto';
import { spawn, spawnSync } from 'node:child_process';
import {
  copyFileSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, unlinkSync, writeFileSync,
} from 'node:fs';
import { availableParallelism, homedir, tmpdir } from 'node:os';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { crc32, deflateSync, inflateSync } from 'node:zlib';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const PROJECT = join(root, 'art_src', 'rive', 'state_tracker');
const OUT = join(root, 'client', 'art', 'rive');
const MANIFEST = join(OUT, 'rive_sprites.json');

// Raise when the way sheets are made changes, so --check asks for a new bake.
const BAKE_VERSION = 2;
// Frames a second in the sheets; the CLI steps at 60, so 60 / FPS must be whole.
const FPS = 30;
// Frames are rendered this many times the artboard's size (the CLI draws the vectors larger with
// --viewport and --fit=contain), so the HUD's stretch up to 2.4x at 4K stays sharp.
const SCALE = 1.5;
// At least this many 60 fps frames run before the first capture: the state machine enters the
// state and finishes the transition's blend. Each state waits a whole number of its own loops, so
// a sheet's first frame is the start of the loop (the state machine enters it on frame 1).
const WARMUP = 60;
// Transparent pixels around every frame in a sheet, so mipmaps never bleed between frames.
const PAD = 2;
// The manifest's source_hash after a partial bake (--only): it matches no source, so --check asks
// for a full bake.
const PARTIAL = 'partial';
// The artboards to bake: the set name the client uses and the state it falls back to.
const SETS = [
  { artboard: 'TaskSeal', set: 'task_seal', fallback: 'queued' },
  { artboard: 'AgentSigil', set: 'agent_sigil', fallback: 'idle' },
];

const args = process.argv.slice(2);
const arg = (name) => {
  const a = args.find((x) => x.startsWith(`--${name}=`));
  return a === undefined ? null : a.slice(name.length + 3);
};
const check = args.includes('--check');

// ---------------------------------------------------------------- the source hash

function sourceFiles(dir = PROJECT) {
  return readdirSync(dir)
    .filter((f) => f.endsWith('.rml') || f === 'rive.yaml')
    .sort();
}

// Line endings are normalised, so a checkout with CRLF hashes like one with LF.
function sourceHash(dir = PROJECT) {
  const h = createHash('sha256');
  h.update(JSON.stringify({ BAKE_VERSION, FPS, SCALE, WARMUP, PAD, SETS }));
  for (const f of sourceFiles(dir)) {
    h.update(`\n${f}\n`);
    h.update(readFileSync(join(dir, f), 'utf8').replace(/\r\n/g, '\n'));
  }
  return h.digest('hex');
}

if (check) {
  const rel = relative(root, MANIFEST).replaceAll('\\', '/');
  if (!existsSync(MANIFEST)) {
    console.error(`${rel} is missing. Run: node scripts/bake-rive.mjs`);
    process.exit(1);
  }
  const manifest = JSON.parse(readFileSync(MANIFEST, 'utf8'));
  let bad = 0;
  if (manifest.source_hash === PARTIAL) {
    console.error('The last bake was partial (--only). Run a full bake: node scripts/bake-rive.mjs');
    bad++;
  } else if (manifest.source_hash !== sourceHash()) {
    console.error('The sprite sheets are older than art_src/rive/state_tracker. Run: node scripts/bake-rive.mjs');
    bad++;
  }
  for (const [set, s] of Object.entries(manifest.sets)) {
    for (const [key, st] of Object.entries(s.states)) {
      if (!existsSync(join(OUT, st.file))) {
        console.error(`client/art/rive/${st.file} (${set} ${key}) is missing.`);
        bad++;
      }
    }
  }
  if (bad === 0) console.log(`${rel} is up to date.`);
  process.exit(bad > 0 ? 1 : 0);
}

// ---------------------------------------------------------------- the Rive CLI

function findRive() {
  const exe = process.platform === 'win32' ? 'rive.exe' : 'rive';
  const given = arg('rive') ?? process.env.RIVE_CLI;
  if (given) return given;
  const which = spawnSync(process.platform === 'win32' ? 'where' : 'which', ['rive'], { encoding: 'utf8' });
  if (which.status === 0 && which.stdout.trim()) return which.stdout.trim().split(/\r?\n/)[0];
  const home = join(homedir(), '.rive', 'bin', exe);
  if (existsSync(home)) return home;
  console.error('The Rive CLI was not found. Install it (https://rive.app/docs/cli/getting-started) or pass --rive=<path>.');
  process.exit(2);
}

const RIVE = findRive();
const RIVE_ENV = { ...process.env, RIVE_NO_TUI: '1' };

function rive(argv) {
  const r = spawnSync(RIVE, argv, { encoding: 'utf8', env: RIVE_ENV, maxBuffer: 256 * 1024 * 1024 });
  if (r.error) throw r.error;
  return r;
}

function riveOnce(argv) {
  return new Promise((resolvePromise) => {
    const p = spawn(RIVE, argv, { env: RIVE_ENV, stdio: ['ignore', 'ignore', 'pipe'] });
    let err = '';
    p.stderr.on('data', (d) => (err += d));
    p.on('error', (e) => resolvePromise({ code: -1, err: e.message }));
    p.on('close', (code, signal) => resolvePromise({ code: code ?? signal, err: err.trim() }));
  });
}

// Under load a capture now and then exits without a word; the same capture then works, so each
// is tried three times.
async function riveAsync(argv) {
  let last = null;
  for (let attempt = 0; attempt < 3; attempt++) {
    last = await riveOnce(argv);
    if (last.code === 0) return;
  }
  throw new Error(`rive ${argv.join(' ')}\nexit ${last.code}${last.err ? `: ${last.err}` : ''}`);
}

// ---------------------------------------------------------------- PNG: 8-bit RGB(A), no interlace

function readPng(file) {
  const buf = readFileSync(file);
  let at = 8;
  let width = 0, height = 0, colorType = 0;
  const idat = [];
  while (at < buf.length) {
    const len = buf.readUInt32BE(at);
    const type = buf.toString('latin1', at + 4, at + 8);
    const data = buf.subarray(at + 8, at + 8 + len);
    if (type === 'IHDR') {
      width = data.readUInt32BE(0);
      height = data.readUInt32BE(4);
      colorType = data[9];
      if (data[8] !== 8 || (colorType !== 6 && colorType !== 2) || data[12] !== 0) {
        throw new Error(`${file}: only 8-bit RGB or RGBA PNGs without interlacing are read`);
      }
    } else if (type === 'IDAT') {
      idat.push(data);
    }
    at += 12 + len;
  }
  const bpp = colorType === 6 ? 4 : 3;
  const raw = inflateSync(Buffer.concat(idat));
  const stride = width * bpp;
  const px = Buffer.alloc(height * stride);
  for (let y = 0; y < height; y++) {
    const f = raw[y * (stride + 1)];
    const line = raw.subarray(y * (stride + 1) + 1, (y + 1) * (stride + 1));
    for (let x = 0; x < stride; x++) {
      const a = x >= bpp ? px[y * stride + x - bpp] : 0;
      const b = y > 0 ? px[(y - 1) * stride + x] : 0;
      const c = x >= bpp && y > 0 ? px[(y - 1) * stride + x - bpp] : 0;
      let v = line[x];
      if (f === 1) v += a;
      else if (f === 2) v += b;
      else if (f === 3) v += (a + b) >> 1;
      else if (f === 4) {
        const p = a + b - c;
        const pa = Math.abs(p - a), pb = Math.abs(p - b), pc = Math.abs(p - c);
        v += pa <= pb && pa <= pc ? a : pb <= pc ? b : c;
      }
      px[y * stride + x] = v & 255;
    }
  }
  if (bpp === 4) return { width, height, rgba: px };
  const rgba = Buffer.alloc(width * height * 4);
  for (let i = 0; i < width * height; i++) {
    rgba[i * 4] = px[i * 3];
    rgba[i * 4 + 1] = px[i * 3 + 1];
    rgba[i * 4 + 2] = px[i * 3 + 2];
    rgba[i * 4 + 3] = 255;
  }
  return { width, height, rgba };
}

function chunk(type, data) {
  const head = Buffer.alloc(8);
  head.writeUInt32BE(data.length, 0);
  head.write(type, 4, 'latin1');
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(Buffer.concat([head.subarray(4), data])) >>> 0, 0);
  return Buffer.concat([head, data, crc]);
}

// RGBA, each row filtered the way that makes it smallest (the usual sum-of-magnitudes guess).
function writePng(file, width, height, rgba) {
  const stride = width * 4;
  const out = Buffer.alloc(height * (stride + 1));
  const cand = Array.from({ length: 5 }, () => Buffer.alloc(stride));
  for (let y = 0; y < height; y++) {
    let best = 0, bestSum = Infinity;
    for (let f = 0; f < 5; f++) {
      let sum = 0;
      for (let x = 0; x < stride; x++) {
        const v = rgba[y * stride + x];
        const a = x >= 4 ? rgba[y * stride + x - 4] : 0;
        const b = y > 0 ? rgba[(y - 1) * stride + x] : 0;
        const c = x >= 4 && y > 0 ? rgba[(y - 1) * stride + x - 4] : 0;
        let pred = 0;
        if (f === 1) pred = a;
        else if (f === 2) pred = b;
        else if (f === 3) pred = (a + b) >> 1;
        else if (f === 4) {
          const p = a + b - c;
          const pa = Math.abs(p - a), pb = Math.abs(p - b), pc = Math.abs(p - c);
          pred = pa <= pb && pa <= pc ? a : pb <= pc ? b : c;
        }
        const d = (v - pred) & 255;
        cand[f][x] = d;
        sum += d < 128 ? d : 256 - d;
      }
      if (sum < bestSum) {
        bestSum = sum;
        best = f;
      }
    }
    out[y * (stride + 1)] = best;
    cand[best].copy(out, y * (stride + 1) + 1);
  }
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0);
  ihdr.writeUInt32BE(height, 4);
  ihdr[8] = 8;
  ihdr[9] = 6;
  writeFileSync(file, Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', ihdr),
    chunk('IDAT', deflateSync(out, { level: 9 })),
    chunk('IEND', Buffer.alloc(0)),
  ]));
}

// The pixel a capture over black and one over white agree on: over black a colour C with alpha a
// shows as a*C, over white as a*C + (1 - a), so the difference gives a and the black one C.
function unmatte(black, white) {
  const n = black.width * black.height;
  const rgba = Buffer.alloc(n * 4);
  for (let i = 0; i < n; i++) {
    const o = i * 4;
    let diff = 0;
    for (let c = 0; c < 3; c++) diff += white.rgba[o + c] - black.rgba[o + c];
    const alpha = Math.min(1, Math.max(0, 1 - diff / (3 * 255)));
    if (alpha < 0.5 / 255) continue;
    for (let c = 0; c < 3; c++) rgba[o + c] = Math.min(255, Math.round(black.rgba[o + c] / alpha));
    rgba[o + 3] = Math.round(alpha * 255);
  }
  return rgba;
}

// ---------------------------------------------------------------- what to bake, from the RML

function walk(o, fn) {
  if (o && typeof o === 'object') {
    fn(o);
    for (const v of Object.values(o)) walk(v, fn);
  }
}

function plan(scene) {
  const roots = [];
  walk(scene.roots, (o) => o.type && roots.push(o));
  const byId = new Map(roots.filter((o) => o.id).map((o) => [o.id, o]));
  const sets = [];
  for (const want of SETS) {
    const ab = scene.artboards.find((a) => a.name === want.artboard);
    if (!ab) throw new Error(`No artboard named ${want.artboard}`);
    const vm = byId.get(ab.viewModelId);
    if (!vm) throw new Error(`${want.artboard} has no view model`);
    const props = (vm.children ?? []).filter((c) => c.type === 'ViewModelPropertyEnumCustom');
    if (props.length !== 1) throw new Error(`${vm.name} needs exactly one enum property, it has ${props.length}`);
    if (!(vm.children ?? []).some((c) => c.type === 'ViewModelPropertyColor' && c.name === 'matte')) {
      throw new Error(`${vm.name} needs a colour property named matte (the background the bake captures over)`);
    }
    const en = byId.get(props[0].enumId);
    const keys = (en?.children ?? []).filter((c) => c.type === 'DataEnumValue').map((c) => c.key);
    const anims = new Map();
    const blends = [];
    walk(ab, (o) => {
      if (o.type === 'LinearAnimation') anims.set(o.name, o);
      if (o.type === 'AnyState') for (const t of o.children ?? []) if (t.type === 'StateTransition') blends.push(t.duration ?? 0);
    });
    const states = [];
    for (const key of keys) {
      const a = anims.get(key);
      if (!a) throw new Error(`${want.artboard} has no animation named "${key}" for that state`);
      const ticks = (a.duration * 60) / (a.fps || 60);
      const step = 60 / FPS;
      if (!Number.isInteger(ticks) || (!Number.isInteger(ticks / step) && ticks > step)) {
        throw new Error(`${want.artboard} "${key}" lasts ${ticks} frames at 60 fps, not a whole number of ${FPS} fps frames`);
      }
      // Whole loops of warm-up, plus the frame on which the state machine enters the state.
      const warmup = Math.ceil(WARMUP / ticks) * ticks + 1;
      states.push({ key, frames: Math.max(1, Math.round(ticks / step)), step, warmup });
    }
    if (!keys.includes(want.fallback)) throw new Error(`${want.artboard} has no state "${want.fallback}"`);
    sets.push({ ...want, property: props[0].name, width: ab.width, height: ab.height,
      frameW: Math.round(ab.width * SCALE), frameH: Math.round(ab.height * SCALE),
      blend_ms: blends.length ? Math.max(...blends) : 0, states });
  }
  return sets;
}

// ---------------------------------------------------------------- the bake

// Runs `run` over `jobs` with `size` workers. After a failure no new job starts, and the error is
// thrown only once every running capture has ended, so the temporary folder is free to remove.
async function pool(jobs, size, run) {
  let next = 0, done = 0, shown = 0;
  let failure = null;
  const total = jobs.length;
  const tty = process.stdout.isTTY;
  const worker = async (w) => {
    while (failure === null && next < total) {
      const job = jobs[next++];
      try {
        await run(job, w);
      } catch (err) {
        failure ??= err;
        return;
      }
      done++;
      if (tty && (done % 20 === 0 || done === total)) process.stdout.write(`\r  ${done}/${total} captures`);
      else if (!tty && (done === total || done >= shown + total / 4)) {
        shown = done;
        console.log(`  ${done}/${total} captures`);
      }
    }
  };
  await Promise.all(Array.from({ length: Math.min(size, total) }, (_, w) => worker(w)));
  if (tty) process.stdout.write('\n');
  if (failure !== null) throw failure;
}

// --only=set or set:key, comma separated: a map from each set to the states to bake, or null for
// everything. An unknown set or state is an error before anything is captured.
function parseOnly(only, sets) {
  if (!only) return null;
  const want = new Map();
  for (const part of only.split(',').map((p) => p.trim()).filter(Boolean)) {
    const [name, key] = part.split(':');
    const s = sets.find((x) => x.set === name);
    if (!s) throw new Error(`--only: no set "${name}" (sets: ${sets.map((x) => x.set).join(', ')})`);
    if (key && !s.states.some((st) => st.key === key)) {
      throw new Error(`--only: ${name} has no state "${key}" (states: ${s.states.map((st) => st.key).join(', ')})`);
    }
    if (!want.has(name)) want.set(name, new Set());
    for (const st of s.states) if (!key || st.key === key) want.get(name).add(st.key);
  }
  return want;
}

async function main() {
  const version = rive(['--version']).stdout.trim();
  console.log(`Rive CLI: ${version} (${RIVE})`);
  const tmp = mkdtempSync(join(tmpdir(), 'ae-rive-bake-'));
  try {
    // Everything below works on one snapshot of the sources: an edit made during the bake is
    // neither captured nor marked as baked.
    const snapshot = join(tmp, 'w0');
    mkdirSync(snapshot);
    for (const f of sourceFiles()) copyFileSync(join(PROJECT, f), join(snapshot, f));
    const hash = sourceHash(snapshot);
    const verify = rive([snapshot, '--verify']);
    if (verify.status !== 0) {
      console.error(verify.stdout + verify.stderr);
      throw new Error('The Rive project does not compile.');
    }
    const scene = JSON.parse(rive(['inspect', snapshot, '--json']).stdout);
    if ((scene.problems ?? []).length) {
      for (const p of scene.problems) console.error(`${p.severity}: ${p.file}:${p.line} ${p.message}`);
      if (scene.problems.some((p) => p.severity === 'error')) throw new Error('The Rive project has errors.');
    }
    const sets = plan(scene);
    const want = parseOnly(arg('only'), sets);
    const wanted = (set, key) => want === null || (want.get(set)?.has(key) ?? false);

    // A partial bake keeps the sheets it does not bake, so they must still fit the manifest.
    const old = existsSync(MANIFEST) ? JSON.parse(readFileSync(MANIFEST, 'utf8')) : { sets: {} };
    if (want !== null) {
      for (const s of sets) {
        const before = old.sets?.[s.set];
        for (const st of s.states) {
          if (wanted(s.set, st.key)) continue;
          const kept = before?.states?.[st.key];
          const same = before && kept && before.size?.[0] === s.frameW && before.size?.[1] === s.frameH &&
            before.pad === PAD && before.fps === FPS && kept.frames === st.frames && existsSync(join(OUT, kept.file));
          if (!same) throw new Error(`${s.set} ${st.key} changed since the last bake or was never baked; bake it too, or run a full bake`);
        }
      }
    }

    const jobsN = Math.max(1, Number(arg('jobs')) || Math.min(4, Math.max(1, Math.floor(availableParallelism() / 2))));
    // Each worker builds its own copy of the snapshot: a capture writes the project's build folder.
    const copies = [snapshot];
    for (let w = 1; w < jobsN; w++) {
      const dir = join(tmp, `w${w}`);
      mkdirSync(dir);
      for (const f of sourceFiles(snapshot)) copyFileSync(join(snapshot, f), join(dir, f));
      copies.push(dir);
    }
    const shots = join(tmp, 'shots');
    mkdirSync(shots);

    const jobs = [];
    for (const s of sets) {
      for (const st of s.states) {
        if (!wanted(s.set, st.key)) continue;
        for (let k = 0; k < st.frames; k++) {
          for (const matte of ['FF000000', 'FFFFFFFF']) {
            jobs.push({ s, st, k, matte, png: join(shots, `${s.set}.${st.key}.${k}.${matte}.png`) });
          }
        }
      }
    }
    console.log(`Capturing ${jobs.length} frames with ${jobsN} workers...`);
    const started = Date.now();
    await pool(jobs, jobsN, (j, w) => riveAsync([copies[w], `--artboard=${j.s.artboard}`, `--screenshot=${j.png}`,
      `--viewport=${j.s.frameW}x${j.s.frameH}`, '--fit=contain', `--data=matte=${j.matte}`,
      `--data=${j.s.property}=${j.st.key}`, `--advance=${j.st.warmup + j.k * j.st.step}`, '--quiet']));

    const manifest = {
      generated_by: 'scripts/bake-rive.mjs',
      source: 'art_src/rive/state_tracker',
      source_hash: want === null ? hash : PARTIAL,
      rive_cli: version,
      sets: {},
    };
    for (const s of sets) {
      const states = {};
      const cell = { w: s.frameW + 2 * PAD, h: s.frameH + 2 * PAD };
      mkdirSync(join(OUT, s.set), { recursive: true });
      for (const st of s.states) {
        if (!wanted(s.set, st.key)) {
          states[st.key] = old.sets[s.set].states[st.key];
          continue;
        }
        const file = `${s.set}/${st.key}.png`;
        const columns = Math.ceil(Math.sqrt(st.frames));
        states[st.key] = { file, frames: st.frames, columns };
        const rows = Math.ceil(st.frames / columns);
        const sheetW = columns * cell.w, sheetH = rows * cell.h;
        const sheet = Buffer.alloc(sheetW * sheetH * 4);
        for (let k = 0; k < st.frames; k++) {
          const black = readPng(join(shots, `${s.set}.${st.key}.${k}.FF000000.png`));
          const white = readPng(join(shots, `${s.set}.${st.key}.${k}.FFFFFFFF.png`));
          if (black.width !== s.frameW || black.height !== s.frameH) {
            throw new Error(`${s.set} ${st.key}: a capture is ${black.width}x${black.height}, not ${s.frameW}x${s.frameH}`);
          }
          const frame = unmatte(black, white);
          const ox = (k % columns) * cell.w + PAD, oy = Math.floor(k / columns) * cell.h + PAD;
          for (let y = 0; y < s.frameH; y++) {
            frame.copy(sheet, ((oy + y) * sheetW + ox) * 4, y * s.frameW * 4, (y + 1) * s.frameW * 4);
          }
        }
        const dst = join(OUT, file);
        writePng(dst, sheetW, sheetH, sheet);
        // Mipmaps keep the small seals smooth; Godot keeps these settings when it imports.
        if (!existsSync(`${dst}.import`)) {
          writeFileSync(`${dst}.import`, '[remap]\n\nimporter="texture"\ntype="CompressedTexture2D"\n\n[params]\n\n' +
            'compress/mode=0\nmipmaps/generate=true\nprocess/fix_alpha_border=true\ndetect_3d/compress_to=0\n');
        }
        console.log(`  ${file}: ${st.frames} frame${st.frames === 1 ? '' : 's'}, ${sheetW}x${sheetH}`);
      }
      manifest.sets[s.set] = {
        artboard: s.artboard,
        property: s.property,
        fallback: s.fallback,
        size: [s.frameW, s.frameH],
        scale: SCALE,
        pad: PAD,
        fps: FPS,
        blend_ms: s.blend_ms,
        states,
      };
      // Sheets of states the RML no longer has.
      for (const f of readdirSync(join(OUT, s.set))) {
        const key = f.replace(/\.png(\.import)?$/, '');
        if ((f.endsWith('.png') || f.endsWith('.png.import')) && !states[key]) unlinkSync(join(OUT, s.set, f));
      }
    }
    writeFileSync(MANIFEST, `${JSON.stringify(manifest, null, 2)}\n`);
    console.log(`Wrote ${relative(root, MANIFEST).replaceAll('\\', '/')} in ${((Date.now() - started) / 1000).toFixed(1)} s.`);
    if (want !== null) console.log('A partial bake: run a full one before committing (--check asks for it).');
  } finally {
    try {
      rmSync(tmp, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
    } catch (err) {
      console.warn(`Could not remove ${tmp}: ${err.message}`);
    }
  }
}

main().catch((err) => {
  console.error(err.message);
  process.exit(1);
});
