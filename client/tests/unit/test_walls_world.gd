extends GutTest
## The walls and the world sounds in a WorldView bound to a generated town: rings drawn for the
## age, a rise that plays and ends, and the cues sent to Audio.play_at while the town works.


## Stands in for the Audio autoload, recording every cue.
class FakeAudio:
	extends Node
	var cues: Array[String] = []
	var at: Array[Vector3] = []

	func play(cue: String) -> void:
		cues.append(cue)
		at.append(Vector3.INF)

	func play_at(cue: String, position: Vector3) -> void:
		cues.append(cue)
		at.append(position)

	func unlock() -> void:
		pass

	func count(cue: String) -> int:
		return cues.count(cue)


var _real_audio: Node
var audio: FakeAudio
var view: WorldView
var cam: Camera3D


func before_each() -> void:
	var root := get_tree().root
	_real_audio = root.get_node_or_null("Audio")
	if _real_audio != null:
		_real_audio.name = "AudioReal"
	audio = FakeAudio.new()
	audio.name = "Audio"
	root.add_child(audio)
	view = WorldView.new()
	add_child_autofree(view)
	cam = Camera3D.new()
	add_child_autofree(cam)
	cam.current = true


func after_each() -> void:
	audio.free()
	if _real_audio != null:
		_real_audio.name = "Audio"


func _town() -> SimWorld:
	var w := SimFixture.generated_world(4127)
	w.allow_debug_commands = true
	view.bind(w)
	_look_at(w.map_center())
	return w


func _look_at(p: Vector2) -> void:
	cam.global_transform = Transform3D(Basis.looking_at(Vector3(0, -1, -1)), Vector3(p.x, 18.0, p.y + 18.0))


## Steps the town and the view together for `seconds`.
func _run(w: SimWorld, seconds: float) -> void:
	var frames := int(seconds * 20.0)
	for i in frames:
		w.step(1)
		view._process(0.05)
		view.walls._process(0.05)


func test_the_age_s_rings_are_drawn() -> void:
	var w := _town()
	assert_eq(view.walls.rings.keys(), [0], "Age I: the Keep Ring")
	var d: WallView.RingDraw = view.walls.rings[0]
	var drawn := 0
	for mm: MultiMesh in d.groups.values():
		drawn += mm.instance_count
	assert_eq(drawn, w.walls.ring_pieces[0].size(), "one instance per piece")
	w.commands.push(GameCommands.debug_set_age(3))
	w.step(1)
	assert_eq(view.walls.rings.size(), 3, "a town that catches up shows its rings at once")
	assert_false(view.walls.is_rising())


func test_a_ring_rises_while_the_town_runs() -> void:
	var w := _town()
	_run(w, 2.0)
	var started: Array[int] = []
	var finished: Array[int] = []
	view.wall_rise_started.connect(func(ring: int, _c: Vector3, _r: float, _s: float) -> void: started.append(ring))
	view.walls.rise_finished.connect(func(ring: int) -> void: finished.append(ring))
	w.commands.push(GameCommands.debug_set_age(2))
	_run(w, 0.1)
	assert_eq(started, [1] as Array[int], "the Merchant Ring starts to rise")
	assert_true(view.walls.is_rising())
	_run(w, WallView.LEAD_S + 7.0)
	assert_eq(finished, [1] as Array[int])
	assert_false(view.walls.is_rising())
	assert_eq(audio.count("wall_rise"), w.walls.pieces_of(1, WallLayout.GATE).size(), "each gatehouse rumbles")


func test_the_town_at_work_is_heard() -> void:
	var w := _town()
	var k := w.keep()
	var ids: Array = w.units.keys()
	var spot := DemoTown.find_spot(w, "cottage", Vector2i(k.center()) + Vector2i(4, 4), 6)
	assert_ne(spot, Pathing.NO_CELL)
	w.commands.push(GameCommands.place_building([ids[0], ids[1]], "cottage", spot))
	_run(w, 30.0)
	assert_gt(audio.count("construct_hit"), 10, "hammering at the site")
	_run(w, 60.0)
	assert_gt(audio.count("chop") + audio.count("gather_food"), 3, "gathering")
	assert_gt(audio.count("drop_off"), 0, "loads dropped off")
	var hits := audio.cues.count("construct_hit")
	var first := audio.cues.find("construct_hit")
	assert_lt(Vector2(audio.at[first].x, audio.at[first].z).distance_to(Vector2(spot) + Vector2.ONE), 2.0, "at the site")
	assert_lt(float(hits), 30.0 / WorldView.HAMMER_S.x + 10.0, "about one blow every half second or more")


func test_a_wisp_setting_off_is_heard() -> void:
	var w := _town()
	w.commands.push(GameCommands.wisp(w.keep_id, "t1", "a1", 10))
	_run(w, 0.2)
	assert_eq(audio.count("wisp"), 0, "still waiting at the Keep")
	_run(w, 1.0)
	assert_eq(audio.count("wisp"), 1, "it set off")
