extends Node
## Audio stub. Phase 5 adds bells, ambience and the web click-to-enter unlock; until then every
## call is a no-op so gameplay code can already name its cues.

var enabled: bool = false


## Plays a named cue ("build_complete", "train_complete", "need_houses", ...).
func play(_cue: String) -> void:
	pass


## Web builds must unlock audio from a user gesture.
func unlock() -> void:
	pass
