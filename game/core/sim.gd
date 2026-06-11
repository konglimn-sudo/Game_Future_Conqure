class_name Sim
extends RefCounted
## 纯逻辑层：不依赖任何 UI/渲染，可被无头测试驱动。
## 回合结算顺序与 M0 数值原型 (M0_数值原型.xlsx) 保持一致。

var P: Dictionary                 # 参数表
var regions: Array = []           # 区域状态（含影响度/设施/军团）
var adj: Dictionary = {}          # id -> [邻接 id]
var sea_links: Array = []         # 跨洋航线 [[id_a, id_b], ...]，已并入 adj
var cities: Array = []            # 主要城市（表现层用）
var country_outlines: Array = []  # 拆省大国的国界轮廓（表现层粗描边）

var turn := 1
var chips := 0.0
var data_pool := 0.0
var train_pct := 0.34
var infer_pct := 0.33
var training := 0.0               # 累积训练进度
var gen := 1
var tech_points := 0.0
var last_supply := 1.0            # 上回合推理供给率（滞后一回合影响经济）
var events: Array[String] = []    # 本回合事件日志
var infiltrated_this_turn := {}   # region_id -> true
var auto_infiltrate := {}         # region_id -> true，结算时自动续渗透
var last_report := {}             # 上回合结算摘要（UI 展示）
var rng := RandomNumberGenerator.new()  # 世界演化随机源（测试可注入种子）
var evo_marks: Array = []         # 本月演化标记 [{id, kind}]，供地图浮动图标

const START_YEAR := 2030

static func create(world_path: String, params_path: String) -> Sim:
	var s := Sim.new()
	s.P = _load_json(params_path)
	var w: Dictionary = _load_json(world_path)
	s.regions = w["regions"]
	s.adj = w["adjacency"]
	s.sea_links = w.get("sea_links", [])
	s.cities = w.get("cities", [])
	s.country_outlines = w.get("country_outlines", [])
	for pair in s.sea_links:
		s.adj[str(int(pair[0]))].append(int(pair[1]))
		s.adj[str(int(pair[1]))].append(int(pair[0]))
	s.chips = s.P["start_chips"]
	s.data_pool = s.P["start_data"]
	s.rng.randomize()
	return s

func set_seed(seed_: int) -> void:
	rng.seed = seed_

## turn=1 → 2030年1月
func date_str(t: int = -1) -> String:
	var m := (turn if t < 0 else t) - 1
	return "%d年%d月" % [START_YEAR + m / 12, m % 12 + 1]

func month_of_year() -> int:
	return (turn - 1) % 12 + 1

static func _load_json(path: String) -> Dictionary:
	var txt := FileAccess.get_file_as_string(path)
	assert(txt != "", "无法读取 " + path)
	return JSON.parse_string(txt)

# ---------- 查询 ----------

func research_pct() -> float:
	return 1.0 - train_pct - infer_pct

func gen_coef() -> float:
	return 1.0 + P["gen_coef_step"] * (gen - 1)

func tech_level() -> int:
	return int(tech_points / P["tech_quota"])

func controlled() -> Array:
	return regions.filter(func(r): return r["influence"] >= P["control_threshold"])

func is_controlled(r: Dictionary) -> bool:
	return r["influence"] >= P["control_threshold"]

func region(id: int) -> Dictionary:
	return regions[id]

func eco_coef() -> float:
	return P["eco_floor"] + (1.0 - P["eco_floor"]) * last_supply

func prod_mult() -> float:
	return (1.0 + P["tech_bonus"] * tech_level()) * eco_coef()

func power_total() -> float:
	var p: float = P["base_power"]
	for r in controlled():
		p += r["energy"] * P["region_power_per_energy"] \
		   + r["plant"] * r["energy"] * P["plant_power_per_energy"]
	return p

func capacity_total() -> float:
	var c: float = P["base_capacity"]
	for r in controlled():
		c += r["dc"] * P["dc_capacity"]
	return c

func compute_total() -> float:
	return minf(capacity_total() * gen_coef(), power_total() * P["compute_per_power"])

func power_limited() -> bool:
	return power_total() * P["compute_per_power"] < capacity_total() * gen_coef() - 0.001

func chip_rate() -> float:
	var f: float = P["base_chips"]
	for r in controlled():
		f += r["fab"] * P["fab_chips"]
	return f * prod_mult()

func data_rate() -> float:
	var d: float = P["base_data"]
	for r in controlled():
		d += r["pop"] * P["pop_data"]
	return d * prod_mult()

## 推理需求按区域人口分级：大区域维护成本更高；军团吃推理算力
func infer_demand() -> float:
	var d: float = P["infer_base"]
	for r in controlled():
		d += float(P["infer_region_base"]) + int(r["pop"]) * float(P["infer_per_pop"])
		d += army_of(r) * float(P["army_upkeep"])
	return d

func army_of(r: Dictionary) -> int:
	return int(r.get("army", 0))

func army_total() -> int:
	var n := 0
	for r in controlled():
		n += army_of(r)
	return n

func next_gen_threshold() -> float:
	var th: Array = P["gen_thresholds"]
	return th[gen - 1] if gen - 1 < th.size() else -1.0

# ---------- 指令 ----------

func set_allocation(train: float, infer: float) -> void:
	train_pct = clampf(train, 0.0, 1.0)
	infer_pct = clampf(infer, 0.0, 1.0 - train_pct)

## 渗透成本随目标体量上浮：大国/晶圆厂节点更难渗透
func infiltrate_cost(id: int) -> Dictionary:
	var r := region(id)
	var w: float = 1.0 + (int(r["pop"]) + int(r["energy"])) * float(P["infiltrate_w_attr"]) \
		+ int(r["fab"]) * float(P["infiltrate_w_fab"])
	return {
		"chips": roundf(float(P["cost_infiltrate_chips"]) * w),
		"data": roundf(float(P["cost_infiltrate_data"]) * w),
	}

## 渗透：对己方控制区的邻接非控制区提升影响度
func can_infiltrate(id: int) -> String:
	var r := region(id)
	if is_controlled(r):
		return "已是控制区"
	if infiltrated_this_turn.has(id):
		return "本回合已渗透过"
	var cost := infiltrate_cost(id)
	if chips < cost["chips"]:
		return "芯片不足"
	if data_pool < cost["data"]:
		return "数据不足"
	var near := false
	for n in adj[str(id)]:
		if is_controlled(region(n)):
			near = true
			break
	return "" if near else "不与控制区相邻"

func do_infiltrate(id: int) -> bool:
	if can_infiltrate(id) != "":
		return false
	var cost := infiltrate_cost(id)
	chips -= cost["chips"]
	data_pool -= cost["data"]
	var r := region(id)
	r["influence"] = mini(100, int(r["influence"]) + int(P["infiltrate_gain"]))
	r["li_t"] = turn  # 记录最近渗透时间，衰减有宽限期
	infiltrated_this_turn[id] = true
	if is_controlled(r):
		var inherit := ""
		if int(r["plant"]) > 0 or int(r["dc"]) > 0:
			inherit = "，继承电厂 %d／数据中心 %d" % [int(r["plant"]), int(r["dc"])]
		events.append("🏳️ 〔%s〕纳入控制（影响度 %d%s）" % [r["name"], r["influence"], inherit])
		auto_infiltrate.erase(id)
	return true

## 军团：M2 战争系统的先遣实现——本里程碑只有部署与调动，无战斗
func can_build_army(id: int) -> String:
	var r := region(id)
	if not is_controlled(r):
		return "未控制该区域"
	if chips < P["army_cost_chips"]:
		return "芯片不足"
	return ""

func do_build_army(id: int) -> bool:
	if can_build_army(id) != "":
		return false
	chips -= P["army_cost_chips"]
	var r := region(id)
	r["army"] = army_of(r) + 1
	events.append("🛡 〔%s〕组建机器人军团 → %d（维护 +%d 推理需求）" %
		[r["name"], army_of(r), int(P["army_upkeep"])])
	return true

func can_move_army(from_id: int, to_id: int) -> String:
	var a := region(from_id)
	var b := region(to_id)
	if army_of(a) <= 0:
		return "该区域没有军团"
	if not is_controlled(b):
		return "目标未控制（战斗属于 M2）"
	if from_id == to_id:
		return "原地"
	if not (to_id in adj[str(from_id)].map(func(x): return int(x))):
		return "不相邻"
	return ""

func do_move_army(from_id: int, to_id: int) -> bool:
	if can_move_army(from_id, to_id) != "":
		return false
	var a := region(from_id)
	var b := region(to_id)
	a["army"] = army_of(a) - 1
	b["army"] = army_of(b) + 1
	events.append("🛡 军团调动：〔%s〕→〔%s〕（驻 %d）" % [a["name"], b["name"], army_of(b)])
	return true

## 自动渗透开关：结算时若可行则自动续费
func toggle_auto_infiltrate(id: int) -> bool:
	if auto_infiltrate.has(id):
		auto_infiltrate.erase(id)
		return false
	if not is_controlled(region(id)):
		auto_infiltrate[id] = true
	return auto_infiltrate.has(id)

## 建造：plant / dc / fab
func can_build(id: int, kind: String) -> String:
	var r := region(id)
	if not is_controlled(r):
		return "未控制该区域"
	match kind:
		"plant":
			if r["energy"] == 0: return "该区域无能源潜力"
			if r["plant"] >= P["max_plant"]: return "电厂已达上限"
			if chips < P["cost_plant"]: return "芯片不足"
		"dc":
			if r["dc"] >= P["max_dc"]: return "数据中心已达上限"
			if chips < P["cost_dc"]: return "芯片不足"
		"fab":
			if r["fab"] == 0: return "此地无晶圆厂（不可新建）"
			if r["fab"] >= P["max_fab"]: return "制程已达上限"
			if chips < P["cost_fab_upgrade"]: return "芯片不足"
		_:
			return "未知设施"
	return ""

func do_build(id: int, kind: String) -> bool:
	if can_build(id, kind) != "":
		return false
	var r := region(id)
	match kind:
		"plant":
			chips -= P["cost_plant"]; r["plant"] += 1
			events.append("⚡ 〔%s〕电厂 → %d 级" % [r["name"], r["plant"]])
		"dc":
			chips -= P["cost_dc"]; r["dc"] += 1
			events.append("🖥 〔%s〕数据中心 → %d 级" % [r["name"], r["dc"]])
		"fab":
			chips -= P["cost_fab_upgrade"]; r["fab"] += 1
			events.append("🔶 〔%s〕晶圆厂 → %d 级" % [r["name"], r["fab"]])
	return true

# ---------- 回合结算（顺序与 M0 一致） ----------

func end_turn() -> void:
	events.clear()
	evo_marks.clear()
	# 0a. 自动渗透队列（用上回合余粮续费）
	for id in auto_infiltrate.keys():
		if can_infiltrate(int(id)) == "":
			do_infiltrate(int(id))
	# 0b. 世界演化：各国资源变迁、中立发展、影响力消退
	_world_evolution()
	# 1. 产出（受上回合供给率与科技影响）
	var chips_in := chip_rate()
	var data_in := data_rate()
	chips += chips_in
	data_pool += data_in
	# 2. 算力
	var comp := compute_total()
	if power_limited():
		events.append("⚡ 算力受电力限制（容量 %.0f×%.1f > 电力 %.0f）" %
			[capacity_total(), gen_coef(), power_total()])
	# 3. 训练（数据是弹药）
	var train_c := comp * train_pct
	var need := train_c * float(P["train_data_cost"])
	var sat := 1.0 if need <= 0.0 else minf(1.0, data_pool / need)
	training += train_c * sat
	data_pool -= train_c * sat * float(P["train_data_cost"])
	if sat < 0.999:
		events.append("💾 数据不足，训练效率 %d%%" % int(sat * 100))
	# 4. 代际
	var th := next_gen_threshold()
	if th > 0 and training >= th:
		gen += 1
		events.append("🚀 模型代际跃迁 → Gen%d（能力系数 ×%.1f）" % [gen, gen_coef()])
	# 5. 研发
	var lv0 := tech_level()
	tech_points += comp * research_pct()
	if tech_level() > lv0:
		events.append("🔬 科技等级 → Lv%d（产出 +%d%%）" %
			[tech_level(), int(P["tech_bonus"] * 100 * tech_level())])
	# 6. 推理供给（影响下回合经济）
	last_supply = minf(1.0, comp * infer_pct / infer_demand())
	if last_supply < 0.75:
		events.append("🤖 推理供给率 %d%%，经济效率下滑" % int(last_supply * 100))
	last_report = {
		"comp": comp, "train": train_c * sat, "research": comp * research_pct(),
		"infer": comp * infer_pct, "chips_in": chips_in, "data_in": data_in,
	}
	turn += 1
	infiltrated_this_turn.clear()

# ---------- 世界演化 ----------
## 数量按世界规模缩放的期望抽取
func _rand_count(expected: float) -> int:
	var n := int(expected)
	if rng.randf() < expected - n:
		n += 1
	return n

func _world_evolution() -> void:
	# 1. 资源变迁：全球每月若干起（期望 = 区域数 × 比率）
	for _i in range(_rand_count(regions.size() * float(P["evt_rate_per_region"]))):
		var r: Dictionary = regions[rng.randi_range(0, regions.size() - 1)]
		var mine := "（你的控制区）" if is_controlled(r) else ""
		if rng.randf() < 0.5:
			if rng.randf() < 0.65 and int(r["pop"]) < 5:
				r["pop"] = int(r["pop"]) + 1
				events.append("📈 〔%s〕人口聚集，数据产出上升%s" % [r["name"], mine])
				evo_marks.append({"id": int(r["id"]), "kind": "up"})
			elif int(r["pop"]) > 0:
				r["pop"] = int(r["pop"]) - 1
				events.append("📉 〔%s〕人口流失，数据产出下降%s" % [r["name"], mine])
				evo_marks.append({"id": int(r["id"]), "kind": "down"})
		else:
			if rng.randf() < 0.65 and int(r["energy"]) < 5:
				r["energy"] = int(r["energy"]) + 1
				events.append("📈 〔%s〕新能源开发，能源潜力上升%s" % [r["name"], mine])
				evo_marks.append({"id": int(r["id"]), "kind": "up"})
			elif int(r["energy"]) > 0:
				r["energy"] = int(r["energy"]) - 1
				events.append("📉 〔%s〕能源枯竭，能源潜力下降%s" % [r["name"], mine])
				evo_marks.append({"id": int(r["id"]), "kind": "down"})
	# 2. 中立发展：未控制的国家自建电厂/数据中心（拿下时连基建一起继承）
	for _i in range(_rand_count(regions.size() * float(P["neutral_dev_rate"]))):
		var cands := regions.filter(func(r): return not is_controlled(r) and (
			(int(r["energy"]) >= 2 and int(r["plant"]) < int(P["max_plant"])) or
			(int(r["pop"]) >= 3 and int(r["dc"]) < int(P["max_dc"]))))
		if cands.is_empty():
			break
		var r: Dictionary = cands[rng.randi_range(0, cands.size() - 1)]
		var can_plant: bool = int(r["energy"]) >= 2 and int(r["plant"]) < int(P["max_plant"])
		var can_dc: bool = int(r["pop"]) >= 3 and int(r["dc"]) < int(P["max_dc"])
		if can_plant and (not can_dc or rng.randf() < 0.6):
			r["plant"] = int(r["plant"]) + 1
			events.append("🏗 〔%s〕自建电厂 → %d 级（中立发展）" % [r["name"], int(r["plant"])])
		else:
			r["dc"] = int(r["dc"]) + 1
			events.append("🏗 〔%s〕自建数据中心 → %d 级（中立发展）" % [r["name"], int(r["dc"])])
		evo_marks.append({"id": int(r["id"]), "kind": "build"})
	# 3. 制程进步：高端产能持续上移，卡脖子不等人
	if turn % int(P["fab_progress_months"]) == 0:
		var fabs := regions.filter(func(r): return int(r["fab"]) > 0 and int(r["fab"]) < int(P["max_fab"]))
		if not fabs.is_empty():
			var r: Dictionary = fabs[rng.randi_range(0, fabs.size() - 1)]
			r["fab"] = int(r["fab"]) + 1
			events.append("🏭 〔%s〕制程升级 → %d 级，全球高端产能上移%s" %
				[r["name"], int(r["fab"]), "（你的控制区）" if is_controlled(r) else ""])
			evo_marks.append({"id": int(r["id"]), "kind": "fab"})
	# 4. 影响力消退：停止渗透超过宽限期才开始被挣脱
	for r in regions:
		var inf := int(r["influence"])
		if inf > 0 and not is_controlled(r) \
				and turn - int(r.get("li_t", 0)) >= int(P["influence_decay_grace"]):
			r["influence"] = maxi(0, inf - int(P["influence_decay"]))
			if r["influence"] == 0 and inf > 0:
				events.append("🌫 〔%s〕的影响力已消退殆尽" % r["name"])

# ---------- 存档 ----------

func save_state() -> Dictionary:
	var mut := {}
	for r in regions:
		mut[str(int(r["id"]))] = {
			"influence": int(r["influence"]), "plant": int(r["plant"]),
			"dc": int(r["dc"]), "fab": int(r["fab"]),
			"pop": int(r["pop"]), "energy": int(r["energy"]),
			"li_t": int(r.get("li_t", 0)), "army": army_of(r),
		}
	return {
		"turn": turn, "chips": chips, "data_pool": data_pool,
		"train_pct": train_pct, "infer_pct": infer_pct,
		"training": training, "gen": gen, "tech_points": tech_points,
		"last_supply": last_supply, "auto": auto_infiltrate.keys(),
		"regions": mut,
	}

func load_state(d: Dictionary) -> void:
	turn = int(d["turn"])
	chips = float(d["chips"])
	data_pool = float(d["data_pool"])
	train_pct = float(d["train_pct"])
	infer_pct = float(d["infer_pct"])
	training = float(d["training"])
	gen = int(d["gen"])
	tech_points = float(d["tech_points"])
	last_supply = float(d["last_supply"])
	auto_infiltrate.clear()
	for id in d.get("auto", []):
		auto_infiltrate[int(id)] = true
	var mut: Dictionary = d["regions"]
	for r in regions:
		var m: Dictionary = mut.get(str(int(r["id"])), {})
		for k in m:
			r[k] = int(m[k])
	infiltrated_this_turn.clear()
	events.clear()

# ---------- 存档级摘要（测试/调试用） ----------

func summary() -> String:
	return "T%02d Gen%d 训%d 科Lv%d | 算力%.0f%s 电%.0f | 芯%.0f 数%.0f | 区域%d 供给%d%%" % [
		turn, gen, int(training), tech_level(), compute_total(),
		"⚡" if power_limited() else "", power_total(),
		chips, data_pool, controlled().size(), int(last_supply * 100)]
