#!/usr/bin/env node
// End-to-end check: a real Town Hall (scripted fake agent) and the Godot client, headless,
// playing the whole loop (client/tools/e2e_client.gd):
// summon -> train -> plot -> home and add-ons -> task by courier -> approval -> review ->
// accept (merge) -> reward and progress, then treasury == Town Hall ledger and save/reload ==
// same town; finally the game closes the Town Hall (the shutdown command), which must exit with
// code 0 and remove its runtime file.
//
// Usage: node scripts/e2e-client.mjs [--keep]
//   GODOT   path to the Godot console executable (default: .tools/godot in this checkout or
//           in the main checkout when run from a worktree)
//   --keep  leave the temporary folder (Town Hall data, work repo, logs) for inspection
//
// Everything runs in a temporary folder: its own Town Hall data, a fresh git repo as the
// agent's work folder, and no discovery file, so a Town Hall you have running is untouched.
import { execFileSync, spawn } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { findGodot } from './lib/godot.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const keep = process.argv.includes('--keep');

function git(cwd, ...args) {
  execFileSync('git', ['-c', 'core.longpaths=true', ...args], { cwd, stdio: 'pipe' });
}

function gitOut(cwd, ...args) {
  return execFileSync('git', ['-c', 'core.longpaths=true', ...args], { cwd, encoding: 'utf8' }).trim();
}

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

const tmp = mkdtempSync(join(os.tmpdir(), 'aurel-e2e-'));
const dataDir = join(tmp, 'data');
const workRoot = join(tmp, 'work');
const repo = join(workRoot, 'app');
mkdirSync(join(repo, 'src'), { recursive: true });
writeFileSync(join(repo, 'README.md'), '# App\n\nA test project for the Aurelhaven end-to-end check.\n');
git(repo, 'init', '-q', '-b', 'main');
git(repo, 'add', '-A');
git(repo, '-c', 'user.name=e2e', '-c', 'user.email=e2e@example.invalid', 'commit', '-q', '-m', 'initial');

const godot = findGodot(root);
if (!existsSync(godot)) {
  console.error(`Godot not found at ${godot}. Set GODOT.`);
  process.exit(2);
}

console.log(`== Town Hall (fake agent) in ${tmp}`);
const townhall = spawn(process.execPath, ['--import', 'tsx', 'src/main.ts'], {
  cwd: join(root, 'townhall'),
  env: {
    ...process.env,
    AURELHAVEN_DATA_DIR: dataDir,
    AURELHAVEN_PROVIDER: 'fake',
    AURELHAVEN_WORK_ROOTS: workRoot,
    AURELHAVEN_PORT: '0',
    AURELHAVEN_DISCOVERY_FILE: 'off',
    AURELHAVEN_LOG_LEVEL: 'warn',
  },
  stdio: ['ignore', 'pipe', 'pipe'],
});
let hallLog = '';
townhall.stdout.on('data', (d) => (hallLog += d));
townhall.stderr.on('data', (d) => (hallLog += d));
let hallExit = null;
const hallExited = new Promise((r) => townhall.once('exit', (code) => r((hallExit = code))));

const runtimeFile = join(dataDir, 'runtime.json');
let exitCode = 1;
try {
  for (let i = 0; i < 100 && !existsSync(runtimeFile); i++) await sleep(200);
  if (!existsSync(runtimeFile)) throw new Error(`the Town Hall did not start:\n${hallLog}`);
  const runtime = JSON.parse(readFileSync(runtimeFile, 'utf8'));
  console.log(`   listening on port ${runtime.port}`);

  console.log('== Godot client (headless)');
  const client = spawn(godot, ['--headless', '--path', join(root, 'client'), '-s', 'res://tools/e2e_client.gd', '--', `--work=${repo}`], {
    env: { ...process.env, AURELHAVEN_RUNTIME: runtimeFile, AURELHAVEN_E2E_DIR: tmp },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  let out = '';
  const onData = (d) => {
    out += d;
    for (const line of String(d).split(/\r?\n/)) {
      if (line.startsWith('e2e:') || line.startsWith('E2E') || line.includes('SCRIPT ERROR')) console.log(`   ${line}`);
    }
  };
  client.stdout.on('data', onData);
  client.stderr.on('data', onData);
  const code = await new Promise((r) => client.on('close', r));

  const errors = out.split(/\r?\n/).filter((l) => /SCRIPT ERROR|^ERROR:/.test(l));
  if (errors.length > 0) {
    console.log(`   ${errors.length} Godot error line(s):`);
    for (const e of errors.slice(0, 10)) console.log(`   ${e}`);
  }
  const ok = code === 0 && out.includes('E2E OK') && errors.length === 0;

  // The accepted work was merged into the repo's main branch.
  const merged = existsSync(join(repo, 'src', 'greeting.txt'));
  const log = gitOut(repo, 'log', '--oneline', '-5');
  console.log(`== Work repo after accept: greeting ${merged ? 'merged' : 'MISSING'}\n${log.replace(/^/gm, '   ')}`);
  // The game closed the Town Hall: it ends by itself, with code 0, and removes its runtime file.
  await Promise.race([hallExited, sleep(15000)]);
  const closed = hallExit === 0 && !existsSync(runtimeFile);
  console.log(`== Town Hall after the game closed it: ${hallExit === null ? 'STILL RUNNING' : `exit code ${hallExit}`}, runtime.json ${existsSync(runtimeFile) ? 'STILL THERE' : 'removed'}`);
  exitCode = ok && merged && closed ? 0 : 1;
} catch (err) {
  console.error(String(err instanceof Error ? err.message : err));
} finally {
  if (hallExit === null) {
    townhall.kill('SIGINT');
    await Promise.race([hallExited, sleep(5000)]);
    if (hallExit === null) townhall.kill();
  }
  if (keep || exitCode !== 0) {
    writeFileSync(join(tmp, 'townhall.log'), hallLog);
    console.log(`== Kept ${tmp}`);
  } else {
    try {
      rmSync(tmp, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
    } catch {
      // Windows may still hold a handle for a moment.
    }
  }
}
console.log(exitCode === 0 ? '== End-to-end check passed' : '== End-to-end check FAILED');
process.exit(exitCode);
