extends GutTest
## Offline saves on disk: the slot is replaced only by a complete save, the autosave phones and
## tablets make when the app goes to the background, and resuming it at the next start. Every
## save goes to a temporary folder (Game.save_dir), never to the player's slots.

var _dir: String = ""
## ClientLog lines before the test: _logged() reads only the lines written since.
var _log_from: int = 0


func before_each() -> void:
	_dir = OS.get_temp_dir().path_join("agentempire-gut-saves-%d" % (randi() & 0xffffff))
	Game.save_dir = _dir
	_log_from = ClientLog.lines.size()


func after_each() -> void:
	Game.stop_town()
	Game.paused = false
	Game.save_dir = Game.SAVE_DIR
	if DirAccess.dir_exists_absolute(_dir):
		for d in DirAccess.get_directories_at(_dir):
			DirAccess.remove_absolute(_dir.path_join(d))
		for f in DirAccess.get_files_at(_dir):
			DirAccess.remove_absolute(_dir.path_join(f))
		DirAccess.remove_absolute(_dir)


func _json(d: Dictionary) -> String:
	return JSON.stringify(d, "", true, true)


func _write(slot_file: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(_dir)
	var f := FileAccess.open(_dir.path_join(slot_file), FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _read(slot_file: String) -> Dictionary:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(_dir.path_join(slot_file)))
	return parsed if typeof(parsed) == TYPE_DICTIONARY else {}


## An offline town with something going on: a townsperson in training, time passed.
func _busy_town(town_id: String) -> SimWorld:
	var w := Game.new_town(1234, town_id)
	Game.issue(GameCommands.train(w.keep_id, "townsfolk"))
	w.step(SimFixture.ticks(w, 5.0))
	return w


func _logged(line: String) -> bool:
	for l in ClientLog.lines.slice(_log_from):
		if l.ends_with(line):
			return true
	return false


func test_save_replaces_the_slot_and_loads_back_the_same_town() -> void:
	# An older save in the slot, and a temporary file left by a save that never finished.
	_write("quick.json", "{\"old\": true}")
	_write("quick.json.tmp", "{\"cut short")
	var w := _busy_town("gut-quick")
	var saved := _json(w.to_dict())
	var ledger := _json(Economy.ledger.to_dict())
	assert_true(await Game.save_offline("quick"))
	assert_false(FileAccess.file_exists(_dir.path_join("quick.json.tmp")), "the temporary file became the slot")
	var doc := _read("quick.json")
	assert_eq(String(doc.get("format", "")), "aurelhaven-offline")
	assert_false(doc.has("old"), "the older save was replaced")

	Game.new_town(99, "gut-other")
	assert_true(Game.load_offline("quick"))
	assert_eq(_json(Game.world.to_dict()), saved, "the loaded town is the saved one")
	assert_eq(_json(Economy.ledger.to_dict()), ledger, "and so is its treasury")


func test_a_save_that_cannot_be_written_leaves_the_slot_as_it_was() -> void:
	_write("quick.json", "{\"old\": true}")
	# A folder where the temporary file should go: the save cannot open it.
	DirAccess.make_dir_recursive_absolute(_dir.path_join("quick.json.tmp"))
	_busy_town("gut-blocked")
	assert_false(await Game.save_offline("quick"))
	assert_eq(FileAccess.get_file_as_string(_dir.path_join("quick.json")), "{\"old\": true}")


func test_the_paused_notification_autosaves_and_pauses_the_town() -> void:
	var w := _busy_town("gut-paused")
	assert_false(FileAccess.file_exists(_dir.path_join(Game.AUTOSAVE_SLOT + ".json")))
	Game.notification(NOTIFICATION_APPLICATION_PAUSED)
	var doc := _read(Game.AUTOSAVE_SLOT + ".json")
	var sim: Dictionary = doc.get("sim", {})
	assert_eq(String(sim.get("town_id", "")), "gut-paused", "the town was autosaved")
	assert_eq(int(sim.get("tick", -1)), w.tick)
	assert_true(Game.paused, "the town waits")
	assert_true(_logged("[game] Autosaved the town."), "quietly, in the log")


func test_autosave_needs_an_offline_town() -> void:
	assert_false(Game.autosave())
	assert_false(DirAccess.dir_exists_absolute(_dir), "nothing was written")


func test_resume_opens_the_autosaved_town() -> void:
	var w := _busy_town("gut-resume")
	var saved := _json(w.to_dict())
	assert_true(Game.autosave())
	Game.stop_town()
	var resumed := Game.resume_town(4242)
	assert_eq(resumed, Game.world)
	assert_eq(resumed.town_id, "gut-resume")
	assert_eq(_json(resumed.to_dict()), saved, "the resumed town is the autosaved one")
	assert_true(_logged("[game] Resumed the autosaved town."))


func test_resume_without_an_autosave_starts_a_new_town() -> void:
	var w := Game.resume_town(4242)
	assert_not_null(w)
	assert_eq(w.map_seed, 4242)
	assert_eq(w.tick, 0)


func test_resume_with_an_unreadable_autosave_starts_a_new_town() -> void:
	_write(Game.AUTOSAVE_SLOT + ".json", "{\"format\": \"aurelhaven-offline\", \"sim\": {\"tow")
	var w := Game.resume_town(4242)
	assert_engine_error("Parse JSON failed")
	assert_eq(w.map_seed, 4242)
	assert_true(_logged("[game] The autosaved town could not be read; starting a new one."))
