extends SceneTree
## 无头测试：机器人按简单策略玩 42 个月，校验核心循环不变量。
## 运行：godot --headless --path game --script res://tests/run_sim.gd

func _init() -> void:
	var sim := Sim.create("res://data/world.json", "res://data/params.json")
	sim.set_seed(20300101)  # 世界演化可复现
	var fails: Array[String] = []
	var saw_power_wall := false
	var saw_data_short := false
	var saw_containment := false

	for t in range(1, 43):
		# 分配策略：前期均衡，中期冲代际；数据见底时让利给扩张
		if t <= 8:
			sim.set_allocation(0.34, 0.33)
		elif sim.data_pool < 120:
			sim.set_allocation(0.32, 0.30)
		elif t <= 20:
			sim.set_allocation(0.50, 0.25)
		else:
			sim.set_allocation(0.40, 0.30)

		# 军团演练 + 驻防：中期起维持 3 支军团（M2 后被宣战时不至于裸奔）
		if t >= 10 and sim.army_total() < 3:
			for r in sim.regions:
				if r.get("capital", false) and sim.can_build_army(int(r["id"])) == "":
					sim.do_build_army(int(r["id"]))
					break

		# 扩张：维持 2 个自动渗透目标（性价比优先），余力再手动补刀
		_maintain_auto_targets(sim, 2)
		_infiltrate_best(sim, 1)
		if t == 16:
			for r in sim.regions:
				if sim.army_of(r) > 0:
					for n in sim.adj[str(int(r["id"]))]:
						if sim.can_move_army(int(r["id"]), int(n)) == "":
							sim.do_move_army(int(r["id"]), int(n))
							break
					break
		if t == 15:
			# 存档读档往返一致性
			var snap_json := JSON.stringify(sim.save_state())
			var before := sim.summary()
			var sim2 := Sim.create("res://data/world.json", "res://data/params.json")
			sim2.load_state(JSON.parse_string(snap_json))
			if sim2.summary() != before:
				fails.append("存档读档不一致：\n  A: %s\n  B: %s" % [before, sim2.summary()])
		for _i in range(4):
			var built := false
			if sim.power_limited():
				built = _build_best(sim, "plant")
			if not built:
				built = _build_best(sim, "dc")
			if not built and sim.chips > 90:
				built = _build_best(sim, "fab")
			if not built:
				break

		sim.end_turn()
		print(sim.summary())
		for e in sim.events:
			print("   " + e)
			if e.begins_with("⚡"):
				saw_power_wall = true
			if e.begins_with("💾"):
				saw_data_short = true
			if e.begins_with("🛑"):
				saw_containment = true

		# 不变量（含 AI 势力）
		for fid in range(sim.factions.size()):
			var f: Dictionary = sim.factions[fid]
			if float(f["chips"]) < -0.001: fails.append("T%d 势力%d 芯片为负" % [t, fid])
			if float(f["data_pool"]) < -0.001: fails.append("T%d 势力%d 数据为负" % [t, fid])
			if sim.compute_total(fid) <= 0: fails.append("T%d 势力%d 算力归零" % [t, fid])
		if absf(sim.train_pct + sim.infer_pct + sim.research_pct() - 1.0) > 0.001:
			fails.append("T%d 分配比例不归一" % t)

	# 结局断言（涌现轨迹）
	if sim.gen < 2: fails.append("42 月未达 Gen2（数值过紧）")
	if sim.controlled().size() < 6: fails.append("扩张停滞（<6 区域）")
	if sim.army_total() < 1: fails.append("军团系统未生效")
	for fid in range(1, sim.factions.size()):
		if sim.controlled_of(fid).size() < 5:
			fails.append("AI〔%s〕扩张停滞（%d 区）" % [sim.faction_name(fid), sim.controlled_of(fid).size()])
	print("（参考）电力墙出现:%s 围堵出现:%s" % ["是" if saw_power_wall else "否", "是" if saw_containment else "否"])

	# 机制单元校验（确定性合成场景，不依赖涌现轨迹）
	# A. 电力墙：把玩家起始区数据中心拉满，容量必然顶到电力上限
	var s2 := Sim.create("res://data/world.json", "res://data/params.json")
	s2.factions[0]["chips"] = 999.0
	for r in s2.controlled():
		while s2.can_build(int(r["id"]), "dc", 0) == "":
			s2.do_build(int(r["id"]), "dc", 0)
	if not s2.power_limited(0):
		fails.append("机制校验失败：数据中心拉满后未触发电力墙")
	# B. 反霸权围堵：给美利坚体系 12 个区 + 代际领先 2 代
	var s3 := Sim.create("res://data/world.json", "res://data/params.json")
	var given := 0
	for r in s3.regions:
		if s3.owner_of(r) == -1 and given < 12:
			r["inf"]["1"] = 100
			given += 1
	s3.factions[1]["gen"] = 4
	s3._update_containment()
	if s3.contained_fid != 1:
		fails.append("机制校验失败：领跑者未被围堵（contained=%d）" % s3.contained_fid)
	# C. 军事威慑豁免：同一领跑者拥有绝对军力后围堵解除
	s3.region(int(s3.factions[1]["capital_id"]))["units"] = {"tank": 15, "inf": 10, "air": 5}
	s3._update_containment()
	if s3.contained_fid != -1:
		fails.append("机制校验失败：绝对军事霸权未豁免围堵（contained=%d）" % s3.contained_fid)

	# D. 战争机制（确定性合成场景）
	var s4 := Sim.create("res://data/world.json", "res://data/params.json")
	s4.set_seed(7)
	# 找一块与美利坚体系控制区相邻的中立区，让玩家空降驻军
	var stage := -1
	var target := -1
	for r in s4.controlled_of(1):
		for n in s4.adj[str(int(r["id"]))]:
			var nr: Dictionary = s4.region(int(n))
			if s4.owner_of(nr) == -1:
				stage = int(n)
				target = int(r["id"])
				break
		if stage >= 0:
			break
	if stage < 0:
		fails.append("战争校验：找不到美方邻接的中立区")
	else:
		s4.region(stage)["inf"] = {"0": 100}
		s4.region(stage)["units"] = {"tank": 3, "inf": 2, "air": 1}
		s4.terr_version += 1
		# D1. 未宣战不可进攻
		if s4.can_attack(stage, target, 0) == "":
			fails.append("战争校验失败：未宣战竟可进攻")
		s4.declare_war(0, 1)
		# D2. 攻占无守备区
		s4.region(target)["units"] = {}
		if not s4.do_attack(stage, target, 0):
			fails.append("战争校验失败：无法进攻无守备敌区")
		elif s4.owner_of(s4.region(target)) != 0:
			fails.append("战争校验失败：攻占后归属未转移")
		# D3. 重兵防守可挫败进攻（守方 10 vs 攻方 2，攻方应无法占领）
		var stage2 := target          # 刚占的区，驻军 6
		s4.region(stage2)["units"] = {"inf": 2}
		var target2 := -1
		for n in s4.adj[str(stage2)]:
			if s4.owner_of(s4.region(int(n))) == 1:
				target2 = int(n)
				break
		if target2 >= 0:
			s4.region(target2)["units"] = {"tank": 5, "inf": 5}
			s4.do_attack(stage2, target2, 0)
			if s4.owner_of(s4.region(target2)) == 0:
				fails.append("战争校验失败：2 攻 10 竟然得手（守方加成失效）")
		# D4. 断补给削弱：孤立区战力应为 0.3 倍
		var p_full := s4.combat_power(0, 4, true)
		var p_cut := s4.combat_power(0, 4, false)
		if absf(p_cut / p_full - float(s4.P["unsupplied_factor"])) > 0.01:
			fails.append("战争校验失败：断补给系数不生效（%.2f）" % (p_cut / p_full))
		# D5. 空降区（不连首都）应判定为断补给
		if s4.supplied(stage, 0):
			fails.append("战争校验失败：飞地竟被判定为有补给")

	print("\n==== 结果 ====")
	print("代际 Gen%d | 控制 %d 区 | 科技 Lv%d | 电力墙:%s 数据短缺:%s" % [
		sim.gen, sim.controlled().size(), sim.tech_level(),
		"是" if saw_power_wall else "否", "是" if saw_data_short else "否"])
	if fails.is_empty():
		print("PASS: 42 月循环全部不变量成立")
		quit(0)
	else:
		for f in fails:
			print("FAIL: " + f)
		quit(1)

func _maintain_auto_targets(sim: Sim, cap: int) -> void:
	while sim.auto_infiltrate.size() < cap:
		var best := -1
		var score := -1.0
		for r in sim.regions:
			if sim.auto_infiltrate.has(int(r["id"])):
				continue
			if sim.can_infiltrate(r["id"]) != "":
				continue
			var cost: Dictionary = sim.infiltrate_cost(r["id"])
			var s: float = (r["pop"] + r["energy"] + r["fab"] * 3.0 + 1.0) \
				/ (cost["chips"] + cost["data"] * 0.5)
			if s > score:
				score = s
				best = int(r["id"])
		if best < 0:
			return
		sim.toggle_auto_infiltrate(best)

func _infiltrate_best(sim: Sim, tries: int) -> void:
	for _i in range(tries):
			var best := -1
			var score := -1.0
			for r in sim.regions:
				if sim.can_infiltrate(r["id"]) == "":
					var cost: Dictionary = sim.infiltrate_cost(r["id"])
					var s: float = (r["pop"] + r["energy"] + r["fab"] * 3.0 + 1.0) \
						/ (cost["chips"] + cost["data"] * 0.5)
					if s > score:
						score = s
						best = r["id"]
			if best >= 0:
				sim.do_infiltrate(best)

func _build_best(sim: Sim, kind: String) -> bool:
	var best := -1
	var score := -1.0
	for r in sim.regions:
		if sim.can_build(r["id"], kind) == "":
			var s: float = 0.0
			match kind:
				"plant": s = r["energy"]
				"dc": s = 1.0
				"fab": s = r["fab"]
			if s > score:
				score = s
				best = r["id"]
	return best >= 0 and sim.do_build(best, kind)
