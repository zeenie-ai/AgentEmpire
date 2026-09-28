extends Node
## Toast notifications. Anything can call Notify.push(); the HUD's toast layer shows them.
## Messages sharing a key are throttled so a busy town does not flood the screen.

signal toast(text: String, kind: String)

const DEFAULT_THROTTLE_MS := 2500

var _last_shown: Dictionary = {}


## kind: "info", "good", "warn" or "error".
func push(text: String, kind: String = "info", key: String = "", throttle_ms: int = DEFAULT_THROTTLE_MS) -> void:
	var k := key if key != "" else text
	var now := Time.get_ticks_msec()
	if _last_shown.has(k) and now - int(_last_shown[k]) < throttle_ms:
		return
	_last_shown[k] = now
	toast.emit(text, kind)
