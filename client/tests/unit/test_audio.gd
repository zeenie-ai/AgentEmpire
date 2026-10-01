extends GutTest
## The Audio autoload: the cue table and its files, the buses and the volume mapping,
## cooldowns, voice limits and priorities, the button and window hooks, and the Realm hooks.
## Headless runs use the dummy driver, so voices are tracked but nothing is heard.

const CueTable = preload("res://audio/cue_table.gd")
const CueFiles = preload("res://audio/cue_files.gd")

var _played: Array[String] = []


## Stands in for the Settings autoload while the bus volumes are checked, so the player's
## settings file is never written.
class FakeSettings:
	extends Node
	var values: Dictionary = {}

	func get_value(key: String, fallback: Variant = null) -> Variant:
		return values.get(key, fallback)


func before_each() -> void:
	_played.clear()
	Audio.stop_all()
	Audio.reset_cooldowns()
	Audio.enabled = true
	Audio.unlocked = true
	Audio.assume_town = false
	if not Audio.cue_played.is_connected(_on_cue):
		Audio.cue_played.connect(_on_cue)


func after_each() -> void:
	Audio.stop_all()
	Audio.reset_cooldowns()
	Audio.assume_town = false
	if Audio.cue_played.is_connected(_on_cue):
		Audio.cue_played.disconnect(_on_cue)


func _on_cue(cue: String) -> void:
	_played.append(cue)


# --- the cue table and its files ----------------------------------------------------------------

func test_every_canonical_cue_is_in_the_table() -> void:
	for cue: String in CueTable.CANONICAL:
		assert_true(CueTable.CUES.has(cue), "%s has no entry in cue_table.gd" % cue)
	for cue: String in CueTable.CUES:
		assert_true(cue in CueTable.CANONICAL, "%s is in cue_table.gd but not canonical" % cue)
	assert_eq(CueTable.CANONICAL.size(), 47)


func test_every_canonical_cue_resolves_to_a_stream() -> void:
	for cue: String in CueTable.CANONICAL:
		var files: Array = CueFiles.FILES.get(cue, [])
		assert_gt(files.size(), 0, "%s has no files" % cue)
		for entry: Array in files:
			var path := String(entry[0])
			assert_true(ResourceLoader.exists(path), "%s: %s is missing" % [cue, path])
			var s := load(path) as AudioStream
			assert_not_null(s, "%s: %s does not load as an AudioStream" % [cue, path])
			if s != null:
				assert_gt(s.get_length(), 0.01, "%s: %s is empty" % [cue, path])
			# measured loudness and true peak come with every file
			assert_between(float(entry[1]), -60.0, -6.0, "%s: odd loudness for %s" % [cue, path])
			assert_lt(float(entry[2]), 0.0, "%s: %s clips" % [cue, path])
		assert_true(Audio.has_cue(cue), "Audio does not know %s" % cue)


func test_no_cue_plays_far_louder_than_its_peers_or_clips() -> void:
	for cue: String in CueTable.CANONICAL:
		var def := CueTable.get_cue(cue)
		assert_between(float(def["lufs"]), -40.0, -12.0, "%s: target loudness out of range" % cue)
		for entry: Array in CueFiles.FILES.get(cue, []):
			var gain := Audio.file_gain(float(def["lufs"]), float(entry[1]), float(entry[2]))
			assert_lte(float(entry[2]) + gain, -1.0 + 0.001, "%s: %s would pass -1 dBTP" % [cue, entry[0]])
			# a file that cannot reach its target (peak-limited) falls short by a few dB at most
			assert_gt(float(entry[1]) + gain, float(def["lufs"]) - 7.0, "%s: %s plays far below its target" % [cue, entry[0]])


func test_music_and_ambience_files_exist() -> void:
	assert_gt(CueFiles.MUSIC.size(), 2, "a playlist of several tracks")
	for t: Dictionary in CueFiles.MUSIC:
		assert_true(ResourceLoader.exists(String(t["path"])), String(t["path"]))
		assert_almost_eq(float(t["lufs"]), -18.0, 1.0, "music is normalised to about -18 LUFS")
		assert_ne(String(t.get("author", "")), "")
	for bed: String in ["day", "night"]:
		assert_true(CueFiles.AMBIENCE.has(bed), "a %s ambience bed" % bed)
		var d: Dictionary = CueFiles.AMBIENCE[bed]
		var s := load(String(d["path"])) as AudioStream
		assert_not_null(s)
		if s != null:
			assert_gt(s.get_length(), 30.0, "a long bed, so the loop is not obvious")


func test_tuned_cues_do_not_vary_their_pitch() -> void:
	for cue: String in ["hand_bell", "alarm_bell", "warning_bell", "dawn_bell", "age_bells", "task_done",
			"reward", "rank_up", "ui_confirm", "approval_granted"]:
		assert_eq(float(CueTable.get_cue(cue)["pitch"]), 0.0, "%s is tuned" % cue)


# --- buses and volumes ----------------------------------------------------------------------------

func test_bus_layout_has_the_five_buses() -> void:
	for bus: String in ["Master", "Music", "SFX", "UI", "Ambience"]:
		var i := AudioServer.get_bus_index(bus)
		assert_gt(i, -1, "bus %s" % bus)
		if bus != "Master" and i > -1:
			assert_eq(String(AudioServer.get_bus_send(i)), "Master", "%s sends to Master" % bus)


func test_volume_mapping() -> void:
	assert_eq(Audio.volume_to_db(0.0), Audio.MUTE_DB, "0 mutes")
	assert_eq(Audio.volume_to_db(-1.0), Audio.MUTE_DB)
	assert_almost_eq(Audio.volume_to_db(1.0), 0.0, 0.001)
	assert_almost_eq(Audio.volume_to_db(0.5), -6.0206, 0.01, "linear amplitude")
	assert_almost_eq(Audio.volume_to_db(0.1), -20.0, 0.01)
	assert_almost_eq(Audio.volume_to_db(2.0), 0.0, 0.001, "above 1 is held at 1")


func test_file_gain_holds_the_true_peak() -> void:
	assert_almost_eq(Audio.file_gain(-20.0, -16.0, -7.0), -4.0, 0.001)
	assert_almost_eq(Audio.file_gain(-10.0, -16.0, -3.0), 2.0, 0.001, "never past -1 dBTP")


func test_settings_drive_the_bus_volumes() -> void:
	var fake := FakeSettings.new()
	add_child_autofree(fake)
	fake.values = {"audio/master": 1.0, "audio/music": 0.25, "audio/sfx": 0.0, "audio/ui": 0.5, "audio/ambience": 1.0,
		"audio/mute_unfocused": true}
	Audio._settings = fake
	Audio._apply_volumes()
	var music := AudioServer.get_bus_index("Music")
	var sfx := AudioServer.get_bus_index("SFX")
	var ui := AudioServer.get_bus_index("UI")
	assert_almost_eq(AudioServer.get_bus_volume_db(music), -12.04 - Audio._duck_db, 0.05)
	assert_false(AudioServer.is_bus_mute(music))
	assert_true(AudioServer.is_bus_mute(sfx), "0 mutes the bus")
	assert_almost_eq(AudioServer.get_bus_volume_db(ui), -6.02, 0.05)
	# live: a change applies at once
	fake.values["audio/sfx"] = 1.0
	Audio._on_setting_changed("audio/sfx", 1.0)
	assert_false(AudioServer.is_bus_mute(sfx))
	assert_almost_eq(AudioServer.get_bus_volume_db(sfx), 0.0, 0.05)
	Audio._settings = null
	Audio._apply_volumes()


# --- playing ----------------------------------------------------------------------------------------

func test_play_reports_unknown_and_locked_cues() -> void:
	assert_false(Audio.play("no_such_cue"))
	Audio.unlocked = false
	assert_false(Audio.play("ui_click"), "nothing plays before the web unlock")
	Audio.unlock()
	assert_true(Audio.unlocked)
	assert_true(Audio.play("ui_click"))
	Audio.enabled = false
	Audio.reset_cooldowns()
	assert_false(Audio.play("ui_click"))
	Audio.enabled = true


func test_cooldown_holds_a_cue_back() -> void:
	assert_true(Audio.play("hand_bell"))
	assert_false(Audio.play("hand_bell"), "the hand bell rings at most once a %.1f s" % float(CueTable.get_cue("hand_bell")["cooldown"]))
	Audio.reset_cooldowns()
	assert_false(Audio.play("hand_bell"), "and only one at a time")
	assert_eq(Audio.voices_of("hand_bell"), 1)


func test_voice_limit_drops_extra_world_sounds() -> void:
	var limit := int(CueTable.get_cue("construct_hit")["voices"])
	var n := 0
	for i in limit + 3:
		Audio.reset_cooldowns()
		if Audio.play_at("construct_hit", Vector3(10, 0, 10)):
			n += 1
	assert_eq(n, limit, "a busy town never stacks more than %d hammer blows" % limit)
	assert_eq(Audio.voices_of("construct_hit"), limit)


func test_voice_limit_restarts_the_oldest_ui_click() -> void:
	var limit := int(CueTable.get_cue("ui_click")["voices"])
	for i in limit + 2:
		Audio.reset_cooldowns()
		assert_true(Audio.play("ui_click"), "clicks always answer")
	assert_eq(Audio.voices_of("ui_click"), limit)


func test_variants_never_repeat_back_to_back() -> void:
	var files: Array = CueFiles.FILES["chop"]
	assert_gt(files.size(), 1)
	var last := ""
	for i in 40:
		var entry: Array = Audio._pick("chop", files)
		assert_ne(String(entry[0]), last)
		last = String(entry[0])


func test_alerts_take_a_voice_from_lower_priorities() -> void:
	# fill the flat pool with feedback sounds
	var fillers := ["ui_open", "ui_close", "ui_click", "build_start", "task_started", "scroll_delivered", "placement_ok", "trade",
		"select_townsfolk", "select_agent", "select_building", "command_move", "command_gather", "command_build",
		"task_sent", "ui_confirm", "ui_error", "placement_bad"]
	var playing := 0
	for pass_i in 3:
		for cue: String in fillers:
			Audio.reset_cooldowns()
			if Audio.play(cue):
				playing += 1
	assert_gte(playing, Audio.POOL_FLAT, "the pool is full")
	Audio.reset_cooldowns()
	assert_true(Audio.play("alarm_bell"), "an alarm always gets through")
	assert_eq(Audio.voices_of("alarm_bell"), 1)


func test_world_sounds_beyond_their_range_are_not_played() -> void:
	var cam := Camera3D.new()
	add_child_autofree(cam)
	cam.look_at_from_position(Vector3(0, 30, 20), Vector3.ZERO, Vector3.UP)
	cam.make_current()
	Audio._ensure_world_pool()
	Audio._update_ear()
	var range_m := float(CueTable.get_cue("chop")["range"])
	assert_false(Audio.play_at("chop", Vector3(range_m * 3.0, 0, 0)), "far off: not played")
	Audio.reset_cooldowns()
	assert_true(Audio.play_at("chop", Vector3(1, 0, 1)), "near the view: played")


# --- buttons and windows ---------------------------------------------------------------------------

func test_a_button_press_clicks() -> void:
	await wait_process_frames(1)
	var b := Button.new()
	add_child_autofree(b)
	b.pressed.emit()
	await wait_physics_frames(2)
	assert_has(_played, "ui_click")


func test_a_cue_in_the_same_frame_replaces_the_click() -> void:
	await wait_process_frames(1)
	var b := Button.new()
	add_child_autofree(b)
	b.pressed.emit()
	Audio.play("ui_confirm")
	await wait_physics_frames(2)
	assert_has(_played, "ui_confirm")
	assert_does_not_have(_played, "ui_click", "one sound per press")


func test_a_cue_played_just_before_the_press_handler_also_replaces_the_click() -> void:
	await wait_process_frames(1)
	var b := Button.new()
	# connected before the button enters the tree, so it runs before the Audio hook
	b.pressed.connect(func() -> void: Audio.play("command_build"))
	add_child_autofree(b)
	b.pressed.emit()
	await wait_physics_frames(2)
	assert_has(_played, "command_build")
	assert_does_not_have(_played, "ui_click")


func test_a_silent_button_stays_quiet() -> void:
	var b := Button.new()
	b.set_meta("audio_silent", true)
	add_child_autofree(b)
	b.pressed.emit()
	await wait_physics_frames(2)
	assert_does_not_have(_played, "ui_click")


func test_windows_open_and_close_with_a_sound() -> void:
	var w := WindowFrame.new()
	add_child(w)
	assert_has(_played, "ui_open")
	Audio.reset_cooldowns()
	w.close()
	assert_has(_played, "ui_close")
	await wait_seconds(0.3)
	if is_instance_valid(w):
		w.free()


# --- the Town Hall's news ---------------------------------------------------------------------------

func _task(state: String, extra: Dictionary = {}) -> Dictionary:
	var t := {"id": "tsk_1", "agent_id": "agt_1", "state": state, "parent_task_id": null}
	t.merge(extra, true)
	return t


func _cue_after(fn: Callable) -> Array[String]:
	_played.clear()
	Audio.stop_all()
	Audio.reset_cooldowns()
	fn.call()
	return _played.duplicate()


func test_task_states_play_their_cues() -> void:
	Audio.assume_town = true
	assert_eq(_cue_after(func() -> void: Audio._on_task_changed(_task("in_transit"), "")), ["task_sent"] as Array[String])
	assert_eq(_cue_after(func() -> void: Audio._on_task_changed(_task("queued"), "")), ["task_sent"] as Array[String], "express")
	assert_eq(_cue_after(func() -> void: Audio._on_task_changed(_task("queued"), "in_transit")), ["scroll_delivered"] as Array[String])
	assert_eq(_cue_after(func() -> void: Audio._on_task_changed(_task("preparing"), "queued")), ["task_started"] as Array[String])
	assert_eq(_cue_after(func() -> void: Audio._on_task_changed(_task("running"), "preparing")), [] as Array[String], "already started")
	assert_eq(_cue_after(func() -> void: Audio._on_task_changed(_task("running"), "awaiting_approval")), [] as Array[String])
	assert_eq(_cue_after(func() -> void: Audio._on_task_changed(_task("failed"), "running")), ["task_failed"] as Array[String])
	assert_eq(_cue_after(func() -> void: Audio._on_task_changed(_task("queued"), "awaiting_review")), ["sent_back"] as Array[String])
	# reward and task_done are TownLink's
	assert_eq(_cue_after(func() -> void: Audio._on_task_changed(_task("awaiting_review"), "running")), [] as Array[String])
	assert_eq(_cue_after(func() -> void: Audio._on_task_changed(_task("accepted"), "accepting")), [] as Array[String])
	# a party sub-task created by delegation is not the player's
	assert_eq(_cue_after(func() -> void: Audio._on_task_changed(_task("queued", {"parent_task_id": "tsk_0"}), "")), [] as Array[String])


func test_nothing_rings_for_an_offline_town() -> void:
	Audio.assume_town = false
	assert_eq(_cue_after(func() -> void: Audio._on_task_changed(_task("failed"), "running")), [] as Array[String])


func test_approval_answers_play_only_for_the_player() -> void:
	Audio.assume_town = true
	assert_eq(_cue_after(func() -> void: Audio._on_approval_resolved("apv_1", {"decision": "allow", "by": "player"})),
		["approval_granted"] as Array[String])
	assert_eq(_cue_after(func() -> void: Audio._on_approval_resolved("apv_2", {"decision": "deny", "by": "player"})),
		["approval_denied"] as Array[String])
	assert_eq(_cue_after(func() -> void: Audio._on_approval_resolved("apv_3", {"decision": "allow", "by": "rule"})),
		[] as Array[String], "rules settle quietly")


func test_incidents_ring_their_bells() -> void:
	Audio.assume_town = true
	for kind: String in ["alarm_bell", "font_dark", "rift", "smoke"]:
		assert_eq(_cue_after(func() -> void: Audio._on_incident_opened({"id": "inc", "kind": kind, "subject": {}})),
			[kind] as Array[String])
	assert_eq(_cue_after(func() -> void: Audio._on_incident_opened({"id": "inc", "kind": "dim_lanterns", "subject": {}})),
		[] as Array[String], "the lanterns follow the Mana level")


func test_hand_bell_incident_rings_only_without_an_approval() -> void:
	Audio.assume_town = true
	var incident := {"id": "inc_h", "kind": "hand_bell", "subject": {"agent_id": "agt_1", "task_id": "tsk_seal"}}
	assert_eq(_cue_after(func() -> void: Audio._on_incident_opened(incident)), ["hand_bell"] as Array[String], "a spent seal")
	Realm.approvals["apv_x"] = {"id": "apv_x", "task_id": "tsk_seal", "status": "pending"}
	assert_eq(_cue_after(func() -> void: Audio._on_incident_opened(incident)), [] as Array[String],
		"an approval's bell is TownLink's")
	Realm.approvals.erase("apv_x")


func test_mana_thresholds() -> void:
	Audio.assume_town = true
	Audio._mana_level = ""
	Audio._mana_period = ""
	var m := {"level": "normal", "period_start": "2026-10-01T06:00:00Z"}
	assert_eq(_cue_after(func() -> void: Audio._on_mana_changed(m)), [] as Array[String], "the first reading is a baseline")
	m = {"level": "dim", "period_start": "2026-10-01T06:00:00Z"}
	assert_eq(_cue_after(func() -> void: Audio._on_mana_changed(m)), ["lanterns_dim"] as Array[String], "25%")
	m = {"level": "warning", "period_start": "2026-10-01T06:00:00Z"}
	assert_eq(_cue_after(func() -> void: Audio._on_mana_changed(m)), ["warning_bell"] as Array[String], "10%")
	m = {"level": "warning", "period_start": "2026-10-01T06:00:00Z"}
	assert_eq(_cue_after(func() -> void: Audio._on_mana_changed(m)), [] as Array[String], "no change, no bell")
	m = {"level": "normal", "period_start": "2026-10-02T06:00:00Z"}
	assert_eq(_cue_after(func() -> void: Audio._on_mana_changed(m)), ["dawn_bell"] as Array[String], "the refill")


func test_research_and_new_ages() -> void:
	Audio.assume_town = true
	Audio._age = 1
	Audio._researching = false
	assert_eq(_cue_after(func() -> void: Audio._on_age_changed({"current": 1, "research": {"target": 2}})),
		["research_start"] as Array[String])
	assert_eq(_cue_after(func() -> void: Audio._on_age_changed({"current": 2, "research": null})), ["age_bells"] as Array[String])


func test_rank_up_and_party_formed() -> void:
	Audio.assume_town = true
	Audio._ranks.clear()
	assert_eq(_cue_after(func() -> void: Audio._on_agent_changed({"id": "agt_r", "rank": "F"})), [] as Array[String], "new agent")
	assert_eq(_cue_after(func() -> void: Audio._on_agent_changed({"id": "agt_r", "rank": "E"})), ["rank_up"] as Array[String])
	assert_eq(_cue_after(func() -> void: Audio._on_agent_changed({"id": "agt_r", "rank": "E"})), [] as Array[String])
	Realm.parties["pty_t"] = {"id": "pty_t", "lead_agent_id": "agt_r", "member_ids": []}
	assert_eq(_cue_after(func() -> void: Audio._on_realm_changed("party", "pty_t")), ["party_formed"] as Array[String])
	assert_eq(_cue_after(func() -> void: Audio._on_realm_changed("party", "pty_t")), [] as Array[String], "an update, not a new party")
	Realm.parties.erase("pty_t")
	Audio._on_realm_changed("party", "pty_t")
	Audio._ranks.erase("agt_r")


func test_a_fresh_state_is_a_baseline() -> void:
	Audio.assume_town = true
	Realm.mana = {"level": "warning", "period_start": "2026-10-01T06:00:00Z"}
	Audio._on_realm_reset()
	assert_eq(_cue_after(func() -> void: Audio._on_mana_changed(Realm.mana)), [] as Array[String],
		"reconnecting at 10% does not ring the warning bell again")
	Realm.mana = {}
	Audio._on_realm_reset()
