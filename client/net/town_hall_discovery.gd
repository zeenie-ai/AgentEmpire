class_name TownHallDiscovery
extends RefCounted
## Finds a running Town Hall: where to connect and the session token (PROTOCOL.md, Connection).
##
## Desktop, first match wins:
## 1. AURELHAVEN_RUNTIME, a path to a runtime file (tests and tools);
## 2. the runtime file of the preferred mode's Town Hall (TownHallLauncher: <data root> for real
##    agents, <data root>/practice for practice), so the game finds the town it means to open;
## 3. the copy the Town Hall writes for clients: AURELHAVEN_DISCOVERY_FILE ("off" skips it), else
##    <config dir>/AgentEmpire/runtime.json (%APPDATA% on Windows, ~/Library/Application Support
##    on macOS, ~/.config elsewhere);
## 4. the other mode's runtime file.
## A mode switch pins one runtime file instead (find(pinned)), so it waits for that Town Hall only.
## A runtime file is {pid, port, token, url, data_dir}; the Town Hall writes a new token on every
## start, so the file is read again before every connection attempt.
##
## Web: the page is served by the Town Hall itself, which puts the token in the URL fragment
## (#t=<token>). It is moved into sessionStorage and cleared from the address bar, so a reload
## of the same tab still connects while the token never stays visible or in history.

const RUNTIME_ENV := "AURELHAVEN_RUNTIME"
## The Town Hall's own setting for its discovery copy: a path, or "off".
const DISCOVERY_ENV := "AURELHAVEN_DISCOVERY_FILE"
const FILE_NAME := "runtime.json"
const TOKEN_KEY := "aurelhaven_token"


## {"host": String, "port": int, "token": String, "source": String, "pid": int, "data_dir": String},
## or {} when none is found. `pinned`: only that runtime file. `mode`: the preferred mode.
static func find(pinned: String = "", mode: String = "") -> Dictionary:
	if OS.has_feature("web"):
		return _from_page()
	var paths := PackedStringArray([pinned]) if pinned != "" else candidate_paths(mode)
	for path in paths:
		var info := read_runtime_file(path)
		if not info.is_empty():
			return info
	return {}


static func candidate_paths(mode: String = "") -> PackedStringArray:
	var out := PackedStringArray()
	var env := OS.get_environment(RUNTIME_ENV)
	if env != "":
		out.append(env)
	var preferred := TownHallLauncher.normalize_mode(mode) if mode != "" else ""
	if preferred != "":
		_add(out, TownHallLauncher.runtime_file_for(preferred))
	_add(out, discovery_copy())
	for m: String in [TownHallLauncher.MODE_REAL, TownHallLauncher.MODE_FAKE]:
		_add(out, TownHallLauncher.runtime_file_for(m))
	return out


## The shared copy of the runtime file, or "" when AURELHAVEN_DISCOVERY_FILE is "off".
static func discovery_copy() -> String:
	var env := OS.get_environment(DISCOVERY_ENV).strip_edges()
	if env.to_lower() == "off":
		return ""
	if env != "":
		return env
	return OS.get_config_dir().path_join("AgentEmpire").path_join(FILE_NAME)


static func _add(out: PackedStringArray, path: String) -> void:
	if path == "":
		return
	for existing in out:
		if TownHallLauncher.same_dir(existing, path):
			return
	out.append(path)


## A runtime file's endpoint, or {} when there is none. A stale file (its Town Hall crashed)
## still gives an endpoint; connecting to it fails fast (Net's connect timeout) and Net keeps
## re-reading the files, so a newly started Town Hall is found.
static func read_runtime_file(path: String) -> Dictionary:
	if path == "" or not FileAccess.file_exists(path):
		return {}
	# A Town Hall that stops removes its file and one that starts replaces it, so the file can be
	# gone or empty by the time it is read: read it without logging an error for that.
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var text := f.get_as_text()
	f.close()
	if text.strip_edges() == "":
		return {}
	var json := JSON.new()
	if json.parse(text) != OK:
		return {}
	return parse_runtime(json.data, path)


static func parse_runtime(parsed: Variant, source: String) -> Dictionary:
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	var d: Dictionary = parsed
	var port := J.gi(d, "port")
	var token := J.gs(d, "token")
	if port <= 0 or port > 65535 or token == "":
		return {}
	return {"host": "127.0.0.1", "port": port, "token": token, "source": source, "pid": J.gi(d, "pid"), "data_dir": J.gs(d, "data_dir")}


static func _from_page() -> Dictionary:
	var hash := String(JavaScriptBridge.eval("window.location.hash", true))
	var token := ""
	if hash.begins_with("#t="):
		token = hash.substr(3).uri_decode()
		JavaScriptBridge.eval("try { sessionStorage.setItem('%s', %s); } catch (e) {}" % [TOKEN_KEY, JSON.stringify(token)], true)
		JavaScriptBridge.eval("history.replaceState(null, '', window.location.pathname + window.location.search)", true)
	else:
		var stored: Variant = JavaScriptBridge.eval("(function () { try { return sessionStorage.getItem('%s') || ''; } catch (e) { return ''; } })()" % TOKEN_KEY, true)
		token = String(stored) if stored != null else ""
	if token == "":
		return {}
	var host := String(JavaScriptBridge.eval("window.location.hostname", true))
	var port := int(String(JavaScriptBridge.eval("window.location.port", true)))
	if port <= 0:
		return {}
	return {"host": host if host != "" else "127.0.0.1", "port": port, "token": token, "source": "page", "pid": 0, "data_dir": ""}
