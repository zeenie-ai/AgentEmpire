// Development build: syncs economy.json into the client, imports the Godot project, then exports
// the Windows desktop build and the web build into client/export/ (run from this checkout, they
// use its townhall/). Release packages for every platform: scripts/package-release.mjs.
//
// Usage: node scripts/build-game.mjs [--windows-only | --web-only]
// Godot is taken from the GODOT environment variable, or the copy in .tools/godot (scripts/setup.mjs).
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readdirSync, statSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { findGodot } from "./lib/godot.mjs";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const client = join(root, "client");
const godot = findGodot(root);
const args = new Set(process.argv.slice(2));

const targets = [
  { preset: "Windows Desktop", dir: join(client, "export", "windows"), file: "Aurelhaven.exe", skip: args.has("--web-only") },
  { preset: "Web", dir: join(client, "export", "web"), file: "index.html", skip: args.has("--windows-only") },
];

function run(cmd, cmdArgs, label) {
  console.log(`\n== ${label}`);
  execFileSync(cmd, cmdArgs, { cwd: root, stdio: "inherit" });
}

if (!existsSync(godot)) {
  console.error(`Godot not found at ${godot}. Set the GODOT environment variable.`);
  process.exit(1);
}

run(process.execPath, [join(root, "scripts", "sync-economy.mjs")], "Sync economy.json into the client");
run(godot, ["--headless", "--path", client, "--import"], "Import the Godot project");

for (const t of targets.filter(t => !t.skip)) {
  mkdirSync(t.dir, { recursive: true });
  run(godot, ["--headless", "--path", client, "--export-release", t.preset, join(t.dir, t.file)], `Export ${t.preset}`);
}

console.log("\n== Output");
for (const t of targets.filter(t => !t.skip)) {
  for (const name of readdirSync(t.dir)) {
    const mb = (statSync(join(t.dir, name)).size / 1048576).toFixed(1);
    console.log(`${join(t.dir, name)}  ${mb} MB`);
  }
}
