// Android builds. Syncs economy.json into the client, imports the Godot project, then exports one
// of the two Android presets into client/export/android/:
//   --apk  AgentEmpire-debug.apk, a debug build from Godot's prebuilt template ("Android APK"),
//          signed with the Android debug key: quick to make, for emulator rounds;
//   --aab  AgentEmpire.aab, the release App Bundle for Google Play, built with Gradle ("Android"),
//          signed with the upload key that GODOT_ANDROID_KEYSTORE_RELEASE_PATH, _USER and
//          _PASSWORD name. The first build installs Godot's Gradle template into client/android/
//          (git-ignored), and Gradle downloads itself and its packages (about 1 GB).
// The Android SDK and the JDK come from Godot's editor settings (scripts/setup-android.mjs).
//
// Usage: node scripts/build-android.mjs --apk | --aab
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, rmSync, statSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { androidToolchain } from './lib/android.mjs';
import { GODOT_VERSION, findGodot } from './lib/godot.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const client = join(root, 'client');
const outDir = join(client, 'export', 'android');
const args = new Set(process.argv.slice(2));

const builds = {
  '--apk': { preset: 'Android APK', mode: '--export-debug', file: 'AgentEmpire-debug.apk' },
  '--aab': { preset: 'Android', mode: '--export-release', file: 'AgentEmpire.aab' },
};
const chosen = Object.keys(builds).filter((a) => args.has(a));
if (chosen.length !== 1) {
  console.error('Usage: node scripts/build-android.mjs --apk | --aab');
  process.exit(1);
}
const build = builds[chosen[0]];

const signing = ['GODOT_ANDROID_KEYSTORE_RELEASE_PATH', 'GODOT_ANDROID_KEYSTORE_RELEASE_USER', 'GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD'];
const unset = signing.filter((name) => !process.env[name]);
if (build.preset === 'Android' && unset.length > 0) {
  console.error(`The release build is signed with the upload key; set ${unset.join(', ')}.`);
  process.exit(1);
}

const godot = findGodot(root);
if (!existsSync(godot)) {
  console.error(`Godot not found at ${godot}. Set the GODOT environment variable.`);
  process.exit(1);
}
const toolchain = androidToolchain(root);
// Without a daemon, Gradle exits with the build, and the console Godot (which waits for every
// process it started) returns.
const env = { ...toolchain.env, GRADLE_OPTS: '-Dorg.gradle.daemon=false' };

function run(cmd, cmdArgs, label) {
  console.log(`\n== ${label}`);
  execFileSync(cmd, cmdArgs, { cwd: root, stdio: 'inherit', env });
}

run(process.execPath, [join(root, 'scripts', 'sync-economy.mjs')], 'Sync economy.json into the client');
run(godot, ['--headless', '--path', client, '--import'], 'Import the Godot project');

const exportArgs = ['--headless', '--path', client];
if (build.preset === 'Android') {
  const versionFile = join(client, 'android', '.build_version');
  const installed = existsSync(versionFile) ? readFileSync(versionFile, 'utf8').trim() : '';
  if (installed !== `${GODOT_VERSION}.stable`) exportArgs.push('--install-android-build-template');
}
const out = join(outDir, build.file);
mkdirSync(outDir, { recursive: true });
rmSync(out, { force: true });
run(godot, [...exportArgs, build.mode, build.preset, out], `Export ${build.preset}`);
if (!existsSync(out)) {
  console.error(`The export wrote no ${out}.`);
  process.exit(1);
}
console.log(`\n== Output\n${out}  ${(statSync(out).size / 1048576).toFixed(1)} MB`);
