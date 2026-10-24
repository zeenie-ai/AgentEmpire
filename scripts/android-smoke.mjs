// Smoke test of an Android build on an emulator. Boots the AVD unless it already runs, installs the
// build and plays it the way a player starts and leaves it: the first start, Home and back, a
// force-stop and a fresh start, then Back, after which the game must still run in front. It checks
// the installed APKs' manifest (aapt2: package, version code, SDK levels, no INTERNET or AD_ID
// permission, Android backup off, landscape) and their 16 KB alignment (zipalign), fails on an
// ERROR, SCRIPT ERROR, FATAL or crash in logcat, and reports the renderer the game used. The
// screenshots and logcat.txt go to out/android/<avd>-<apk|aab>/.
//
// Usage: node scripts/android-smoke.mjs --avd=ae_phone|ae_tablet [--aab [<path>]]
//   Without --aab it installs client/export/android/AgentEmpire-debug.apk (build-android --apk).
//   With --aab, bundletool makes the emulator's APKs from the App Bundle (by default
//   client/export/android/AgentEmpire.aab), signed with the debug key.
// The emulator keeps running afterwards; `adb -s <serial> emu kill` stops it.
import { spawn, spawnSync } from 'node:child_process';
import { closeSync, existsSync, mkdirSync, openSync, readFileSync, rmSync } from 'node:fs';
import { basename, dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { ACTIVITY, AVDS, MIN_SDK, PACKAGE, TARGET_SDK, androidToolchain, bundletoolJar, presetOptions } from './lib/android.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const exportDir = join(root, 'client', 'export', 'android');
const argv = process.argv.slice(2);
const avd = argv.find((a) => a.startsWith('--avd='))?.slice('--avd='.length);
const aabAt = argv.indexOf('--aab');
const aabArg = argv[aabAt + 1];
const aab = aabAt < 0 ? null : resolve(aabArg && !aabArg.startsWith('--') ? aabArg : join(exportDir, 'AgentEmpire.aab'));
if (!avd || !(avd in AVDS)) {
  console.error(`Usage: node scripts/android-smoke.mjs --avd=${Object.keys(AVDS).join('|')} [--aab [<path>]]`);
  process.exit(1);
}

const BOOT_TIMEOUT_MS = 6 * 60_000; // a cold boot of a new emulator
const TOWN_TIMEOUT_MS = 2 * 60_000; // from a launch to the game's "Town ... started" line
const SETTLE_MS = 3_000; // drawing after a launch or a key press, before a screenshot

const kind = aab ? 'aab' : 'apk';
const build = aab ?? join(exportDir, 'AgentEmpire-debug.apk');
const preset = presetOptions(readFileSync(join(root, 'client', 'export_presets.cfg'), 'utf8'), aab ? 'Android' : 'Android APK');
const runDir = join(root, 'out', 'android', `${avd}-${kind}`);
const logFile = join(runDir, 'logcat.txt');
const { tools, env, debugKeystore } = androidToolchain(root);
const problems = [];
let serial = null;
let logcat = null;

function step(text) {
  console.log(`\n== ${text}`);
}

function sleep(ms) {
  return new Promise((done) => setTimeout(done, ms));
}

function adb(args) {
  return spawnSync(tools.adb, serial ? ['-s', serial, ...args] : args, { encoding: 'utf8', env });
}

function adbOk(args) {
  const r = adb(args);
  if (r.status !== 0) throw new Error(`adb ${args.join(' ')} failed:\n${r.stdout}${r.stderr}`);
  return r.stdout;
}

function bundletool(args) {
  const r = spawnSync(tools.java, ['-jar', bundletoolJar(root), ...args], { encoding: 'utf8', env });
  if (r.status !== 0) throw new Error(`bundletool ${args[0]} failed:\n${r.stdout}${r.stderr}`);
  return r.stdout;
}

function emulators() {
  return [...spawnSync(tools.adb, ['devices'], { encoding: 'utf8' }).stdout.matchAll(/^(emulator-\d+)\s+\w+/gm)].map((m) => m[1]);
}

function avdOf(s) {
  const r = spawnSync(tools.adb, ['-s', s, 'emu', 'avd', 'name'], { encoding: 'utf8' });
  return r.status === 0 ? r.stdout.split(/\r?\n/)[0].trim() : '';
}

/** The serial of the emulator running `avd`, booting it when no emulator runs (one at a time). */
async function startEmulator() {
  const running = emulators();
  const mine = running.find((s) => avdOf(s) === avd);
  if (mine) return mine;
  if (running.length > 0) {
    throw new Error(`another emulator runs (${running.map((s) => `${s} ${avdOf(s)}`).join(', ')}); stop it with adb -s <serial> emu kill`);
  }
  console.log(`   booting ${avd}`);
  spawn(tools.emulator, ['-avd', avd, '-no-snapshot-save'], { detached: true, stdio: 'ignore' }).unref();
  const deadline = Date.now() + BOOT_TIMEOUT_MS;
  for (;;) {
    const s = emulators().find((x) => avdOf(x) === avd);
    if (s) return s;
    if (Date.now() > deadline) throw new Error(`${avd} did not appear in adb within ${BOOT_TIMEOUT_MS / 1000} s`);
    await sleep(2000);
  }
}

async function waitForBoot() {
  const deadline = Date.now() + BOOT_TIMEOUT_MS;
  while (adb(['shell', 'getprop', 'sys.boot_completed']).stdout.trim() !== '1') {
    if (Date.now() > deadline) throw new Error(`${avd} did not finish booting within ${BOOT_TIMEOUT_MS / 1000} s`);
    await sleep(2000);
  }
}

function install() {
  if (!aab) {
    adbOk(['install', '-r', build]);
    return;
  }
  const apks = join(runDir, 'AgentEmpire.apks');
  bundletool([
    'build-apks', `--bundle=${build}`, `--output=${apks}`, '--overwrite', '--connected-device', `--device-id=${serial}`,
    `--adb=${tools.adb}`, `--ks=${debugKeystore.path}`, `--ks-key-alias=${debugKeystore.user}`,
    `--ks-pass=pass:${debugKeystore.password}`, `--key-pass=pass:${debugKeystore.password}`,
  ]);
  bundletool(['install-apks', `--apks=${apks}`, `--device-id=${serial}`, `--adb=${tools.adb}`]);
}

function launch() {
  const out = adbOk(['shell', 'am', 'start', '-W', '-n', `${PACKAGE}/${ACTIVITY}`]);
  const state = /LaunchState: (\w+)/.exec(out)?.[1] ?? '?';
  const ms = /TotalTime: (\d+)/.exec(out)?.[1] ?? '?';
  console.log(`   launched (${state}, ${ms} ms)`);
}

function logText() {
  return readFileSync(logFile, 'utf8');
}

/** Waits for the game's "[game] Town <id> started" line after `from` in the logcat. */
async function waitForTown(from) {
  const started = Date.now();
  for (;;) {
    const m = /\[game\] Town \S+ started[^\r\n]*/.exec(logText().slice(from));
    if (m) {
      console.log(`   ${m[0]} (${((Date.now() - started) / 1000).toFixed(1)} s)`);
      return;
    }
    if (logcat.exitCode !== null) throw new Error('the logcat stream ended early (was the adb server stopped?)');
    if (Date.now() - started > TOWN_TIMEOUT_MS) throw new Error(`the town did not start within ${TOWN_TIMEOUT_MS / 1000} s`);
    await sleep(500);
  }
}

function pid() {
  return adb(['shell', 'pidof', PACKAGE]).stdout.trim();
}

function inFront() {
  return /ResumedActivity.*\bai\.zeenie\.agentempire\//.test(adbOk(['shell', 'dumpsys', 'activity', 'activities']));
}

async function screenshot(name) {
  await sleep(SETTLE_MS);
  const remote = `/data/local/tmp/${name}`;
  adbOk(['shell', 'screencap', '-p', remote]);
  adbOk(['pull', remote, join(runDir, name)]);
  adbOk(['shell', 'rm', remote]);
  console.log(`   ${join(runDir, name)}`);
}

function expectRunning(after) {
  const p = pid();
  if (!p) problems.push(`the game was not running after ${after}`);
  else if (!inFront()) problems.push(`the game was not in front after ${after}`);
  return p;
}

async function play() {
  launch();
  await waitForTown(0);
  await screenshot('01-start.png');
  const first = expectRunning('the first start');

  adbOk(['shell', 'input', 'keyevent', 'KEYCODE_HOME']);
  await sleep(SETTLE_MS);
  launch();
  await screenshot('02-home-relaunch.png');
  const resumed = expectRunning('Home and a relaunch');
  if (first && resumed && first !== resumed) problems.push(`Home and a relaunch restarted the game (pid ${first}, then ${resumed})`);

  adbOk(['shell', 'am', 'force-stop', PACKAGE]);
  if (pid()) problems.push('the game still ran after a force-stop');
  const from = logText().length;
  launch();
  await waitForTown(from);
  await screenshot('03-force-stop-relaunch.png');
  const restarted = expectRunning('a force-stop and a relaunch');

  adbOk(['shell', 'input', 'keyevent', 'KEYCODE_BACK']);
  await screenshot('04-back.png');
  const after = expectRunning('Back');
  if (restarted && after && restarted !== after) problems.push(`Back restarted the game (pid ${restarted}, then ${after})`);
}

/** Pulls the installed APKs, then checks their manifest and their 16 KB alignment. */
function checkInstalled() {
  const dir = join(runDir, 'installed');
  mkdirSync(dir, { recursive: true });
  const apks = [...adbOk(['shell', 'pm', 'path', PACKAGE]).matchAll(/^package:(.+?)\r?$/gm)].map((m) => {
    const local = join(dir, basename(m[1]));
    adbOk(['pull', m[1], local]);
    return local;
  });
  const base = apks.find((a) => basename(a) === 'base.apk');
  const badging = spawnSync(tools.aapt2, ['dump', 'badging', base], { encoding: 'utf8' }).stdout;
  const pkg = /^package: name='([^']*)' versionCode='([^']*)' versionName='([^']*)'/m.exec(badging) ?? [];
  const target = /^targetSdkVersion:'(\d+)'/m.exec(badging)?.[1];
  const min = /^minSdkVersion:'(\d+)'/m.exec(badging)?.[1];
  const permissions = [...badging.matchAll(/^uses-permission: name='([^']+)'/gm)].map((m) => m[1]);
  const landscape = /uses-implied-feature: name='android\.hardware\.screen\.landscape' reason='one or more activities have specified a landscape orientation'/.test(badging);
  // Badging leaves out android:allowBackup; without the attribute Android backs the app up.
  const manifest = spawnSync(tools.aapt2, ['dump', 'xmltree', '--file', 'AndroidManifest.xml', base], { encoding: 'utf8' }).stdout;
  const backup = /:allowBackup\(0x01010280\)=(\S+)/.exec(manifest)?.[1] ?? 'not set';
  console.log(`   ${pkg[1]} ${pkg[3]} (version code ${pkg[2]}), target SDK ${target}, min SDK ${min}`);
  console.log(`   permissions: ${permissions.length ? permissions.join(', ') : 'none'}; landscape: ${landscape ? 'yes' : 'no'}; allowBackup: ${backup}`);
  const code = preset['version/code'];
  if (pkg[1] !== PACKAGE) problems.push(`the package is ${pkg[1]}, not ${PACKAGE}`);
  if (pkg[2] !== code) problems.push(`the version code is ${pkg[2]}, the preset's is ${code}`);
  if (target !== String(TARGET_SDK)) problems.push(`the target SDK is ${target}, not ${TARGET_SDK}`);
  if (min !== String(MIN_SDK)) problems.push(`the min SDK is ${min}, not ${MIN_SDK}`);
  if (permissions.includes('android.permission.INTERNET')) problems.push('the app asks for the INTERNET permission');
  if (permissions.includes('com.google.android.gms.permission.AD_ID')) problems.push('the app asks for the advertising ID (AD_ID)');
  if (backup !== 'false') problems.push(`android:allowBackup is ${backup}, not false (user_data_backup/allow)`);
  if (!landscape) problems.push('no activity is landscape');
  for (const apk of apks) {
    const r = spawnSync(tools.zipalign, ['-c', '-P', '16', '-v', '4', apk], { encoding: 'utf8' });
    const ok = r.status === 0 && /Verification successful/.test(r.stdout);
    console.log(`   ${basename(apk)}: ${ok ? '16 KB aligned' : 'NOT 16 KB aligned'}`);
    if (!ok) problems.push(`${basename(apk)} failed zipalign -c -P 16:\n${r.stdout.split(/\r?\n/).filter((l) => /BAD|FAILED/.test(l)).join('\n')}`);
  }
}

/** The game's errors and crashes in the logcat, and the renderer it reported. */
function readLog() {
  const lines = logText().split(/\r?\n/);
  const pids = new Set([...logText().matchAll(/Start proc (\d+):ai\.zeenie\.agentempire\//g)].map((m) => m[1]));
  const line = /^\S+\s+\S+\s+(\d+)\s+\d+\s+([VDIWEFA])\s+(.*?)\s*: (.*)$/;
  const failures = [];
  const otherErrors = [];
  let renderer = null;
  for (const l of lines) {
    const m = line.exec(l);
    if (!m) continue;
    const [, p, level, tag, msg] = m;
    if (tag === 'godot') {
      if (/\b(ERROR|FATAL)\b/.test(msg)) failures.push(l);
      if (/(Vulkan|OpenGL API) .* - (Forward Mobile|Forward\+|Compatibility) - Using Device/.test(msg)) renderer = msg.trim();
    } else if (pids.has(p) && (level === 'F' || /FATAL/.test(msg))) {
      failures.push(l);
    } else if (/ANR in ai\.zeenie\.agentempire|>>> ai\.zeenie\.agentempire <<</.test(msg)) {
      failures.push(l);
    } else if (pids.has(p) && level === 'E') {
      otherErrors.push(l);
    }
  }
  return { failures, otherErrors, renderer };
}

async function main() {
  if (!existsSync(build)) throw new Error(`no ${build}; build it with node scripts/build-android.mjs --${kind}`);
  rmSync(runDir, { recursive: true, force: true });
  mkdirSync(runDir, { recursive: true });

  step(`Emulator ${avd}`);
  serial = await startEmulator();
  await waitForBoot();
  // A freshly booted emulator is still delivering its boot broadcasts to every app; a game started
  // then crawls, and its first screenshot catches an unfinished frame.
  adbOk(['shell', 'am', 'wait-for-broadcast-idle']);
  adbOk(['shell', 'input', 'keyevent', 'KEYCODE_WAKEUP']);
  adbOk(['shell', 'wm', 'dismiss-keyguard']);
  adbOk(['shell', 'svc', 'power', 'stayon', 'true']);
  // Android shows a one-time "Viewing full screen" notice over the first immersive app; on the test
  // emulator it is marked as seen, so the screenshots show the game.
  adbOk(['shell', 'settings', 'put', 'secure', 'immersive_mode_confirmations', 'confirmed']);
  console.log(`   ${serial}, Android ${adbOk(['shell', 'getprop', 'ro.build.version.release']).trim()}`);

  step(`Install ${build}`);
  install();

  step('Play');
  adbOk(['logcat', '-c']);
  const fd = openSync(logFile, 'w');
  logcat = spawn(tools.adb, ['-s', serial, 'logcat', '-v', 'threadtime'], { stdio: ['ignore', fd, fd] });
  const logcatExit = new Promise((done) => logcat.once('exit', done));
  try {
    await play();
    if (logcat.exitCode !== null) problems.push('the logcat stream ended early (was the adb server stopped?)');
  } catch (err) {
    problems.push(err instanceof Error ? err.message : String(err));
  } finally {
    logcat.kill();
    await logcatExit;
    closeSync(fd);
  }

  step('Installed APKs');
  checkInstalled();

  step('Logcat');
  const log = readLog();
  console.log(`   renderer: ${log.renderer ?? 'not reported'}`);
  console.log(`   ${logFile}`);
  if (!log.renderer) problems.push('the game reported no renderer in logcat');
  for (const l of log.failures) problems.push(`logcat: ${l}`);
  if (log.otherErrors.length > 0) {
    console.log(`   ${log.otherErrors.length} other error lines from the game's process (not failures), the first:`);
    for (const l of log.otherErrors.slice(0, 5)) console.log(`     ${l}`);
  }

  step(problems.length === 0 ? `Passed: ${avd}, ${kind}` : `FAILED: ${avd}, ${kind}`);
  for (const p of problems) console.log(`   ${p}`);
  console.log(`   The emulator keeps running; stop it with: adb -s ${serial} emu kill`);
  process.exit(problems.length === 0 ? 0 : 1);
}

main().catch((err) => {
  console.error(`\nAndroid smoke test failed: ${err instanceof Error ? err.message : String(err)}`);
  process.exit(1);
});
