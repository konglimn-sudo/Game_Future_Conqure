extends RefCounted
## AI 大国月度决策：效用评分（设计文档 9.3）。
## 与玩家共用 Sim 的同一套动作与成本——不作弊资源，只按性格权重选动作。

static func act(sim, fid: int) -> void:
	var f: Dictionary = sim.factions[fid]
	var p: Dictionary = f["persona"]

	# 1. 算力分配：性格基线；数据见底时让利给扩张与推理
	var train: float = p["alloc_train"]
	var infer: float = p["alloc_infer"]
	if float(f["data_pool"]) < 100.0:
		train = minf(train, 0.28)
		infer += 0.04
	sim.set_allocation(train, infer, fid)

	# 2. 渗透：性价比 ×性格权重，最多 expand 个目标/月
	for _i in range(int(p["expand"])):
		var best := -1
		var score := -1.0
		for r in sim.regions:
			var id := int(r["id"])
			if sim.can_infiltrate(id, fid) != "":
				continue
			var cost: Dictionary = sim.infiltrate_cost(id)
			var value: float = r["pop"] * p["w_pop"] + r["energy"] * p["w_energy"] \
				+ r["fab"] * p["w_fab"] + 1.0
			# 已有投入的目标优先收尾（防止被衰减磨掉）
			if sim.influence_of(r, fid) > 0:
				value *= 1.8
			var s: float = value / (cost["chips"] + cost["data"] * 0.5)
			if s > score:
				score = s
				best = id
		if best < 0:
			break
		sim.do_infiltrate(best, fid)

	# 3. 建造：电力受限建电厂，否则扩数据中心；芯片富余升晶圆厂
	for _i in range(3):
		var built := false
		if sim.power_limited(fid):
			built = _build_best(sim, fid, "plant")
		if not built:
			built = _build_best(sim, fid, "dc")
		if not built and float(f["chips"]) > 90.0:
			built = _build_best(sim, fid, "fab")
		if not built:
			break

	# 4. 军团：军事性格驱动，规模与控制区数挂钩
	var cap: int = int(ceil(sim.controlled_of(fid).size() * float(p["army_drive"])))
	if sim.army_total(fid) < cap and float(f["chips"]) > sim.P["army_cost_chips"] + 20.0:
		sim.do_build_army(int(f["capital_id"]), fid)

static func _build_best(sim, fid: int, kind: String) -> bool:
	var best := -1
	var score := -1.0
	for r in sim.controlled_of(fid):
		var id := int(r["id"])
		if sim.can_build(id, kind, fid) != "":
			continue
		var s := 1.0
		match kind:
			"plant": s = float(r["energy"])
			"fab": s = float(r["fab"])
		if s > score:
			score = s
			best = id
	return best >= 0 and sim.do_build(best, kind, fid)
