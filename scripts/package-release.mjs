#!/usr/bin/env node
// Builds Aurelhaven's release packages. Each is one zip with everything a player needs:
//   - the game, exported by Godot;
//   - the Town Hall, compiled, with its packages installed for that platform;
//   - its own Node.js, so players don't have to install it;
//   - the game constants (protocol/), a README.txt, the credits and licences.
//
// Usage: node scripts/package-release.mjs [--targets host|all|<list>] [--version <x.y.z>]
//                                         [--skip-export] [--unpacked]
//   --targets      host (the default: this computer), all, or a comma list of windows, linux,
//                  macos-arm64 and macos-x64
//   --version      defaults to config/version in client/project.godot
//   --skip-export  reuse the games already exported to client/export/
//   --unpacked     also leave each package unzipped in dist/, ready to play
//
// Run `node scripts/setup.mjs` first (Godot, its export templates, the Town Hall's packages);
// packages for other platforms need their templates too (setup.mjs --all-templates).
// Output: dist/Aurelhaven-<version>-<target>.zip, dist/SHA256SUMS.txt and dist/RELEASE_NOTES.md.
import { spawnSync } from 'node:child_process';
import {
  chmodSync, copyFileSync, cpSync, existsSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync,
} from 'node:fs';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { gunzipSync } from 'node:zlib';
import { checksumFor, download, fetchText, fileHash } from './lib/download.mjs';
import { findGodot, toolsDir } from './lib/godot.mjs';
import { ZipWriter, openZip } from './lib/zip.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const client = join(root, 'client');
const townhall = join(root, 'townhall');
const dist = join(root, 'dist');
const REPO_URL = 'https://github.com/zeenie-ai/agent_game';
/** The Node.js every package carries (an LTS release, checked against nodejs.org's SHA-256 list). */
const NODE_VERSION = '22.20.0';

const TARGETS = {
  windows: {
    label: 'Windows (64-bit)', preset: 'Windows Desktop', exported: 'export/windows/Aurelhaven.exe', game: 'Aurelhaven.exe',
    os: 'win32', cpu: 'x64', node: 'win-x64', nodeArchive: 'zip',
  },
  linux: {
    label: 'Linux (64-bit)', preset: 'Linux', exported: 'export/linux/Aurelhaven.x86_64', game: 'Aurelhaven.x86_64',
    os: 'linux', cpu: 'x64', node: 'linux-x64', nodeArchive: 'tar.gz',
  },
  'macos-arm64': {
    label: 'macOS (Apple Silicon)', preset: 'macOS', exported: 'export/macos/Aurelhaven.zip', game: 'Aurelhaven.app',
    os: 'darwin', cpu: 'arm64', node: 'darwin-arm64', nodeArchive: 'tar.gz',
  },
  'macos-x64': {
    label: 'macOS (Intel)', preset: 'macOS', exported: 'export/macos/Aurelhaven.zip', game: 'Aurelhaven.app',
    os: 'darwin', cpu: 'x64', node: 'darwin-x64', nodeArchive: 'tar.gz',
  },
};

const argv = process.argv.slice(2);
const opt = (name) => {
  const i = argv.indexOf(name);
  return i >= 0 ? argv[i + 1] : undefined;
};

function hostTarget() {
  if (process.platform === 'win32') return 'windows';
  if (process.platform === 'darwin') return process.arch === 'arm64' ? 'macos-arm64' : 'macos-x64';
  if (process.platform === 'linux' && process.arch === 'x64') return 'linux';
  throw new Error(`no release package for ${process.platform} ${process.arch}`);
}

function selectedTargets() {
  const raw = opt('--targets') ?? 'host';
  const ids = raw === 'host' ? [hostTarget()] : raw === 'all' ? Object.keys(TARGETS) : raw.split(',').map((s) => s.trim());
  for (const id of ids) if (!TARGETS[id]) throw new Error(`unknown target "${id}" (use ${Object.keys(TARGETS).join(', ')})`);
  return ids.map((id) => ({ id, ...TARGETS[id] }));
}

function projectVersion() {
  const m = /^config\/version="([^"]+)"/m.exec(readFileSync(join(client, 'project.godot'), 'utf8'));
  if (!m) throw new Error('client/project.godot has no config/version');
  return m[1];
}

function step(text) {
  console.log(`\n== ${text}`);
}

function run(cmd, args, cwd = root) {
  const r = spawnSync(cmd, args, { cwd, stdio: 'inherit' });
  if (r.error) throw r.error;
  if (r.status !== 0) throw new Error(`${cmd} ${args.join(' ')} exited with ${r.status}`);
}

/** npm through the shell, so Windows finds npm.cmd. Arguments here never contain spaces. */
function npm(args, cwd) {
  const r = spawnSync('npm', args, { cwd, stdio: 'inherit', shell: true });
  if (r.status !== 0) throw new Error(`npm ${args.join(' ')} failed in ${cwd}`);
}

/** Files of a tar.gz archive (ustar, with GNU and pax long names). */
function* tarEntries(file) {
  const buf = gunzipSync(readFileSync(file));
  let p = 0;
  let longName = null;
  while (p + 512 <= buf.length) {
    const header = buf.subarray(p, p + 512);
    if (header.every((b) => b === 0)) break;
    const field = (offset, length) => header.toString('utf8', offset, offset + length).replace(/\0[\s\S]*$/, '');
    let name = field(0, 100);
    const prefix = field(345, 155);
    if (prefix) name = `${prefix}/${name}`;
    const mode = parseInt(field(100, 8).trim() || '0', 8);
    const size = parseInt(field(124, 12).trim() || '0', 8);
    const type = String.fromCharCode(header[156] || 48);
    const data = buf.subarray(p + 512, p + 512 + size);
    p += 512 + Math.ceil(size / 512) * 512;
    if (type === 'L') {
      longName = data.toString('utf8').replace(/\0[\s\S]*$/, '');
      continue;
    }
    if (type === 'x') {
      const m = /\d+ path=([^\n]+)\n/.exec(data.toString('utf8'));
      if (m) longName = m[1];
      continue;
    }
    if (type === 'g') continue;
    if (longName) {
      name = longName;
      longName = null;
    }
    yield { name, mode, type, data };
  }
}

let nodeSums = null;
/** Puts the target's Node.js (the program and its licence) in `dir`; returns the program's path in it. */
async function stageNode(t, dir) {
  const base = `node-v${NODE_VERSION}-${t.node}`;
  const archive = `${base}.${t.nodeArchive}`;
  nodeSums ??= await fetchText(`https://nodejs.org/dist/v${NODE_VERSION}/SHASUMS256.txt`);
  const file = await download(
    `https://nodejs.org/dist/v${NODE_VERSION}/${archive}`,
    join(toolsDir(root), 'downloads', archive),
    { algorithm: 'sha256', digest: checksumFor(nodeSums, archive) },
  );
  mkdirSync(dir, { recursive: true });
  if (t.nodeArchive === 'zip') {
    const zip = openZip(file);
    try {
      for (const [from, to] of [[`${base}/node.exe`, 'node.exe'], [`${base}/LICENSE`, 'LICENSE']]) {
        const e = zip.entries.find((x) => x.name === from);
        if (!e) throw new Error(`${archive} has no ${from}`);
        writeFileSync(join(dir, to), e.read());
      }
    } finally {
      zip.close();
    }
    return 'node.exe';
  }
  let found = 0;
  for (const e of tarEntries(file)) {
    if (e.name === `${base}/bin/node`) {
      mkdirSync(join(dir, 'bin'), { recursive: true });
      writeFileSync(join(dir, 'bin', 'node'), e.data);
      found++;
    } else if (e.name === `${base}/LICENSE`) {
      writeFileSync(join(dir, 'LICENSE'), e.data);
      found++;
    }
  }
  if (found !== 2) throw new Error(`${archive} is missing bin/node or LICENSE`);
  return 'bin/node';
}

/** The compiled Town Hall with its runtime files and the target platform's packages. */
function stageTownHall(t, dir, version) {
  mkdirSync(join(dir, 'scripts'), { recursive: true });
  for (const f of ['package.json', 'package-lock.json', 'README.md']) copyFileSync(join(townhall, f), join(dir, f));
  copyFileSync(join(townhall, 'scripts', 'launch.mjs'), join(dir, 'scripts', 'launch.mjs'));
  cpSync(join(townhall, 'dist'), join(dir, 'dist'), { recursive: true });
  // The migrations, the practice scenarios, the MCP glue scripts and pi's gate extension are read
  // from src/ at run time (townhall/src/paths.ts, srcPath).
  cpSync(join(townhall, 'src'), join(dir, 'src'), { recursive: true });
  writeFileSync(join(dir, 'release.json'), `${JSON.stringify({ version, target: t.id, built: new Date().toISOString() }, null, 2)}\n`);
  npm(['ci', '--omit=dev', '--ignore-scripts', '--no-audit', '--no-fund', `--os=${t.os}`, `--cpu=${t.cpu}`], dir);
  // pi loads TypeScript extensions with esbuild, whose program is a per-platform package.
  const esbuild = join(dir, 'node_modules', '@esbuild');
  if (existsSync(join(dir, 'node_modules', 'esbuild'))) {
    const want = `${t.os}-${t.cpu}`;
    if (!existsSync(join(esbuild, want))) throw new Error(`the ${t.id} package is missing @esbuild/${want}`);
    for (const other of readdirSync(esbuild)) if (other !== want) rmSync(join(esbuild, other), { recursive: true, force: true });
  }
}

/** The licences of what a package ships besides its own code and Node.js (which keeps its own). */
function stageLicences(dir) {
  mkdirSync(dir, { recursive: true });
  for (const family of readdirSync(join(client, 'ui', 'fonts'))) {
    const ofl = join(client, 'ui', 'fonts', family, 'OFL.txt');
    if (existsSync(ofl)) copyFileSync(ofl, join(dir, `font-${family}-OFL.txt`));
  }
  writeFileSync(join(dir, 'godot-MIT.txt'), `Godot Engine (https://godotengine.org)

Copyright (c) 2014-present Godot Engine contributors (see https://github.com/godotengine/godot/blob/master/AUTHORS.md).
Copyright (c) 2007-2014 Juan Linietsky, Ariel Manzur.

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and
associated documentation files (the "Software"), to deal in the Software without restriction,
including without limitation the rights to use, copy, modify, merge, publish, distribute,
sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or
substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT
NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT
OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

Godot also contains third-party components under their own licences; they are listed at
https://godotengine.org/license.
`);
}

function readme(t, version) {
  const start = {
    windows: [
      'Double-click Aurelhaven.exe.',
      '',
      'If Windows says "Windows protected your PC", click "More info" and then "Run anyway".',
      'The game is not signed with a paid certificate, so Windows does not recognise it yet.',
    ],
    linux: [
      'Double-click Aurelhaven.x86_64, or run it from a terminal in this folder:',
      '    ./Aurelhaven.x86_64',
      'If it does not start, make it runnable first:',
      '    chmod +x Aurelhaven.x86_64 runtime/node/bin/node',
    ],
    macos: [
      'macOS blocks apps from developers it does not know. Before the first start, open',
      'Terminal (in Applications > Utilities), type the line below with a space at the end,',
      'drag this folder onto the Terminal window, and press Return:',
      '    xattr -dr com.apple.quarantine',
      'Then double-click Aurelhaven.app.',
    ],
  }[t.os === 'win32' ? 'windows' : t.os === 'darwin' ? 'macos' : 'linux'];
  const data = {
    win32: '%APPDATA%\\Aurelhaven\\townhall',
    darwin: '~/Library/Application Support/Aurelhaven/townhall',
    linux: '~/.local/share/Aurelhaven/townhall',
  }[t.os];
  return [
    `AURELHAVEN ${version} for ${t.label}`,
    '',
    'A town-building game in which your agents are real AI coding agents.',
    `Website and help: ${REPO_URL}`,
    '',
    'START THE GAME',
    ...start.map((l) => `  ${l}`),
    '',
    'Keep this folder together: the game needs the townhall, runtime and protocol folders next',
    'to it. Move or copy the whole folder, never the game alone.',
    '',
    'PRACTICE AGENTS AND REAL AGENTS',
    '  The game starts with practice agents: a stand-in that plays through tasks, approvals and',
    '  reviews without running anything or spending money. To use real AI agents, install and',
    '  sign in to Claude Code (https://claude.com/claude-code) or the Codex CLI, then follow',
    `  "Real agents" in ${REPO_URL}#real-agents`,
    '',
    'YOUR TOWNS',
    `  The Town Hall keeps your towns in ${data}.`,
    '  Deleting or updating this folder does not touch them.',
    '',
    'CREDITS AND LICENCES',
    '  See CREDITS.md and the licenses folder. Node.js keeps its licence in runtime/node/LICENSE.',
    '',
  ].join(t.os === 'win32' ? '\r\n' : '\n');
}

/** Zips `stage` under the folder name `top`, with Unix modes from `modes` (else 0644, folders 0755). */
function zipFolder(stage, out, top, modes) {
  const zip = new ZipWriter(out);
  zip.addDir(top);
  const walk = (dir) => {
    for (const name of readdirSync(dir).sort()) {
      const full = join(dir, name);
      const rel = relative(stage, full).split('\\').join('/');
      if (statSync(full).isDirectory()) {
        zip.addDir(`${top}/${rel}`);
        walk(full);
      } else {
        zip.addFile(`${top}/${rel}`, readFileSync(full), modes.get(rel) ?? 0o644);
      }
    }
  };
  walk(stage);
  zip.close();
}

function releaseNotes(version, targets) {
  const rows = targets.map((t) => `| ${t.label} | \`Aurelhaven-${version}-${t.id}.zip\` |`).join('\n');
  return `Aurelhaven ${version} is an early preview: the town, agents as villagers, practice agents, and real
agents on Claude Code, Codex and pi. Ages, walls, menus, onboarding and sound are still being built.

## Download

| Computer | File |
|---|---|
${rows}

Unzip it and start the game; there is nothing else to install for practice agents. Each zip has a
README.txt with the steps for its system, including what to do when Windows or macOS warns about
an unsigned app. For real agents, install and sign in to Claude Code or the Codex CLI first.

The checksums are in \`SHA256SUMS.txt\`. The builds are not code-signed.

See the [README](${REPO_URL}#readme) for how to play, build it yourself and use real agents.
`;
}

async function main() {
  const targets = selectedTargets();
  const version = (opt('--version') ?? projectVersion()).replace(/^v/, '');
  const godot = findGodot(root);
  if (!argv.includes('--skip-export') && !existsSync(godot)) {
    throw new Error(`Godot not found at ${godot}. Run: node scripts/setup.mjs`);
  }
  if (!existsSync(join(townhall, 'node_modules', 'typescript'))) throw new Error('the Town Hall packages are missing. Run: node scripts/setup.mjs');
  console.log(`Aurelhaven ${version}: ${targets.map((t) => t.id).join(', ')}`);

  step('Sync the shared files into the client');
  run(process.execPath, [join(root, 'scripts', 'sync-economy.mjs')]);

  if (!argv.includes('--skip-export')) {
    step('Import the Godot project');
    run(godot, ['--headless', '--path', client, '--import']);
    for (const preset of [...new Set(targets.map((t) => t.preset))]) {
      const t = targets.find((x) => x.preset === preset);
      step(`Export the game: ${preset}`);
      mkdirSync(dirname(join(client, t.exported)), { recursive: true });
      rmSync(join(client, t.exported), { force: true });
      run(godot, ['--headless', '--path', client, '--export-release', preset, t.exported]);
      if (!existsSync(join(client, t.exported))) throw new Error(`Godot did not write ${t.exported}`);
    }
  }

  step('Compile the Town Hall');
  rmSync(join(townhall, 'dist'), { recursive: true, force: true });
  npm(['run', 'build'], townhall);

  mkdirSync(dist, { recursive: true });
  const zips = [];
  for (const t of targets) {
    const name = `Aurelhaven-${version}-${t.id}`;
    step(`Package ${name}`);
    const stage = join(root, 'build', 'release', name);
    rmSync(stage, { recursive: true, force: true });
    mkdirSync(stage, { recursive: true });
    /** Unix modes of the programs in the package, by path inside it. */
    const modes = new Map();

    if (t.os === 'darwin') {
      const app = openZip(join(client, t.exported));
      try {
        for (const e of app.entries) {
          const out = join(stage, e.name);
          if (e.isDir) {
            mkdirSync(out, { recursive: true });
            continue;
          }
          mkdirSync(dirname(out), { recursive: true });
          writeFileSync(out, e.read());
          if (e.mode & 0o111) modes.set(e.name, e.mode);
          if (process.platform !== 'win32') chmodSync(out, e.mode);
        }
      } finally {
        app.close();
      }
    } else {
      copyFileSync(join(client, t.exported), join(stage, t.game));
      modes.set(t.game, 0o755);
    }

    stageTownHall(t, join(stage, 'townhall'), version);
    const nodeProgram = await stageNode(t, join(stage, 'runtime', 'node'));
    modes.set(`runtime/node/${nodeProgram}`, 0o755);
    if (process.platform !== 'win32') {
      for (const [rel, mode] of modes) chmodSync(join(stage, rel), mode);
    }
    mkdirSync(join(stage, 'protocol'), { recursive: true });
    for (const f of ['economy.json', 'pricing.json']) copyFileSync(join(root, 'protocol', f), join(stage, 'protocol', f));
    copyFileSync(join(root, 'CREDITS.md'), join(stage, 'CREDITS.md'));
    stageLicences(join(stage, 'licenses'));
    writeFileSync(join(stage, 'README.txt'), readme(t, version));

    const zipPath = join(dist, `${name}.zip`);
    rmSync(zipPath, { force: true });
    zipFolder(stage, zipPath, name, modes);
    zips.push(zipPath);
    console.log(`   ${relative(root, zipPath)}  ${(statSync(zipPath).size / 1048576).toFixed(1)} MB`);
    if (argv.includes('--unpacked')) {
      rmSync(join(dist, name), { recursive: true, force: true });
      cpSync(stage, join(dist, name), { recursive: true });
      console.log(`   ready to play: ${relative(root, join(dist, name))}`);
    }
  }

  const sums = [];
  for (const z of zips) sums.push(`${await fileHash(z, 'sha256')}  ${relative(dist, z)}`);
  writeFileSync(join(dist, 'SHA256SUMS.txt'), `${sums.join('\n')}\n`);
  writeFileSync(join(dist, 'RELEASE_NOTES.md'), releaseNotes(version, targets));
  step('Done');
  for (const z of zips) console.log(`   ${relative(root, z)}`);
}

main().catch((err) => {
  console.error(`\nPackaging failed: ${err instanceof Error ? err.message : String(err)}`);
  process.exit(1);
});
