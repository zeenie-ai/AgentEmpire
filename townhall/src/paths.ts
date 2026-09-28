import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const PACKAGE_NAME = "aurelhaven-townhall";

let cachedRoot: string | null = null;

/**
 * The townhall package folder. Resolved by walking up from this module so it works
 * the same from `src/` (tsx, vitest) and from `dist/` (compiled build).
 */
export function packageRoot(): string {
  if (cachedRoot) return cachedRoot;
  let dir = path.dirname(fileURLToPath(import.meta.url));
  for (;;) {
    const manifest = path.join(dir, "package.json");
    if (existsSync(manifest)) {
      try {
        const parsed = JSON.parse(readFileSync(manifest, "utf8")) as { name?: string };
        if (parsed.name === PACKAGE_NAME) {
          cachedRoot = dir;
          return dir;
        }
      } catch {
        // not our manifest; keep walking
      }
    }
    const parent = path.dirname(dir);
    if (parent === dir) throw new Error("townhall package root not found");
    dir = parent;
  }
}

/** Source-tree assets (SQL migrations, fake scenarios) are read from `src/` in every mode. */
export function srcPath(...parts: string[]): string {
  return path.join(packageRoot(), "src", ...parts);
}

export function defaultEconomyPath(): string {
  return path.resolve(packageRoot(), "..", "protocol", "economy.json");
}

export function defaultDataDir(): string {
  return path.join(packageRoot(), "data");
}

export function defaultWebDir(): string {
  return path.resolve(packageRoot(), "..", "client", "export", "web");
}

export function generatedGdPath(): string {
  return path.resolve(packageRoot(), "..", "protocol", "generated", "protocol.gd");
}
