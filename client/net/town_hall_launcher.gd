class_name TownHallLauncher
extends RefCounted
## Starts the Town Hall for the player when none is running (desktop only), so opening the game
## is enough. It looks for the townhall/ folder the way TownHallDiscovery looks for its runtime
## file (AURELHAVEN_TOWNHALL_DIR, next to the client project, or three folders up from an
## exported build in client/export/<platform>/) and runs townhall/scripts/launch.mjs, which
## starts the Town Hall detached (no console, no handles inherited from the game, output to
## <data dir>/townhall.log) and exits at once. The Town Hall keeps running after the game quits
## (agents work while the player is away); it writes its runtime file, which Net then finds.
## Settings: "townhall/auto_start" (on by default) and "townhall/provider" ("fake" runs the
## scripted stand-in agent, "real" the installed Claude Code, Codex and pi).

const DIR_ENV := "AURELHAVEN_TOWNHALL_DIR"


## The townhall folder, or "" when there is none (a web build, or a lone exported exe).
static func find_dir() -> String:
	if OS.has_feature("web"):
		return ""
	var candidates := PackedStringArray()
	var env := OS.get_environment(DIR_ENV)
	if env != "":
		candidates.append(env)
	var project := ProjectSettings.globalize_path("res://")
	if project != "" and not OS.has_feature("template"):
		candidates.append(project.path_join("../townhall").simplify_path())
	var exe_dir := OS.get_executable_path().get_base_dir()
	if OS.has_feature("template") and exe_dir != "":
		candidates.append(exe_dir.path_join("../../../townhall").simplify_path())
	for dir in candidates:
		if FileAccess.file_exists(dir.path_join("scripts/launch.mjs")) and FileAccess.file_exists(dir.path_join("node_modules/tsx/dist/cli.mjs")):
			return dir
	return ""


## Starts the Town Hall. Returns the launcher's process id, or -1 when it could not start.
static func start(provider: String) -> int:
	var dir := find_dir()
	if dir == "":
		return -1
	OS.set_environment("AURELHAVEN_PROVIDER", provider)
	var pid := OS.create_process(_node(), PackedStringArray([dir.path_join("scripts/launch.mjs")]), false)
	if pid > 0:
		ClientLog.info("townhall", "Starting the Town Hall (%s agents) from %s." % [provider, dir])
	else:
		ClientLog.warn("townhall", "Could not start the Town Hall: is Node.js installed?")
	return pid


static func _node() -> String:
	return "node.exe" if OS.has_feature("windows") else "node"
