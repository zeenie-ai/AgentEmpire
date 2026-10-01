extends GutTest
## The Town Hall's age, mirrored into the town by TownLink and shown in the world: research under
## way appears at the Keep (ResearchView), and when the age arrives the next ring rises.
## Everything runs synchronously inside the test (no frames pass while the town counts as the
## Town Hall's), and the Game, TownLink and Realm autoloads are put back afterwards.

var game: Node
var realm: Node


func before_each() -> void:
	game = get_tree().root.get_node("Game")
	realm = get_tree().root.get_node("Realm")


func _age_event(current: int, research: Variant) -> Dictionary:
	return {"type": "age_updated", "payload": {"age": {"current": current, "research": research}}}


func _iso(unix: int) -> String:
	return Time.get_datetime_string_from_unix_time(unix) + ".000Z"


func test_research_then_the_age_arrives() -> void:
	var w := SimFixture.generated_world(4127)
	var view := WorldView.new()
	add_child_autofree(view)
	realm.call("apply_state", {"agents": [], "tools": [], "tasks": [], "approvals": [],
		"age": {"current": 1, "research": null}})
	game.link.online_town = true
	game.call("start_world", w)
	view.bind(w)
	view._bound_s = 5.0
	w.step(1)
	assert_eq(w.age, 1)

	# Research of the Market Age, a third of the way through.
	var started := int(Time.get_unix_time_from_system()) - 30
	realm.call("apply_event", _age_event(1, {"target": 2, "started_at": _iso(started), "duration_ms": 90000}))
	w.step(1)
	view._process(0.1)
	assert_eq(w.age, 1, "research changes nothing in the town yet")
	assert_eq(J.gi(view.research.research, "target"), 2, "the world shows the research")
	assert_almost_eq(view.research.progress(Time.get_unix_time_from_system()), 30.0 / 90.0, 0.03)
	var gates := w.walls.pieces_of(1, WallLayout.GATE).size()
	assert_gte(view.research.get_child_count(), 1 + 4 + gates * 4, "bar and light, banners, a masons' yard per gate")

	# The Town Hall finishes the research: the Merchant Ring rises.
	realm.call("apply_event", _age_event(2, null))
	w.step(1)
	view._process(0.1)
	assert_eq(w.age, 2, "TownLink mirrored the new age")
	assert_eq(w.walls_up, 2)
	assert_true(view.walls.is_rising(), "the ring rises in front of the player")
	assert_true(view.research.research.is_empty(), "the research is gone")

	game.call("stop_town")
	realm.call("clear")
	view.unbind()
	assert_false(game.link.online_town)
