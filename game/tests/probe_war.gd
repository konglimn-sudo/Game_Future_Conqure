extends SceneTree
## 一次性探针：AI 战争为何不爆发——边境接触与军力对比诊断

func _init() -> void:
	var sim := Sim.create("res://data/world.json", "res://data/params.json")
	sim.set_seed(20300101)
	for t in range(1, 31):
		sim.set_allocation(0.34, 0.33)
		sim.end_turn()
	print("T31 各势力态势：")
	for fid in range(sim.factions.size()):
		var names := []
		for r in sim.controlled_of(fid):
			names.append(r["name"])
		print("  %d %s | 区域%d | 军团%d 军力%.1f | %s" % [fid, sim.factions[fid]["key"],
			names.size(), sim.army_total(fid), sim.military_index(fid), ", ".join(names)])
	print("边境接触矩阵：")
	for a in range(sim.factions.size()):
		for b in range(a + 1, sim.factions.size()):
			var ai := load("res://core/ai.gd")
			if ai._shares_border(sim, a, b):
				print("  %d-%d 接壤" % [a, b])
	quit(0)
