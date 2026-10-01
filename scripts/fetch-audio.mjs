// Builds AgentEmpire's sound: downloads the CC0 sources (Kenney audio packs, OpenGameArt music,
// Freesound field recordings) into .tools/vendor/audio, synthesises the bells, chimes and
// magic, then trims, layers, normalises and encodes everything into client/audio/.
//
// Usage: node scripts/fetch-audio.mjs [--vendor <dir>] [--out <dir>] [--only <cue,cue,...>]
//                                     [--no-music] [--offline]
//   --vendor    where downloads are cached (default: the main checkout's .tools/vendor/audio, so
//               every git worktree shares one cache)
//   --out       output directory (default: client/audio)
//   --only      rebuild just these cues (by name; "music" and "ambience" are names too)
//   --no-music  skip the music and ambience beds (they take the longest)
//   --offline   never download; fail if a source is missing from the cache
//
// Needs Node 22 and ffmpeg (with libvorbis) on PATH, or FFMPEG set to its path. Every source is
// pinned by URL and SHA-256; synthesis is seeded, so the same inputs give the same files.
//
// Loudness. Every effect file is normalised to the same peak momentary loudness (TARGET_M, EBU
// R128 momentary = 400 ms window) with true peaks at or below -1 dBTP; the mix (how loud each cue
// plays in the game) lives in client/audio/cue_table.gd. Music is normalised to -18 LUFS
// integrated and the ambience beds to -24 LUFS. Outputs: short effects as 16-bit WAV (Godot
// imports them as QOA), long ones and anything with a reverb tail as Ogg Vorbis.
//
// Also writes client/audio/cue_files.gd: every cue's files, the music playlist and the
// ambience beds, which the Audio autoload loads.
import { createHash } from "node:crypto";
import { execFileSync, spawnSync } from "node:child_process";
import {
  existsSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync,
} from "node:fs";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { inflateRawSync } from "node:zlib";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const args = process.argv.slice(2);
const opt = (name) => {
  const i = args.indexOf(name);
  return i >= 0 ? args[i + 1] : undefined;
};
const FFMPEG = process.env.FFMPEG ?? "ffmpeg";
const OUT = resolve(opt("--out") ?? join(root, "client", "audio"));
const ONLY = opt("--only") ? new Set(opt("--only").split(",").map((s) => s.trim())) : null;
const NO_MUSIC = args.includes("--no-music");
const OFFLINE = args.includes("--offline");
const SR = 44100;
/** Peak momentary loudness every effect file is normalised to (LUFS). */
const TARGET_M = -16;
const TRUE_PEAK = -1.0;
const MUSIC_LUFS = -18;
const AMBIENCE_LUFS = -24;

// ------------------------------------------------------------------------------------------------
// Sources. Every file is CC0; CREDITS.md lists them with their pages.

const KENNEY = [
  { dir: "kenney_rpg-audio", page: "https://kenney.nl/assets/rpg-audio",
    url: "https://kenney.nl/media/pages/assets/rpg-audio/8e99002d76-1677590336/kenney_rpg-audio.zip",
    sha256: "6dbeaf8544da958d8f2adcb4a4a4b76c1ade34a05f8ab9edccd327da7375f38b" },
  { dir: "kenney_interface-sounds", page: "https://kenney.nl/assets/interface-sounds",
    url: "https://kenney.nl/media/pages/assets/interface-sounds/fa43c1dd4d-1677589452/kenney_interface-sounds.zip",
    sha256: "f2193d072726d6758a5f7871b2dcc54dcce0d5c35c6f0a62f92549b327c81232" },
  { dir: "kenney_impact-sounds", page: "https://kenney.nl/assets/impact-sounds",
    url: "https://kenney.nl/media/pages/assets/impact-sounds/87b4ddecda-1677589768/kenney_impact-sounds.zip",
    sha256: "029d734af1582474edf3a694d1b0cebc97c1c152f2f39fa34d4c2bafc5de77f8" },
  { dir: "kenney_ui-audio", page: "https://kenney.nl/assets/ui-audio",
    url: "https://kenney.nl/media/pages/assets/ui-audio/490d233f68-1677590494/kenney_ui-audio.zip",
    sha256: "946fc23a63d535d693eb31b2eabb80c8c28d6351e2186b344ceb71b2cb1d5eb6" },
];

const MUSIC = [
  { id: "bards_tale", title: "Medieval: The Bard's Tale", author: "RandomMind",
    page: "https://opengameart.org/content/medieval-the-bards-tale",
    url: "https://opengameart.org/sites/default/files/The_Bards_Tale.mp3",
    sha256: "6e93e8e8215bea17a209c321c182111058e024c53e3ad775ce1481ca1d1fcfc2" },
  { id: "town_theme", title: "Town Theme RPG", author: "cynicmusic",
    page: "https://opengameart.org/content/town-theme-rpg",
    url: "https://opengameart.org/sites/default/files/TownTheme.mp3",
    sha256: "2657861d5107d4a3c01ef81cb6a4d61ddd5e7a054b6da57e658373d79d0c3466" },
  { id: "exploration", title: "Medieval: Exploration", author: "RandomMind",
    page: "https://opengameart.org/content/medieval-exploration",
    url: "https://opengameart.org/sites/default/files/Exploration_0.mp3",
    sha256: "7e412350d4f4a777981285ca36b1c1a30feb7e5e255d7774ce61480e99daa8d9" },
  { id: "calm_town", title: "Calming RPG Town Theme", author: "Destin715",
    page: "https://opengameart.org/content/calming-rpg-town-theme",
    url: "https://opengameart.org/sites/default/files/CalmTownTheme_0.mp3",
    sha256: "52920d544a144a6a90c59e44a7601bdd265322aad3eb78aebb9d3eecf47935ac" },
];

const FIELD = {
  meadow: { title: "Springtime birdsong with soft wind ambiance", author: "rubindaniel",
    page: "https://freesound.org/people/rubindaniel/sounds/847380/",
    url: "https://cdn.freesound.org/previews/847/847380_15082088-hq.mp3",
    sha256: "b12aaac38019d77675310a2c2f274266e1d25e6213d78cddc3c8117db8be1a82" },
  porch: { title: "Night Crickets Back Porch", author: "hdfreema",
    page: "https://freesound.org/people/hdfreema/sounds/333221/",
    url: "https://cdn.freesound.org/previews/333/333221_2098408-hq.mp3",
    sha256: "7429a4e5b023514f9d9ec313d0ec3d3304e69525b1d3689378d9809d4635128a" },
  crickets: { title: "Crickets At Night - Clean sound", author: "Defelozedd94",
    page: "https://freesound.org/people/Defelozedd94/sounds/522298/",
    url: "https://cdn.freesound.org/previews/522/522298_9084007-hq.mp3",
    sha256: "8ae77b161d9e530739f31f4885941e6bdfff218060d530314b59383cbce0bdfa" },
};

// ------------------------------------------------------------------------------------------------
// Paths and downloads

/** The main checkout's .tools/vendor/audio (worktrees share it), else this checkout's. */
function defaultVendor() {
  try {
    const common = execFileSync("git", ["rev-parse", "--path-format=absolute", "--git-common-dir"], {
      cwd: root, stdio: ["ignore", "pipe", "ignore"],
    }).toString().trim();
    if (common) return join(dirname(common), ".tools", "vendor", "audio");
  } catch {
    // not a git checkout: fall through
  }
  return join(root, ".tools", "vendor", "audio");
}

const VENDOR = resolve(opt("--vendor") ?? defaultVendor());
const DOWNLOADS = join(VENDOR, "downloads");
const TMP = join(VENDOR, "tmp");

const sha256 = (buf) => createHash("sha256").update(buf).digest("hex");

async function fetchPinned(url, sha, file) {
  if (existsSync(file) && sha256(readFileSync(file)) === sha) return file;
  if (OFFLINE) throw new Error(`${file} is missing or changed and --offline was given`);
  console.log(`  downloading ${url}`);
  const res = await fetch(url, { headers: { "User-Agent": "Mozilla/5.0 (AgentEmpire fetch-audio)" } });
  if (!res.ok) throw new Error(`${url}: HTTP ${res.status}`);
  const buf = Buffer.from(await res.arrayBuffer());
  const got = sha256(buf);
  if (got !== sha) throw new Error(`${url}: SHA-256 ${got}, expected ${sha}`);
  mkdirSync(dirname(file), { recursive: true });
  writeFileSync(file, buf);
  return file;
}

/** Minimal zip reader (stored and deflated entries), so no unzip tool is needed. */
function unzip(zipFile, dest) {
  const z = readFileSync(zipFile);
  let eocd = z.length - 22;
  while (eocd >= 0 && z.readUInt32LE(eocd) !== 0x06054b50) eocd--;
  if (eocd < 0) throw new Error(`${zipFile}: not a zip`);
  const count = z.readUInt16LE(eocd + 10);
  let p = z.readUInt32LE(eocd + 16);
  for (let i = 0; i < count; i++) {
    if (z.readUInt32LE(p) !== 0x02014b50) throw new Error(`${zipFile}: bad central directory`);
    const method = z.readUInt16LE(p + 10);
    const csize = z.readUInt32LE(p + 20);
    const nlen = z.readUInt16LE(p + 28);
    const xlen = z.readUInt16LE(p + 30);
    const clen = z.readUInt16LE(p + 32);
    const local = z.readUInt32LE(p + 42);
    const name = z.toString("utf8", p + 46, p + 46 + nlen);
    p += 46 + nlen + xlen + clen;
    if (name.endsWith("/")) continue;
    const lnlen = z.readUInt16LE(local + 26);
    const lxlen = z.readUInt16LE(local + 28);
    const data = z.subarray(local + 30 + lnlen + lxlen, local + 30 + lnlen + lxlen + csize);
    const outFile = join(dest, name);
    if (!resolve(outFile).startsWith(resolve(dest))) throw new Error(`${zipFile}: unsafe path ${name}`);
    mkdirSync(dirname(outFile), { recursive: true });
    writeFileSync(outFile, method === 0 ? data : inflateRawSync(data));
  }
}

async function prepareSources() {
  for (const k of KENNEY) {
    const zip = await fetchPinned(k.url, k.sha256, join(DOWNLOADS, `${k.dir}.zip`));
    const dir = join(VENDOR, "kenney", k.dir);
    const stamp = join(dir, ".sha256");
    if (!existsSync(stamp) || readFileSync(stamp, "utf8") !== k.sha256) {
      rmSync(dir, { recursive: true, force: true });
      unzip(zip, dir);
      writeFileSync(stamp, k.sha256);
    }
  }
  if (!NO_MUSIC) {
    for (const m of MUSIC) await fetchPinned(m.url, m.sha256, join(DOWNLOADS, "music", m.url.split("/").pop()));
    for (const f of Object.values(FIELD)) await fetchPinned(f.url, f.sha256, join(DOWNLOADS, "ambience", f.url.split("/").pop()));
  }
}

const kenney = (pack, file) => join(VENDOR, "kenney", `kenney_${pack}`, "Audio", file);

// ------------------------------------------------------------------------------------------------
// ffmpeg

function ff(ffArgs, label) {
  const r = spawnSync(FFMPEG, ["-hide_banner", "-nostdin", ...ffArgs], { maxBuffer: 1 << 30 });
  if (r.status !== 0) throw new Error(`ffmpeg failed (${label}): ${r.stderr?.toString().slice(-800)}`);
  return r;
}

/** Decodes any audio file to channels of Float32 at SR. */
function decode(file, channels = 1) {
  const r = ff(["-v", "error", "-i", file, "-ac", String(channels), "-ar", String(SR), "-f", "f32le", "-"], file);
  const all = new Float32Array(r.stdout.buffer, r.stdout.byteOffset, r.stdout.byteLength / 4);
  const n = all.length / channels;
  const out = [];
  for (let c = 0; c < channels; c++) {
    const ch = new Float32Array(n);
    for (let i = 0; i < n; i++) ch[i] = all[i * channels + c];
    out.push(ch);
  }
  return out;
}

/** Channel count of an audio file (from ffmpeg's stream line). */
function channelsOf(file) {
  const r = spawnSync(FFMPEG, ["-hide_banner", "-nostdin", "-i", file], { maxBuffer: 1 << 24 });
  const m = r.stderr.toString().match(/Audio: [^\n]*?, \d+ Hz, (mono|stereo|(\d+) channels)/);
  return !m ? 2 : m[1] === "mono" ? 1 : m[1] === "stereo" ? 2 : parseInt(m[2]);
}

/** EBU R128 numbers: peak momentary (M), integrated (I) and true peak (TP), padded so even a
 *  20 ms click fills one 400 ms momentary window. A mono file is measured as Godot plays it:
 *  the same signal at full level on both channels (3 dB louder than one channel). */
function measure(file) {
  const dual = channelsOf(file) === 1 ? "pan=stereo|c0=c0|c1=c0," : "";
  const r = ff(["-nostats", "-v", "verbose", "-i", file, "-af", `${dual}apad=pad_dur=0.5,ebur128=peak=true:framelog=verbose`,
    "-f", "null", "-"], `measure ${file}`);
  const err = r.stderr.toString();
  let m = -Infinity;
  for (const x of err.matchAll(/ M:\s*(-?[0-9.]+)/g)) m = Math.max(m, parseFloat(x[1]));
  const summary = err.slice(err.lastIndexOf("Summary:"));
  const i = summary.match(/I:\s*(-?[0-9.]+|-inf)\s*LUFS/);
  const tp = summary.match(/Peak:\s*(-?[0-9.]+|-inf)\s*dBFS/);
  return { M: m, I: i ? parseFloat(i[1]) : -Infinity, TP: tp ? parseFloat(tp[1]) : -Infinity };
}

function writeWavFloat(file, chans) {
  const n = chans[0].length;
  const nc = chans.length;
  const buf = Buffer.alloc(44 + n * nc * 4);
  buf.write("RIFF", 0);
  buf.writeUInt32LE(36 + n * nc * 4, 4);
  buf.write("WAVE", 8);
  buf.write("fmt ", 12);
  buf.writeUInt32LE(16, 16);
  buf.writeUInt16LE(3, 20); // IEEE float
  buf.writeUInt16LE(nc, 22);
  buf.writeUInt32LE(SR, 24);
  buf.writeUInt32LE(SR * nc * 4, 28);
  buf.writeUInt16LE(nc * 4, 32);
  buf.writeUInt16LE(32, 34);
  buf.write("data", 36);
  buf.writeUInt32LE(n * nc * 4, 40);
  let o = 44;
  for (let i = 0; i < n; i++) {
    for (let c = 0; c < nc; c++) {
      buf.writeFloatLE(chans[c][i], o);
      o += 4;
    }
  }
  mkdirSync(dirname(file), { recursive: true });
  writeFileSync(file, buf);
}

// ------------------------------------------------------------------------------------------------
// DSP. A sound is an array of channels (Float32Array at SR): [mono] or [left, right].

const TAU = Math.PI * 2;
const db = (x) => Math.pow(10, x / 20);
const samples = (sec) => Math.max(1, Math.round(sec * SR));
const midi = (m) => 440 * Math.pow(2, (m - 69) / 12);
const NOTE = { C: 0, D: 2, E: 4, F: 5, G: 7, A: 9, B: 11 };
/** "A5", "F#4", "Bb3" -> Hz. */
function hz(name) {
  const m = name.match(/^([A-G])([#b]?)(-?\d)$/);
  if (!m) throw new Error(`bad note ${name}`);
  return midi(12 * (parseInt(m[3]) + 1) + NOTE[m[1]] + (m[2] === "#" ? 1 : m[2] === "b" ? -1 : 0));
}

/** mulberry32: a small seeded PRNG so synthesis is reproducible. */
function rng(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const mono = (sec) => [new Float32Array(samples(sec))];
const stereo = (sec) => [new Float32Array(samples(sec)), new Float32Array(samples(sec))];
const len = (s) => s[0].length;

/** Mixes `src` into `dst` at `at` seconds. A mono source going into a stereo bus is panned
 *  (-1 left .. 1 right, constant power); the destination grows when needed. */
function mix(dst, src, at = 0, gain = 1, pan = 0) {
  const off = Math.round(at * SR);
  const need = off + len(src);
  if (need > len(dst)) {
    for (let c = 0; c < dst.length; c++) {
      const g = new Float32Array(need);
      g.set(dst[c]);
      dst[c] = g;
    }
  }
  for (let c = 0; c < dst.length; c++) {
    const s = src.length === 1 ? src[0] : src[Math.min(c, src.length - 1)];
    let g = gain;
    if (src.length === 1 && dst.length === 2) {
      const a = (pan + 1) * Math.PI / 4;
      g *= c === 0 ? Math.cos(a) * Math.SQRT2 : Math.sin(a) * Math.SQRT2;
    }
    const d = dst[c];
    for (let i = 0; i < s.length; i++) d[off + i] += s[i] * g;
  }
  return dst;
}

function scale(s, g) {
  for (const ch of s) for (let i = 0; i < ch.length; i++) ch[i] *= g;
  return s;
}

function peak(s) {
  let p = 0;
  for (const ch of s) for (let i = 0; i < ch.length; i++) p = Math.max(p, Math.abs(ch[i]));
  return p;
}

function toStereo(s) {
  return s.length === 2 ? s : [Float32Array.from(s[0]), Float32Array.from(s[0])];
}

function toMono(s) {
  if (s.length === 1) return s;
  const m = new Float32Array(len(s));
  for (let i = 0; i < m.length; i++) m[i] = (s[0][i] + s[1][i]) * 0.5;
  return [m];
}

function fade(s, inSec, outSec) {
  const n = len(s);
  const a = samples(inSec);
  const b = samples(outSec);
  for (const ch of s) {
    for (let i = 0; i < Math.min(a, n); i++) ch[i] *= Math.sin((i / a) * Math.PI / 2);
    for (let i = 0; i < Math.min(b, n); i++) ch[n - 1 - i] *= Math.sin((i / b) * Math.PI / 2);
  }
  return s;
}

function slice(s, from, to) {
  const a = Math.max(0, Math.round(from * SR));
  const b = to === undefined ? len(s) : Math.min(len(s), Math.round(to * SR));
  return s.map((ch) => ch.slice(a, b));
}

/** Cuts leading audio below `startDb` and trailing audio below `endDb` (relative to the peak),
 *  keeping a short pre-roll, and fades the ends. */
function trim(s, startDb = -46, endDb = -62, pre = 0.003, tail = 0.03) {
  const p = peak(s);
  if (p === 0) return s;
  const n = len(s);
  let first = n;
  let last = 0;
  const t0 = p * db(startDb);
  const t1 = p * db(endDb);
  for (const ch of s) {
    for (let i = 0; i < n; i++) if (Math.abs(ch[i]) > t0) { first = Math.min(first, i); break; }
    for (let i = n - 1; i >= 0; i--) if (Math.abs(ch[i]) > t1) { last = Math.max(last, i); break; }
  }
  const a = Math.max(0, first - samples(pre));
  const b = Math.min(n, last + samples(tail));
  return fade(s.map((ch) => ch.slice(a, b)), 0.002, Math.min(tail, (b - a) / SR / 4));
}

/** Plays a sound faster (ratio > 1, higher and shorter) or slower, with cubic interpolation. */
function resample(s, ratio) {
  const n = Math.floor((len(s) - 3) / ratio);
  return s.map((ch) => {
    const o = new Float32Array(Math.max(n, 1));
    for (let i = 0; i < n; i++) {
      const x = 1 + i * ratio;
      const k = Math.floor(x);
      const f = x - k;
      const y0 = ch[k - 1], y1 = ch[k], y2 = ch[k + 1], y3 = ch[k + 2];
      o[i] = y1 + 0.5 * f * (y2 - y0 + f * (2 * y0 - 5 * y1 + 4 * y2 - y3 + f * (3 * (y1 - y2) + y3 - y0)));
    }
    return o;
  });
}

/** RBJ biquad coefficients. */
function biquad(type, f, q = 0.7071, gainDb = 0) {
  const w = TAU * Math.min(f, SR * 0.49) / SR;
  const cw = Math.cos(w);
  const sw = Math.sin(w);
  const alpha = sw / (2 * q);
  const A = Math.pow(10, gainDb / 40);
  let b0, b1, b2, a0, a1, a2;
  switch (type) {
    case "lp": b0 = (1 - cw) / 2; b1 = 1 - cw; b2 = b0; a0 = 1 + alpha; a1 = -2 * cw; a2 = 1 - alpha; break;
    case "hp": b0 = (1 + cw) / 2; b1 = -(1 + cw); b2 = b0; a0 = 1 + alpha; a1 = -2 * cw; a2 = 1 - alpha; break;
    case "bp": b0 = alpha; b1 = 0; b2 = -alpha; a0 = 1 + alpha; a1 = -2 * cw; a2 = 1 - alpha; break;
    case "peak": b0 = 1 + alpha * A; b1 = -2 * cw; b2 = 1 - alpha * A; a0 = 1 + alpha / A; a1 = -2 * cw; a2 = 1 - alpha / A; break;
    case "lowshelf": {
      const sa = 2 * Math.sqrt(A) * alpha;
      b0 = A * ((A + 1) - (A - 1) * cw + sa); b1 = 2 * A * ((A - 1) - (A + 1) * cw); b2 = A * ((A + 1) - (A - 1) * cw - sa);
      a0 = (A + 1) + (A - 1) * cw + sa; a1 = -2 * ((A - 1) + (A + 1) * cw); a2 = (A + 1) + (A - 1) * cw - sa;
      break;
    }
    case "highshelf": {
      const sa = 2 * Math.sqrt(A) * alpha;
      b0 = A * ((A + 1) + (A - 1) * cw + sa); b1 = -2 * A * ((A - 1) + (A + 1) * cw); b2 = A * ((A + 1) + (A - 1) * cw - sa);
      a0 = (A + 1) - (A - 1) * cw + sa; a1 = 2 * ((A - 1) - (A + 1) * cw); a2 = (A + 1) - (A - 1) * cw - sa;
      break;
    }
    default: throw new Error(`biquad ${type}`);
  }
  return [b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0];
}

function runBiquad(ch, c) {
  const [b0, b1, b2, a1, a2] = c;
  let z1 = 0, z2 = 0;
  for (let i = 0; i < ch.length; i++) {
    const x = ch[i];
    const y = b0 * x + z1;
    z1 = b1 * x - a1 * y + z2;
    z2 = b2 * x - a2 * y;
    ch[i] = y;
  }
}

/** Filters in place: filter(s, "lp", 2000, 0.7) or a chain [["hp", 80], ["peak", 300, 1, 3]]. */
function filter(s, type, f, q, gainDb) {
  const chain = Array.isArray(type) ? type : [[type, f, q, gainDb]];
  for (const [t, fr, qq, g] of chain) {
    const c = biquad(t, fr, qq ?? 0.7071, g ?? 0);
    for (const ch of s) runBiquad(ch, c);
  }
  return s;
}

/** A biquad whose cutoff follows fn(t seconds), updated every 32 samples. */
function sweep(s, type, fn, q = 0.7071) {
  for (const ch of s) {
    let z1 = 0, z2 = 0;
    let c = biquad(type, fn(0), q);
    for (let i = 0; i < ch.length; i++) {
      if ((i & 31) === 0) c = biquad(type, Math.max(20, fn(i / SR)), q);
      const [b0, b1, b2, a1, a2] = c;
      const x = ch[i];
      const y = b0 * x + z1;
      z1 = b1 * x - a1 * y + z2;
      z2 = b2 * x - a2 * y;
      ch[i] = y;
    }
  }
  return s;
}

function noise(sec, seed, color = "white") {
  const r = rng(seed);
  const o = new Float32Array(samples(sec));
  let b0 = 0, b1 = 0, b2 = 0, b3 = 0, b4 = 0, b5 = 0, b6 = 0, br = 0;
  for (let i = 0; i < o.length; i++) {
    const w = r() * 2 - 1;
    if (color === "pink") {
      b0 = 0.99886 * b0 + w * 0.0555179; b1 = 0.99332 * b1 + w * 0.0750759; b2 = 0.969 * b2 + w * 0.153852;
      b3 = 0.8665 * b3 + w * 0.3104856; b4 = 0.55 * b4 + w * 0.5329522; b5 = -0.7616 * b5 - w * 0.016898;
      o[i] = (b0 + b1 + b2 + b3 + b4 + b5 + b6 + w * 0.5362) * 0.11;
      b6 = w * 0.115926;
    } else if (color === "brown") {
      br = (br + 0.02 * w) / 1.02;
      o[i] = br * 3.5;
    } else {
      o[i] = w;
    }
  }
  return [o];
}

/** Multiplies by an envelope fn(t seconds). */
function shape(s, fn) {
  for (const ch of s) for (let i = 0; i < ch.length; i++) ch[i] *= fn(i / SR);
  return s;
}

/** Attack-decay envelope: linear rise over `a`, exponential fall reaching -60 dB at `t60`. */
const ad = (a, t60) => (t) => (t < a ? t / a : 1) * Math.exp(-6.9078 * Math.max(0, t - a) / t60);

/** Adds a decaying sine partial into `ch` (mono Float32Array) from `start` seconds. */
function partial(ch, f, amp, t60, { start = 0, attack = 0.001, phase = 0, glide = 0, glideT = 0.2 } = {}) {
  const off = Math.round(start * SR);
  const n = Math.min(ch.length - off, samples(t60 * 1.15 + attack));
  let ph = phase;
  for (let i = 0; i < n; i++) {
    const t = i / SR;
    const env = (t < attack ? t / attack : 1) * Math.exp(-6.9078 * t / t60);
    const fr = glide ? f * Math.pow(2, (glide / 12) * Math.min(1, t / glideT)) : f;
    ph += TAU * fr / SR;
    ch[off + i] += amp * env * Math.sin(ph);
  }
}

// ---- FFT convolution (reverb) ----

function fft(re, im, inverse) {
  const n = re.length;
  for (let i = 1, j = 0; i < n; i++) {
    let bit = n >> 1;
    for (; j & bit; bit >>= 1) j ^= bit;
    j ^= bit;
    if (i < j) {
      [re[i], re[j]] = [re[j], re[i]];
      [im[i], im[j]] = [im[j], im[i]];
    }
  }
  for (let size = 2; size <= n; size <<= 1) {
    const half = size >> 1;
    const ang = (inverse ? TAU : -TAU) / size;
    const wr = Math.cos(ang), wi = Math.sin(ang);
    for (let start = 0; start < n; start += size) {
      let cr = 1, ci = 0;
      for (let k = 0; k < half; k++) {
        const a = start + k, b = a + half;
        const tr = re[b] * cr - im[b] * ci;
        const ti = re[b] * ci + im[b] * cr;
        re[b] = re[a] - tr; im[b] = im[a] - ti;
        re[a] += tr; im[a] += ti;
        const ncr = cr * wr - ci * wi;
        ci = cr * wi + ci * wr;
        cr = ncr;
      }
    }
  }
  if (inverse) for (let i = 0; i < n; i++) { re[i] /= n; im[i] /= n; }
}

function convolve(x, h) {
  const n = x.length + h.length - 1;
  let size = 1;
  while (size < n) size <<= 1;
  const xr = new Float64Array(size), xi = new Float64Array(size);
  const hr = new Float64Array(size), hi = new Float64Array(size);
  xr.set(x);
  hr.set(h);
  fft(xr, xi, false);
  fft(hr, hi, false);
  for (let i = 0; i < size; i++) {
    const r = xr[i] * hr[i] - xi[i] * hi[i];
    xi[i] = xr[i] * hi[i] + xi[i] * hr[i];
    xr[i] = r;
  }
  fft(xr, xi, true);
  return Float32Array.from(xr.subarray(0, n));
}

/** A synthetic stereo room: early reflections plus a diffuse tail that darkens as it decays.
 *  Normalised to unit energy per channel. */
function room({ rt60 = 1.6, pre = 0.012, bright = 9000, dark = 1400, er = 6, width = 1, seed = 7 } = {}) {
  const sec = rt60 * 1.1 + pre;
  const out = [];
  for (let c = 0; c < 2; c++) {
    const r = rng(seed * 31 + c * 977);
    const ch = new Float32Array(samples(sec));
    // diffuse tail: noise, exponential decay, low-pass falling from `bright` to `dark`
    let lp = 0;
    const p0 = samples(pre);
    for (let i = p0; i < ch.length; i++) {
      const t = (i - p0) / SR;
      const fc = dark + (bright - dark) * Math.exp(-t / (rt60 * 0.35));
      const a = 1 - Math.exp(-TAU * fc / SR);
      lp += a * ((r() * 2 - 1) - lp);
      const rise = Math.min(1, t / 0.03);
      ch[i] = lp * rise * Math.exp(-6.9078 * t / rt60);
    }
    // early reflections
    for (let k = 0; k < er; k++) {
      const t = pre + 0.004 + r() * 0.07;
      const i = samples(t);
      if (i < ch.length) ch[i] += (r() < 0.5 ? -1 : 1) * (0.5 + r() * 0.5) * 0.9 * Math.exp(-t * 6);
    }
    out.push(ch);
  }
  if (width < 1) {
    const [l, rr] = out;
    for (let i = 0; i < l.length; i++) {
      const m = (l[i] + rr[i]) * 0.5, s = (l[i] - rr[i]) * 0.5 * width;
      l[i] = m + s; rr[i] = m - s;
    }
  }
  for (const ch of out) {
    let e = 0;
    for (let i = 0; i < ch.length; i++) e += ch[i] * ch[i];
    const g = 1 / Math.sqrt(e || 1);
    for (let i = 0; i < ch.length; i++) ch[i] *= g;
  }
  return out;
}

const ROOMS = {};
const roomOf = (name) => (ROOMS[name] ??= {
  // a small close space: UI chimes, plucks
  close: () => room({ rt60: 0.55, pre: 0.006, bright: 8000, dark: 2500, er: 8, seed: 3 }),
  // the open town square between houses
  square: () => room({ rt60: 1.5, pre: 0.014, bright: 9000, dark: 1600, er: 10, seed: 5 }),
  // a bell tower over the town: long, dark tail
  tower: () => room({ rt60: 3.2, pre: 0.025, bright: 7000, dark: 900, er: 12, seed: 11 }),
  // the great bells of a new age
  cathedral: () => room({ rt60: 4.6, pre: 0.035, bright: 6500, dark: 700, er: 14, seed: 13 }),
}[name]());

/** Adds a reverb: returns a stereo sound, dry plus `wetDb` of the room. */
function verb(s, name, wetDb = -10, dryDb = 0) {
  const ir = roomOf(name);
  const st = toStereo(s);
  const tail = len(ir) - 1;
  const out = [new Float32Array(len(st) + tail), new Float32Array(len(st) + tail)];
  const wet = db(wetDb), dry = db(dryDb);
  for (let c = 0; c < 2; c++) {
    const w = convolve(st[c], ir[c]);
    for (let i = 0; i < w.length; i++) out[c][i] = w[i] * wet + (i < st[c].length ? st[c][i] * dry : 0);
  }
  return out;
}

// ------------------------------------------------------------------------------------------------
// Instruments

/** Bell partial tables: [ratio to the prime, amplitude, decay as a share of the bell's T60, beat Hz].
 *  TOWER follows a minor-third church bell (hum, prime, tierce, quint, nominal and the upper
 *  partials), HAND an English handbell (fundamental and tuned twelfth, weak upper modes). */
const TOWER = [
  [0.5, 0.42, 1.0, 0.35], [1.0, 0.5, 0.62, 0.6], [1.19, 0.48, 0.5, 0.9], [1.505, 0.16, 0.34, 1.1],
  [2.0, 1.0, 0.42, 1.3], [2.51, 0.3, 0.24, 1.7], [2.67, 0.24, 0.2, 2.1], [3.01, 0.3, 0.16, 2.4],
  [4.06, 0.2, 0.11, 3.0], [5.2, 0.12, 0.07, 3.4], [5.95, 0.09, 0.055, 4.0], [6.69, 0.06, 0.045, 4.6],
  [8.01, 0.05, 0.035, 5.2], [9.31, 0.03, 0.028, 5.9], [10.65, 0.02, 0.022, 6.5],
];
const HAND = [
  [1.0, 1.0, 1.0, 0.7], [2.32, 0.05, 0.2, 1.5], [3.0, 0.24, 0.42, 1.1], [4.13, 0.035, 0.14, 2.2],
  [5.18, 0.08, 0.2, 2.6], [7.55, 0.035, 0.1, 3.1], [10.2, 0.015, 0.06, 3.8],
];

/** One bell stroke: every partial as a pair of slightly split modes (the slow beating that makes
 *  a bell shimmer), plus the clapper's strike: a short clang of high inharmonic modes and a
 *  breath of noise. `f` is the prime in Hz (the strike note a listener hears). */
function bellStroke(f, { table = TOWER, t60 = 4, amp = 1, seed = 1, strike = 0.25, strikeHz = 3200,
  bright = 1, dur } = {}) {
  const r = rng(seed);
  const total = dur ?? t60 * 1.1;
  const s = mono(total);
  const ch = s[0];
  for (const [ratio, a, share, beat] of table) {
    const fr = f * ratio;
    if (fr > SR * 0.45) continue;
    const tilt = ratio > 2 ? Math.pow(bright, Math.log2(ratio / 2)) : 1;
    const T = Math.max(0.05, t60 * share);
    const split = beat * (0.7 + r() * 0.6);
    partial(ch, fr, amp * a * tilt * 0.62, T, { phase: r() * TAU, attack: 0.0015 });
    partial(ch, fr + split, amp * a * tilt * 0.38, T * 0.92, { phase: r() * TAU, attack: 0.0015 });
  }
  if (strike > 0) {
    // the clang: short-lived high modes, louder for heavier strikes
    for (let k = 0; k < 10; k++) {
      const fr = f * (6 + r() * 14);
      if (fr > 16000) continue;
      partial(ch, fr, amp * strike * (0.05 + r() * 0.08), 0.03 + r() * 0.09, { phase: r() * TAU, attack: 0.0005 });
    }
    const n = noise(0.06, seed + 101, "white");
    filter(n, [["bp", strikeHz, 1.3], ["hp", 600]]);
    shape(n, ad(0.0008, 0.03));
    mix(s, n, 0, amp * strike * 0.6);
  }
  return s;
}

/** Struck metal bar (glockenspiel / celesta): bar modes 1 : 2.756 : 5.404 : 8.933. `soft` rounds
 *  the attack like a felt hammer. */
function chime(f, { t60 = 1.4, amp = 1, seed = 1, soft = 0.4, dur } = {}) {
  const r = rng(seed);
  const s = mono(dur ?? t60 * 1.1);
  const ch = s[0];
  const attack = 0.001 + soft * 0.004;
  partial(ch, f, amp, t60, { phase: r() * TAU, attack });
  partial(ch, f * 1.0016, amp * 0.25, t60 * 0.9, { phase: r() * TAU, attack });
  partial(ch, f * 2.0, amp * 0.12 * (1 - soft * 0.5), t60 * 0.35, { phase: r() * TAU, attack });
  partial(ch, f * 2.756, amp * 0.1 * (1 - soft * 0.6), t60 * 0.22, { phase: r() * TAU, attack });
  partial(ch, f * 5.404, amp * 0.035 * (1 - soft), t60 * 0.1, { phase: r() * TAU, attack });
  const n = noise(0.01, seed + 7);
  filter(n, "bp", Math.min(f * 3, 9000), 2);
  shape(n, ad(0.0005, 0.006));
  mix(s, n, 0, amp * 0.12 * (1 - soft));
  return s;
}

/** A wooden bar (marimba); `muted` shortens it into a knock. */
function woodTone(f, { t60 = 0.7, amp = 1, seed = 1, muted = 0 } = {}) {
  const r = rng(seed);
  const T = t60 * (1 - muted * 0.8);
  const s = mono(T * 1.2 + 0.05);
  const ch = s[0];
  partial(ch, f, amp, T, { phase: r() * TAU, attack: 0.003 });
  partial(ch, f * 3.93, amp * 0.28, T * 0.22, { phase: r() * TAU, attack: 0.002 });
  partial(ch, f * 9.2, amp * 0.06, T * 0.07, { phase: r() * TAU, attack: 0.001 });
  const n = noise(0.03, seed + 3);
  filter(n, [["lp", 1800], ["hp", 120]]);
  shape(n, ad(0.001, 0.012 + muted * 0.02));
  mix(s, n, 0, amp * (0.25 + muted * 0.35));
  return s;
}

/** Plucked string (extended Karplus-Strong): fractional-delay tuning, a loss filter set for `t60`,
 *  a pick-position comb and a lute or harp body. */
function pluck(f, { t60 = 1.6, amp = 1, seed = 1, bright = 0.55, pick = 0.18, body = "lute", dur } = {}) {
  const r = rng(seed);
  const total = dur ?? t60 * 1.05 + 0.05;
  const out = new Float32Array(samples(total));
  const S = 0.5;
  const N = SR / f;
  let P = Math.floor(N - S);
  let eta = N - S - P;
  if (eta < 0.1) { P -= 1; eta += 1; }
  const C = (1 - eta) / (1 + eta);
  const rho = Math.pow(10, -3 / (f * t60));
  const line = new Float32Array(P);
  let lp = 0;
  const a = 1 - Math.exp(-TAU * (300 + bright * 9000) / SR);
  for (let i = 0; i < P; i++) {
    lp += a * ((r() * 2 - 1) - lp);
    line[i] = lp;
  }
  const k = Math.max(1, Math.round(pick * P));
  const exc = Float32Array.from(line);
  for (let i = 0; i < P; i++) line[i] = exc[i] - (i >= k ? exc[i - k] : 0);
  let mean = 0;
  for (let i = 0; i < P; i++) mean += line[i] / P;
  for (let i = 0; i < P; i++) line[i] -= mean;
  let idx = 0, prev = 0, apx = 0, apy = 0;
  for (let i = 0; i < out.length; i++) {
    const y = line[idx];
    const loss = rho * ((1 - S) * y + S * prev);
    prev = y;
    const ap = C * loss + apx - C * apy;
    apx = loss;
    apy = ap;
    line[idx] = ap;
    idx = (idx + 1) % P;
    out[i] = y;
  }
  const s = [out];
  if (body === "lute") filter(s, [["hp", 70], ["peak", 120, 1.2, 4], ["peak", 290, 1.4, 3], ["peak", 520, 2, 2], ["lp", 5200, 0.6]]);
  else if (body === "harp") filter(s, [["hp", 60], ["peak", 200, 0.9, 2], ["highshelf", 3000, 0.7, 2]]);
  // a little finger noise on the attack
  const n = noise(0.02, seed + 9);
  filter(n, [["bp", 2500, 0.9]]);
  shape(n, ad(0.0005, 0.01));
  mix(s, n, 0, 0.08);
  const p = peak(s);
  return scale(s, amp / (p || 1));
}

/** Soft high pings scattered over [from, to] seconds: magic, coins' glint, the Font. */
function sparkles(dur, { count = 12, from = 0, to = dur, notes = ["D6", "F#6", "A6", "B6", "D7", "E7"], amp = 0.25, seed = 5,
  t60 = [0.25, 0.7], rise = 0 } = {}) {
  const r = rng(seed);
  const s = stereo(dur);
  for (let i = 0; i < count; i++) {
    const at = from + (to - from) * (rise ? Math.pow(r(), 1 / (1 + rise)) : r());
    const f = hz(notes[Math.floor(r() * notes.length)]) * (r() < 0.25 ? 2 : 1);
    const one = mono(t60[1] * 1.2);
    partial(one[0], f, 1, t60[0] + r() * (t60[1] - t60[0]), { phase: r() * TAU, attack: 0.002 + r() * 0.01 });
    partial(one[0], f * 2.01, 0.15, t60[0] * 0.5, { phase: r() * TAU, attack: 0.002 });
    mix(s, one, at, amp * (0.5 + r() * 0.5), r() * 1.6 - 0.8);
  }
  return s;
}

/** Band-passed noise whose centre glides from f0 to f1: wind, whooshes, the wisp's flight. */
function whoosh(dur, f0, f1, { q = 1.2, seed = 3, color = "pink", env = (t) => Math.sin(Math.PI * Math.min(1, t / dur)) } = {}) {
  const s = noise(dur, seed, color);
  sweep(s, "bp", (t) => f0 * Math.pow(f1 / f0, Math.min(1, t / dur)), q);
  return shape(s, env);
}

/** A sustained, slowly swelling chord of detuned sines (the Font's glow). */
function pad(dur, notes, { attack = 0.6, release = 1.2, amp = 0.3, seed = 2, detune = 4, glide = 0, glideT = 0.4 } = {}) {
  const r = rng(seed);
  const s = stereo(dur + release);
  for (const name of notes) {
    const f = hz(name);
    for (let v = 0; v < 3; v++) {
      const cents = (v - 1) * detune + (r() - 0.5) * 2;
      const fr = f * Math.pow(2, cents / 1200);
      const one = mono(dur + release);
      const ch = one[0];
      let ph = r() * TAU;
      for (let i = 0; i < ch.length; i++) {
        const t = i / SR;
        const g = glide ? Math.pow(2, (glide / 12) * Math.min(1, t / glideT)) : 1;
        ph += TAU * fr * g / SR;
        const e = t < attack ? Math.pow(t / attack, 1.6) : t < dur ? 1 : Math.exp(-6.9078 * (t - dur) / release);
        ch[i] = Math.sin(ph) * e;
      }
      mix(s, one, 0, amp / notes.length, (v - 1) * 0.6);
    }
  }
  return s;
}

/** A Kenney sample (mono), with its silence trimmed. */
const sample = (pack, file, channels = 1) => trim(decode(kenney(pack, file), channels));

/** Lookahead peak limiter: pulls the peaks down by `reduceDb` (linked across channels), so a
 *  spiky one-shot can sit at the same loudness as its siblings without clipping. */
function limit(s, reduceDb, { look = 0.0015, release = 0.06 } = {}) {
  const n = len(s);
  const ceiling = peak(s) * db(-reduceDb);
  const req = new Float32Array(n);
  for (let i = 0; i < n; i++) {
    let a = 0;
    for (const ch of s) a = Math.max(a, Math.abs(ch[i]));
    req[i] = a > ceiling ? ceiling / a : 1;
  }
  // minimum of the required gain over the next `look` seconds (monotonic deque)
  const L = samples(look);
  const wmin = new Float32Array(n);
  const dq = [];
  for (let i = n - 1; i >= 0; i--) {
    while (dq.length && req[dq[dq.length - 1]] >= req[i]) dq.pop();
    dq.push(i);
    while (dq[0] > i + L) dq.shift();
    wmin[i] = req[dq[0]];
  }
  const att = 1 - Math.exp(-3 / L);
  const rel = 1 - Math.exp(-1 / (release * SR));
  let g = 1;
  for (let i = 0; i < n; i++) {
    g += (wmin[i] - g) * (wmin[i] < g ? att : rel);
    for (const ch of s) ch[i] = Math.max(-ceiling, Math.min(ceiling, ch[i] * g));
  }
  return s;
}

// ------------------------------------------------------------------------------------------------
// Cues. Each recipe returns one sound per variant; the Audio autoload picks a variant at random.
// group: the folder under client/audio; fmt: "wav" (short, frequent) or "ogg" (long, tails).

const CUES = {};
function cue(name, group, fmt, build, opts = {}) {
  CUES[name] = { group, fmt, build, ...opts };
}

/** World cues (played with Audio.play_at) start with this much silence: Godot ramps a 3D voice
 *  up from silence over its first mix block (about 11 ms), which would eat a sharp attack. */
const WORLD_PREROLL = 0.02;
const WORLD = { world: true };
const preroll = (s, sec) => s.map((ch) => {
  const o = new Float32Array(ch.length + samples(sec));
  o.set(ch, samples(sec));
  return o;
});

// ---- Bells (the most-heard sounds: each one distinct) ----

// The hand bell over an agent's home: an approval is waiting. A small, sweet handbell rung
// twice, like a servant's bell; heard often, so it stays soft and short.
cue("hand_bell", "agents", "ogg", () => [0, 1].map((v) => {
  const f = hz("A5") * (v ? 1.0 : 0.9993);
  const s = stereo(2.2);
  mix(s, bellStroke(f, { table: HAND, t60: 1.6, seed: 40 + v, strike: 0.12, strikeHz: 5200, bright: 0.8 }), 0.0, 1.0, -0.1);
  mix(s, bellStroke(f, { table: HAND, t60: 1.5, seed: 50 + v, strike: 0.1, strikeHz: 5200, bright: 0.75 }), 0.2 + v * 0.02, 0.72, 0.1);
  return trim(verb(s, "square", -15));
}));

// The alarm bell: an agent is stalled or looping. A tower bell rung fast and hard, like a tocsin.
cue("alarm_bell", "alerts", "ogg", () => {
  const r = rng(61);
  const s = stereo(4);
  const f = hz("E4");
  for (let k = 0; k < 6; k++) {
    const at = k * 0.3 + (r() - 0.5) * 0.03;
    mix(s, bellStroke(f, { table: TOWER, t60: 2.4, seed: 62 + k, strike: 0.45, strikeHz: 2600, bright: 1.1 }), at, 0.85 + r() * 0.15, k % 2 ? 0.15 : -0.15);
  }
  return [trim(verb(s, "square", -9))];
});

// The warning bell: Mana is down to 10%. One large, deep bell tolled twice, slow and solemn.
cue("warning_bell", "alerts", "ogg", () => {
  const s = stereo(7);
  const f = hz("G3");
  mix(s, bellStroke(f, { table: TOWER, t60: 5.5, seed: 71, strike: 0.3, strikeHz: 1800, bright: 0.85 }), 0, 1.0);
  mix(s, bellStroke(f, { table: TOWER, t60: 5.0, seed: 72, strike: 0.28, strikeHz: 1800, bright: 0.85 }), 2.3, 0.9);
  return [trim(verb(s, "tower", -10))];
});

// The Dawn Bell: the Mana pool refills. A bright peal of four bells (rounds), twice.
cue("dawn_bell", "alerts", "ogg", () => {
  const s = stereo(5);
  const notes = ["G5", "E5", "D5", "C5"];
  let k = 0;
  for (let round = 0; round < 2; round++) {
    notes.forEach((n, i) => {
      const at = round * 1.62 + i * 0.36;
      mix(s, bellStroke(hz(n) / 2, { table: TOWER, t60: 2.8, seed: 80 + k, strike: 0.18, strikeHz: 4200, bright: 0.9 }), at,
        0.9 - i * 0.04, 0.5 - i * 0.33);
      k++;
    });
  }
  return [trim(verb(s, "tower", -11))];
});

// The great age bells: the town advances an age. Six big bells ring rounds twice, then the
// great tenor tolls under them.
cue("age_bells", "ages", "ogg", () => {
  const s = stereo(12);
  const notes = ["A4", "G4", "F4", "E4", "D4", "C4"];
  let k = 0;
  for (let round = 0; round < 2; round++) {
    notes.forEach((n, i) => {
      const at = round * 2.7 + i * 0.42;
      mix(s, bellStroke(hz(n) / 2, { table: TOWER, t60: 4.2, seed: 90 + k, strike: 0.22, strikeHz: 2400, bright: 0.85 }), at,
        0.75, 0.75 - i * 0.3);
      k++;
    });
  }
  const tenor = bellStroke(hz("C3") / 2, { table: TOWER, t60: 7.5, seed: 120, strike: 0.35, strikeHz: 1200, bright: 1.05 });
  mix(s, tenor, 5.6, 1.15, 0);
  // the low boom of the tenor's hum in the stones
  const boom = mono(5);
  partial(boom[0], hz("C2"), 1, 4.2, { attack: 0.01 });
  mix(s, boom, 5.6, 0.25);
  return [trim(verb(s, "cathedral", -8))];
});

// ---- UI ----

// Every button: a soft, slightly woody click (Kenney UI Audio, a little lower and darker).
cue("ui_click", "ui", "wav", () => ["click1.ogg", "click2.ogg", "click3.ogg"].map((f) =>
  trim(filter(resample(sample("ui-audio", f), 0.88), [["hp", 160], ["lp", 6500, 0.7]]))));

// Hovering a button: the faintest tick.
cue("ui_hover", "ui", "wav", () => ["tick_002.ogg", "tick_004.ogg"].map((f) =>
  trim(filter(resample(sample("interface-sounds", f), 0.8), [["hp", 300], ["lp", 5000, 0.7]]))));

// A window opens: a page turned on the parchment.
cue("ui_open", "ui", "wav", () => ["bookFlip2.ogg", "bookFlip3.ogg"].map((f) =>
  trim(filter(sample("rpg-audio", f), [["hp", 220], ["lp", 9000, 0.7]]))));

// A window closes: the book shut and set down.
cue("ui_close", "ui", "wav", () => ["bookClose.ogg", "bookPlace1.ogg"].map((f) =>
  trim(filter(sample("rpg-audio", f), [["hp", 120], ["lp", 8000, 0.7]]))));

// Confirm: two harp notes rising a fourth, with a glint.
cue("ui_confirm", "ui", "ogg", () => {
  const s = mono(1.0);
  mix(s, pluck(hz("D5"), { t60: 0.9, seed: 201, bright: 0.65, pick: 0.25, body: "harp" }), 0, 0.8);
  mix(s, pluck(hz("G5"), { t60: 0.9, seed: 202, bright: 0.65, pick: 0.25, body: "harp" }), 0.075, 0.9);
  mix(s, chime(hz("G6"), { t60: 0.6, seed: 203, soft: 0.7 }), 0.08, 0.12);
  return [trim(toMono(verb(s, "close", -14)))];
});

// Error: a dull double knock on wood, falling.
cue("ui_error", "ui", "wav", () => {
  const s = mono(0.5);
  mix(s, woodTone(hz("A3"), { t60: 0.4, seed: 211, muted: 0.7 }), 0, 1.0);
  mix(s, woodTone(hz("F3"), { t60: 0.4, seed: 212, muted: 0.75 }), 0.1, 0.9);
  return [trim(filter(s, "lp", 3500))];
});

// ---- Commands ----

// Selecting townsfolk: the rustle of a work coat.
cue("select_townsfolk", "commands", "wav", () => ["cloth1.ogg", "cloth2.ogg", "cloth3.ogg"].map((f) =>
  trim(filter(sample("rpg-audio", f), [["hp", 150], ["lp", 9000, 0.7]]))));

// Selecting an agent: a small magical glint (celesta and two sparks), on three notes of the chord.
cue("select_agent", "commands", "ogg", () => ["D6", "E6", "A5"].map((n, i) => {
  const s = mono(0.9);
  mix(s, chime(hz(n), { t60: 0.7, seed: 220 + i, soft: 0.6 }), 0, 0.8);
  mix(s, toMono(sparkles(0.6, { count: 3, from: 0.02, to: 0.18, amp: 0.25, seed: 225 + i, t60: [0.15, 0.35] })), 0, 1);
  return trim(toMono(verb(s, "close", -16)));
}));

// Selecting a building: a knock on its timber with a creak of the door.
cue("select_building", "commands", "wav", () => [0, 1, 2].map((i) => {
  const s = sample("impact-sounds", `impactWood_light_00${i}.ogg`);
  const creak = slice(sample("rpg-audio", "creak3.ogg"), 0, 0.3);
  mix(s, fade(creak, 0.01, 0.08), 0.02, 0.22);
  return trim(filter(s, [["hp", 70], ["lp", 7000, 0.7]]));
}));

// Move: two footsteps on packed earth.
cue("command_move", "commands", "wav", () => [["footstep00.ogg", "footstep03.ogg"], ["footstep01.ogg", "footstep04.ogg"],
  ["footstep02.ogg", "footstep06.ogg"]].map(([a, b]) => {
  const s = sample("rpg-audio", a);
  mix(s, sample("rpg-audio", b), 0.15, 0.8);
  return trim(filter(s, [["hp", 90], ["lp", 7000, 0.7]]));
}));

// Gather: a leather strap and the clink of a tool taken up.
cue("command_gather", "commands", "wav", () => [["handleSmallLeather.ogg", "metalClick.ogg"],
  ["handleSmallLeather2.ogg", "metalLatch.ogg"]].map(([a, b]) => {
  const s = sample("rpg-audio", a);
  mix(s, sample("rpg-audio", b), 0.05, 0.45);
  return trim(filter(s, [["hp", 150], ["lp", 8000, 0.7]]));
}));

// Build: two quick hammer taps.
cue("command_build", "commands", "wav", () => [[1, 3], [2, 0]].map(([a, b]) => {
  const s = sample("impact-sounds", `impactPlank_medium_00${a}.ogg`);
  mix(s, sample("impact-sounds", `impactPlank_medium_00${b}.ogg`), 0.16, 0.85);
  return trim(filter(s, [["hp", 90]]));
}));

// A building placed: a solid timber thunk and a breath of dust.
cue("placement_ok", "commands", "wav", () => [0, 2].map((i) => {
  const s = sample("impact-sounds", `impactWood_heavy_00${i}.ogg`);
  mix(s, sample("impact-sounds", `impactPlank_medium_00${i + 1}.ogg`), 0.005, 0.5);
  const dust = noise(0.5, 230 + i, "pink");
  filter(dust, [["lp", 1500], ["hp", 200]]);
  shape(dust, ad(0.02, 0.35));
  mix(s, dust, 0.01, 0.08);
  return trim(filter(s, "hp", 45));
}));

// Can't build there: a dull, low knock.
cue("placement_bad", "commands", "wav", () => {
  const s = woodTone(hz("D3"), { t60: 0.35, seed: 240, muted: 0.85 });
  const thud = noise(0.15, 241, "brown");
  filter(thud, "lp", 400);
  shape(thud, ad(0.003, 0.08));
  mix(s, thud, 0, 0.5);
  return [trim(filter(s, "lp", 2500))];
});

// ---- Town ----

// Construction begins: the first timber laid and two hammer blows.
cue("build_start", "town", "wav", () => [[0, 1, 3], [3, 2, 4]].map(([w, a, b]) => {
  const s = sample("impact-sounds", `impactWood_heavy_00${w}.ogg`);
  mix(s, sample("impact-sounds", `impactPlank_medium_00${a}.ogg`), 0.22, 0.8);
  mix(s, sample("impact-sounds", `impactPlank_medium_00${b}.ogg`), 0.42, 0.75);
  return trim(filter(s, "hp", 50));
}));

// A hammer blow on a building site (many per second across a busy town): a plank struck,
// sometimes with the ring of the nail.
cue("construct_hit", "town", "wav", () => [0, 1, 2, 3, 4].map((i) => {
  const s = sample("impact-sounds", `impactPlank_medium_00${i}.ogg`);
  if (i % 2 === 0) mix(s, resample(sample("impact-sounds", `impactMetal_light_00${i}.ogg`), 1.2), 0.002, 0.12);
  return trim(filter(s, [["hp", 80], ["lp", 9000, 0.7]]), -46, -55);
}), WORLD);

// A building completed: the last blow, then a lute's rising chord.
cue("build_complete", "town", "ogg", () => {
  const s = stereo(2.2);
  mix(s, sample("impact-sounds", "impactWood_heavy_001.ogg"), 0, 0.7);
  ["G3", "B3", "D4", "G4"].forEach((n, i) =>
    mix(s, pluck(hz(n), { t60: 1.8, seed: 250 + i, bright: 0.5 }), 0.16 + i * 0.1, 0.55, -0.3 + i * 0.2));
  return [trim(verb(s, "square", -14))];
});

// Someone trained at the Keep is ready: a lute's bright "ready", a fifth.
cue("train_complete", "town", "ogg", () => {
  const s = stereo(1.6);
  mix(s, pluck(hz("D4"), { t60: 1.3, seed: 260, bright: 0.55 }), 0, 0.6, -0.15);
  mix(s, pluck(hz("A4"), { t60: 1.5, seed: 261, bright: 0.6 }), 0.12, 0.7, 0.15);
  mix(s, chime(hz("A5"), { t60: 0.8, seed: 262, soft: 0.8 }), 0.13, 0.1);
  return [trim(verb(s, "square", -15))];
});

// The Summoning Font answers: a rising swell of light, sparks and a breath of wind.
cue("summon", "town", "ogg", () => {
  const s = pad(1.4, ["D4", "A4", "D5", "F#5", "A5"], { attack: 0.9, release: 1.4, amp: 0.55, seed: 270, glide: 2, glideT: 0.9 });
  mix(s, sparkles(2.6, { count: 26, from: 0.15, to: 1.9, amp: 0.22, seed: 271, rise: 1.5 }), 0, 1);
  mix(s, toStereo(whoosh(1.4, 300, 3000, { q: 0.9, seed: 272 })), 0, 0.35);
  mix(s, chime(hz("D6"), { t60: 1.6, seed: 273, soft: 0.5 }), 1.2, 0.35, 0.2);
  return [trim(verb(fade(s, 0.01, 0.4), "cathedral", -9))];
});

// Population cap reached: a wooden "uh-oh", two notes down.
cue("need_houses", "town", "ogg", () => {
  const s = mono(0.9);
  mix(s, woodTone(hz("E4"), { t60: 0.6, seed: 280, muted: 0.25 }), 0, 0.9);
  mix(s, woodTone(hz("C4"), { t60: 0.7, seed: 281, muted: 0.25 }), 0.16, 1.0);
  return [trim(toMono(verb(s, "close", -16)))];
});

// An axe in timber: Kenney's chop over a heavy wooden thunk, pitched a little each time.
cue("chop", "town", "wav", () => [0, 1, 2, 3].map((i) => {
  const s = sample("rpg-audio", "chop.ogg");
  mix(s, sample("impact-sounds", `impactWood_heavy_00${i}.ogg`), 0.004, 0.55);
  return trim(filter(resample(s, [1.0, 0.94, 1.05, 0.9][i]), [["hp", 70], ["lp", 9500, 0.7]]));
}), WORLD);

// Picking berries or cutting grain: a short rustle of leaves and stalks.
cue("gather_food", "town", "wav", () => [0, 1, 2, 3].map((i) => {
  const s = slice(sample("impact-sounds", `footstep_grass_00${i}.ogg`), 0, 0.35);
  mix(s, slice(sample("rpg-audio", `cloth${(i % 3) + 1}.ogg`), 0, 0.25), 0.03, 0.35);
  return trim(fade(filter(resample(s, 1.08), [["hp", 250], ["lp", 8500, 0.7]]), 0.003, 0.08));
}), WORLD);

// A load set down at a storehouse: a sack and a soft thud.
cue("drop_off", "town", "wav", () => [0, 1, 2].map((i) => {
  const s = sample("rpg-audio", "dropLeather.ogg");
  mix(s, sample("impact-sounds", `impactSoft_medium_00${i}.ogg`), 0.0, 0.7);
  return trim(filter(resample(s, [1.0, 0.93, 1.06][i]), [["hp", 60], ["lp", 8000, 0.7]]));
}), WORLD);

// A Font Wisp takes a scroll: a soft airy swirl, a gliding glow and a few sparks (mono: it is
// placed in the world).
cue("wisp", "town", "ogg", () => [0, 1].map((i) => {
  const s = whoosh(0.9, 700 + i * 150, 2400, { q: 2.2, seed: 290 + i, env: (t) => Math.sin(Math.PI * Math.min(1, t / 0.9)) ** 2 });
  scale(s, 0.35);
  mix(s, toMono(sparkles(1.1, { count: 9, from: 0.08, to: 0.7, amp: 0.35, seed: 295 + i, t60: [0.2, 0.5] })), 0, 1);
  const glide = mono(1.0);
  partial(glide[0], hz(i ? "A5" : "D6"), 0.3, 0.8, { attack: 0.18, glide: 5, glideT: 0.7 });
  partial(glide[0], hz(i ? "A5" : "D6") * 1.5, 0.1, 0.6, { attack: 0.2, glide: 5, glideT: 0.7 });
  mix(s, glide, 0.04, 1);
  return trim(s);
}), WORLD);

// A scroll delivered at an agent's home: parchment set down and a small glint.
cue("scroll_delivered", "town", "ogg", () => {
  const s = sample("rpg-audio", "bookPlace2.ogg");
  mix(s, chime(hz("A6"), { t60: 0.7, seed: 300, soft: 0.5 }), 0.05, 0.18);
  return [trim(toMono(verb(filter(s, "hp", 120), "close", -16)))];
});

// ---- Agents ----

// A task sent: the scroll rolled, and away.
cue("task_sent", "agents", "ogg", () => {
  const s = sample("rpg-audio", "bookFlip3.ogg");
  mix(s, whoosh(0.5, 500, 2200, { q: 1.1, seed: 310 }), 0.08, 0.25);
  mix(s, pluck(hz("A4"), { t60: 0.8, seed: 311, bright: 0.5 }), 0.1, 0.25);
  return [trim(filter(s, "hp", 120))];
});

// An agent starts work: three soft notes rising, and the Font's hum.
cue("task_started", "agents", "ogg", () => {
  const s = stereo(1.5);
  ["D5", "F#5", "A5"].forEach((n, i) => mix(s, chime(hz(n), { t60: 0.9, seed: 320 + i, soft: 0.8 }), i * 0.08, 0.5, -0.3 + i * 0.3));
  mix(s, pad(0.4, ["D4", "A4"], { attack: 0.25, release: 0.6, amp: 0.16, seed: 324 }), 0, 1);
  return [trim(verb(s, "square", -15))];
});

// Work finished, waiting for review: three small bells, a bright rising triad.
cue("task_done", "agents", "ogg", () => {
  const s = stereo(2.0);
  ["A5", "C#6", "E6"].forEach((n, i) => mix(s, chime(hz(n), { t60: 1.3, seed: 330 + i, soft: 0.3 }), i * 0.13, 0.7, -0.35 + i * 0.35));
  mix(s, chime(hz("A6"), { t60: 1.0, seed: 334, soft: 0.5 }), 0.4, 0.25, 0.2);
  return [trim(verb(s, "square", -13))];
});

// Accepted work paid out: coins spill, and a glittering run up the chord.
cue("reward", "agents", "ogg", () => {
  const s = stereo(2.2);
  mix(s, sample("rpg-audio", "handleCoins.ogg"), 0, 0.9, -0.1);
  mix(s, sample("rpg-audio", "handleCoins2.ogg"), 0.28, 0.6, 0.25);
  ["D6", "F#6", "A6", "D7"].forEach((n, i) => mix(s, chime(hz(n), { t60: 1.1, seed: 340 + i, soft: 0.4 }), 0.12 + i * 0.07, 0.4, -0.4 + i * 0.27));
  mix(s, sparkles(1.8, { count: 10, from: 0.35, to: 1.1, amp: 0.15, seed: 345 }), 0, 1);
  return [trim(verb(s, "square", -14))];
});

// Sent back: the book shut, and a lute's falling fourth.
cue("sent_back", "agents", "ogg", () => {
  const s = sample("rpg-audio", "bookClose.ogg");
  mix(s, pluck(hz("A4"), { t60: 0.9, seed: 350, bright: 0.45 }), 0.08, 0.5);
  mix(s, pluck(hz("E4"), { t60: 1.1, seed: 351, bright: 0.4 }), 0.24, 0.55);
  return [trim(toMono(verb(filter(s, "hp", 90), "close", -16)))];
});

// A task failed: a cracked, muffled bell and a falling minor third.
cue("task_failed", "agents", "ogg", () => {
  const s = stereo(1.8);
  mix(s, filter(bellStroke(hz("A3"), { table: TOWER, t60: 1.2, seed: 360, strike: 0.4, strikeHz: 1500, bright: 0.6 }), "lp", 1800), 0, 0.8);
  mix(s, woodTone(hz("C4"), { t60: 0.6, seed: 361, muted: 0.3 }), 0.18, 0.45, -0.2);
  mix(s, woodTone(hz("A3"), { t60: 0.8, seed: 362, muted: 0.3 }), 0.36, 0.5, 0.2);
  return [trim(verb(s, "square", -14))];
});

// An approval granted: a rising fourth on small bells over a soft stamp.
cue("approval_granted", "agents", "ogg", () => {
  const s = sample("impact-sounds", "impactSoft_medium_001.ogg");
  scale(s, 0.5);
  mix(s, chime(hz("A5"), { t60: 0.8, seed: 370, soft: 0.5 }), 0.02, 0.7);
  mix(s, chime(hz("D6"), { t60: 1.0, seed: 371, soft: 0.5 }), 0.1, 0.8);
  return [trim(toMono(verb(s, "close", -15)))];
});

// An approval denied: a muted wooden fall over the same stamp.
cue("approval_denied", "agents", "ogg", () => {
  const s = sample("impact-sounds", "impactSoft_medium_002.ogg");
  scale(s, 0.5);
  mix(s, woodTone(hz("D4"), { t60: 0.5, seed: 380, muted: 0.45 }), 0.02, 0.8);
  mix(s, woodTone(hz("A3"), { t60: 0.6, seed: 381, muted: 0.45 }), 0.13, 0.85);
  return [trim(toMono(verb(s, "close", -16)))];
});

// An agent's guild rank rises: a lute and bells climb the chord to a held, shining note.
cue("rank_up", "agents", "ogg", () => {
  const s = stereo(3.0);
  ["D4", "F#4", "A4", "D5"].forEach((n, i) => mix(s, pluck(hz(n), { t60: 1.8, seed: 390 + i, bright: 0.6 }), i * 0.07, 0.45, -0.3 + i * 0.2));
  ["F#5", "A5", "D6", "F#6"].forEach((n, i) => mix(s, chime(hz(n), { t60: 1.3, seed: 395 + i, soft: 0.4 }), 0.28 + i * 0.07, 0.4, 0.3 - i * 0.2));
  mix(s, chime(hz("A6"), { t60: 2.0, seed: 399, soft: 0.3 }), 0.6, 0.35);
  mix(s, pad(0.9, ["D4", "A4", "D5", "F#5"], { attack: 0.3, release: 1.2, amp: 0.25, seed: 400 }), 0.3, 1);
  mix(s, sparkles(2.4, { count: 14, from: 0.5, to: 1.6, amp: 0.14, seed: 401 }), 0, 1);
  return [trim(verb(s, "square", -12))];
});

// A party formed: three bells, one for each member, with the clink of drawn steel.
cue("party_formed", "agents", "ogg", () => {
  const s = stereo(2.4);
  ["G4", "B4", "D5"].forEach((n, i) => {
    mix(s, bellStroke(hz(n), { table: HAND, t60: 1.6, seed: 410 + i, strike: 0.1, strikeHz: 4000, bright: 0.8 }), i * 0.2, 0.6, -0.5 + i * 0.5);
    mix(s, slice(sample("rpg-audio", `drawKnife${i + 1}.ogg`), 0, 0.25), i * 0.2, 0.25, -0.5 + i * 0.5);
  });
  mix(s, pad(0.6, ["G3", "D4", "B4"], { attack: 0.3, release: 1.0, amp: 0.09, seed: 415 }), 0.5, 1);
  return [trim(verb(s, "square", -13))];
});

// ---- Alerts ----

// The lanterns dim (Mana at 25%): flames drawn down in a long breath, two low notes sinking.
cue("lanterns_dim", "alerts", "ogg", () => {
  const s = noise(1.6, 420, "pink");
  sweep(s, "lp", (t) => 2600 * Math.pow(160 / 2600, Math.min(1, t / 1.3)), 0.8);
  shape(s, (t) => Math.min(1, t / 0.08) * Math.exp(-2.2 * t));
  const st = toStereo(scale(s, 0.6));
  const tone = mono(1.8);
  partial(tone[0], hz("A3"), 0.25, 1.6, { attack: 0.1, glide: -1, glideT: 1.2 });
  partial(tone[0], hz("E4"), 0.18, 1.4, { attack: 0.1, glide: -1, glideT: 1.2 });
  mix(st, tone, 0.05, 1);
  return [trim(verb(st, "square", -12))];
});

// The Font goes dark (the pool is empty, or a provider's limit is reached): the Font's chord
// sinks and closes, ending in a low, soft thud.
cue("font_dark", "alerts", "ogg", () => {
  const s = pad(1.4, ["D4", "A4", "D5"], { attack: 0.08, release: 0.9, amp: 0.5, seed: 430, glide: -5, glideT: 1.6, detune: 7 });
  sweep(s, "lp", (t) => 5000 * Math.pow(180 / 5000, Math.min(1, t / 1.8)), 0.7);
  const thud = mono(1.2);
  partial(thud[0], 55, 0.9, 0.9, { attack: 0.005 });
  const dust = noise(0.4, 431, "brown");
  filter(dust, "lp", 300);
  shape(dust, ad(0.005, 0.25));
  mix(thud, dust, 0, 0.6);
  mix(s, thud, 1.55, 0.8);
  return [trim(verb(s, "cathedral", -10))];
});

// A rift (an agent's process crashed, or its login expired): a blue crackle and a torn,
// wavering chord.
cue("rift", "alerts", "ogg", () => {
  const r = rng(440);
  const s = stereo(2.0);
  for (let k = 0; k < 70; k++) {
    const at = 0.05 + Math.pow(r(), 0.8) * 1.2;
    const c = noise(0.03, 441 + k);
    filter(c, "bp", 1500 + r() * 4000, 6);
    shape(c, ad(0.0003, 0.012 + r() * 0.02));
    mix(s, c, at, 0.6 + r() * 0.8, r() * 1.6 - 0.8);
  }
  const drone = mono(1.6);
  partial(drone[0], 233, 0.35, 1.3, { attack: 0.03, glide: -3, glideT: 1.3 });
  partial(drone[0], 247, 0.3, 1.2, { attack: 0.03, glide: -3, glideT: 1.3 });
  shape(drone, (t) => 0.65 + 0.35 * Math.sin(TAU * 11 * t));
  mix(s, drone, 0, 1);
  const hit = noise(0.2, 449, "brown");
  filter(hit, "lp", 500);
  shape(hit, ad(0.002, 0.12));
  mix(s, hit, 0, 0.7);
  return [trim(verb(s, "square", -12))];
});

// Smoke (a task failed): a soft puff and a few cinders.
cue("smoke", "alerts", "ogg", () => {
  const s = noise(1.2, 450, "pink");
  filter(s, [["lp", 900, 0.6], ["hp", 90]]);
  shape(s, (t) => Math.min(1, t / 0.06) * Math.exp(-4 * t));
  const r = rng(451);
  for (let k = 0; k < 9; k++) {
    const c = noise(0.01, 452 + k);
    filter(c, "bp", 2500 + r() * 2500, 4);
    shape(c, ad(0.0003, 0.006));
    mix(s, c, 0.1 + r() * 0.6, 0.25);
  }
  return [trim(s)];
});

// ---- Ages and trade ----

// Research begins: a book opened and a harp run up the scale, into a faint glow.
cue("research_start", "ages", "ogg", () => {
  const s = stereo(2.6);
  mix(s, sample("rpg-audio", "bookOpen.ogg"), 0, 0.8);
  ["D4", "E4", "F#4", "A4", "B4", "D5", "E5", "F#5", "A5"].forEach((n, i) =>
    mix(s, pluck(hz(n), { t60: 1.4, seed: 460 + i, bright: 0.7, pick: 0.3, body: "harp" }), 0.12 + i * 0.05, 0.35, -0.6 + i * 0.15));
  mix(s, pad(0.8, ["D5", "A5"], { attack: 0.4, release: 1.0, amp: 0.14, seed: 470 }), 0.4, 1);
  mix(s, sparkles(2.2, { count: 8, from: 0.6, to: 1.4, amp: 0.12, seed: 471 }), 0, 1);
  return [trim(verb(s, "square", -13))];
});

// A wall section rises from the ground: stone grinding over a deep rumble (mono, placed in the world).
cue("wall_rise", "ages", "ogg", () => [0, 1, 2].map((v) => {
  const r = rng(480 + v);
  const s = noise(2.8, 481 + v, "brown");
  filter(s, [["lp", 220], ["hp", 30]]);
  shape(s, (t) => Math.min(1, t / 0.4) * (t < 2.0 ? 1 : Math.exp(-5 * (t - 2.0))));
  scale(s, 1.4);
  for (let k = 0; k < 9; k++) {
    const g = resample(sample("impact-sounds", `impactMining_00${Math.floor(r() * 5)}.ogg`), 0.62 + r() * 0.2);
    mix(s, filter(g, "lp", 2500), 0.15 + r() * 1.8, 0.18 + r() * 0.2);
  }
  mix(s, filter(sample("impact-sounds", `impactWood_heavy_00${v}.ogg`), "lp", 600), 2.05, 0.8);
  return trim(s);
}), WORLD);

// A trade at the Quartermaster: a purse of coins.
cue("trade", "ages", "wav", () => [["handleCoins2.ogg", 1.0], ["handleCoins.ogg", 1.06]].map(([f, p]) =>
  trim(filter(resample(slice(sample("rpg-audio", f), 0, 0.6), p), [["hp", 250], ["lp", 11000, 0.7]]))));

// ------------------------------------------------------------------------------------------------
// Output

const groupDir = (g) => join(OUT, g);

function encode(tmp, out, gainDb, fmt) {
  const af = `volume=${gainDb.toFixed(2)}dB`;
  mkdirSync(dirname(out), { recursive: true });
  if (fmt === "wav") {
    ff(["-v", "error", "-y", "-i", tmp, "-af", `${af},aresample=osf=s16:dither_method=triangular`, "-c:a", "pcm_s16le",
      "-ar", String(SR), "-map_metadata", "-1", "-fflags", "+bitexact", "-flags:a", "+bitexact", out], out);
  } else {
    ff(["-v", "error", "-y", "-i", tmp, "-af", af, "-c:a", "libvorbis", "-q:a", fmt === "ogg-music" ? "2" : "5",
      "-ar", String(SR), "-map_metadata", "-1", "-fflags", "+bitexact", "-flags:a", "+bitexact", out], out);
  }
}

function removeOld(dir, name) {
  if (!existsSync(dir)) return;
  for (const f of readdirSync(dir)) {
    const m = f.match(/^(.*?)(?:_(\d+))?\.(wav|ogg)$/);
    if (m && m[1] === name) rmSync(join(dir, f));
  }
}

const report = [];

/** How loud a sound can get (peak momentary, LUFS) before its true peak reaches TRUE_PEAK. */
const reach = (m) => Math.min(TARGET_M, m.M + (TRUE_PEAK - m.TP));

/** Renders a cue's variants at one shared loudness: TARGET_M when every variant can reach it,
 *  else the median of what they can reach, with a limiter lifting the quiet, spiky ones (at
 *  most MAX_LIMIT dB). */
const MAX_LIMIT = 6;
function renderCue(name) {
  const c = CUES[name];
  const sounds = c.build().map((snd) => (c.world ? preroll(snd, WORLD_PREROLL) : snd));
  removeOld(groupDir(c.group), name);
  const bases = sounds.map((_, i) => (sounds.length === 1 ? name : `${name}_${i + 1}`));
  const tmps = bases.map((b) => join(TMP, `${b}.wav`));
  const ms = sounds.map((snd, i) => {
    writeWavFloat(tmps[i], snd);
    return measure(tmps[i]);
  });
  const reached = ms.map(reach).sort((a, b) => a - b);
  const target = Math.min(TARGET_M, reached[Math.floor((reached.length - 1) / 2)]);
  sounds.forEach((snd, i) => {
    let m = ms[i];
    const short = target - reach(m);
    if (short > 0.3) {
      limit(snd, Math.min(MAX_LIMIT, short + 0.4));
      writeWavFloat(tmps[i], snd);
      m = measure(tmps[i]);
    }
    let gain = target - m.M;
    if (m.TP + gain > TRUE_PEAK) gain = TRUE_PEAK - m.TP;
    const out = join(groupDir(c.group), `${bases[i]}.${c.fmt}`);
    encode(tmps[i], out, gain, c.fmt);
    rmSync(tmps[i]);
    const after = measure(out);
    report.push({ file: relative(OUT, out).replaceAll("\\", "/"), sec: len(snd) / SR, ch: snd.length, ...after, bytes: statSync(out).size });
  });
}

function printReport() {
  if (report.length === 0) return;
  console.log("\nfile                                    sec  ch   M(max)      I     TP      KB");
  for (const r of report) {
    const f = (x) => (Number.isFinite(x) ? x.toFixed(1) : "-inf").padStart(6);
    console.log(`${r.file.padEnd(38)} ${r.sec.toFixed(2).padStart(5)}  ${r.ch}  ${f(r.M)} ${f(r.I)} ${f(r.TP)} ${(r.bytes / 1024).toFixed(0).padStart(7)}`);
  }
}

function dirBytes(d) {
  if (!existsSync(d)) return 0;
  let n = 0;
  for (const f of readdirSync(d)) {
    const p = join(d, f);
    const st = statSync(p);
    n += st.isDirectory() ? dirBytes(p) : f.endsWith(".import") ? 0 : st.size;
  }
  return n;
}

// ------------------------------------------------------------------------------------------------
// Music and ambience

/** Encodes a long sound at `lufs` integrated loudness; a limiter catches peaks above -1.5 dBFS. */
function writeLong(id, snd, out, lufs, quality) {
  const tmp = join(TMP, `${id}.wav`);
  writeWavFloat(tmp, snd);
  const m = measure(tmp);
  const gain = lufs - m.I;
  let af = `volume=${gain.toFixed(2)}dB`;
  if (m.TP + gain > TRUE_PEAK) af += `,alimiter=limit=${db(-1.5).toFixed(4)}:attack=5:release=80:level=0`;
  mkdirSync(dirname(out), { recursive: true });
  ff(["-v", "error", "-y", "-i", tmp, "-af", af, "-c:a", "libvorbis", "-q:a", quality, "-ar", String(SR),
    "-map_metadata", "-1", "-fflags", "+bitexact", "-flags:a", "+bitexact", out], out);
  rmSync(tmp);
  const after = measure(out);
  report.push({ file: relative(OUT, out).replaceAll("\\", "/"), sec: len(snd) / SR, ch: snd.length, ...after, bytes: statSync(out).size });
}

const fileOf = (url, sub) => join(DOWNLOADS, sub, url.split("/").pop());

function renderMusic() {
  const dir = join(OUT, "music");
  if (existsSync(dir)) for (const f of readdirSync(dir)) if (f.endsWith(".ogg")) rmSync(join(dir, f));
  for (const m of MUSIC) {
    process.stdout.write(`${m.id} `);
    const s = trim(decode(fileOf(m.url, "music"), 2), -50, -58, 0.01, 0.6);
    writeLong(m.id, s, join(dir, `${m.id}.ogg`), MUSIC_LUFS, "2");
  }
}

/** A seamless loop of `dur` seconds cut from `src` at `from`: the `xf` seconds after the cut are
 *  cross-faded (equal power) into the start, so the end runs straight into the beginning. */
function loopBed(src, from, dur, xf, chain) {
  const seg = filter(slice(decode(src, 2), from, from + dur + xf), chain);
  const D = samples(dur), X = samples(xf);
  const out = seg.map((ch) => ch.slice(0, D));
  for (let c = 0; c < 2; c++) {
    for (let i = 0; i < X; i++) {
      const a = (i / X) * Math.PI / 2;
      out[c][i] = seg[c][i] * Math.sin(a) + seg[c][D + i] * Math.cos(a);
    }
  }
  return out;
}

/** Scales a sound to `lufs` integrated (measured with ffmpeg). */
function atLufs(snd, lufs, id) {
  const tmp = join(TMP, `${id}-level.wav`);
  writeWavFloat(tmp, snd);
  const m = measure(tmp);
  rmSync(tmp);
  return scale(snd, db(lufs - m.I));
}

function renderAmbience() {
  const dir = join(OUT, "ambience");
  if (existsSync(dir)) for (const f of readdirSync(dir)) if (f.endsWith(".ogg")) rmSync(join(dir, f));
  // Day: birdsong over a soft meadow wind; the wind's low rumble is filtered out.
  process.stdout.write("day ");
  const day = loopBed(fileOf(FIELD.meadow.url, "ambience"), 20, 84, 5, [["hp", 150], ["hp", 150], ["lowshelf", 400, 0.7, -3]]);
  writeLong("day", day, join(dir, "day.ogg"), AMBIENCE_LUFS, "2");
  // Night: a summer insect chorus, with one clear cricket a little in front.
  process.stdout.write("night ");
  const chorus = atLufs(loopBed(fileOf(FIELD.porch.url, "ambience"), 30, 84, 5, [["hp", 260], ["hp", 260]]), -24, "porch");
  const cricket = atLufs(loopBed(fileOf(FIELD.crickets.url, "ambience"), 1, 84, 5, [["hp", 420], ["hp", 420], ["highshelf", 6000, 0.7, -3]]), -24, "cricket");
  writeLong("night", mix(chorus, cricket, 0, db(-6)), join(dir, "night.ogg"), AMBIENCE_LUFS, "2");
}

// ------------------------------------------------------------------------------------------------
// The index the Audio autoload loads

/** Writes client/audio/cue_files.gd: each cue's files with their measured peak momentary
 *  loudness (the Audio autoload turns a cue's target loudness into a gain per file), the music
 *  playlist and the ambience beds with their integrated loudness. Measures every file, so a
 *  partial run (--only) still leaves a complete, correct index. */
function writeIndex() {
  const files = {};
  for (const g of ["ui", "commands", "town", "agents", "alerts", "ages"]) {
    const dir = groupDir(g);
    if (!existsSync(dir)) continue;
    const names = readdirSync(dir).filter((f) => /\.(wav|ogg)$/.test(f))
      .sort((a, b) => a.localeCompare(b, "en", { numeric: true }));
    for (const f of names) {
      const m = f.match(/^(.*?)(?:_(\d+))?\.(wav|ogg)$/);
      const l = measure(join(dir, f));
      (files[m[1]] ??= []).push(`[${JSON.stringify(`res://audio/${g}/${f}`)}, ${l.M.toFixed(1)}, ${l.TP.toFixed(1)}]`);
    }
  }
  const q = (s) => JSON.stringify(s);
  const integrated = (p) => (existsSync(p) ? measure(p).I.toFixed(1) : "0.0");
  const music = MUSIC.filter((m) => existsSync(join(OUT, "music", `${m.id}.ogg`)));
  const lines = [
    "# Generated by scripts/fetch-audio.mjs. Do not edit by hand: rerun the script.",
    "# FILES: cue -> [[path, peak momentary loudness in LUFS, true peak in dBTP], ...]; one file is",
    "# picked at random each time. MUSIC: the playlist. AMBIENCE: the day and night beds (seamless",
    "# loops). The music and beds carry their integrated loudness in LUFS.",
    "extends RefCounted",
    "",
    "const FILES := {",
    ...Object.keys(files).sort().map((k) => `\t${q(k)}: [${files[k].join(", ")}],`),
    "}",
    "",
    "const MUSIC := [",
    ...music.map((m) => `\t{"path": ${q(`res://audio/music/${m.id}.ogg`)}, "title": ${q(m.title)}, "author": ${q(m.author)}, ` +
      `"lufs": ${integrated(join(OUT, "music", `${m.id}.ogg`))}},`),
    "]",
    "",
    "const AMBIENCE := {",
    ...["day", "night"].filter((b) => existsSync(join(OUT, "ambience", `${b}.ogg`)))
      .map((b) => `\t${q(b)}: {"path": ${q(`res://audio/ambience/${b}.ogg`)}, "lufs": ${integrated(join(OUT, "ambience", `${b}.ogg`))}},`),
    "}",
    "",
  ];
  writeFileSync(join(OUT, "cue_files.gd"), lines.join("\n"));
}

// ------------------------------------------------------------------------------------------------
// Main

await prepareSources();
mkdirSync(TMP, { recursive: true });
for (const name of Object.keys(CUES)) {
  if (ONLY && !ONLY.has(name)) continue;
  process.stdout.write(`${name} `);
  renderCue(name);
}
if (!NO_MUSIC && (!ONLY || ONLY.has("music"))) renderMusic();
if (!NO_MUSIC && (!ONLY || ONLY.has("ambience"))) renderAmbience();
console.log("");
writeIndex();
rmSync(TMP, { recursive: true, force: true });
printReport();
console.log(`\nclient/audio: ${(dirBytes(OUT) / 1048576).toFixed(2)} MB`);
