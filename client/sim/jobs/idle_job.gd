class_name IdleJob
extends RefCounted
## Idle townsfolk that were not told to wait (Stop or a move order) start gathering after a
## short delay: whichever of Food and Wood is lower, or the Keep's Gather Focus, from the
## nearest source within gather.search_radius_tiles.


static func tick(w: SimWorld, u: SimUnit) -> void:
	u.idle_ticks += 1
	if u.kind == "agent":
		# Agents look for their next site or go home right away, then every retry interval.
		if u.idle_ticks == 1 or u.idle_ticks % SimConst.RETRY_EVERY_TICKS == 0:
			AgentJob.decide(w, u)
		return
	if u.hold or u.kind != "townsfolk":
		return
	var delay := int(SimConst.AUTO_GATHER_DELAY_S * float(w.tick_rate))
	if u.idle_ticks < delay or (u.idle_ticks - delay) % SimConst.RETRY_EVERY_TICKS != 0:
		return
	GatherJob.auto_assign(w, u)
