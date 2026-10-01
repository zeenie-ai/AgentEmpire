#!/usr/bin/env node
// Starts the Town Hall in the background and exits at once. The game runs this when it opens
// and finds no Town Hall (client/net/town_hall_launcher.gd). The Town Hall is detached: no
// console window, no handles inherited from the game, and it keeps running after the game
// quits so agents can work while the player is away. Its output goes to
// <data dir>/townhall.log. Prints {"pid": <Town Hall pid>}.
//
// In a release package (scripts/package-release.mjs writes release.json next to this folder's
// package.json) it runs the compiled Town Hall, dist/main.js. In a development checkout it runs
// the TypeScript sources through tsx, even if an older `npm run build` left a dist/ behind.
//
// Environment: the usual AURELHAVEN_* settings (AURELHAVEN_PROVIDER, AURELHAVEN_DATA_DIR, ...)
// are passed through.
import { spawn } from 'node:child_process';
import { existsSync, mkdirSync, openSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const dataDir = resolve(process.env.AURELHAVEN_DATA_DIR ?? join(root, 'data'));
mkdirSync(dataDir, { recursive: true });
const log = openSync(join(dataDir, 'townhall.log'), 'a');
const release = existsSync(join(root, 'release.json'));
const args = release
  ? [join(root, 'dist', 'main.js')]
  : [join(root, 'node_modules', 'tsx', 'dist', 'cli.mjs'), join(root, 'src', 'main.ts')];
const child = spawn(process.execPath, args, {
  cwd: root,
  detached: true,
  stdio: ['ignore', log, log],
  windowsHide: true,
  env: process.env,
});
child.unref();
process.stdout.write(`${JSON.stringify({ pid: child.pid })}\n`);
