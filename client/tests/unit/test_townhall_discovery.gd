extends GutTest
## Finding the Town Hall and starting it: where each mode keeps its data, the order in which
## runtime files are read, the shared copy's override, and what a launch failure looks like.
## Environment overrides are set per test and restored afterwards.

const VARS := ["AURELHAVEN_RUNTIME", "AURELHAVEN_DATA_ROOT", "AURELHAVEN_DISCOVERY_FILE"]

var _saved: Dictionary = {}
var _tmp: String = ""


func before_each() -> void:
	_saved.clear()
	for v: String in VARS:
		_saved[v] = OS.get_environment(v)
		OS.unset_environment(v)
	_tmp = OS.get_temp_dir().path_join("aurelhaven-gut-discovery-%d" % (randi() & 0xffffff))
	DirAccess.make_dir_recursive_absolute(_tmp.path_join("practice"))


func after_each() -> void:
	for v: String in VARS:
		var old := String(_saved[v])
		if old == "":
			OS.unset_environment(v)
		else:
			OS.set_environment(v, old)
	for f in ["runtime.json", "practice/runtime.json", "practice/townhall.log", "shared.json"]:
		DirAccess.remove_absolute(_tmp.path_join(f))
	DirAccess.remove_absolute(_tmp.path_join("practice"))
	DirAccess.remove_absolute(_tmp)


func _write(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _runtime(port: int, data_dir: String) -> String:
	return JSON.stringify({"pid": 4242, "port": port, "token": "tok-%d" % port, "url": "", "data_dir": data_dir})


func test_each_mode_has_its_own_data_folder_under_the_data_root() -> void:
	OS.set_environment("AURELHAVEN_DATA_ROOT", _tmp)
	assert_eq(TownHallLauncher.data_dir_for("real"), _tmp)
	assert_eq(TownHallLauncher.data_dir_for("fake"), _tmp.path_join("practice"))
	assert_eq(TownHallLauncher.runtime_file_for("fake"), _tmp.path_join("practice/runtime.json"))
	assert_eq(TownHallLauncher.log_file_for("real"), _tmp.path_join("townhall.log"))
	# Anything but "real" is practice, the safe one.
	assert_eq(TownHallLauncher.normalize_mode("nonsense"), "fake")


func test_without_an_override_the_data_root_is_the_townhall_data_folder() -> void:
	var root := TownHallLauncher.data_root()
	assert_true(root.ends_with("townhall/data"), root)
	assert_eq(TownHallLauncher.data_dir_for("fake"), root.path_join("practice"))


func test_the_preferred_mode_is_read_before_the_shared_copy_and_the_other_mode() -> void:
	OS.set_environment("AURELHAVEN_DATA_ROOT", _tmp)
	OS.set_environment("AURELHAVEN_DISCOVERY_FILE", _tmp.path_join("shared.json"))
	var practice := TownHallDiscovery.candidate_paths("fake")
	assert_eq(Array(practice), [_tmp.path_join("practice/runtime.json"), _tmp.path_join("shared.json"), _tmp.path_join("runtime.json")])
	var real := TownHallDiscovery.candidate_paths("real")
	assert_eq(Array(real), [_tmp.path_join("runtime.json"), _tmp.path_join("shared.json"), _tmp.path_join("practice/runtime.json")])
	# An explicit runtime file always comes first.
	OS.set_environment("AURELHAVEN_RUNTIME", _tmp.path_join("explicit.json"))
	assert_eq(TownHallDiscovery.candidate_paths("real")[0], _tmp.path_join("explicit.json"))


func test_the_shared_copy_can_be_turned_off() -> void:
	OS.set_environment("AURELHAVEN_DATA_ROOT", _tmp)
	OS.set_environment("AURELHAVEN_DISCOVERY_FILE", "off")
	assert_eq(TownHallDiscovery.discovery_copy(), "")
	assert_eq(Array(TownHallDiscovery.candidate_paths("fake")), [_tmp.path_join("practice/runtime.json"), _tmp.path_join("runtime.json")])
	OS.unset_environment("AURELHAVEN_DISCOVERY_FILE")
	assert_true(TownHallDiscovery.discovery_copy().ends_with("Aurelhaven/runtime.json"))


func test_finds_the_preferred_town_hall_and_only_the_pinned_one_when_pinned() -> void:
	OS.set_environment("AURELHAVEN_DATA_ROOT", _tmp)
	OS.set_environment("AURELHAVEN_DISCOVERY_FILE", "off")
	_write(_tmp.path_join("runtime.json"), _runtime(4001, _tmp))
	_write(_tmp.path_join("practice/runtime.json"), _runtime(4002, _tmp.path_join("practice")))
	var found := TownHallDiscovery.find("", "fake")
	assert_eq(J.gi(found, "port"), 4002)
	assert_eq(J.gi(found, "pid"), 4242)
	assert_eq(J.gs(found, "data_dir"), _tmp.path_join("practice"))
	assert_eq(J.gi(TownHallDiscovery.find("", "real"), "port"), 4001)
	# Pinned: that file or nothing, even while another Town Hall's file exists.
	DirAccess.remove_absolute(_tmp.path_join("practice/runtime.json"))
	assert_eq(TownHallDiscovery.find(_tmp.path_join("practice/runtime.json"), "real"), {})
	assert_eq(J.gi(TownHallDiscovery.find("", "fake"), "port"), 4001)


func test_parses_runtime_files_defensively() -> void:
	assert_eq(TownHallDiscovery.parse_runtime({"port": 0, "token": "x"}, "s"), {})
	assert_eq(TownHallDiscovery.parse_runtime({"port": 5000.0, "token": ""}, "s"), {})
	assert_eq(TownHallDiscovery.parse_runtime("nope", "s"), {})
	var old := TownHallDiscovery.parse_runtime({"port": 5000.0, "token": "t"}, "s")
	assert_eq(J.gi(old, "port"), 5000)
	assert_eq(J.gi(old, "pid"), 0)
	assert_eq(J.gs(old, "data_dir"), "")


func test_reads_a_launch_failure_from_the_new_part_of_the_log() -> void:
	OS.set_environment("AURELHAVEN_DATA_ROOT", _tmp)
	var log_path := TownHallLauncher.log_file_for("fake")
	_write(log_path, "The Town Hall could not start: an old failure\n")
	var offset := TownHallLauncher.file_size(log_path)
	assert_eq(TownHallLauncher.launch_failure("fake", offset), "")
	var f := FileAccess.open(log_path, FileAccess.READ_WRITE)
	f.seek_end()
	f.store_string("Aurelhaven Town Hall is starting\nThe Town Hall could not start: AURELHAVEN_PORT must be a non-negative integer\n")
	f.close()
	assert_eq(TownHallLauncher.launch_failure("fake", offset), "AURELHAVEN_PORT must be a non-negative integer")
	# Another Town Hall on that data folder is the one to connect to, not a failure.
	assert_eq(TownHallLauncher.failure_in("The Town Hall could not start: another Town Hall (pid 9) is using D:/x\n"), "")


func test_compares_folders_the_way_the_platform_does() -> void:
	assert_true(TownHallLauncher.same_dir("D:\\town\\data\\", "D:/town/data"))
	assert_false(TownHallLauncher.same_dir("D:/town/data", "D:/town/data/practice"))
	assert_false(TownHallLauncher.same_dir("", ""))
	if OS.has_feature("windows"):
		assert_true(TownHallLauncher.same_dir("d:/Town/Data", "D:/town/data"))
