extends SceneTree
## Boots the game the way the player does (the main scene with autostart) and reports whether
## it ended up in the Town Hall's town or an offline one, and how long that took. Headless is
## fine. With no Town Hall running this also checks that the game starts one.
##   <godot> --headless --path client -s res://tools/boot_check.gd [-- --timeout=40]
## Note: when the game started a Town Hall, the *_console.exe wrapper keeps running after the
## game quits, because it waits for every process it (indirectly) started and the Town Hall
## is meant to keep running. The game itself has exited; the regular exe (and the exported
## game) returns at once.

var _start := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var timeout := 40.0
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--timeout="):
			timeout = float(a.substr(10))
	_start = Time.get_ticks_msec()
	var main: Node = load("res://game/main.tscn").instantiate()
	root.add_child(main)
	var game: Node = root.get_node("Game")
	var net: Node = root.get_node("Net")
	var last_report := 0
	while Time.get_ticks_msec() - _start < int(timeout * 1000.0):
		if game.world != null and not game.booting:
			break
		if Time.get_ticks_msec() - last_report > 2000:
			last_report = Time.get_ticks_msec()
			print("BOOT ... %.1f s net=%s attempts=%d endpoint=%s booting=%s" % [(last_report - _start) / 1000.0, net.status,
				int(net.get("attempts")), str(net.endpoint.get("port", "-")), str(game.booting)])
		await process_frame
	var secs := (Time.get_ticks_msec() - _start) / 1000.0
	if game.world == null:
		print("BOOT no town after %.1f s (net %s: %s)" % [secs, net.status, net.last_problem])
		quit(1)
		return
	print("BOOT %s town %s after %.1f s (net %s, endpoint %s)" % ["Town Hall" if game.is_online_town() else "offline",
		game.world.town_id, secs, net.status, String(net.endpoint.get("source", "-"))])
	quit(0)
