extends GutTest
## Realm keeps the Town Hall's progress (protocol 1.3: get_state.progress and progress_updated),
## and Net reads which kind of Town Hall it is connected to from its hello features.

const PROGRESS := {
	"age": {"current": 1, "research": null},
	"facts": {"accepted": 2, "accepted_first_try": 1, "tools_built": 3, "rites_passed": 0, "party_tasks": 0, "under_baseline": 1},
	"next": {
		"n": 2, "id": "market", "name": "Market", "wall": "Merchant Ring",
		"cost": {"food": 400, "wood": 300, "stone": 150, "gold": 100}, "research_s": 90, "ready": false,
		"milestones": [
			{"key": "accepted", "label": "tasks accepted", "have": 2, "want": 3, "met": false},
			{"key": "tools_built", "label": "add-ons built", "have": 3, "want": 2, "met": true},
		],
	},
	"quartermaster": {"basic_rate": 0.95, "precious_rate": 1},
}

var seen: Array[Dictionary] = []


func before_each() -> void:
	Realm.clear()
	seen.clear()
	Realm.town_progress_changed.connect(_on_progress)


func after_each() -> void:
	Realm.town_progress_changed.disconnect(_on_progress)
	Realm.clear()


func _on_progress(p: Dictionary) -> void:
	seen.append(p)


func _state(extra: Dictionary) -> Dictionary:
	var s := {"seq": 7, "agents": [], "tools": [], "tasks": [], "approvals": [], "parties": [], "incidents": [],
		"mana": {}, "age": {"current": 1, "research": null}, "settings": {}, "providers": [], "treasury": {}, "town": null}
	s.merge(extra, true)
	return s


func test_a_full_state_brings_the_progress_and_announces_it() -> void:
	Realm.apply_state(_state({"progress": PROGRESS}))
	assert_eq(Realm.town_progress, PROGRESS)
	assert_eq(seen.size(), 1)
	var next: Dictionary = J.gd(Realm.town_progress, "next")
	assert_eq(J.gs(next, "wall"), "Merchant Ring")
	assert_eq(J.a(next.get("milestones")).size(), 2)


func test_progress_updated_replaces_the_progress() -> void:
	Realm.apply_state(_state({"progress": PROGRESS}))
	var updated := PROGRESS.duplicate(true)
	updated["quartermaster"] = {"basic_rate": 0.96, "precious_rate": 1}
	var kinds: Array[String] = []
	var on_changed := func(kind: String, _id: String) -> void: kinds.append(kind)
	Realm.changed.connect(on_changed)
	Realm.apply_event({"v": 1, "type": "progress_updated", "seq": 8, "payload": updated})
	Realm.changed.disconnect(on_changed)
	assert_eq(J.f(J.gd(Realm.town_progress, "quartermaster").get("basic_rate")), 0.96)
	assert_eq(seen.size(), 2)
	assert_eq(kinds, ["progress"] as Array[String])


func test_a_town_hall_older_than_1_3_leaves_the_progress_empty() -> void:
	Realm.apply_state(_state({}))
	assert_eq(Realm.town_progress, {})
	assert_eq(seen.size(), 1)


func test_the_town_hall_mode_comes_from_its_hello_features() -> void:
	assert_eq(Net.mode_from_features(["fake_provider", "replay", "progress"]), "fake")
	assert_eq(Net.mode_from_features(["real_providers", "shutdown"]), "real")
	assert_eq(Net.mode_from_features(["replay"]), "")
	assert_eq(Net.mode_from_features([]), "")
