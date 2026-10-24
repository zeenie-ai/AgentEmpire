#!/usr/bin/env node
// Sets up this computer to build AgentEmpire for Android and to test it on emulators:
//   1. the Android keys in Godot's editor settings: the JDK 17 that Gradle runs on, and the
//      Android debug keystore (~/.android/debug.keystore) that signs debug builds;
//   2. the SDK packages Godot 4.7.2's Gradle build needs (the NDK and build-tools 36.1.0), added
//      with sdkmanager to the Android SDK the editor settings name;
//   3. the Android export templates, from Godot's templates archive if any is missing;
//   4. two emulators for scripts/android-smoke.mjs, ae_phone (a Pixel 7) and ae_tablet (a Pixel
//      Tablet), from the Android 36 Google Play x86_64 system image;
//   5. bundletool, pinned and checked, into .tools/bundletool/, to install .aab builds.
// Running it again only does what is missing. Close the Godot editor first: it writes its settings
// back when it quits.
//
// Usage: node scripts/setup-android.mjs [--jdk=<JDK 17 folder>]
//   --jdk is needed once, while the editor settings name no JDK.
import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  AVDS, BUILD_TOOLS, BUNDLETOOL_SHA256, BUNDLETOOL_URL, BUNDLETOOL_VERSION, NDK, SYSTEM_IMAGE,
  androidTools, bundletoolJar, editorSettingsFile, readSetting, writeSetting,
} from './lib/android.mjs';
import { checksumFor, download, fetchText } from './lib/download.mjs';
import { ANDROID_TEMPLATE_FILES, GODOT_RELEASES, TEMPLATES_ARCHIVE, templatesDir, toolsDir } from './lib/godot.mjs';
import { openZip } from './lib/zip.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const jdkArg = process.argv.slice(2).find((a) => a.startsWith('--jdk='))?.slice('--jdk='.length);
const settingsFile = editorSettingsFile(root);

function step(text) {
  console.log(`\n== ${text}`);
}

/** Runs sdkmanager or avdmanager. On Windows they are batch files, which Node starts only through the shell. */
function runBatch(file, args, options) {
  return spawnSync([file, ...args].map((a) => `"${a}"`).join(' '), { shell: true, encoding: 'utf8', ...options });
}

/** Godot writes paths with forward slashes. */
function godotPath(path) {
  return path.replaceAll('\\', '/');
}

function javaMajor(jdk) {
  const release = join(jdk, 'release');
  if (!existsSync(release)) return null;
  return /^JAVA_VERSION="(\d+)/m.exec(readFileSync(release, 'utf8'))?.[1] ?? null;
}

function setupPackages(sdk, tools, env) {
  step('Android SDK packages');
  const list = runBatch(tools.sdkmanager, [`--sdk_root=${sdk}`, '--list_installed'], { env });
  if (list.status !== 0) throw new Error(`sdkmanager --list_installed failed:\n${list.stdout}${list.stderr}`);
  const installed = new Set(list.stdout.split(/\r?\n/).map((line) => line.split('|')[0].trim()));
  // The NDK first: it is by far the largest download.
  for (const pkg of [`ndk;${NDK}`, `build-tools;${BUILD_TOOLS}`]) {
    if (installed.has(pkg)) {
      console.log(`   ${pkg}: already installed`);
      continue;
    }
    console.log(`   ${pkg}: installing`);
    const r = runBatch(tools.sdkmanager, [`--sdk_root=${sdk}`, '--install', pkg], { env, stdio: 'inherit' });
    if (r.status !== 0) throw new Error(`sdkmanager could not install ${pkg}`);
  }
}

async function setupTemplates() {
  step('Godot Android export templates');
  const dir = templatesDir(root);
  const missing = ['version.txt', ...ANDROID_TEMPLATE_FILES].filter((f) => !existsSync(join(dir, f)));
  if (missing.length === 0) {
    console.log(`   already in ${dir}`);
    return;
  }
  console.log('   One download of about 1.2 GB.');
  const archive = join(toolsDir(root), 'downloads', TEMPLATES_ARCHIVE);
  const sums = await fetchText(`${GODOT_RELEASES}/SHA512-SUMS.txt`);
  await download(`${GODOT_RELEASES}/${TEMPLATES_ARCHIVE}`, archive, { algorithm: 'sha512', digest: checksumFor(sums, TEMPLATES_ARCHIVE) });
  const zip = openZip(archive);
  try {
    mkdirSync(dir, { recursive: true });
    for (const name of missing) {
      const e = zip.entries.find((x) => x.name === `templates/${name}`);
      if (!e) throw new Error(`${TEMPLATES_ARCHIVE} has no templates/${name}`);
      writeFileSync(join(dir, name), e.read());
    }
  } finally {
    zip.close();
  }
  rmSync(archive, { force: true });
  console.log(`   installed in ${dir}: ${missing.join(', ')}`);
}

function setupEditorSettings(jdk, tools) {
  step("Godot's Android editor settings");
  // The keystore Android Studio makes for debug builds, with its well-known alias and password.
  const keystore = join(os.homedir(), '.android', 'debug.keystore');
  const check = spawnSync(tools.keytool, ['-list', '-keystore', keystore, '-storepass', 'android', '-alias', 'androiddebugkey'], { encoding: 'utf8' });
  if (check.status !== 0) throw new Error(`${keystore} does not open as androiddebugkey / android:\n${check.stdout}${check.stderr}`);
  const wanted = {
    'export/android/java_sdk_path': godotPath(jdk),
    'export/android/debug_keystore': godotPath(keystore),
    'export/android/debug_keystore_user': 'androiddebugkey',
    'export/android/debug_keystore_pass': 'android',
  };
  const before = readFileSync(settingsFile, 'utf8');
  let text = before;
  for (const [key, value] of Object.entries(wanted)) text = writeSetting(text, key, value);
  if (text === before) {
    console.log('   already set');
    return;
  }
  writeFileSync(settingsFile, text);
  for (const [key, value] of Object.entries(wanted)) console.log(`   ${key} = ${key.endsWith('_pass') ? '(the debug password)' : value}`);
}

/** Each AVD's name and folder, from avdmanager. */
function listAvds(tools, env) {
  const r = runBatch(tools.avdmanager, ['list', 'avd'], { env });
  if (r.status !== 0) throw new Error(`avdmanager list avd failed:\n${r.stdout}${r.stderr}`);
  const avds = new Map();
  let name = null;
  for (const line of r.stdout.split(/\r?\n/)) {
    const m = /^\s*(Name|Path):\s*(.+)$/.exec(line);
    if (m?.[1] === 'Name') name = m[2].trim();
    else if (m && name) avds.set(name, m[2].trim());
  }
  return avds;
}

function setIni(text, key, value) {
  const re = new RegExp(`^${key.replaceAll('.', '\\.')}\\s*=.*$`, 'm');
  const line = `${key}=${value}`;
  return re.test(text) ? text.replace(re, line) : `${text.replace(/\s*$/, '')}\n${line}\n`;
}

function setupAvds(tools, env) {
  step('Emulators');
  const existing = listAvds(tools, env);
  for (const [name, device] of Object.entries(AVDS)) {
    if (existing.has(name)) {
      console.log(`   ${name}: already created`);
      continue;
    }
    // avdmanager asks whether to make a custom hardware profile: no, the device's profile.
    const r = runBatch(tools.avdmanager, ['create', 'avd', '--name', name, '--package', SYSTEM_IMAGE, '--device', device], {
      env, input: 'no\n', stdio: ['pipe', 'inherit', 'inherit'],
    });
    if (r.status !== 0) throw new Error(`avdmanager could not create ${name}`);
    console.log(`   ${name}: created from ${device}`);
  }
  const avds = listAvds(tools, env);
  for (const name of Object.keys(AVDS)) {
    const config = join(avds.get(name), 'config.ini');
    const before = readFileSync(config, 'utf8');
    let text = before;
    for (const [key, value] of [['hw.ramSize', '4096'], ['hw.gpu.enabled', 'yes'], ['hw.gpu.mode', 'host']]) text = setIni(text, key, value);
    if (text !== before) writeFileSync(config, text);
    console.log(`   ${name}: 4096 MB, host GPU (${config})`);
  }
}

async function setupBundletool() {
  step(`bundletool ${BUNDLETOOL_VERSION}`);
  const jar = bundletoolJar(root);
  await download(BUNDLETOOL_URL, jar, { algorithm: 'sha256', digest: BUNDLETOOL_SHA256 });
  console.log(`   in ${jar}`);
}

async function main() {
  if (!existsSync(settingsFile)) {
    throw new Error(`no Godot editor settings at ${settingsFile}; run node scripts/setup.mjs and import the project once`);
  }
  const settings = readFileSync(settingsFile, 'utf8');
  const sdkSetting = readSetting(settings, 'export/android/android_sdk_path') ?? '';
  const jdkSetting = jdkArg ?? readSetting(settings, 'export/android/java_sdk_path') ?? '';
  if (!sdkSetting) throw new Error('the editor settings name no Android SDK (export/android/android_sdk_path)');
  if (!jdkSetting) throw new Error('the editor settings name no JDK: pass --jdk=<JDK 17 folder>');
  const sdk = resolve(sdkSetting);
  const jdk = resolve(jdkSetting);
  if (javaMajor(jdk) !== '17') throw new Error(`${jdk} is not a JDK 17 (Godot's Gradle build runs on JDK 17)`);
  const tools = androidTools(sdk, jdk);
  if (!existsSync(tools.sdkmanager)) {
    throw new Error(`no Android SDK command-line tools in ${sdk}; install them with Android Studio's SDK Manager`);
  }
  const env = { ...process.env, JAVA_HOME: jdk };
  console.log(`Android SDK: ${sdk}\nJDK: ${jdk}`);
  setupEditorSettings(jdk, tools);
  setupPackages(sdk, tools, env);
  await setupTemplates();
  setupAvds(tools, env);
  await setupBundletool();
  step('Ready');
  console.log('   Build: node scripts/build-android.mjs --apk (or --aab)');
  console.log('   Test on an emulator: node scripts/android-smoke.mjs --avd=ae_phone');
}

main().catch((err) => {
  console.error(`\nAndroid setup failed: ${err instanceof Error ? err.message : String(err)}`);
  process.exit(1);
});
