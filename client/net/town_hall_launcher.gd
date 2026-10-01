class_name TownHallLauncher
extends RefCounted
## Starts the Town Hall for the player when none is running (desktop only), so opening the game
## is enough. It looks for the townhall/ folder the way TownHallDiscovery looks for its runtime
## file (AURELHAVEN_TOWNHALL_DIR, next to the client project, or three folders up from an
## exported build in client/export/<platform>/) and runs townhall/scripts/launch.mjs, which
## starts the Town Hall detached (no console, no handles inherited from the game, output to
## <data dir>/townhall.log) and exits at once. The Town Hall keeps running after the game quits
## (agents work while the player is away); it writes its runtime file, which Net then finds.
##
## Two modes, each with its own town: "fake" (practice: scripted stand-in agents) keeps its data
## in <data root>/practice, "real" (the installed Claude Code, Codex and pi) in <data root>
## itself. The data root is <townhall>/data, or AURELHAVEN_DATA_ROOT. Settings: "townhall/
## auto_start" (on by default) and "townhall/provider" (the mode to start).

const DIR_ENV := "AURELHAVEN_TOWNHALL_DIR"
## Where the Town Halls keep their data (tests and tools): real in it, practice in its practice/.
const DATA_ROOT_ENV := "AURELHAVEN_DATA_ROOT"
const MODE_REAL := "real"
const MODE_FAKE := "fake"
const PRACTICE_DIR := "practice"
## The line the Town Hall prints when it cannot start (townhall/src/main.ts).
const START_FAILED := "The Town Hall could not start: "
## ...unless another Town Hall already uses that data folder: that one is the one to connect to.
const ALREADY_RUNNING := "another Town Hall"


## The townhall folder, or "" when there is none (a web build, or a lone exported exe).
static func find_dir() -> String:
	for dir in _candidates():
		if FileAccess.file_exists(dir.path_join("scripts/launch.mjs")) and FileAccess.file_exists(dir.path_join("node_modules/tsx/dist/cli.mjs")):
			return dir
	return ""


static func _candidates() -> PackedStringArray:
	var candidates := PackedStringArray()
	if OS.has_feature("web"):
		return candidates
	var env := OS.get_environment(DIR_ENV)
	if env != "":
		candidates.append(env)
	var project := ProjectSettings.globalize_path("res://")
	if project != "" and not OS.has_feature("template"):
		candidates.append(project.path_join("../townhall").simplify_path())
	var exe_dir := OS.get_executable_path().get_base_dir()
	if OS.has_feature("template") and exe_dir != "":
		candidates.append(exe_dir.path_join("../../../townhall").simplify_path())
	return candidates


## "real" or "fake" (anything else counts as practice, the safe one).
static func normalize_mode(mode: String) -> String:
	return MODE_REAL if mode == MODE_REAL else MODE_FAKE


## Where the Town Halls keep their data: AURELHAVEN_DATA_ROOT, else <townhall>/data; "" when unknown.
static func data_root() -> String:
	var env := OS.get_environment(DATA_ROOT_ENV)
	if env != "":
		return env.replace("\\", "/").simplify_path()
	for dir in _candidates():
		if FileAccess.file_exists(dir.path_join("scripts/launch.mjs")):
			return dir.path_join("data")
	return ""


## The data folder of a mode's Town Hall ("" when the data root is unknown).
static func data_dir_for(mode: String) -> String:
	var root := data_root()
	if root == "":
		return ""
	return root if normalize_mode(mode) == MODE_REAL else root.path_join(PRACTICE_DIR)


## The runtime file a mode's Town Hall writes while it runs ("" when unknown).
static func runtime_file_for(mode: String) -> String:
	var dir := data_dir_for(mode)
	return dir.path_join("runtime.json") if dir != "" else ""


## Where a mode's Town Hall writes its output (launch.mjs appends to it).
static func log_file_for(mode: String) -> String:
	var dir := data_dir_for(mode)
	return dir.path_join("townhall.log") if dir != "" else ""


## The size of a file in bytes, 0 when it does not exist.
static func file_size(path: String) -> int:
	if path == "" or not FileAccess.file_exists(path):
		return 0
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return 0
	var n := f.get_length()
	f.close()
	return n


## Why a mode's Town Hall could not start, from what it wrote to its log after `since_bytes`
## (file_size() before the launch), or "" when it has not failed (yet). A Town Hall that found
## another one on its data folder is not a failure: that one is the Town Hall to connect to.
static func launch_failure(mode: String, since_bytes: int) -> String:
	var path := log_file_for(mode)
	var size := file_size(path)
	if size <= since_bytes:
		return ""
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	f.seek(since_bytes)
	var text := f.get_buffer(size - since_bytes).get_string_from_utf8()
	f.close()
	return failure_in(text)


## The reason in a Town Hall start failure line, or "".
static func failure_in(text: String) -> String:
	for line in text.split("\n"):
		var at := line.find(START_FAILED)
		if at < 0:
			continue
		var reason := line.substr(at + START_FAILED.length()).strip_edges()
		if reason.begins_with(ALREADY_RUNNING):
			continue
		return reason if reason != "" else "unknown error"
	return ""


## Starts a Town Hall in `mode` ("fake" or "real") on that mode's data folder. Returns the
## launcher's process id, or -1 when it could not start.
static func start(mode: String) -> int:
	var dir := find_dir()
	var data := data_dir_for(mode)
	if dir == "" or data == "":
		return -1
	mode = normalize_mode(mode)
	OS.set_environment("AURELHAVEN_PROVIDER", mode)
	OS.set_environment("AURELHAVEN_DATA_DIR", data)
	var pid := OS.create_process(_node(), PackedStringArray([dir.path_join("scripts/launch.mjs")]), false)
	if pid > 0:
		ClientLog.info("townhall", "Starting the Town Hall (%s agents) from %s on %s." % [mode, dir, data])
	else:
		ClientLog.warn("townhall", "Could not start the Town Hall: is Node.js installed?")
	return pid


## Whether a process is still running. Any process, not only the game's own children (Godot's
## OS.is_process_running only knows those): tasklist on Windows, kill -0 elsewhere. Blocks for
## a moment (a few hundred ms on Windows), so call it sparingly.
static func process_alive(pid: int) -> bool:
	if pid <= 0:
		return false
	var out: Array = []
	if OS.has_feature("windows"):
		var tasklist := OS.get_environment("SystemRoot").path_join("System32").path_join("tasklist.exe")
		var code := OS.execute(tasklist, PackedStringArray(["/FI", "PID eq %d" % pid, "/NH", "/FO", "CSV"]), out)
		var text := "".join(PackedStringArray(out))
		return code == 0 and text.contains("\"%d\"" % pid)
	return OS.execute("kill", PackedStringArray(["-0", str(pid)]), out) == 0


## True when two folder paths name the same folder (slashes, case on Windows, trailing slash).
static func same_dir(a: String, b: String) -> bool:
	if a == "" or b == "":
		return false
	var x := a.replace("\\", "/").simplify_path().trim_suffix("/")
	var y := b.replace("\\", "/").simplify_path().trim_suffix("/")
	if OS.has_feature("windows"):
		return x.to_lower() == y.to_lower()
	return x == y


static func _node() -> String:
	return "node.exe" if OS.has_feature("windows") else "node"
