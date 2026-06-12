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

	# 2. 军事性格/战时：先军后扩，芯片优先喂军队
	var at_war: bool = sim.at_war_any(fid)
	var drive: float = p["army_drive"] + (0.6 if at_war else 0.0)
	# 底线武装：再温和的势力也维持基本常备军（不设防 = 邀请闪电战）
	var army_cap: int = maxi(int(ceil(sim.controlled_of(fid).size() * drive)), 2)
	if drive >= 0.5 or at_war:
		for _i in range(2 if at_war else 1):
			if sim.army_total(fid) >= army_cap:
				break
			if not sim.do_build_army(_army_site(sim, fid), fid):
				break

	# 3. 渗透：性价比 ×性格权重，最多 expand 个目标/月
	var foe: int = sim.contained_fid if sim.contained_fid != fid else -1
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
			# 反霸权围堵：抢领跑者正在渗透的目标、堵它的扩张边界
			if foe >= 0:
				var blocking: bool = sim.influence_of(r, foe) > 0
				if not blocking:
					for n in sim.adj[str(id)]:
						if sim.is_owned_by(sim.region(int(n)), foe):
							blocking = true
							break
				if blocking:
					value *= float(sim.P["containment_focus"])
			var s: float = value / (cost["chips"] + cost["data"] * 0.5)
			if s > score:
				score = s
				best = id
		if best < 0:
			break
		sim.do_infiltrate(best, fid)

	# 4. 建造：电力受限建电厂，否则扩数据中心；芯片富余升晶圆厂
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
	# 温和性格也维持基本武装（基建之后的余钱）
	if sim.army_total(fid) < army_cap and float(f["chips"]) > sim.P["army_cost_chips"] + 20.0:
		sim.do_build_army(_army_site(sim, fid), fid)

	# 5. 战争决策
	_consider_war(sim, fid, p)
	if sim.at_war_any(fid):
		_wage_war(sim, fid)

## 宣战考量：要么有压倒性军力优势 + 性格侵略性掷骰，要么围攻被围堵的领跑者
static func _consider_war(sim, fid: int, p: Dictionary) -> void:
	if sim.at_war_any(fid):
		return
	for tfid in range(sim.factions.size()):
		if tfid == fid or sim.is_at_war(fid, tfid):
			continue
		if not _shares_border(sim, fid, tfid):
			continue
		var mine: float = sim.military_index(fid)
		var theirs: float = sim.military_index(tfid)
		if mine < float(sim.P["ai_war_advantage"]) * maxf(theirs, 1.0):
			continue
		var dogpile: bool = tfid == sim.contained_fid
		if dogpile or sim.rng.randf() < float(p.get("aggression", 0.2)) * float(sim.P["ai_war_base_prob"]):
			sim.declare_war(fid, tfid)
			return

## 建军地点：优先放在与他国接壤的前沿，否则首都
static func _army_site(sim, fid: int) -> int:
	for r in sim.controlled_of(fid):
		var rid := int(r["id"])
		for n in sim.adj[str(rid)]:
			var o: int = sim.owner_of(sim.region(int(n)))
			if o >= 0 and o != fid:
				return rid
	return int(sim.factions[fid]["capital_id"])

static func _shares_border(sim, a: int, b: int) -> bool:
	for r in sim.controlled_of(a):
		for n in sim.adj[str(int(r["id"]))]:
			if sim.is_owned_by(sim.region(int(n)), b):
				return true
	return false

## 交战：前线有局部优势才进攻；后方军团向前线机动
static func _wage_war(sim, fid: int) -> void:
	var enemies: Array = sim.enemies_of(fid)
	# 进攻
	for r in sim.controlled_of(fid):
		var rid := int(r["id"])
		if sim.army_of(r) <= 0:
			continue
		var best_target := -1
		var best_score := 0.0
		for n in sim.adj[str(rid)]:
			var ni := int(n)
			if sim.can_attack(rid, ni, fid) != "":
				continue
			var t: Dictionary = sim.region(ni)
			var dfid: int = sim.owner_of(t)
			var my_p: float = sim.combat_power(fid, sim.army_of(r), sim.supplied(rid, fid))
			var their_p: float = sim.combat_power(dfid, sim.army_of(t), sim.supplied(ni, dfid)) \
				* float(sim.P["defender_bonus"])
			if my_p >= float(sim.P["ai_attack_margin"]) * maxf(their_p, 0.5):
				var s: float = t["pop"] + t["energy"] + t["fab"] * 3.0 - sim.army_of(t)
				if s > best_score:
					best_score = s
					best_target = ni
		if best_target >= 0:
			sim.do_attack(rid, best_target, fid)
	# 机动：不在前线的军团向敌境方向移动一步
	var frontier := {}
	for r in sim.controlled_of(fid):
		for n in sim.adj[str(int(r["id"]))]:
			var o: int = sim.owner_of(sim.region(int(n)))
			if o in enemies:
				frontier[int(r["id"])] = true
				break
	for r in sim.controlled_of(fid):
		var rid := int(r["id"])
		if sim.army_of(r) <= 0 or frontier.has(rid):
			continue
		for n in sim.adj[str(rid)]:
			var ni := int(n)
			if frontier.has(ni) and sim.can_move_army(rid, ni, fid) == "":
				sim.do_move_army(rid, ni, fid)
				break

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
