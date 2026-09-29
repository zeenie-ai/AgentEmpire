// Fetches the CC0 KayKit art kits used by the art pipeline (art_src/) into .tools/vendor,
// each at a pinned commit so every build starts from identical sources.
//
// Usage: node scripts/fetch-assets.mjs [--dest <dir>]
//   --dest   fetch into another directory instead of .tools/vendor (for testing)
//
// Idempotent: a kit already checked out cleanly at its pinned commit is skipped. A kit present at
// another commit (or with missing files) is fetched and switched to the pinned one. Needs git on PATH and network access for the
// first run. Git is confined to the vendor directories (GIT_CEILING_DIRECTORIES), so it never
// touches the project's own repository.
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync } from "node:fs";
import { delimiter, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const args = process.argv.slice(2);
const destArg = args.indexOf("--dest");
const vendor = destArg >= 0 ? resolve(args[destArg + 1]) : join(root, ".tools", "vendor");

const KITS = [
  {
    dir: "kaykit-medieval",
    name: "KayKit Medieval Hexagon Pack 1.0",
    url: "https://github.com/KayKit-Game-Assets/KayKit-Medieval-Hexagon-Pack-1.0.git",
    commit: "84fa4e91af6a88989be7c99e0891cede11f2ca38",
    expect: "addons/kaykit_medieval_hexagon_pack/Textures/hexagons_medieval.png",
  },
  {
    dir: "kaykit-adventurers",
    name: "KayKit Character Pack: Adventurers 1.0",
    url: "https://github.com/KayKit-Game-Assets/KayKit-Character-Pack-Adventures-1.0.git",
    commit: "672074b73ba276876a19e8816ecdc5241817ab47",
    expect: "addons/kaykit_character_pack_adventures/Characters/gltf/Rogue_Hooded.glb",
  },
];

const gitEnv = {
  ...process.env,
  GIT_CEILING_DIRECTORIES: [vendor, dirname(vendor)].join(delimiter),
  GIT_TERMINAL_PROMPT: "0",
};

function git(cwd, ...gitArgs) {
  return execFileSync("git", gitArgs, { cwd, env: gitEnv, stdio: ["ignore", "pipe", "inherit"] })
    .toString()
    .trim();
}

// The checked-out commit, read from .git directly (no git process needed for the skip check).
function headCommit(dir) {
  const gitDir = join(dir, ".git");
  if (!existsSync(join(gitDir, "HEAD"))) return null;
  const head = readFileSync(join(gitDir, "HEAD"), "utf8").trim();
  if (/^[0-9a-f]{40}$/.test(head)) return head;
  const ref = head.match(/^ref: (.+)$/)?.[1];
  if (!ref) return null;
  if (existsSync(join(gitDir, ref))) return readFileSync(join(gitDir, ref), "utf8").trim();
  const packed = join(gitDir, "packed-refs");
  if (existsSync(packed)) {
    for (const line of readFileSync(packed, "utf8").split("\n")) {
      const [sha, name] = line.trim().split(" ");
      if (name === ref) return sha;
    }
  }
  return null;
}

mkdirSync(vendor, { recursive: true });
let failed = false;
for (const kit of KITS) {
  const dir = join(vendor, kit.dir);
  const short = kit.commit.slice(0, 7);
  try {
    if (headCommit(dir) === kit.commit && existsSync(join(dir, kit.expect))) {
      // at the pinned commit: skip unless files are missing or modified (e.g. an interrupted checkout)
      if (git(dir, "status", "--porcelain", "--untracked-files=no") === "") {
        console.log(`${kit.dir}: already at ${short}, skipped`);
        continue;
      }
      console.log(`${kit.dir}: at ${short} but the working tree is incomplete, restoring`);
    }
    if (!existsSync(join(dir, ".git"))) {
      if (existsSync(dir)) throw new Error(`${dir} exists but is not a git checkout; remove it and re-run`);
      mkdirSync(dir, { recursive: true });
      git(dir, "init", "--quiet");
      git(dir, "remote", "add", "origin", kit.url);
    }
    // the kits contain long .obj/.fbx file names; allow paths beyond 260 characters on Windows
    git(dir, "config", "core.longpaths", "true");
    console.log(`${kit.dir}: fetching ${kit.name} at ${short} ...`);
    git(dir, "fetch", "--quiet", "--depth", "1", "origin", kit.commit);
    git(dir, "-c", "advice.detachedHead=false", "checkout", "--quiet", "--force", "--detach", kit.commit);
    const now = git(dir, "rev-parse", "HEAD");
    if (now !== kit.commit || !existsSync(join(dir, kit.expect))) {
      throw new Error(`checkout ended at ${now} without ${kit.expect}`);
    }
    console.log(`${kit.dir}: ready at ${short}`);
  } catch (err) {
    failed = true;
    console.error(`${kit.dir}: ${err.message}`);
  }
}
if (failed) process.exit(1);
console.log(`Kits are in ${vendor}. Next: blender --background --factory-startup --python-exit-code 1 --python art_src/blender/build_all.py`);
