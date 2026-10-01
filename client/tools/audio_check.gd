extends SceneTree
## Renders every sound cue through the game's own mixer (the Audio autoload, the buses and the
## master limiter, every slider at 1) into WAV files, so the sounds can be reviewed without
## speakers, then prints a loudness table from ffmpeg's EBU R128 meter: peak momentary loudness
## (M), integrated (I), true peak (TP) and length, against each cue's target in cue_table.gd.
## Headless is fine (Godot's dummy driver still mixes):
##   <godot> --headless --path client -s res://tools/audio_check.gd [-- options]
## Options after "--":
##   --out=<dir>        where the WAVs go (default: out/audio_check at the repository root)
##   --only=cue,cue     just these cues
##   --variants         every file of each cue, not one take
##   --world            the world cues (Audio.play_at) at the centre of an RTS view, through
##                      the 3D listener: how they sound where the player looks
## Writes <out>/<cue>.wav (or <cue>_<n>.wav with --variants), <out>/all_cues.wav (every take in
## order, with a short pause between) and <out>/loudness.txt (the table). Exit code 1 when a
## take clips (true peak above -1 dBTP) or plays more than 3 dB off its target.
## ffmpeg comes from the FFMPEG environment variable or PATH; without it only the WAVs are made.

const CueTable = preload("res://audio/cue_table.gd")
const CueFiles = preload("res://audio/cue_files.gd")
const TAIL_S := 0.35
const GAP_S := 0.6
## The cues the town places in the world (Audio.play_at).
const WORLD_CUES := ["construct_hit", "chop", "gather_food", "drop_off", "wisp", "wall_rise"]
## The default RTS view: looking at the ground point FOCUS from about 30 tiles away.
const FOCUS := Vector3(64.0, 0.0, 64.0)

var _world_mode := false

var _args: PackedStringArray
var _ffmpeg := ""


func _initialize() -> void:
	_args = OS.get_cmdline_user_args()
	_run.call_deferred()


func _arg(arg_name: String, fallback: String) -> String:
	for a in _args:
		if a.begins_with("--%s=" % arg_name):
			return a.get_slice("=", 1)
	return fallback


## Plays at full volume: every slider at 1, whatever the player's own settings are.
class FullVolume:
	extends Node

	func get_value(key: String, fallback: Variant = null) -> Variant:
		return true if key == "audio/mute_unfocused" else (1.0 if key.begins_with("audio/") else fallback)


func _run() -> void:
	var out := _arg("out", ProjectSettings.globalize_path("res://").path_join("../out/audio_check").simplify_path())
	DirAccess.make_dir_recursive_absolute(out)
	var audio: Node = root.get_node("Audio")
	audio.set("playback", true)
	audio.set("unlocked", true)
	audio.set("enabled", true)
	var full := FullVolume.new()
	root.add_child(full)
	audio.set("_settings", full)
	audio.call("_apply_volumes")
	var rng: RandomNumberGenerator = audio.get("_rng")
	rng.seed = 4127
	var rec := AudioEffectRecord.new()
	rec.format = AudioStreamWAV.FORMAT_16_BITS
	AudioServer.add_bus_effect(0, rec)
	_ffmpeg = _find_ffmpeg()

	_world_mode = "--world" in _args
	if _world_mode:
		var cam := Camera3D.new()
		root.add_child(cam)
		var pitch := deg_to_rad(55.0)
		cam.look_at_from_position(FOCUS + Vector3(0.0, sin(pitch), cos(pitch)) * 30.0, FOCUS, Vector3.UP)
		cam.make_current()
		await process_frame
		audio.call("_ensure_world_pool")
		audio.call("_update_ear")
	var only := _arg("only", "")
	var cues: Array[String] = []
	for c: String in (WORLD_CUES if _world_mode else CueTable.CANONICAL):
		if only == "" or c in only.split(","):
			cues.append(c)
	var takes: Array[Dictionary] = []
	for cue in cues:
		var files: Array = CueFiles.FILES.get(cue, [])
		var count := files.size() if "--variants" in _args else 1
		for i in count:
			var file := "%s.wav" % cue if count == 1 else "%s_%d.wav" % [cue, i + 1]
			if _world_mode:
				file = "world_" + file
			var path := out.path_join(file)
			audio.set("_forced_variant", i if count > 1 else -1)
			var secs := await _render(audio, rec, cue, path)
			if secs < 0.0:
				print("audio_check: %s did not play" % cue)
				continue
			takes.append({"cue": cue, "path": path, "file": file})
			print("audio_check: %s (%.2f s)" % [file, secs])
	audio.set("_forced_variant", -1)
	audio.call("stop_all")
	AudioServer.remove_bus_effect(0, AudioServer.get_bus_effect_count(0) - 1)
	audio.set("_settings", null)
	full.queue_free()
	# let the mixer release every playback before quitting
	for i in 10:
		await process_frame
	var code := 0
	if _ffmpeg != "":
		code = _report(takes, out)
		_concat(takes, out.path_join("all_cues.wav"))
	else:
		print("audio_check: ffmpeg not found; WAVs written to %s, no loudness table" % out)
	quit(code)


## Records one cue on the Master bus. Returns its length in seconds, or -1 when it did not play.
func _render(audio: Node, rec: AudioEffectRecord, cue: String, path: String) -> float:
	audio.call("stop_all")
	audio.call("reset_cooldowns")
	await process_frame
	rec.set_recording_active(true)
	await process_frame
	var started := Time.get_ticks_msec()
	var played := bool(audio.call("play_at", cue, FOCUS)) if _world_mode else bool(audio.call("play", cue))
	if not played:
		rec.set_recording_active(false)
		return -1.0
	var longest := 0.0
	for v: Object in audio.call("_all_voices"):
		if String(v.get("cue")) == cue:
			longest = maxf(longest, float(v.get("ends")) - float(v.get("started")))
	while Time.get_ticks_msec() - started < int((longest + TAIL_S) * 1000.0):
		await process_frame
	rec.set_recording_active(false)
	var wav := rec.get_recording()
	if wav == null:
		return -1.0
	wav.save_to_wav(path)
	return longest


func _find_ffmpeg() -> String:
	var env := OS.get_environment("FFMPEG")
	for candidate in ([env] if env != "" else []) + ["ffmpeg"]:
		var output: Array = []
		if OS.execute(candidate, ["-hide_banner", "-version"], output, true) == 0:
			return candidate
	return ""


## EBU R128 numbers for a file: M (peak momentary), I, TP and its length.
func _measure(path: String) -> Dictionary:
	var output: Array = []
	OS.execute(_ffmpeg, ["-hide_banner", "-nostats", "-v", "verbose", "-i", path, "-af",
		"apad=pad_dur=0.5,ebur128=peak=true:framelog=verbose", "-f", "null", "-"], output, true)
	var text := "\n".join(PackedStringArray(output))
	var m := -INF
	var re := RegEx.create_from_string(" M:\\s*(-?[0-9.]+)")
	for hit in re.search_all(text):
		m = maxf(m, float(hit.get_string(1)))
	var summary := text.substr(text.rfind("Summary:"))
	var i := RegEx.create_from_string("I:\\s*(-?[0-9.]+)\\s*LUFS").search(summary)
	var tp := RegEx.create_from_string("Peak:\\s*(-?[0-9.]+|-inf)\\s*dBFS").search(summary)
	var dur := RegEx.create_from_string("Duration: (\\d+):(\\d+):([0-9.]+)").search(text)
	var secs := 0.0
	if dur != null:
		secs = float(dur.get_string(1)) * 3600.0 + float(dur.get_string(2)) * 60.0 + float(dur.get_string(3))
	return {
		"M": m,
		"I": float(i.get_string(1)) if i != null else -INF,
		"TP": float(tp.get_string(1)) if tp != null and tp.get_string(1) != "-inf" else -INF,
		"sec": secs,
	}


func _report(takes: Array[Dictionary], out: String) -> int:
	var lines: PackedStringArray = []
	lines.append("Aurelhaven sound cues through the game mixer (every slider at 1). Loudness in LUFS (EBU R128):")
	lines.append("M = peak momentary (400 ms), I = integrated, TP = true peak (dBTP). target = cue_table.gd lufs.")
	lines.append("")
	lines.append("%-24s %-6s %6s %7s %7s %7s %7s  %s" % ["take", "bus", "sec", "target", "M", "I", "TP", "check"])
	var bad := 0
	for t in takes:
		var def := CueTable.get_cue(String(t["cue"]))
		var r := _measure(String(t["path"]))
		var target := float(def["lufs"])
		var notes: PackedStringArray = []
		if float(r["TP"]) > -1.0:
			notes.append("CLIPS")
		if absf(float(r["M"]) - target) > 3.0:
			notes.append("OFF TARGET")
		if not notes.is_empty():
			bad += 1
		lines.append("%-24s %-6s %6.2f %7.1f %7.1f %7.1f %7.1f  %s" % [String(t["file"]).get_basename(), String(def["bus"]),
			float(r["sec"]), target, float(r["M"]), float(r["I"]), float(r["TP"]), "ok" if notes.is_empty() else ", ".join(notes)])
	lines.append("")
	lines.append("Music and ambience (the files; in game the music plays %+.1f dB and the beds %+.1f dB over them):" % [
		float(root.get_node("Audio").get("MUSIC_DB")), float(root.get_node("Audio").get("AMBIENCE_DB"))])
	var long_files: Array[String] = []
	for t: Dictionary in CueFiles.MUSIC:
		long_files.append(String(t["path"]))
	for bed: String in CueFiles.AMBIENCE:
		long_files.append(String((CueFiles.AMBIENCE[bed] as Dictionary)["path"]))
	for p in long_files:
		var r := _measure(ProjectSettings.globalize_path(p))
		lines.append("%-24s %-6s %6.1f %7s %7.1f %7.1f %7.1f" % [p.get_file().get_basename(), "Music" if "/music/" in p else "Amb.",
			float(r["sec"]), "", float(r["M"]), float(r["I"]), float(r["TP"])])
	lines.append("")
	lines.append("%d take(s), %d flagged." % [takes.size(), bad])
	var text := "\n".join(lines)
	print(text)
	var f := FileAccess.open(out.path_join("loudness.txt"), FileAccess.WRITE)
	if f != null:
		f.store_string(text + "\n")
		f.close()
	return 1 if bad > 0 else 0


## Every take in order with a pause between, in one file to listen through.
func _concat(takes: Array[Dictionary], dest: String) -> void:
	if takes.is_empty():
		return
	var ffargs: PackedStringArray = ["-hide_banner", "-v", "error", "-y"]
	var chain := ""
	for i in takes.size():
		ffargs.append_array(["-i", String(takes[i]["path"])])
		chain += "[%d:a]apad=pad_dur=%.2f[a%d];" % [i, GAP_S, i]
	for i in takes.size():
		chain += "[a%d]" % i
	chain += "concat=n=%d:v=0:a=1[out]" % takes.size()
	ffargs.append_array(["-filter_complex", chain, "-map", "[out]", dest])
	var output: Array = []
	if OS.execute(_ffmpeg, ffargs, output, true) != 0:
		print("audio_check: could not write %s" % dest)
	else:
		print("audio_check: wrote %s" % dest)
