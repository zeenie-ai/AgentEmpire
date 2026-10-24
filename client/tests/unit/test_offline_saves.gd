extends GutTest
## Offline saves on disk: the slot is replaced only by a complete save. Every save goes to a
## temporary folder (Game.save_dir), never to the player's slots.

var _dir: String = ""


func before_each() -> void:
	_dir = OS.get_temp_dir().path_join("agentempire-gut-saves-%d" % (randi() & 0xffffff))
	Game.save_dir = _dir


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
