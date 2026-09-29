class_name TownHallDiscovery
extends RefCounted
## Finds a running Town Hall: where to connect and the session token (PROTOCOL.md, Connection).
##
## Desktop, first match wins:
## 1. AURELHAVEN_RUNTIME, a path to a runtime file (tests and tools);
## 2. <config dir>/Aurelhaven/runtime.json, the copy the Town Hall writes for clients
##    (%APPDATA% on Windows, ~/Library/Application Support on macOS, ~/.config elsewhere);
## 3. the development layout: townhall/data/runtime.json next to the client project, seen from
##    the editor (res://) or from an exported build in client/export/<platform>/.
## A runtime file is {pid, port, token, url, data_dir}; the Town Hall writes a new token on every
## start, so the file is read again before every connection attempt.
##
## Web: the page is served by the Town Hall itself, which puts the token in the URL fragment
## (#t=<token>). It is moved into sessionStorage and cleared from the address bar, so a reload
## of the same tab still connects while the token never stays visible or in history.

const RUNTIME_ENV := "AURELHAVEN_RUNTIME"
const FILE_NAME := "runtime.json"
const TOKEN_KEY := "aurelhaven_token"


## {"host": String, "port": int, "token": String, "source": String}, or {} when none is found.
static func find() -> Dictionary:
	if OS.has_feature("web"):
		return _from_page()
	for path in candidate_paths():
		var info := read_runtime_file(path)
		if not info.is_empty():
			return info
	return {}


static func candidate_paths() -> PackedStringArray:
	var out := PackedStringArray()
	var env := OS.get_environment(RUNTIME_ENV)
	if env != "":
		out.append(env)
	out.append(OS.get_config_dir().path_join("Aurelhaven").path_join(FILE_NAME))
	var project := ProjectSettings.globalize_path("res://")
	if project != "" and not OS.has_feature("template"):
		out.append(project.path_join("../townhall/data").path_join(FILE_NAME).simplify_path())
	var exe_dir := OS.get_executable_path().get_base_dir()
	if OS.has_feature("template") and exe_dir != "":
		out.append(exe_dir.path_join("../../../townhall/data").path_join(FILE_NAME).simplify_path())
	return out


## A runtime file's endpoint, or {} when there is none. A stale file (its Town Hall crashed)
## still gives an endpoint; connecting to it fails fast (Net's connect timeout) and Net keeps
## re-reading the files, so a newly started Town Hall is found.
static func read_runtime_file(path: String) -> Dictionary:
	if path == "" or not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parse_runtime(parsed, path)


static func parse_runtime(parsed: Variant, source: String) -> Dictionary:
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	var d: Dictionary = parsed
	var port := int(d.get("port", 0))
	var token := String(d.get("token", ""))
	if port <= 0 or port > 65535 or token == "":
		return {}
	return {"host": "127.0.0.1", "port": port, "token": token, "source": source}


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
	return {"host": host if host != "" else "127.0.0.1", "port": port, "token": token, "source": "page"}
