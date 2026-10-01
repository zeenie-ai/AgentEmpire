// Where Godot lives for this project, on Windows, macOS and Linux.
//
// The editor goes in .tools/godot/ (git-ignored). A worktree under .wt/<name> uses the main
// checkout's .tools/. On Windows and Linux the editor runs self-contained (a ._sc_ file next to
// it), so its export templates live in .tools/godot/editor_data/; on macOS they go where Godot
// looks by default, ~/Library/Application Support/Godot/export_templates/.
import { existsSync } from 'node:fs';
import os from 'node:os';
import { basename, dirname, join } from 'node:path';

export const GODOT_VERSION = '4.7.2';
export const GODOT_TAG = `${GODOT_VERSION}-stable`;
export const GODOT_RELEASES = `https://github.com/godotengine/godot/releases/download/${GODOT_TAG}`;
export const TEMPLATES_ARCHIVE = `Godot_v${GODOT_TAG}_export_templates.tpz`;

/** The .tools folder: this checkout's, or the main checkout's when this is a worktree under .wt/. */
export function toolsDir(root) {
  const own = join(root, '.tools');
  const main = join(root, '..', '..', '.tools');
  if (!existsSync(own) && basename(dirname(root)) === '.wt' && existsSync(main)) return main;
  return own;
}

/** The editor download for this computer and the program inside it that scripts run. */
export function hostEditor(platform = process.platform, arch = process.arch) {
  if (platform === 'win32') {
    return { archive: `Godot_v${GODOT_TAG}_win64.exe.zip`, binary: `Godot_v${GODOT_TAG}_win64_console.exe`, selfContained: true };
  }
  if (platform === 'darwin') {
    return { archive: `Godot_v${GODOT_TAG}_macos.universal.zip`, binary: 'Godot.app/Contents/MacOS/Godot', selfContained: false };
  }
  if (platform === 'linux') {
    const suffix = arch === 'arm64' ? 'linux.arm64' : 'linux.x86_64';
    return { archive: `Godot_v${GODOT_TAG}_${suffix}.zip`, binary: `Godot_v${GODOT_TAG}_${suffix}`, selfContained: true };
  }
  throw new Error(`Godot is not available for ${platform} ${arch}`);
}

/** The Godot program to run: GODOT if set, else the editor in .tools/godot. */
export function findGodot(root) {
  if (process.env.GODOT) return process.env.GODOT;
  return join(toolsDir(root), 'godot', hostEditor().binary);
}

/** Where this computer's Godot looks for its export templates. */
export function templatesDir(root, platform = process.platform) {
  if (platform === 'darwin') {
    return join(os.homedir(), 'Library', 'Application Support', 'Godot', 'export_templates', `${GODOT_VERSION}.stable`);
  }
  return join(toolsDir(root), 'godot', 'editor_data', 'export_templates', `${GODOT_VERSION}.stable`);
}

/** The template files each release target needs (names inside the templates archive's templates/ folder). */
export const TEMPLATE_FILES = {
  windows: ['windows_release_x86_64.exe', 'windows_release_x86_64_console.exe'],
  linux: ['linux_release.x86_64'],
  macos: ['macos.zip'],
};
