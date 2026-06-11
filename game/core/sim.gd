class_name Sim
extends RefCounted
## 纯逻辑层：多势力（玩家 + AI 大国）。不依赖任何 UI/渲染，可被无头测试驱动。
## 月度结算顺序与 M0 数值原型保持一致；所有势力共用同一套成本与产出公式（AI 不作弊资源）。

const AIPolicy = preload("res://core/ai.gd")

var P: Dictionary                 # 参数表
var regions: Array = []           # 区域状态（设施/军团/按势力影响度）
var adj: Dictionary = {}          # id -> [邻接 id]
var sea_links: Array = []         # 跨洋航线
var cities: Array = []            # 主要城市（表现层用）
var country_outlines: Array = []  # 国界轮廓（表现层用）

## 势力：factions[0] 恒为玩家
var factions: Array = []
var turn := 1
var events: Array[String] = []    # 本月事件日志（玩家视角）
var evo_marks: Array = []         # 地图浮动标记 [{id, kind}]
var auto_infiltrate := {}         # 玩家自动渗透队列 region_id -> true
var infiltrated_this_turn := {}   # "fid:rid" -> true
var last_report := {}             # 玩家结算摘要
var contained_fid := -1           # 当前被全球围堵的势力（-1 = 无）
var rng := RandomNumberGenerator.new()

const START_YEAR := 2030
const CTRL := 60                  # 控制阈值（与参数表 control_threshold 一致）

## AI 大国预设：起始区域 + 性格权重（w_* 影响渗透选址，alloc 为算力分配基线）
const AI_FACTIONS := [
	{
		"key": "USA", "name": "美利坚体系",
		"capital": "USA:纽约州", "start": ["USA:加利福尼亚州", "USA:得克萨斯州"],
		"start_fab": "USA:加利福尼亚州",
		"persona": {"w_pop": 1.0, "w_energy": 1.0, "w_fab": 4.0,
			"alloc_train": 0.38, "alloc_infer": 0.34, "army_drive": 0.4, "expand": 2},
	},
	{
		"key": "RUS", "name": "北方集团",
		"capital": "RUS:西部", "start": ["RUS:乌拉尔", "RUS:西西伯利亚"],
		"start_fab": "",
		"persona": {"w_pop": 0.6, "w_energy": 1.6, "w_fab": 2.0,
			"alloc_train": 0.22, "alloc_infer": 0.46, "army_drive": 1.0, "expand": 2},
	},
]

static func create(world_path: String, params_path: String) -> Sim:
	var s := Sim.new()
	s.P = _load_json(params_path)
	var w: Dictionary = _load_json(world_path)
	s.regions = w["regions"]
	s.adj = w["adjacency"]
	s.sea_links = w.get("sea_links", [])
	for pair in s.sea_links:
		s.adj[str(int(pair[0]))].append(int(pair[1]))
		s.adj[str(int(pair[1]))].append(int(pair[0]))
	s.cities = w.get("cities", [])
	s.country_outlines = w.get("country_outlines", [])
	s._init_factions(w)
	s.rng.randomize()
	return s

static func _load_json(path: String) -> Dictionary:
	var txt := FileAccess.get_file_as_string(path)
	assert(txt != "", "无法读取 " + path)
	return JSON.parse_string(txt)

func _new_faction(key: String, name_: String, persona: Dictionary) -> Dictionary:
	return {
		"key": key, "name": name_, "persona": persona,
		"chips": float(P["start_chips"]), "data_pool": float(P["start_data"]),
		"train_pct": 0.34, "infer_pct": 0.33,
		"training": 0.0, "gen": 1, "tech_points": 0.0, "last_supply": 1.0,
		"capital_id": -1,
	}

func _init_factions(_w: Dictionary) -> void:
	var key2id := {}
	for r in regions:
		key2id[r.get("key", "")] = int(r["id"])
		# 影响度迁移为按势力记账：世界数据里烘焙的是玩家起始区
		var inf := {}
		if int(r.get("influence", 0)) > 0:
			inf["0"] = int(r["influence"])
		r["inf"] = inf
		r["li"] = {}
	# 玩家
	var player := _new_faction("PLAYER", "玩家", {})
	for r in regions:
		if r.get("capital", false):
			player["capital_id"] = int(r["id"])
	factions = [player]
	# AI 大国
	for spec in AI_FACTIONS:
		var f := _new_faction(spec["key"], spec["name"], spec["persona"])
		var fid := factions.size()
		var cap_id: int = key2id.get(spec["capital"], -1)
		assert(cap_id >= 0, "AI 首都不存在: " + spec["capital"])
		f["capital_id"] = cap_id
		var cap := region(cap_id)
		cap["inf"][str(fid)] = 100
		cap["dc"] = maxi(int(cap["dc"]), 2)
		cap["plant"] = maxi(int(cap["plant"]), 1)
		for k in spec["start"]:
			if key2id.has(k):
				region(key2id[k])["inf"][str(fid)] = 100
		if spec["start_fab"] != "" and key2id.has(spec["start_fab"]):
			var fr := region(key2id[spec["start_fab"]])
			fr["fab"] = maxi(int(fr["fab"]), 1)
		factions.append(f)

func set_seed(seed_: int) -> void:
	rng.seed = seed_

## 玩家字段代理：UI/测试可继续用 sim.chips 等读取玩家状态
func _get(prop: StringName):
	match prop:
		&"chips": return factions[0]["chips"]
		&"data_pool": return factions[0]["data_pool"]
		&"train_pct": return factions[0]["train_pct"]
		&"infer_pct": return factions[0]["infer_pct"]
		&"training": return factions[0]["training"]
		&"gen": return factions[0]["gen"]
		&"tech_points": return factions[0]["tech_points"]
		&"last_supply": return factions[0]["last_supply"]
	return null

# ---------- 日期 ----------

func date_str(t: int = -1) -> String:
	var m := (turn if t < 0 else t) - 1
	return "%d年%d月" % [START_YEAR + m / 12, m % 12 + 1]

func month_of_year() -> int:
	return (turn - 1) % 12 + 1

# ---------- 查询 ----------

func region(id: int) -> Dictionary:
	return regions[id]

func faction_name(fid: int) -> String:
	return factions[fid]["name"]

func influence_of(r: Dictionary, fid: int) -> int:
	return int(r["inf"].get(str(fid), 0))

## 区域归属：影响度 >= 阈值的势力（互斥：达成控制时清空他人影响度）
func owner_of(r: Dictionary) -> int:
	for fid_s in r["inf"]:
		if int(r["inf"][fid_s]) >= CTRL:
			return int(fid_s)
	return -1

func is_owned_by(r: Dictionary, fid: int) -> bool:
	return influence_of(r, fid) >= CTRL

func is_controlled(r: Dictionary) -> bool:
	return is_owned_by(r, 0)

func controlled_of(fid: int) -> Array:
	return regions.filter(func(r): return is_owned_by(r, fid))

func controlled() -> Array:
	return controlled_of(0)

func research_pct(fid: int = 0) -> float:
	var f: Dictionary = factions[fid]
	return 1.0 - f["train_pct"] - f["infer_pct"]

func gen_coef(fid: int = 0) -> float:
	return 1.0 + P["gen_coef_step"] * (int(factions[fid]["gen"]) - 1)

func tech_level(fid: int = 0) -> int:
	return int(float(factions[fid]["tech_points"]) / P["tech_quota"])

func eco_coef(fid: int = 0) -> float:
	return P["eco_floor"] + (1.0 - P["eco_floor"]) * float(factions[fid]["last_supply"])

func prod_mult(fid: int = 0) -> float:
	return (1.0 + P["tech_bonus"] * tech_level(fid)) * eco_coef(fid)

func power_total(fid: int = 0) -> float:
	var p: float = P["base_power"]
	for r in controlled_of(fid):
		p += r["energy"] * P["region_power_per_energy"] \
		   + r["plant"] * r["energy"] * P["plant_power_per_energy"]
	return p

func capacity_total(fid: int = 0) -> float:
	var c: float = P["base_capacity"]
	for r in controlled_of(fid):
		c += r["dc"] * P["dc_capacity"]
	return c

func compute_total(fid: int = 0) -> float:
	return minf(capacity_total(fid) * gen_coef(fid), power_total(fid) * P["compute_per_power"])

func power_limited(fid: int = 0) -> bool:
	return power_total(fid) * P["compute_per_power"] < capacity_total(fid) * gen_coef(fid) - 0.001

func chip_rate(fid: int = 0) -> float:
	var v: float = P["base_chips"]
	for r in controlled_of(fid):
		v += r["fab"] * P["fab_chips"]
	return v * prod_mult(fid)

func data_rate(fid: int = 0) -> float:
	var d: float = P["base_data"]
	for r in controlled_of(fid):
		d += r["pop"] * P["pop_data"]
	return d * prod_mult(fid)

func infer_demand(fid: int = 0) -> float:
	var d: float = P["infer_base"]
	for r in controlled_of(fid):
		d += float(P["infer_region_base"]) + int(r["pop"]) * float(P["infer_per_pop"])
		d += army_of(r) * float(P["army_upkeep"])
	return d

func next_gen_threshold(fid: int = 0) -> float:
	var th: Array = P["gen_thresholds"]
	var g: int = factions[fid]["gen"]
	return th[g - 1] if g - 1 < th.size() else -1.0

func army_of(r: Dictionary) -> int:
	return int(r.get("army", 0))

func army_total(fid: int = 0) -> int:
	var n := 0
	for r in controlled_of(fid):
		n += army_of(r)
	return n

## 军力指数：军团规模 × 代际系数（M2 战力公式的雏形）
func military_index(fid: int) -> float:
	return army_total(fid) * gen_coef(fid)

# ---------- 反霸权动力学（设计文档 7.5 / 9.4） ----------
## 领跑者触发全球围堵：渗透增益削减、影响力消退加速、AI 转向堵截。
## 例外：拥有绝对军事霸权者无人敢围堵——弱霸权遭合纵，强霸权遭追随。

func _update_containment() -> void:
	# 领跑判定：控制区份额 / 代际领先
	var total := 0
	for fid in range(factions.size()):
		total += controlled_of(fid).size()
	var leader := -1
	var leader_n := 0
	for fid in range(factions.size()):
		var n := controlled_of(fid).size()
		if n > leader_n:
			leader_n = n
			leader = fid
	var threat := false
	if leader >= 0 and leader_n >= int(P["threat_min_regions"]):
		if total > 0 and float(leader_n) / total >= float(P["threat_region_share"]):
			threat = true
		var best_other_gen := 1
		for fid in range(factions.size()):
			if fid != leader:
				best_other_gen = maxi(best_other_gen, int(factions[fid]["gen"]))
		if int(factions[leader]["gen"]) - best_other_gen >= int(P["threat_gen_lead"]):
			threat = true
	# 绝对军事霸权豁免
	var exempt := false
	if threat:
		var others_mil := 0.0
		for fid in range(factions.size()):
			if fid != leader:
				others_mil += military_index(fid)
		var lm := military_index(leader)
		exempt = lm >= float(P["deterrence_min_mil"]) \
			and lm >= float(P["deterrence_ratio"]) * maxf(others_mil, 1.0)
	var new_contained := leader if (threat and not exempt) else -1
	if new_contained != contained_fid:
		if new_contained >= 0:
			events.append(("🛑 反霸权围堵：你的领跑引发全球警惕（渗透增益下降、影响力消退加速）"
				if new_contained == 0 else
				"🛑 反霸权围堵：〔%s〕的扩张引发全球合纵" % faction_name(new_contained)))
		elif contained_fid >= 0:
			if threat and exempt:
				events.append("⚔ 军事威慑：%s的绝对军力令围堵无从组织" %
					("你" if leader == 0 else "〔%s〕" % faction_name(leader)))
			else:
				events.append("🕊 围堵解除：%s不再被视为头号威胁" %
					("你" if contained_fid == 0 else "〔%s〕" % faction_name(contained_fid)))
		contained_fid = new_contained
	elif threat and exempt and contained_fid == -1 and turn % 12 == 0:
		events.append("⚔ 军事威慑维持中：%s的军力令各方不敢轻举妄动" %
			("你" if leader == 0 else "〔%s〕" % faction_name(leader)))

# ---------- 指令（fid 默认 0 = 玩家，UI/测试调用方式不变） ----------

func set_allocation(train: float, infer: float, fid: int = 0) -> void:
	var f: Dictionary = factions[fid]
	f["train_pct"] = clampf(train, 0.0, 1.0)
	f["infer_pct"] = clampf(infer, 0.0, 1.0 - f["train_pct"])

func infiltrate_cost(id: int) -> Dictionary:
	var r := region(id)
	var w: float = 1.0 + (int(r["pop"]) + int(r["energy"])) * float(P["infiltrate_w_attr"]) \
		+ int(r["fab"]) * float(P["infiltrate_w_fab"])
	return {
		"chips": roundf(float(P["cost_infiltrate_chips"]) * w),
		"data": roundf(float(P["cost_infiltrate_data"]) * w),
	}

func can_infiltrate(id: int, fid: int = 0) -> String:
	var r := region(id)
	var owner := owner_of(r)
	if owner == fid:
		return "已是控制区"
	if owner >= 0:
		return "已被〔%s〕控制（夺取属于 M2 战争）" % faction_name(owner)
	if infiltrated_this_turn.has("%d:%d" % [fid, id]):
		return "本月已渗透过"
	var f: Dictionary = factions[fid]
	var cost := infiltrate_cost(id)
	if f["chips"] < cost["chips"]:
		return "芯片不足"
	if f["data_pool"] < cost["data"]:
		return "数据不足"
	for n in adj[str(id)]:
		if is_owned_by(region(int(n)), fid):
			return ""
	return "不与控制区相邻"

func do_infiltrate(id: int, fid: int = 0) -> bool:
	if can_infiltrate(id, fid) != "":
		return false
	var f: Dictionary = factions[fid]
	var cost := infiltrate_cost(id)
	f["chips"] -= cost["chips"]
	f["data_pool"] -= cost["data"]
	var r := region(id)
	var key := str(fid)
	var gain := int(P["infiltrate_gain"])
	if fid == contained_fid:
		gain = int(round(gain * (1.0 - float(P["containment_gain_cut"]))))
	r["inf"][key] = mini(100, influence_of(r, fid) + gain)
	r["li"][key] = turn
	infiltrated_this_turn["%d:%d" % [fid, id]] = true
	if int(r["inf"][key]) >= CTRL:
		# 拉锯结束：竞争者的投入清零
		for k in r["inf"].keys():
			if k != key:
				r["inf"].erase(k)
		var inherit := ""
		if int(r["plant"]) > 0 or int(r["dc"]) > 0:
			inherit = "，继承电厂 %d／数据中心 %d" % [int(r["plant"]), int(r["dc"])]
		if fid == 0:
			events.append("🏳️ 〔%s〕纳入控制（影响度 %d%s）" % [r["name"], r["inf"][key], inherit])
			auto_infiltrate.erase(id)
		else:
			events.append("🌐 〔%s〕将〔%s〕纳入势力范围" % [faction_name(fid), r["name"]])
			evo_marks.append({"id": id, "kind": "flag"})
	return true

func toggle_auto_infiltrate(id: int) -> bool:
	if auto_infiltrate.has(id):
		auto_infiltrate.erase(id)
		return false
	if owner_of(region(id)) != 0:
		auto_infiltrate[id] = true
	return auto_infiltrate.has(id)

func can_build(id: int, kind: String, fid: int = 0) -> String:
	var r := region(id)
	if not is_owned_by(r, fid):
		return "未控制该区域"
	var f: Dictionary = factions[fid]
	match kind:
		"plant":
			if r["energy"] == 0: return "该区域无能源潜力"
			if r["plant"] >= P["max_plant"]: return "电厂已达上限"
			if f["chips"] < P["cost_plant"]: return "芯片不足"
		"dc":
			if r["dc"] >= P["max_dc"]: return "数据中心已达上限"
			if f["chips"] < P["cost_dc"]: return "芯片不足"
		"fab":
			if r["fab"] == 0: return "此地无晶圆厂（不可新建）"
			if r["fab"] >= P["max_fab"]: return "制程已达上限"
			if f["chips"] < P["cost_fab_upgrade"]: return "芯片不足"
		_:
			return "未知设施"
	return ""

func do_build(id: int, kind: String, fid: int = 0) -> bool:
	if can_build(id, kind, fid) != "":
		return false
	var r := region(id)
	var f: Dictionary = factions[fid]
	var who := "" if fid == 0 else "〔%s〕" % faction_name(fid)
	match kind:
		"plant":
			f["chips"] -= P["cost_plant"]; r["plant"] += 1
			if fid == 0: events.append("⚡ 〔%s〕电厂 → %d 级" % [r["name"], r["plant"]])
		"dc":
			f["chips"] -= P["cost_dc"]; r["dc"] += 1
			if fid == 0: events.append("🖥 〔%s〕数据中心 → %d 级" % [r["name"], r["dc"]])
		"fab":
			f["chips"] -= P["cost_fab_upgrade"]; r["fab"] += 1
			events.append("🔶 %s〔%s〕晶圆厂 → %d 级" % [who, r["name"], r["fab"]])
	return true

func can_build_army(id: int, fid: int = 0) -> String:
	if not is_owned_by(region(id), fid):
		return "未控制该区域"
	if factions[fid]["chips"] < P["army_cost_chips"]:
		return "芯片不足"
	return ""

func do_build_army(id: int, fid: int = 0) -> bool:
	if can_build_army(id, fid) != "":
		return false
	factions[fid]["chips"] -= P["army_cost_chips"]
	var r := region(id)
	r["army"] = army_of(r) + 1
	if fid == 0:
		events.append("🛡 〔%s〕组建机器人军团 → %d（维护 +%d 推理需求）" %
			[r["name"], army_of(r), int(P["army_upkeep"])])
	return true

func can_move_army(from_id: int, to_id: int, fid: int = 0) -> String:
	var a := region(from_id)
	var b := region(to_id)
	if not is_owned_by(a, fid):
		return "出发地未控制"
	if army_of(a) <= 0:
		return "该区域没有军团"
	if not is_owned_by(b, fid):
		return "目标未控制（战斗属于 M2）"
	if from_id == to_id:
		return "原地"
	if not (to_id in adj[str(from_id)].map(func(x): return int(x))):
		return "不相邻"
	return ""

func do_move_army(from_id: int, to_id: int, fid: int = 0) -> bool:
	if can_move_army(from_id, to_id, fid) != "":
		return false
	var a := region(from_id)
	var b := region(to_id)
	a["army"] = army_of(a) - 1
	b["army"] = army_of(b) + 1
	if fid == 0:
		events.append("🛡 军团调动：〔%s〕→〔%s〕（驻 %d）" % [a["name"], b["name"], army_of(b)])
	return true

# ---------- 月度结算 ----------

func end_turn() -> void:
	events.clear()
	evo_marks.clear()
	# 0. 反霸权态势更新（AI 决策与渗透增益都依赖它）
	_update_containment()
	# 0a. 玩家自动渗透队列
	for id in auto_infiltrate.keys():
		if can_infiltrate(int(id), 0) == "":
			do_infiltrate(int(id), 0)
	# 0b. AI 大国决策（与玩家同一套动作集与成本）
	for fid in range(1, factions.size()):
		AIPolicy.act(self, fid)
	# 0c. 世界演化
	_world_evolution()
	# 1~6. 各势力经济结算
	for fid in range(factions.size()):
		_resolve_economy(fid)
	turn += 1
	infiltrated_this_turn.clear()

func _resolve_economy(fid: int) -> void:
	var f: Dictionary = factions[fid]
	var chips_in := chip_rate(fid)
	var data_in := data_rate(fid)
	f["chips"] += chips_in
	f["data_pool"] += data_in
	var comp := compute_total(fid)
	if fid == 0 and power_limited(0):
		events.append("⚡ 算力受电力限制（容量 %.0f×%.1f > 电力 %.0f）" %
			[capacity_total(0), gen_coef(0), power_total(0)])
	# 训练
	var train_c: float = comp * f["train_pct"]
	var need: float = train_c * float(P["train_data_cost"])
	var sat := 1.0 if need <= 0.0 else minf(1.0, float(f["data_pool"]) / need)
	f["training"] += train_c * sat
	f["data_pool"] -= train_c * sat * float(P["train_data_cost"])
	if fid == 0 and sat < 0.999:
		events.append("💾 数据不足，训练效率 %d%%" % int(sat * 100))
	# 代际
	var th := next_gen_threshold(fid)
	if th > 0 and float(f["training"]) >= th:
		f["gen"] = int(f["gen"]) + 1
		if fid == 0:
			events.append("🚀 模型代际跃迁 → Gen%d（能力系数 ×%.1f）" % [f["gen"], gen_coef(0)])
		else:
			events.append("📡 情报：〔%s〕模型代际跃迁 → Gen%d" % [f["name"], f["gen"]])
	# 研发
	var lv0 := tech_level(fid)
	f["tech_points"] += comp * research_pct(fid)
	if fid == 0 and tech_level(0) > lv0:
		events.append("🔬 科技等级 → Lv%d（产出 +%d%%）" %
			[tech_level(0), int(P["tech_bonus"] * 100 * tech_level(0))])
	# 推理供给
	f["last_supply"] = minf(1.0, comp * f["infer_pct"] / infer_demand(fid))
	if fid == 0:
		if f["last_supply"] < 0.75:
			events.append("🤖 推理供给率 %d%%，经济效率下滑" % int(f["last_supply"] * 100))
		last_report = {
			"comp": comp, "train": train_c * sat, "research": comp * research_pct(0),
			"infer": comp * f["infer_pct"], "chips_in": chips_in, "data_in": data_in,
		}

# ---------- 世界演化 ----------

func _rand_count(expected: float) -> int:
	var n := int(expected)
	if rng.randf() < expected - n:
		n += 1
	return n

func _owner_note(r: Dictionary) -> String:
	var o := owner_of(r)
	if o == 0:
		return "（你的控制区）"
	if o > 0:
		return "（%s控制区）" % faction_name(o)
	return ""

func _world_evolution() -> void:
	# 1. 资源变迁
	for _i in range(_rand_count(regions.size() * float(P["evt_rate_per_region"]))):
		var r: Dictionary = regions[rng.randi_range(0, regions.size() - 1)]
		var mine := _owner_note(r)
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
	# 2. 中立发展
	for _i in range(_rand_count(regions.size() * float(P["neutral_dev_rate"]))):
		var cands := regions.filter(func(r): return owner_of(r) == -1 and (
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
	# 3. 制程进步
	if turn % int(P["fab_progress_months"]) == 0:
		var fabs := regions.filter(func(r): return int(r["fab"]) > 0 and int(r["fab"]) < int(P["max_fab"]))
		if not fabs.is_empty():
			var r: Dictionary = fabs[rng.randi_range(0, fabs.size() - 1)]
			r["fab"] = int(r["fab"]) + 1
			events.append("🏭 〔%s〕制程升级 → %d 级，全球高端产能上移%s" %
				[r["name"], int(r["fab"]), _owner_note(r)])
			evo_marks.append({"id": int(r["id"]), "kind": "fab"})
	# 4. 影响力消退（仅中立区域、且超过宽限期未续；被围堵者加速消退）
	for r in regions:
		if owner_of(r) >= 0:
			continue
		for k in r["inf"].keys():
			if turn - int(r["li"].get(k, 0)) >= int(P["influence_decay_grace"]):
				var dec: int = int(P["influence_decay"])
				if int(k) == contained_fid:
					dec *= int(P["containment_decay_mult"])
				var v: int = int(r["inf"][k]) - dec
				if v <= 0:
					r["inf"].erase(k)
					if k == "0":
						events.append("🌫 〔%s〕的影响力已消退殆尽" % r["name"])
				else:
					r["inf"][k] = v

# ---------- 存档 ----------

func save_state() -> Dictionary:
	var mut := {}
	for r in regions:
		mut[str(int(r["id"]))] = {
			"inf": r["inf"], "li": r["li"], "plant": int(r["plant"]),
			"dc": int(r["dc"]), "fab": int(r["fab"]),
			"pop": int(r["pop"]), "energy": int(r["energy"]), "army": army_of(r),
		}
	return {
		"v": 2, "turn": turn, "factions": factions,
		"auto": auto_infiltrate.keys(), "regions": mut,
	}

func load_state(d: Dictionary) -> void:
	turn = int(d["turn"])
	factions = d["factions"]
	for f in factions:
		f["gen"] = int(f["gen"])
		f["capital_id"] = int(f["capital_id"])
	auto_infiltrate.clear()
	for id in d.get("auto", []):
		auto_infiltrate[int(id)] = true
	var mut: Dictionary = d["regions"]
	for r in regions:
		var m: Dictionary = mut.get(str(int(r["id"])), {})
		for k in m:
			r[k] = m[k]
		for kk in ["plant", "dc", "fab", "pop", "energy", "army"]:
			r[kk] = int(r.get(kk, 0))
	infiltrated_this_turn.clear()
	events.clear()

func summary() -> String:
	var ai := ""
	for fid in range(1, factions.size()):
		ai += " %s%d区Gen%d" % [factions[fid]["key"], controlled_of(fid).size(), factions[fid]["gen"]]
	return "T%02d Gen%d 训%d 科Lv%d | 算力%.0f%s 电%.0f | 芯%.0f 数%.0f | 区域%d 供给%d%% |%s" % [
		turn, factions[0]["gen"], int(factions[0]["training"]), tech_level(0), compute_total(0),
		"⚡" if power_limited(0) else "", power_total(0),
		factions[0]["chips"], factions[0]["data_pool"], controlled().size(),
		int(factions[0]["last_supply"] * 100), ai]
