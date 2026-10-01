extends SceneTree
## Switches the Town Hall between its modes the way the Esc menu does (Game.switch_town_hall_mode
## and Game.close_town_hall), against Town Halls started from this checkout's townhall/ with
## temporary data, and checks every step:
##   <godot> --headless --path client -s res://tools/townhall_mode_check.gd [-- --keep]
##
## The check runs in a child Godot whose APPDATA (user:// and the config folder) points into a
## temporary folder, with AURELHAVEN_DATA_ROOT there as well and the shared discovery copy off:
## the player's settings, saves and Town Halls are never touched. The parent waits for it, stops
## any Town Hall it left behind, removes the folder (unless --keep) and prints
## "TOWNHALL MODE CHECK OK" or "TOWNHALL MODE CHECK FAILED".
##
## The child: a stale practice runtime file is passed over and boot() starts a practice Town Hall;
## the town is saved; switch to real (the practice Town Hall shuts down and ends, the real one
## starts and probes the harnesses; no agent task runs); a practice Town Hall that cannot start
## (a bad AURELHAVEN_PORT) leaves an offline town and a toast; switch to practice again reopens
## the saved practice town; close_town_hall() leaves an offline town and no Town Hall running.

const TIMEOUT_S := 360.0
const SEED := 4127
## A process id no Town Hall has (a stale runtime file names it).
const DEAD_PID := 2147483644

var _root := ""
var _failures: Array[String] = []
var _toasts: Array[String] = []
var _modes: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	if "--child" in args:
		_root = _arg(args, "--root=")
		await _child()
		_log("mode-check: %s" % ("OK" if _failures.is_empty() else "FAILED: " + "; ".join(_failures)))
		quit(0 if _failures.is_empty() else 1)
		return
	quit(await _parent("--keep" in args))


static func _arg(args: PackedStringArray, prefix: String) -> String:
	for a in args:
		if a.begins_with(prefix):
			return a.substr(prefix.length())
	return ""


# --- the parent: an isolated child, then clean-up -------------------------------------------------

func _parent(keep: bool) -> int:
	_root = OS.get_temp_dir().path_join("aurelhaven-modecheck-%08x" % (randi() & 0x7fffffff))
	for d in ["appdata", "data/practice", "work"]:
		DirAccess.make_dir_recursive_absolute(_root.path_join(d))
	var env := {
		"APPDATA": _root.path_join("appdata"),
		"XDG_CONFIG_HOME": _root.path_join("appdata"),
		"XDG_DATA_HOME": _root.path_join("appdata"),
		"AURELHAVEN_DATA_ROOT": _root.path_join("data"),
		"AURELHAVEN_DISCOVERY_FILE": "off",
		"AURELHAVEN_PORT": "0",
		"AURELHAVEN_LOG_LEVEL": "warn",
		"AURELHAVEN_WORK_ROOTS": _root.path_join("work"),
	}
	for k: String in env:
		OS.set_environment(k, String(env[k]))
	for k in ["AURELHAVEN_RUNTIME", "AURELHAVEN_DATA_DIR", "AURELHAVEN_PROVIDER"]:
		OS.unset_environment(k)
	print("== Town Hall mode check in %s" % _root)
	var exe := OS.get_environment("GODOT") if OS.get_environment("GODOT") != "" else OS.get_executable_path()
	var args := PackedStringArray(["--headless", "--path", ProjectSettings.globalize_path("res://"), "-s", "res://tools/townhall_mode_check.gd",
		"--", "--child", "--root=" + _root])
	var pid := OS.create_process(exe, args, false)
	if pid <= 0:
		print("TOWNHALL MODE CHECK FAILED: could not start %s" % exe)
		return 1
	var log_path := _root.path_join("child.log")
	var shown := 0
	var deadline := Time.get_ticks_msec() + int(TIMEOUT_S * 1000.0)
	while OS.is_process_running(pid) and Time.get_ticks_msec() < deadline:
		shown = _echo(log_path, shown)
		await create_timer(0.25).timeout
	shown = _echo(log_path, shown)
	var code := -1
	if OS.is_process_running(pid):
		print("   the check did not finish within %d s" % int(TIMEOUT_S))
		OS.kill(pid)
	else:
		code = OS.get_process_exit_code(pid)
	var leftovers := _stop_leftovers()
	var ok := code == 0 and leftovers == 0
	if keep or not ok:
		print("== Kept %s" % _root)
	else:
		_remove_tree(_root)
		if DirAccess.dir_exists_absolute(_root):
			print("   could not remove %s" % _root)
	print("TOWNHALL MODE CHECK %s" % ("OK" if ok else "FAILED (exit code %d, %d Town Hall(s) left running)" % [code, leftovers]))
	return 0 if ok else 1


## Prints what the child wrote since `from`; returns the new offset.
func _echo(path: String, from: int) -> int:
	if not FileAccess.file_exists(path):
		return from
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return from
	var size := f.get_length()
	if size > from:
		f.seek(from)
		var text := f.get_buffer(size - from).get_string_from_utf8()
		for line in text.split("\n", false):
			print("   " + line)
		from = size
	f.close()
	return from


## Ends any Town Hall still listed in the check's data folders (there should be none).
func _stop_leftovers() -> int:
	var n := 0
	for rel in ["data/runtime.json", "data/practice/runtime.json"]:
		var path := _root.path_join(rel)
		if not FileAccess.file_exists(path):
			continue
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
		var pid := J.gi(J.d(parsed), "pid")
		if pid > 0 and _alive(pid):
			print("   LEFTOVER Town Hall (pid %d, %s): stopping it" % [pid, rel])
			OS.kill(pid)
			n += 1
	return n


func _remove_tree(path: String) -> void:
	for attempt in 20:
		_remove_inside(path)
		DirAccess.remove_absolute(path)
		if not DirAccess.dir_exists_absolute(path):
			return
		OS.delay_msec(250)


func _remove_inside(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.include_hidden = true
	for f in dir.get_files():
		DirAccess.remove_absolute(path.path_join(f))
	for d in dir.get_directories():
		_remove_inside(path.path_join(d))
		DirAccess.remove_absolute(path.path_join(d))


# --- the child: the game's own code, step by step --------------------------------------------------

func _child() -> void:
	var game: Node = root.get_node("Game")
	var net: Node = root.get_node("Net")
	var realm: Node = root.get_node("Realm")
	var settings: Node = root.get_node("Settings")
	var notify: Node = root.get_node("Notify")
	notify.toast.connect(_on_toast)
	game.town_hall_mode_changed.connect(_on_mode)
	var data := _root.path_join("data")
	var practice := data.path_join("practice")

	_check(OS.get_user_data_dir().begins_with(_root), "user:// is the temporary one (%s)" % OS.get_user_data_dir())
	_check(settings.get_value("townhall/provider", "") == "fake", "a fresh profile starts in practice mode")
	if not _failures.is_empty():
		return

	# A stale practice runtime file: its Town Hall is gone. Boot must start a new one anyway.
	_write(practice.path_join("runtime.json"), JSON.stringify({"pid": DEAD_PID, "port": 9, "token": "stale", "url": "", "data_dir": practice}))
	_step("boot (a stale practice runtime file is in the way)")
	await game.boot(SEED)
	_check(game.is_online_town(), "boot opened the Town Hall's town")
	_check(game.town_hall_mode() == "fake", "the practice Town Hall answers (mode %s)" % game.town_hall_mode())
	_check(game.town_hall_launched_by_game(), "the game started it")
	_check(_same(net.endpoint.get("data_dir", ""), practice), "it keeps its data in %s" % practice)
	if not _failures.is_empty():
		return
	var practice_town := String(game.world.town_id)
	var practice_pid := J.gi(net.endpoint, "pid")
	_step("practice town %s, Town Hall pid %d" % [practice_town, practice_pid])
	var save: NetRequest = game.link.save_now()
	await save.done
	_check(save.ok, "the practice town is saved")

	_step("switch to real")
	await game.switch_town_hall_mode("real")
	_check(_gone(practice.path_join("runtime.json"), practice_pid), "the practice Town Hall shut down and ended")
	_check(game.is_online_town() and game.town_hall_mode() == "real", "the real Town Hall's town is open (mode %s)" % game.town_hall_mode())
	_check(game.town_hall_launched_by_game(), "the game started the real Town Hall")
	_check(_same(net.endpoint.get("data_dir", ""), data), "it keeps its data in %s" % data)
	_check(settings.get_value("townhall/provider", "") == "real", "townhall/provider is now real")
	_check(game.world != null and String(game.world.town_id) != practice_town, "the real town is not the practice town")
	var providers: Array = realm.providers
	_check(providers.size() == 3, "the real Town Hall probed three harnesses")
	for p: Variant in providers:
		var d := J.d(p)
		_step("  %s: installed=%s signed_in=%s %s" % [J.gs(d, "id"), str(J.b(d.get("installed"))), str(J.b(d.get("logged_in"))), J.gs(d, "message")])
	_check(not J.gd(realm.town_progress, "age").is_empty(), "the Town Hall sent its progress (protocol 1.3)")
	var real_pid := J.gi(net.endpoint, "pid")

	_step("switch to practice with a Town Hall that cannot start")
	_toasts.clear()
	OS.set_environment("AURELHAVEN_PORT", "not-a-port")
	await game.switch_town_hall_mode("fake")
	OS.set_environment("AURELHAVEN_PORT", "0")
	_check(_gone(data.path_join("runtime.json"), real_pid), "the real Town Hall shut down and ended")
	_check(game.world != null and not game.is_online_town(), "the player still has a town: an offline one")
	_check(game.town_hall_mode() == "", "no Town Hall is connected")
	_check(_toasts.any(func(t: String) -> bool: return t.contains("Could not open the practice Town Hall") and t.contains("AURELHAVEN_PORT")),
		"a toast said why")

	_step("switch to practice")
	await game.switch_town_hall_mode("fake")
	_check(game.is_online_town() and game.town_hall_mode() == "fake", "the practice Town Hall's town is open again")
	_check(game.world != null and String(game.world.town_id) == practice_town, "it is the saved practice town (%s)" % practice_town)
	var practice_pid2 := J.gi(net.endpoint, "pid")

	_step("close the Town Hall")
	await game.close_town_hall()
	_check(_gone(practice.path_join("runtime.json"), practice_pid2), "the practice Town Hall shut down and ended")
	_check(game.world != null and not game.is_online_town(), "the game plays on in an offline town")
	_check(game.town_hall_mode() == "", "no Town Hall is connected")
	_check(net.is_enabled(), "the game keeps looking for a Town Hall")

	var cfg := ConfigFile.new()
	_check(cfg.load("user://settings.cfg") == OK and String(cfg.get_value("townhall", "provider", "")) == "fake", "settings.cfg remembers practice")
	# Boot (practice), switch to real (closed, real), a failed start (closed), practice again, closed.
	var expected: Array[String] = ["fake", "", "real", "", "fake", ""]
	_check(_modes == expected, "town_hall_mode_changed went %s" % str(_modes))


func _on_toast(text: String, kind: String) -> void:
	_toasts.append("%s: %s" % [kind, text])
	_log("mode-check:     toast %s: %s" % [kind, text])


func _on_mode(mode: String) -> void:
	_modes.append(mode)


## True once the runtime file no longer names `pid` and the process has ended.
func _gone(runtime_path: String, pid: int) -> bool:
	if FileAccess.file_exists(runtime_path):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(runtime_path))
		if J.gi(J.d(parsed), "pid") == pid:
			return false
	return not _alive(pid)


## TownHallLauncher, loaded once the autoloads exist (a -s script compiles before them, and the
## launcher logs through ClientLog).
func _launcher() -> GDScript:
	return load("res://net/town_hall_launcher.gd")


func _alive(pid: int) -> bool:
	return bool(_launcher().call("process_alive", pid))


func _same(a: Variant, b: String) -> bool:
	return bool(_launcher().call("same_dir", J.s(a), b))


func _write(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _step(text: String) -> void:
	_log("mode-check: " + text)


func _check(ok: bool, what: String) -> void:
	_log("mode-check:   %s %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failures.append(what)


func _log(line: String) -> void:
	print(line)
	if _root == "":
		return
	var path := _root.path_join("child.log")
	var f := FileAccess.open(path, FileAccess.READ_WRITE) if FileAccess.file_exists(path) else FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return
	f.seek_end()
	f.store_string(line + "\n")
	f.close()
