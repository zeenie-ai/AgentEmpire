#!/usr/bin/env node
// Smoke test for an unzipped release package: does it work the way a player would use it?
//   1. Its bundled Node.js runs its compiled Town Hall, which answers on its port.
//   2. esbuild's native program runs (pi needs it for its extensions; it must stay executable).
//   3. Its game, started headless, launches its own Town Hall (practice agents) with that
//      Node.js and connects to it.
// Everything runs in a temporary data folder with the shared discovery file off, so nothing a
// player or another Town Hall uses is touched; every process started here is stopped.
//
// Usage: node scripts/smoke-package.mjs <unzipped package folder>
import { spawn } from 'node:child_process';
import { existsSync, mkdtempSync, readFileSync, readdirSync, rmSync } from 'node:fs';
import os from 'node:os';
import { join, resolve } from 'node:path';

const pkg = resolve(process.argv[2] ?? '');
if (!process.argv[2] || !existsSync(join(pkg, 'townhall', 'release.json'))) {
  console.error('Usage: node scripts/smoke-package.mjs <unzipped package folder>');
  process.exit(2);
}

const win = process.platform === 'win32';
const node = join(pkg, 'runtime', 'node', win ? 'node.exe' : join('bin', 'node'));
/** The game: the package's .exe (Windows), .x86_64 (Linux) or the program inside its .app (macOS). */
const game = (() => {
  const top = readdirSync(pkg);
  const exe = top.find((n) => n.endsWith('.exe') || n.endsWith('.x86_64'));
  if (exe) return join(pkg, exe);
  const app = top.find((n) => n.endsWith('.app'));
  const macos = app ? join(pkg, app, 'Contents', 'MacOS') : '';
  const names = macos && existsSync(macos) ? readdirSync(macos) : [];
  return names.length > 0 ? join(macos, names[0]) : null;
})();
const tmp = mkdtempSync(join(os.tmpdir(), 'aurelhaven-smoke-'));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const children = [];
let failed = false;

function check(ok, text) {
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${text}`);
  if (!ok) failed = true;
  return ok;
}

function readJson(file) {
  try {
    return JSON.parse(readFileSync(file, 'utf8'));
  } catch {
    return null;
  }
}

/** Stops a process tree started here (taskkill on Windows; the process group elsewhere). */
function stop(child) {
  if (!child || child.exitCode !== null) return;
  if (win) spawn(join(process.env.SystemRoot ?? 'C:\\Windows', 'System32', 'taskkill.exe'), ['/PID', String(child.pid), '/T', '/F'], { stdio: 'ignore' });
  else {
    try {
      process.kill(-child.pid, 'SIGKILL');
    } catch {
      child.kill('SIGKILL');
    }
  }
}

function stopPid(pid) {
  if (!pid) return;
  try {
    if (win) spawn(join(process.env.SystemRoot ?? 'C:\\Windows', 'System32', 'taskkill.exe'), ['/PID', String(pid), '/T', '/F'], { stdio: 'ignore' });
    else process.kill(pid, 'SIGKILL');
  } catch {
    // already gone
  }
}

async function waitFor(cond, ms) {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    if (cond()) return true;
    await sleep(250);
  }
  return cond();
}

const env = {
  ...process.env,
  AURELHAVEN_DISCOVERY_FILE: 'off',
  AURELHAVEN_PORT: '0',
  AURELHAVEN_LOG_LEVEL: 'info',
};

async function townHallAlone() {
  const data = join(tmp, 'alone');
  const out = [];
  const child = spawn(node, [join(pkg, 'townhall', 'dist', 'main.js')], {
    cwd: join(pkg, 'townhall'),
    env: { ...env, AURELHAVEN_DATA_DIR: data, AURELHAVEN_PROVIDER: 'fake' },
    stdio: ['ignore', 'pipe', 'pipe'],
    detached: !win,
  });
  children.push(child);
  child.stdout.on('data', (d) => out.push(String(d)));
  child.stderr.on('data', (d) => out.push(String(d)));
  const ready = await waitFor(() => out.join('').includes('Town Hall is ready'), 30_000);
  if (!check(ready, 'the bundled Node.js runs the compiled Town Hall')) console.log(out.join('').slice(-2000));
  const info = readJson(join(data, 'runtime.json'));
  if (check(Boolean(info?.port), 'it writes its runtime file')) {
    const res = await fetch(`http://127.0.0.1:${info.port}/`).catch(() => null);
    check(res !== null, `it answers HTTP on port ${info.port}`);
  }
  stop(child);
}

/** pi loads TypeScript extensions with esbuild, whose native program must run on this system. */
async function esbuildRuns() {
  const th = join(pkg, 'townhall');
  const candidates = [
    join(th, 'node_modules', 'esbuild'),
    join(th, 'node_modules', '@earendil-works', 'pi-coding-agent', 'node_modules', 'esbuild'),
  ];
  const esbuild = candidates.find((p) => existsSync(join(p, 'package.json')));
  if (!esbuild) {
    console.log('skip the package has no esbuild');
    return;
  }
  const code = `require(${JSON.stringify(esbuild)}).transformSync('let x: number = 1', { loader: 'ts' })`;
  const child = spawn(node, ['-e', code], { cwd: th, stdio: ['ignore', 'pipe', 'pipe'] });
  const err = [];
  child.stderr.on('data', (d) => err.push(String(d)));
  const status = await new Promise((resolve) => child.on('close', resolve));
  if (!check(status === 0, 'esbuild runs, so pi can load its extensions')) console.log(err.join('').slice(-1500));
}

async function gameStartsItsTownHall() {
  if (!check(game !== null && existsSync(game), 'the package has the game')) return;
  const root = join(tmp, 'game');
  const child = spawn(game, ['--headless'], {
    cwd: pkg,
    env: { ...env, AURELHAVEN_DATA_ROOT: root },
    stdio: 'ignore',
    detached: !win,
  });
  children.push(child);
  const log = join(root, 'practice', 'townhall.log');
  const connected = await waitFor(() => existsSync(log) && readFileSync(log, 'utf8').includes('client connected'), 90_000);
  check(connected, 'the game starts its own practice Town Hall and connects to it');
  if (!connected && existsSync(log)) console.log(readFileSync(log, 'utf8').slice(-2000));
  stop(child);
  stopPid(readJson(join(root, 'practice', 'runtime.json'))?.pid);
}

try {
  await townHallAlone();
  await esbuildRuns();
  await gameStartsItsTownHall();
} finally {
  for (const c of children) stop(c);
  await sleep(1500);
  rmSync(tmp, { recursive: true, force: true, maxRetries: 10, retryDelay: 300 });
}
console.log(failed ? '\nThe package failed its smoke test.' : '\nThe package passed its smoke test.');
process.exit(failed ? 1 : 0);
