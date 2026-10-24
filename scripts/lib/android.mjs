// The Android toolchain for the Android builds. Godot's editor settings say where the Android SDK
// and the JDK are (scripts/setup-android.mjs fills them in); the Android scripts take every tool
// from there, so they run the same SDK and JDK as Godot's export.
import { existsSync, readFileSync } from 'node:fs';
import os from 'node:os';
import { join, resolve } from 'node:path';
import { GODOT_VERSION, toolsDir } from './godot.mjs';

/** The app's package and the activity Godot's template launches. */
export const PACKAGE = 'ai.zeenie.agentempire';
export const ACTIVITY = 'com.godot.game.GodotAppLauncher';

/** The SDK packages Godot 4.7.2's Gradle build template names (config.gradle in android_source.zip). */
export const BUILD_TOOLS = '36.1.0';
export const NDK = '29.0.14206865';

/** The emulators for the smoke test and the device profiles they copy, from the installed image. */
export const SYSTEM_IMAGE = 'system-images;android-36;google_apis_playstore;x86_64';
export const AVDS = { ae_phone: 'pixel_7', ae_tablet: 'pixel_tablet' };

/** bundletool, which turns an .aab into the APKs a device installs. */
export const BUNDLETOOL_VERSION = '1.18.3';
export const BUNDLETOOL_SHA256 = 'a099cfa1543f55593bc2ed16a70a7c67fe54b1747bb7301f37fdfd6d91028e29';
export const BUNDLETOOL_URL = `https://github.com/google/bundletool/releases/download/${BUNDLETOOL_VERSION}/bundletool-all-${BUNDLETOOL_VERSION}.jar`;

export function bundletoolJar(root) {
  return join(toolsDir(root), 'bundletool', `bundletool-all-${BUNDLETOOL_VERSION}.jar`);
}

const exe = process.platform === 'win32' ? '.exe' : '';
const bat = process.platform === 'win32' ? '.bat' : '';

/** Godot's editor settings file: in .tools/godot/editor_data (self-contained) except on macOS. */
export function editorSettingsFile(root) {
  const name = `editor_settings-${GODOT_VERSION.split('.').slice(0, 2).join('.')}.tres`;
  if (process.platform === 'darwin') return join(os.homedir(), 'Library', 'Application Support', 'Godot', name);
  return join(toolsDir(root), 'godot', 'editor_data', name);
}

function keyPattern(key) {
  return new RegExp(`^${key.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')} = (.*)$`, 'm');
}

/** The string value `key` has in the editor settings text, or null when the file does not set it. */
export function readSetting(text, key) {
  const m = keyPattern(key).exec(text);
  if (!m) return null;
  const s = /^"((?:[^"\\]|\\.)*)"$/.exec(m[1]);
  if (!s) throw new Error(`${key} in the editor settings is not a string: ${m[1]}`);
  return s[1].replace(/\\(.)/g, '$1');
}

/** The editor settings text with `key` set to the string `value` (added at the end when missing). */
export function writeSetting(text, key, value) {
  const line = `${key} = "${value.replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`;
  if (keyPattern(key).test(text)) return text.replace(keyPattern(key), () => line);
  return `${text.replace(/\n*$/, '')}\n${line}\n`;
}

/** The programs an Android build and the smoke test run. */
export function androidTools(sdk, jdk) {
  return {
    sdkmanager: join(sdk, 'cmdline-tools', 'latest', 'bin', `sdkmanager${bat}`),
    avdmanager: join(sdk, 'cmdline-tools', 'latest', 'bin', `avdmanager${bat}`),
    adb: join(sdk, 'platform-tools', `adb${exe}`),
    emulator: join(sdk, 'emulator', `emulator${exe}`),
    aapt2: join(sdk, 'build-tools', BUILD_TOOLS, `aapt2${exe}`),
    zipalign: join(sdk, 'build-tools', BUILD_TOOLS, `zipalign${exe}`),
    java: join(jdk, 'bin', `java${exe}`),
    keytool: join(jdk, 'bin', `keytool${exe}`),
    jarsigner: join(jdk, 'bin', `jarsigner${exe}`),
  };
}

/**
 * The SDK and JDK the editor settings name, the tools in them, and the environment to run them
 * with (JAVA_HOME is the JDK: the `java` on PATH may be an older one).
 */
export function androidToolchain(root) {
  const file = editorSettingsFile(root);
  const text = existsSync(file) ? readFileSync(file, 'utf8') : '';
  const sdkSetting = readSetting(text, 'export/android/android_sdk_path') ?? '';
  const jdkSetting = readSetting(text, 'export/android/java_sdk_path') ?? '';
  if (!sdkSetting || !jdkSetting) {
    throw new Error(`the Android SDK or JDK is not set in ${file}; run node scripts/setup-android.mjs first`);
  }
  const sdk = resolve(sdkSetting);
  const jdk = resolve(jdkSetting);
  return { sdk, jdk, tools: androidTools(sdk, jdk), env: { ...process.env, JAVA_HOME: jdk } };
}
