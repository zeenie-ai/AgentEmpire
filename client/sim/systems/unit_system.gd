class_name UnitSystem
extends RefCounted
## Runs every unit's job, moves units along their paths, then steers them apart.


static func tick(w: SimWorld) -> void:
	w.spatial.clear()
	for u: SimUnit in w.units.values():
		w.spatial.insert(u.id, u.pos)
	for u: SimUnit in w.units.values():
		match u.job:
			SimConst.JOB_IDLE:
				IdleJob.tick(w, u)
			SimConst.JOB_MOVE:
				MoveJob.tick(w, u)
			SimConst.JOB_GATHER:
				GatherJob.tick(w, u)
			SimConst.JOB_BUILD:
				BuildJob.tick(w, u)
			SimConst.JOB_DEPOSIT:
				DepositJob.tick(w, u)
			SimConst.JOB_COURIER:
				CourierJob.tick(w, u)
		Movement.advance(w, u)
	Movement.separate(w)
