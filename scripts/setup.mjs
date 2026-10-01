#!/usr/bin/env node
// Sets up everything needed to build and run AgentEmpire from source, on Windows, macOS or Linux:
//   1. Godot 4.7.2, the game engine, into .tools/godot/ (from Godot's official GitHub release,
//      checked against its published SHA-512 list);
//   2. the export templates this computer's build needs, or every platform's with --all-templates
//      (Godot ships them as one archive of about 1.2 GB; only the needed files are kept);
//   3. the Town Hall's packages (npm ci in townhall/).
// Running it again only does what is missing.
//
// Usage: node scripts/setup.mjs [--all-templates] [--no-templates] [--skip-townhall]
import { spawnSync } from 'node:child_process';
import { chmodSync, existsSync, mkdirSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { checksumFor, download, fetchText } from './lib/download.mjs';
import {
  GODOT_RELEASES, GODOT_TAG, TEMPLATES_ARCHIVE, TEMPLATE_FILES, hostEditor, templatesDir, toolsDir,
} from './lib/godot.mjs';
import { openZip } from './lib/zip.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const args = new Set(process.argv.slice(2));

function step(text) {
  console.log(`\n== ${text}`);
}

function checkNode() {
  const [major, minor] = process.versions.node.split('.').map(Number);
  if (major < 22 || (major === 22 && minor < 12)) {
    console.error(`AgentEmpire needs Node.js 22.12 or newer; this computer has ${process.versions.node}.`);
    console.error('Install the LTS version from https://nodejs.org and run this again.');
    process.exit(1);
  }
}

let godotSums = null;
async function godotChecksum(name) {
  godotSums ??= await fetchText(`${GODOT_RELEASES}/SHA512-SUMS.txt`);
  return { algorithm: 'sha512', digest: checksumFor(godotSums, name) };
}

function hostTarget() {
  if (process.platform === 'win32') return 'windows';
  if (process.platform === 'darwin') return 'macos';
  return 'linux';
}

async function setupEditor() {
  step(`Godot ${GODOT_TAG}`);
  const editor = hostEditor();
  const godotDir = join(toolsDir(root), 'godot');
  const program = join(godotDir, editor.binary);
  if (existsSync(program)) {
    console.log(`   already in ${godotDir}`);
    return;
  }
  const archive = join(toolsDir(root), 'downloads', editor.archive);
  await download(`${GODOT_RELEASES}/${editor.archive}`, archive, await godotChecksum(editor.archive));
  const zip = openZip(archive);
  try {
    for (const e of zip.entries) {
      const out = join(godotDir, e.name);
      if (e.isDir) {
        mkdirSync(out, { recursive: true });
        continue;
      }
      mkdirSync(dirname(out), { recursive: true });
      writeFileSync(out, e.read());
      if (process.platform !== 'win32') chmodSync(out, e.mode);
    }
  } finally {
    zip.close();
  }
  // Self-contained: the editor keeps its settings and templates in .tools/godot/editor_data.
  if (editor.selfContained) writeFileSync(join(godotDir, '._sc_'), '');
  if (process.platform !== 'win32') chmodSync(program, 0o755);
  rmSync(archive, { force: true });
  console.log(`   installed in ${godotDir}`);
}

async function setupTemplates() {
  if (args.has('--no-templates')) return;
  step('Godot export templates');
  const targets = args.has('--all-templates') ? Object.keys(TEMPLATE_FILES) : [hostTarget()];
  const dir = templatesDir(root);
  const wanted = ['version.txt', ...targets.flatMap((t) => TEMPLATE_FILES[t])];
  const missing = wanted.filter((f) => !existsSync(join(dir, f)));
  if (missing.length === 0) {
    console.log(`   already in ${dir}`);
    return;
  }
  console.log('   One download of about 1.2 GB; this is the longest step.');
  const archive = join(toolsDir(root), 'downloads', TEMPLATES_ARCHIVE);
  await download(`${GODOT_RELEASES}/${TEMPLATES_ARCHIVE}`, archive, await godotChecksum(TEMPLATES_ARCHIVE));
  const zip = openZip(archive);
  try {
    mkdirSync(dir, { recursive: true });
    for (const name of missing) {
      const e = zip.entries.find((x) => x.name === `templates/${name}`);
      if (!e) throw new Error(`${TEMPLATES_ARCHIVE} has no templates/${name}`);
      const out = join(dir, name);
      writeFileSync(out, e.read());
      if (process.platform !== 'win32') chmodSync(out, e.mode | 0o644);
    }
  } finally {
    zip.close();
  }
  rmSync(archive, { force: true });
  console.log(`   installed in ${dir}: ${missing.join(', ')}`);
}

function setupTownHall() {
  if (args.has('--skip-townhall')) return;
  step('The Town Hall packages');
  const dir = join(root, 'townhall');
  const marker = join(dir, 'node_modules', '.package-lock.json');
  if (existsSync(marker) && statSync(marker).mtimeMs >= statSync(join(dir, 'package-lock.json')).mtimeMs) {
    console.log('   already installed');
    return;
  }
  // Through the shell so Windows finds npm.cmd; the arguments contain no spaces. Without install
  // scripts: none is needed (better-sqlite3 and pi's esbuild ship their programs for every
  // platform), and npm would otherwise compile better-sqlite3 from source, which needs a C++
  // toolchain most players don't have.
  const r = spawnSync('npm', ['ci', '--ignore-scripts', '--no-audit', '--no-fund'], { cwd: dir, stdio: 'inherit', shell: true });
  if (r.status !== 0) throw new Error('npm ci failed in townhall/');
}

async function main() {
  checkNode();
  await setupEditor();
  await setupTemplates();
  setupTownHall();
  step('Ready');
  console.log('   Build the game for this computer: node scripts/package-release.mjs --unpacked');
}

main().catch((err) => {
  console.error(`\nSetup failed: ${err instanceof Error ? err.message : String(err)}`);
  process.exit(1);
});
