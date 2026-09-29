"""Rebuilds all Aurelhaven art from the KayKit sources, in order:

  1. build_models.py      client/art/models/*.glb and anchors.json      } in parallel
     build_characters.py  client/art/characters/*.glb                   }
  2. render_icons.py      client/art/icons/*.png
  3. contact_sheets.py    out/art/<category>.png (four processes in parallel)
  4. verify.py            re-imports every output; out/art/verify_report.json

Run it with Blender (the fresh-clone path, after `node scripts/fetch-assets.mjs`):

    blender --background --factory-startup --python art_src/blender/build_all.py

or with any Python 3.10+, pointing at Blender:

    python art_src/blender/build_all.py --blender "C:/Program Files/Blender Foundation/Blender 5.1/blender.exe"

Every step runs in its own Blender process (full logs in out/art/logs/); the build stops at the
first failing step and exits non-zero.
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
LOGS = REPO / "out" / "art" / "logs"
TMP = REPO / "out" / "art" / ".tmp"
DEFAULT_BLENDER = r"C:\Program Files\Blender Foundation\Blender 5.1\blender.exe"


def blender_binary() -> str:
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else sys.argv[1:]
    if "--blender" in argv:
        return argv[argv.index("--blender") + 1]
    try:
        import bpy  # noqa: F401
        return bpy.app.binary_path
    except ImportError:
        return os.environ.get("BLENDER", DEFAULT_BLENDER)


def check_sources() -> None:
    import json
    manifest = json.loads((REPO / "art_src" / "manifest.json").read_text(encoding="utf-8"))
    missing = [k for k, rel in manifest["source_roots"].items() if not (REPO / rel).is_dir()]
    if missing:
        sys.exit(f"KayKit sources missing ({', '.join(missing)}). Run: node scripts/fetch-assets.mjs")


def pump(proc: subprocess.Popen, log, name: str) -> None:
    for line in proc.stdout:
        log.write(line)
        if line.startswith("[art]"):
            print(f"{name:>10} | {line[6:].rstrip()}", flush=True)


def run_group(blender: str, steps: list[tuple[str, str, list[str]]]) -> None:
    """Run (name, script, args) steps in parallel Blender processes; exit on any failure."""
    LOGS.mkdir(parents=True, exist_ok=True)
    running = []
    for name, script, args in steps:
        log = open(LOGS / f"{name}.log", "w", encoding="utf-8")
        cmd = [blender, "--background", "--factory-startup", "--python-exit-code", "1",
               "--python", str(HERE / script), "--", *args]
        proc = subprocess.Popen(cmd, cwd=REPO, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                text=True, encoding="utf-8", errors="replace")
        t = threading.Thread(target=pump, args=(proc, log, name), daemon=True)
        t.start()
        running.append((name, proc, t, log))
    failed = []
    for name, proc, t, log in running:
        proc.wait()
        t.join()
        log.close()
        if proc.returncode != 0:
            failed.append(name)
    if failed:
        sys.exit(f"build_all: step(s) failed: {', '.join(failed)} (see {LOGS})")


def main() -> None:
    blender = blender_binary()
    if not Path(blender).exists():
        sys.exit(f"Blender not found at {blender}; pass --blender <path> or set BLENDER")
    check_sources()
    start = time.time()
    print(f"build_all: Blender {blender}", flush=True)
    run_group(blender, [("models", "build_models.py", []), ("characters", "build_characters.py", [])])
    run_group(blender, [("icons", "render_icons.py", [])])
    run_group(blender, [("sheets-a", "contact_sheets.py", ["buildings", "construction", "tools"]),
                        ("sheets-b", "contact_sheets.py", ["nature", "props"]),
                        ("sheets-c", "contact_sheets.py", ["characters"]),
                        ("sheets-d", "contact_sheets.py", ["icons"])])
    run_group(blender, [("verify", "verify.py", [])])
    shutil.rmtree(TMP, ignore_errors=True)
    print(f"build_all: done in {time.time() - start:.0f} s. Contact sheets in {REPO / 'out' / 'art'}", flush=True)


if __name__ == "__main__":
    main()
