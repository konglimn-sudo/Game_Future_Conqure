extends SceneTree
## 无头测试：机器人按简单策略玩 42 个月，校验核心循环不变量。
## 运行：godot --headless --path game --script res://tests/run_sim.gd

func _init() -> void:
	var sim := Sim.create("res://data/world.json", "res://data/params.json")
	sim.set_seed(20300101)  # 世界演化可复现
	var fails: Array[String] = []
	var saw_power_wall := false
	var saw_data_short := false

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

		# 军团演练：中期组建一支并调动，验证机制即可（省级地图下芯片紧张）
		if t >= 10 and t <= 28 and sim.army_total() < 1:
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

		# 不变量（含 AI 势力）
		for fid in range(sim.factions.size()):
			var f: Dictionary = sim.factions[fid]
			if float(f["chips"]) < -0.001: fails.append("T%d 势力%d 芯片为负" % [t, fid])
			if float(f["data_pool"]) < -0.001: fails.append("T%d 势力%d 数据为负" % [t, fid])
			if sim.compute_total(fid) <= 0: fails.append("T%d 势力%d 算力归零" % [t, fid])
		if absf(sim.train_pct + sim.infer_pct + sim.research_pct() - 1.0) > 0.001:
			fails.append("T%d 分配比例不归一" % t)

	# 结局断言
	if sim.gen < 2: fails.append("42 月未达 Gen2（数值过紧）")
	if sim.controlled().size() < 6: fails.append("扩张停滞（<6 区域）")
	if not saw_power_wall: fails.append("全程未见电力墙（M0 核心机制未触发）")
	if sim.army_total() < 1: fails.append("军团系统未生效")
	for fid in range(1, sim.factions.size()):
		if sim.controlled_of(fid).size() < 5:
			fails.append("AI〔%s〕扩张停滞（%d 区）" % [sim.faction_name(fid), sim.controlled_of(fid).size()])

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
