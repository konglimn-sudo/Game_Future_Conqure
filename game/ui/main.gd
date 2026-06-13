extends Node2D
## M1 表现层：真实国界世界地图 + 面板 + 算力分配。所有规则调用 core/sim.gd。

const COL_NEUTRAL := Color(0.21, 0.23, 0.27)
const COL_OWNED := Color(0.16, 0.42, 0.78)
const COL_TOUCH := Color(0.17, 0.34, 0.42)
const COL_BORDER := Color(0.05, 0.06, 0.09, 0.9)

# 势力主色：0=玩家（皇家蓝）、1=美利坚体系（青）、2=北方集团（绯红）
# 3=欧罗巴联合体（琥珀金）、4=天竺崛起（藏红橙）
const FACTION_COLORS := {
	0: Color(0.16, 0.42, 0.78),
	1: Color(0.10, 0.46, 0.46),
	2: Color(0.64, 0.17, 0.15),
	3: Color(0.62, 0.52, 0.16),
	4: Color(0.80, 0.47, 0.10),
}

# 政治地图配色：主要国家钉死色（自制暗色系），其余按国家码散列取色
const COUNTRY_COLORS := {
	"USA": Color(0.30, 0.37, 0.49), "RUS": Color(0.47, 0.27, 0.24),
	"IND": Color(0.46, 0.39, 0.22), "CAN": Color(0.35, 0.31, 0.43),
	"GBR": Color(0.41, 0.30, 0.38), "FRA": Color(0.28, 0.34, 0.52),
	"DEU": Color(0.36, 0.38, 0.41), "JPN": Color(0.47, 0.38, 0.42),
	"KOR": Color(0.28, 0.42, 0.42), "TWN": Color(0.33, 0.44, 0.35),
	"BRA": Color(0.29, 0.43, 0.30), "AUS": Color(0.46, 0.36, 0.25),
	"SAU": Color(0.43, 0.40, 0.27), "IRN": Color(0.39, 0.32, 0.25),
	"EGY": Color(0.44, 0.40, 0.29), "MEX": Color(0.40, 0.35, 0.27),
	"IDN": Color(0.34, 0.40, 0.31), "TUR": Color(0.43, 0.33, 0.30),
	"PAK": Color(0.30, 0.40, 0.34), "NGA": Color(0.32, 0.41, 0.28),
	"UKR": Color(0.38, 0.40, 0.30), "POL": Color(0.42, 0.34, 0.34),
	"ESP": Color(0.44, 0.37, 0.28), "ITA": Color(0.32, 0.42, 0.36),
}
var country_color_cache := {}

var sim: Sim
var selected := -1
var centers := {}          # id -> 标签锚点
var rings := {}            # id -> Array[PackedVector2Array]（点击判定 + 高亮）
var polynodes := {}        # id -> Array[Polygon2D]
var highlight: Line2D
var cam: Camera2D
var panning := false       # 右/中键拖动中
var maybe_select := false  # 左键按下，待判定是点击还是拖动
var drag_accum := 0.0      # 左键按下后的累计位移（像素）
var map_rect := Rect2()    # 镜头活动边界

var lbl_top := {}
var log_box: RichTextLabel
var sl_train: HSlider
var sl_infer: HSlider
var lbl_alloc: Label
var lbl_preview: Label
var lbl_region: RichTextLabel
var btn := {}
var labels := {}           # id -> 地图标签
var label_score := {}      # id -> 显示权重（决定缩放显隐）
var detail_labels := {}    # id -> 资源详情条（●⚡🔌🖥）
var army_badges := {}      # id -> 军团徽章（按势力着色）
var badge_styles := {}     # fid -> StyleBoxFlat
var big_labels: Array = [] # 大国名横铺层 {label, w}
var city_nodes: Array = [] # {dot, label, tier, region}
var border_lines: Array = []   # 省界细线
var outline_lines: Array = []  # 国界粗线
var lane_lines: Array = []     # 航线
var river_lines: Array = []    # 河流
var range_labels: Array = []   # 山脉/高原名
var ocean_labels: Array = []   # 大洋名
var mountain_polys: Array = [] # {poly, lat} 冬季积雪用
var lake_polys: Array = []     # {poly, lat} 结冰用
var terra_polys: Array = []    # {poly, lat, base} 地貌填充（沙漠/绿地/冻原）
var sea_labels: Array = []     # 海域名
var terrain_cache := {}        # terrain.json 解析缓存

# 卫星模式（NASA Blue Marble 逐月真彩影像，公有领域）与昼夜循环
var satellite_mode := true
var sat_sprite: Sprite2D
var sat_month := -1
var bathy_nodes: Array = []
var glacier_nodes: Array = []
var daynight_mat: ShaderMaterial
var sun_lon := 116.0           # 开局首都正午
# 高清瓦片层：21600×10800 四季影像切片，按视野动态装卸
var hd_layer: Node2D
var hd_tiles := {}             # "q_cx_cy" -> Sprite2D
const HD_ZOOM := 3.0           # 超过此缩放启用高清瓦片
const HD_TILE_WORLD := 315.0   # 每片覆盖的世界像素（2520/8）
const HD_COLS := 8
const HD_ROWS := 4
const HD_QUARTER := [1, 1, 2, 2, 2, 3, 3, 3, 4, 4, 4, 1]  # 月→季度图
# 第三级：500m/像素（86400×43200 全球 32×16 网格，纯海洋瓦片不存在→由下层垫底）
var hd2_layer: Node2D
var hd2_tiles := {}
const HD2_ZOOM := 8.0
const HD2_TILE_WORLD := 78.75  # 2520/32
const HD2_COLS := 32
const HD2_ROWS := 16
var lbl_tod: Label
var tod_accum := 0.0
const DECL_BY_MONTH := [-21.0, -13.0, -2.0, 9.0, 19.0, 23.0, 21.0, 14.0, 3.0, -8.0, -18.0, -23.0]
const DAY_CYCLE_SEC := 90.0    # 现实秒/一昼夜（纯演出层，与游戏速度无关）

# 海洋水深配色（卫星/暗色模式）：清屏色=大陆架浅蓝，越深越暗
const BATHY_COLORS := {
	200: Color(0.075, 0.125, 0.19),
	2000: Color(0.055, 0.095, 0.155),
	5000: Color(0.04, 0.07, 0.118),
}
# 纸图模式：经典战争地图的浅蓝海与亮色块
const BATHY_PAPER := {
	200: Color(0.62, 0.72, 0.82),
	2000: Color(0.55, 0.66, 0.78),
	5000: Color(0.49, 0.60, 0.73),
}
const PAPER_OCEAN := Color(0.55, 0.66, 0.78)
const PAPER_TEXT := Color(0.13, 0.14, 0.18)
const PAPER_TEXT_SHADOW := Color(1, 1, 1, 0.4)
const SAT_TEXT := Color(0.93, 0.96, 1.0)
const SAT_TEXT_SHADOW := Color(0, 0, 0, 0.8)

# 地貌配色（半透明叠加在政治底色之上）
const TERRA_COLORS := {
	"desert": Color(0.62, 0.53, 0.32, 0.26),
	"green": Color(0.27, 0.45, 0.25, 0.20),
	"tundra": Color(0.48, 0.52, 0.48, 0.22),
}

const MAP_SCALE := 7.0         # 像素/经度°，与生成器一致
const FONT_K := 3.0            # 地图文字按 3 倍字号光栅化再缩回，保证高倍缩放锐利
const SEASON_ICON := ["❄", "❄", "🌱", "🌱", "🌱", "☀", "☀", "☀", "🍂", "🍂", "🍂", "❄"]
var move_mode := false     # 军团调动：等待点击目的地
var attack_mode := false   # 军团进攻：等待点击相邻敌区
var milestones_done := {}

# 时间流动：每"月"自动结算一次
const SPEEDS := [10.0, 5.0, 2.5, 1.0]   # 秒/月
const SPEED_NAMES := ["1×", "2×", "4×", "10×"]
var paused := true
var speed_idx := 0
var month_accum := 0.0
var btn_pause: Button
var btn_speeds: Array[Button] = []
var month_bar: ProgressBar

func _ready() -> void:
	_setup_font()
	sim = Sim.create("res://data/world.json", "res://data/params.json")
	_build_map()
	_build_ui()
	var cap := _capital_id()
	cam = Camera2D.new()
	cam.position = centers.get(cap, Vector2.ZERO) + Vector2(-150, 60)
	cam.zoom = Vector2(0.85, 0.85)
	add_child(cam)
	cam.make_current()
	# 镜头活动边界：地图范围外扩一圈
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for c in centers.values():
		lo = lo.min(c)
		hi = hi.max(c)
	map_rect = Rect2(lo - Vector2(250, 250), hi - lo + Vector2(500, 500))
	_select(cap)
	_apply_zoom_styles()
	_update_label_visibility()
	_refresh_time_controls()
	_set_map_mode(false)  # 默认经典纸图（M 切换卫星）
	_update_tod_label()
	_refresh()
	# 截图模式：FC_SNAPSHOT=输出路径（可选 FC_SNAPSHOT_ZOOM），等渲染稳定后截屏退出
	var snap_path := OS.get_environment("FC_SNAPSHOT")
	if snap_path != "":
		var sz := OS.get_environment("FC_SNAPSHOT_ZOOM")
		if sz != "":
			cam.zoom = Vector2(float(sz), float(sz))
			cam.position = centers.get(_capital_id(), Vector2.ZERO)
			_apply_zoom_styles()
			_update_label_visibility()
		await get_tree().create_timer(2.5).timeout
		get_viewport().get_texture().get_image().save_png(snap_path)
		get_tree().quit()
	_log("[b]M3 大国竞逐[/b] —— 🟦 你（京津冀）对阵四大势力：[color=#2aa]美利坚体系（青）[/color]｜[color=#e54]北方集团（红）[/color]｜[color=#cb4]欧罗巴联合体（金）[/color]｜[color=#e92]天竺崛起（橙）[/color]")
	_log("时间以月流动；各国资源会变迁、中立国会自建基建（占领时继承）、放任的影响力会消退；中立区先到 60 影响度者得。")
	_log("左键拖动/点击选国 ｜ 双指或滚轮缩放 ｜ WASD 平移 ｜ 空格=继续/暂停 ｜ 1~4=速度 ｜ 回车=单步 ｜ M=卫星/政治图层 ｜ F5/F9=存/读档")
	_log("⚔ 战争（M2）：选敌方区域「宣战」→ 选己方驻军区「进攻」点相邻敌区。战力 = 军团×代际×补给×推理供给；断补给（⛓）战力 ×0.3，守方 +25%，新占领区 2 个月整编")
	_log("[color=#fc6]目标：控制 45 区、拿下高端晶圆厂、算力 200、科技 Lv10。按空格开始。[/color]")

func _setup_font() -> void:
	var f := SystemFont.new()
	f.font_names = PackedStringArray(["PingFang SC", "Hiragino Sans GB", "Heiti SC", "Arial Unicode MS"])
	# MSDF：距离场渲染，文字在任意缩放下保持矢量级锐利
	f.multichannel_signed_distance_field = true
	f.msdf_pixel_range = 8
	ThemeDB.fallback_font = f

func _capital_id() -> int:
	for r in sim.regions:
		if r["capital"]:
			return int(r["id"])
	return 0

# ---------------- 地图 ----------------

func _terrain_data() -> Dictionary:
	if terrain_cache.is_empty():
		var txt := FileAccess.get_file_as_string("res://data/terrain.json")
		terrain_cache = JSON.parse_string(txt) if txt != "" else {}
	return terrain_cache

func _build_map() -> void:
	var map := Node2D.new()
	map.name = "Map"
	add_child(map)
	# 卫星底图（逐月 Blue Marble，最底层）
	sat_sprite = Sprite2D.new()
	sat_sprite.centered = false
	sat_sprite.scale = Vector2(2520.0 / 2700.0, 1260.0 / 1350.0)
	map.add_child(sat_sprite)
	hd_layer = Node2D.new()
	map.add_child(hd_layer)
	hd2_layer = Node2D.new()
	map.add_child(hd2_layer)
	# 海洋水深分层（纸图/暗色两套配色，垫在陆地之下）
	for layer in _terrain_data().get("bathy", []):
		var depth := int(layer["depth"])
		for ring in layer["rings"]:
			var pts := PackedVector2Array()
			for p in ring:
				pts.append(Vector2(p[0], p[1]))
			var poly := Polygon2D.new()
			poly.polygon = pts
			poly.color = BATHY_PAPER.get(depth, PAPER_OCEAN)
			map.add_child(poly)
			bathy_nodes.append({"poly": poly, "depth": depth})
	# 区域多边形（含外环描边）
	for r in sim.regions:
		var id := int(r["id"])
		centers[id] = Vector2(r["label"][0], r["label"][1])
		rings[id] = []
		polynodes[id] = []
		for ring in r["polys"]:
			var pts := PackedVector2Array()
			for p in ring:
				pts.append(Vector2(p[0], p[1]))
			rings[id].append(pts)
			var poly := Polygon2D.new()
			poly.polygon = pts
			map.add_child(poly)
			polynodes[id].append(poly)
			var border := Line2D.new()
			var bp := pts.duplicate()
			bp.append(pts[0])
			border.points = bp
			border.width = 1.3
			border.default_color = COL_BORDER
			map.add_child(border)
			border_lines.append(border)
	_build_terrain(map)
	# 昼夜晨昏线（盖在地表之上、政区标签之下）
	var dn := Polygon2D.new()
	dn.polygon = PackedVector2Array([Vector2(-200, -200), Vector2(2720, -200),
		Vector2(2720, 1460), Vector2(-200, 1460)])
	daynight_mat = ShaderMaterial.new()
	daynight_mat.shader = load("res://ui/daynight.gdshader")
	dn.material = daynight_mat
	map.add_child(dn)
	# 拆省大国的国界粗描边
	for ring in sim.country_outlines:
		var pts := PackedVector2Array()
		for p in ring:
			pts.append(Vector2(p[0], p[1]))
		pts.append(pts[0])
		var ol := Line2D.new()
		ol.points = pts
		ol.width = 3.0
		ol.default_color = Color(0.02, 0.03, 0.05, 0.95)
		map.add_child(ol)
		outline_lines.append(ol)
	# 跨洋航线
	for pair in sim.sea_links:
		var lane := Line2D.new()
		lane.points = PackedVector2Array([centers[int(pair[0])], centers[int(pair[1])]])
		lane.width = 2.0
		lane.default_color = Color(0.45, 0.65, 0.95, 0.38)
		map.add_child(lane)
		lane_lines.append(lane)
	# 标签（按区域重要度 + 缩放级别显隐）
	for r in sim.regions:
		var id := int(r["id"])
		var lab := Label.new()
		lab.text = _region_caption(r)
		lab.position = centers[id] + Vector2(-52, -9)
		lab.size = Vector2(104, 18)
		lab.pivot_offset = Vector2(52, 9)
		lab.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		lab.add_theme_font_size_override("font_size", 10)
		lab.add_theme_color_override("font_color", Color(0.93, 0.96, 1.0))
		lab.add_theme_constant_override("shadow_offset_x", 1)
		lab.add_theme_constant_override("shadow_offset_y", 1)
		lab.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
		lab.mouse_filter = Control.MOUSE_FILTER_IGNORE
		map.add_child(lab)
		labels[id] = lab
		var det := Label.new()
		det.position = centers[id] + Vector2(-52, 5)
		det.size = Vector2(104, 16)
		det.pivot_offset = Vector2(52, 8)
		det.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		det.add_theme_font_size_override("font_size", 9)
		det.add_theme_color_override("font_color", Color(0.82, 0.9, 0.97))
		det.add_theme_stylebox_override("normal", _chip_style(true))
		det.mouse_filter = Control.MOUSE_FILTER_IGNORE
		map.add_child(det)
		detail_labels[id] = det
		var ab := Label.new()
		ab.position = centers[id] + Vector2(-22, 22)
		ab.size = Vector2(44, 15)
		ab.pivot_offset = Vector2(22, 7)
		ab.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		ab.add_theme_font_size_override("font_size", 10)
		ab.add_theme_color_override("font_color", Color(1, 0.92, 0.9))
		var absb := StyleBoxFlat.new()
		absb.bg_color = Color(0.52, 0.13, 0.13, 0.88)
		absb.set_corner_radius_all(3)
		absb.set_content_margin_all(1)
		ab.add_theme_stylebox_override("normal", absb)
		ab.mouse_filter = Control.MOUSE_FILTER_IGNORE
		ab.visible = false
		map.add_child(ab)
		army_badges[id] = ab
		var area := 0.0
		for ring in rings[id]:
			area = maxf(area, _ring_area(ring))
		label_score[id] = clampf(area / 2500.0, 0.0, 4.0) + int(r["pop"]) \
			+ int(r["fab"]) * 2 + (4 if r["capital"] else 0)
	# 主要城市图层
	for c in sim.cities:
		var pos := Vector2(c["x"], c["y"])
		var dot := Polygon2D.new()
		var rad: float = 3.4 if int(c["tier"]) == 1 else 2.2
		dot.polygon = _circle(rad)
		dot.position = pos
		dot.color = Color(0.98, 0.86, 0.5) if int(c["tier"]) == 1 else Color(0.75, 0.8, 0.88)
		map.add_child(dot)
		var cl := Label.new()
		cl.text = c["name"]
		cl.position = pos + Vector2(4, -8)
		cl.add_theme_font_size_override("font_size", 9)
		cl.add_theme_color_override("font_color", Color(0.85, 0.82, 0.7))
		cl.add_theme_constant_override("shadow_offset_x", 1)
		cl.add_theme_constant_override("shadow_offset_y", 1)
		cl.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
		cl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		map.add_child(cl)
		city_nodes.append({"dot": dot, "label": cl, "tier": int(c["tier"]), "region": int(c["region"])})
	_build_country_names(map)
	# 锐化所有地图文字：字号×K、盒子×K、围绕锚点缩回 1/K
	var all_map_labels := []
	for id in labels:
		all_map_labels.append(labels[id])
		all_map_labels.append(detail_labels[id])
		all_map_labels.append(army_badges[id])
	for c in city_nodes:
		all_map_labels.append(c["label"])
	all_map_labels.append_array(range_labels)
	all_map_labels.append_array(ocean_labels)
	all_map_labels.append_array(sea_labels)
	all_map_labels.append_array(big_labels)
	for lab in all_map_labels:
		_crispify(lab)
	highlight = Line2D.new()
	highlight.width = 2.6
	highlight.default_color = Color(1.0, 0.85, 0.3)
	highlight.visible = false
	map.add_child(highlight)

## 大国名横铺：多省国家的国名按领土跨度放大、拉开字距铺在版图上
func _build_country_names(map: Node2D) -> void:
	var groups := {}
	for r in sim.regions:
		var cc: String = str(r.get("key", "?")).split(":")[0]
		if not groups.has(cc):
			groups[cc] = {"ids": [], "name": ""}
		groups[cc]["ids"].append(int(r["id"]))
		groups[cc]["name"] = r["arch"] if ":" in str(r.get("key", "")) else r["name"]
	for cc in groups:
		var g: Dictionary = groups[cc]
		var lo := Vector2(INF, INF)
		var hi := Vector2(-INF, -INF)
		# 视觉重心 = 全部省份多边形的面积加权质心（包围盒中心对横跨大陆的国家会跑偏）
		var area_sum := 0.0
		var centroid := Vector2.ZERO
		for id in g["ids"]:
			lo = lo.min(centers[id])
			hi = hi.max(centers[id])
			for ring in rings[id]:
				var ra := _ring_area(ring)
				area_sum += ra
				centroid += _ring_centroid(ring) * ra
		var w: float = hi.x - lo.x
		if g["ids"].size() < 3 and w < 240.0:
			continue
		var anchor := (centroid / area_sum) if area_sum > 0.0 else (lo + hi) / 2.0
		var chars: PackedStringArray = []
		for ch in str(g["name"]):
			chars.append(ch)
		var lab := Label.new()
		lab.text = "  ".join(chars)
		var fs := clampi(int(w / maxi(chars.size(), 2) / 2.6), 16, 56)
		lab.add_theme_font_size_override("font_size", fs)
		lab.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		lab.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		lab.position = anchor + Vector2(-w / 2.0 - 40, -fs * 0.8)
		lab.size = Vector2(w + 80, fs * 1.6)
		lab.pivot_offset = lab.size / 2.0
		lab.mouse_filter = Control.MOUSE_FILTER_IGNORE
		lab.modulate.a = 0.55
		map.add_child(lab)
		big_labels.append(lab)

## 多边形质心（标准公式）
func _ring_centroid(ring: PackedVector2Array) -> Vector2:
	var a := 0.0
	var c := Vector2.ZERO
	for i in range(ring.size()):
		var p := ring[i]
		var q := ring[(i + 1) % ring.size()]
		var cross := p.x * q.y - q.x * p.y
		a += cross
		c += (p + q) * cross
	if absf(a) < 0.001:
		return ring[0]
	return c / (3.0 * a)

func _ring_area(ring: PackedVector2Array) -> float:
	var a := 0.0
	for i in range(ring.size()):
		var p := ring[i]
		var q := ring[(i + 1) % ring.size()]
		a += p.x * q.y - q.x * p.y
	return absf(a) * 0.5

## 缩放越远，只显示越重要的标签；选中/渗透中的区域始终显示
func _update_label_visibility() -> void:
	var z := cam.zoom.x
	var need := 0.0
	if z < 0.65:
		need = 8.0
	elif z < 1.0:
		need = 6.0
	elif z < 1.5:
		need = 3.5
	for id in labels:
		var r := sim.region(id)
		var active: bool = not sim.is_controlled(r) \
			and (sim.auto_infiltrate.has(id) or sim.influence_of(r, 0) > 0)
		labels[id].visible = label_score[id] >= need or id == selected or active
		# 详情条：拉近或选中时显示（军团有独立常显徽章）
		detail_labels[id].visible = labels[id].visible and (z >= 0.8 or id == selected)
	# 城市：一级城市中景可见，二级城市近景可见
	for c in city_nodes:
		var t1: bool = c["tier"] == 1
		c["dot"].visible = z >= (0.6 if t1 else 1.0) or c["region"] == selected
		c["label"].visible = z >= (0.9 if t1 else 1.35) or c["region"] == selected

## 地形表现层：山脉/高原体块、湖泊、河流、大洋名（纯视觉，不参与规则）
func _build_terrain(map: Node2D) -> void:
	var t := _terrain_data()
	if t.is_empty():
		return
	# 地貌填充：沙漠沙色、平原/三角洲/盆地绿色、冻原灰绿（画在山脉之下）
	for tr in t.get("terras", []):
		var base: Color = TERRA_COLORS.get(tr["cls"], Color(0.4, 0.4, 0.4, 0.15))
		for ring in tr["rings"]:
			var pts := PackedVector2Array()
			for p in ring:
				pts.append(Vector2(p[0], p[1]))
			var poly := Polygon2D.new()
			poly.polygon = pts
			poly.color = base
			map.add_child(poly)
			terra_polys.append({"poly": poly, "lat": float(tr["lat"]), "base": base})
	for rg in t.get("ranges", []):
		for ring in rg["rings"]:
			var pts := PackedVector2Array()
			for p in ring:
				pts.append(Vector2(p[0], p[1]))
			var poly := Polygon2D.new()
			poly.polygon = pts
			poly.color = Color(0.45, 0.36, 0.25, 0.15)
			map.add_child(poly)
			mountain_polys.append({"poly": poly, "lat": 90.0 - rg["label"][1] / MAP_SCALE})
		if rg.get("name", "") != "":
			var ml := Label.new()
			ml.text = "⛰ " + rg["name"]
			ml.position = Vector2(rg["label"][0] - 70, rg["label"][1] - 7)
			ml.size = Vector2(140, 14)
			ml.pivot_offset = Vector2(70, 7)
			ml.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			ml.add_theme_font_size_override("font_size", 9)
			ml.add_theme_color_override("font_color", Color(0.74, 0.64, 0.5, 0.8))
			ml.add_theme_constant_override("shadow_offset_x", 1)
			ml.add_theme_constant_override("shadow_offset_y", 1)
			ml.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.6))
			ml.mouse_filter = Control.MOUSE_FILTER_IGNORE
			map.add_child(ml)
			range_labels.append(ml)
	for ring in t.get("lakes", []):
		var pts := PackedVector2Array()
		for p in ring:
			pts.append(Vector2(p[0], p[1]))
		var lake := Polygon2D.new()
		lake.polygon = pts
		lake.color = Color(0.055, 0.095, 0.155)
		map.add_child(lake)
		var cy := 0.0
		for p in pts:
			cy += p.y
		lake_polys.append({"poly": lake, "lat": 90.0 - (cy / pts.size()) / MAP_SCALE})
	# 永久冰盖（格陵兰冰原等，常年雪白）
	for ring in t.get("glaciers", []):
		var pts := PackedVector2Array()
		for p in ring:
			pts.append(Vector2(p[0], p[1]))
		var gl := Polygon2D.new()
		gl.polygon = pts
		gl.color = Color(0.85, 0.89, 0.93, 0.5)
		map.add_child(gl)
		glacier_nodes.append(gl)
	for line in t.get("rivers", []):
		var pts := PackedVector2Array()
		for p in line:
			pts.append(Vector2(p[0], p[1]))
		var rv := Line2D.new()
		rv.points = pts
		rv.width = 1.0
		rv.default_color = Color(0.2, 0.36, 0.55, 0.7)
		map.add_child(rv)
		river_lines.append(rv)
	# 主要海域名称
	for s in t.get("seas", []):
		var sl := Label.new()
		sl.text = s["name"]
		sl.position = Vector2(s["p"][0] - 60, s["p"][1] - 9)
		sl.size = Vector2(120, 18)
		sl.pivot_offset = Vector2(60, 9)
		sl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		sl.add_theme_font_size_override("font_size", 11)
		sl.add_theme_color_override("font_color", Color(0.42, 0.55, 0.7, 0.6))
		sl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		map.add_child(sl)
		sea_labels.append(sl)
	for o in t.get("oceans", []):
		var ol := Label.new()
		ol.text = o["name"]
		ol.position = Vector2(o["p"][0] - 80, o["p"][1] - 12)
		ol.size = Vector2(160, 24)
		ol.pivot_offset = Vector2(80, 12)
		ol.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		ol.add_theme_font_size_override("font_size", 17)
		ol.add_theme_color_override("font_color", Color(0.4, 0.52, 0.68, 0.65))
		ol.mouse_filter = Control.MOUSE_FILTER_IGNORE
		map.add_child(ol)
		ocean_labels.append(ol)

func _circle(rad: float, n := 24) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in range(n):
		var a := TAU * i / n
		pts.append(Vector2(cos(a), sin(a)) * rad)
	return pts

## 芯片随内容收缩：盒子=文字实测最小尺寸，围绕锚点居中
func _fit_chip(lab: Label, anchor: Vector2) -> void:
	var ms2: Vector2 = lab.get_minimum_size()
	lab.size = ms2
	lab.pivot_offset = ms2 / 2.0
	lab.position = anchor - ms2 / 2.0

var chip_styles := {}
## 详情条芯片底：卫星=深底浅字，纸图=浅底深字
func _chip_style(sat: bool) -> StyleBoxFlat:
	if not chip_styles.has(sat):
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(0.07, 0.09, 0.13, 0.72) if sat else Color(0.96, 0.97, 0.99, 0.72)
		sb.set_corner_radius_all(int(3 * FONT_K))
		sb.set_content_margin_all(int(FONT_K))
		chip_styles[sat] = sb
	return chip_styles[sat]

## 势力着色的军团徽章底
func _badge_style(fid: int) -> StyleBoxFlat:
	var key := maxi(fid, -1)
	if not badge_styles.has(key):
		var sb := StyleBoxFlat.new()
		var c: Color = FACTION_COLORS.get(key, Color(0.35, 0.35, 0.38))
		sb.bg_color = Color(c.r * 0.75, c.g * 0.75, c.b * 0.75, 0.92)
		sb.set_corner_radius_all(int(3 * FONT_K))
		sb.set_content_margin_all(int(FONT_K))
		badge_styles[key] = sb
	return badge_styles[key]

func _is_capital(id: int) -> bool:
	for f in sim.factions:
		if int(f["capital_id"]) == id:
			return true
	return false

func _region_caption(r: Dictionary) -> String:
	var tags := ""
	if int(r["fab"]) > 0: tags += " ▲%d" % int(r["fab"])
	if int(r["launch"]) > 0: tags += " ☄"
	return ("★" if _is_capital(int(r["id"])) else "") + r["name"] + tags

## 资源详情条：人口/能源/电厂/数据中心（军团走独立徽章）
func _detail_text(r: Dictionary) -> String:
	var t := "●%d ⚡%d" % [int(r["pop"]), int(r["energy"])]
	if int(r["plant"]) > 0: t += " 🔌%d" % int(r["plant"])
	if int(r["dc"]) > 0: t += " 🖥%d" % int(r["dc"])
	return t

## 国家底色：钉死表优先，否则按国家码确定性散列到柔和暗色
func _country_color(key: String) -> Color:
	var cc := key.split(":")[0]
	if country_color_cache.has(cc):
		return country_color_cache[cc]
	var col: Color
	if COUNTRY_COLORS.has(cc):
		col = COUNTRY_COLORS[cc]
	else:
		var h := float(hash(cc) % 997) / 997.0
		var s := 0.24 + float(hash(cc + "s") % 100) / 800.0   # 0.24~0.36
		var v := 0.33 + float(hash(cc + "v") % 100) / 900.0   # 0.33~0.44
		col = Color.from_hsv(h, s, v)
	country_color_cache[cc] = col
	return col

## 季节积雪强度（0~1）：冬季雪线南压、夏季北退，南半球镜像
func _snow01(lat: float, m: int) -> float:
	var north := cos(float(m - 1) / 12.0 * TAU) * 0.5 + 0.5  # 1月=1，7月=0
	if lat >= 0.0:
		var line := lerpf(78.0, 36.0, north)
		return clampf((lat - line) / 10.0, 0.0, 1.0)
	var south := 1.0 - north
	var line_s := lerpf(-78.0, -40.0, south)
	return clampf((line_s - lat) / 10.0, 0.0, 1.0)

func _map_color(r: Dictionary) -> Color:
	var id := int(r["id"])
	var owner := sim.owner_of(r)
	var base := _country_color(str(r.get("key", "?")))
	var col: Color
	if owner == 0:
		col = COL_OWNED.lerp(Color(0.3, 0.62, 1.0), (sim.influence_of(r, 0) - 60) / 40.0)
	elif owner > 0:
		col = FACTION_COLORS.get(owner, Color(0.5, 0.3, 0.5))
	else:
		# 中立：被渗透最深的势力颜色浸染（拉锯可视化）
		var lead := -1
		var lead_inf := 0
		for fid in range(sim.factions.size()):
			var v := sim.influence_of(r, fid)
			if v > lead_inf:
				lead_inf = v
				lead = fid
		if lead >= 0:
			col = base.lerp(FACTION_COLORS.get(lead, COL_OWNED), 0.15 + 0.55 * lead_inf / 60.0)
		else:
			col = base
			for n in sim.adj[str(id)]:
				if sim.is_controlled(sim.region(int(n))):
					col = base.lightened(0.05)
					break
	# 同国相邻省份明度微差，避免粘连
	var tint := (float((id * 73856093) % 7) - 3.0) * 0.013
	col = col.lightened(tint) if tint > 0.0 else col.darkened(-tint)
	if satellite_mode:
		# 卫星模式：政治色作半透明罩层，露出真彩地表（积雪由影像自带）
		var infl_any := owner >= 0 or not (r["inf"] as Dictionary).is_empty()
		col.a = 0.52 if owner >= 0 else (0.38 if infl_any else 0.28)
		return col
	# 纸图模式：经典战争地图的明亮色块
	col = col.lightened(0.22)
	# 季节积雪：高纬区域冬季覆霜（控制区减弱以保辨识度）
	var snow := _snow01(90.0 - centers[id].y / MAP_SCALE, sim.month_of_year())
	if snow > 0.0:
		col = col.lerp(Color(0.88, 0.91, 0.95), snow * (0.32 if owner >= 0 else 0.48))
	return col

# ---------------- UI ----------------

func _panel_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.10, 0.12, 0.17, 0.94)
	sb.set_corner_radius_all(8)
	sb.set_content_margin_all(10)
	sb.border_color = Color(0.25, 0.30, 0.40)
	sb.set_border_width_all(1)
	return sb

func _build_ui() -> void:
	var ui := CanvasLayer.new()
	add_child(ui)

	var top := PanelContainer.new()
	top.add_theme_stylebox_override("panel", _panel_style())
	top.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	top.offset_left = 8; top.offset_right = -8; top.offset_top = 6
	ui.add_child(top)
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 14)
	top.add_child(hb)
	# 时间控制：暂停 + 速度档 + 月进度
	btn_pause = Button.new()
	btn_pause.add_theme_font_size_override("font_size", 14)
	btn_pause.pressed.connect(_toggle_pause)
	hb.add_child(btn_pause)
	for i in range(SPEEDS.size()):
		var sb := Button.new()
		sb.text = SPEED_NAMES[i]
		sb.add_theme_font_size_override("font_size", 13)
		sb.pressed.connect(_set_speed.bind(i))
		hb.add_child(sb)
		btn_speeds.append(sb)
	month_bar = ProgressBar.new()
	month_bar.custom_minimum_size = Vector2(70, 0)
	month_bar.max_value = 1.0
	month_bar.show_percentage = false
	hb.add_child(month_bar)
	for key in ["turn", "tod", "gen", "compute", "chips", "data", "misc"]:
		var l := Label.new()
		l.add_theme_font_size_override("font_size", 14)
		hb.add_child(l)
		lbl_top[key] = l
	lbl_tod = lbl_top["tod"]

	var right := PanelContainer.new()
	right.add_theme_stylebox_override("panel", _panel_style())
	right.set_anchors_and_offsets_preset(Control.PRESET_RIGHT_WIDE)
	right.offset_left = -286; right.offset_right = -8
	right.offset_top = 56; right.offset_bottom = -176
	ui.add_child(right)
	var rv := VBoxContainer.new()
	rv.add_theme_constant_override("separation", 8)
	right.add_child(rv)
	lbl_region = RichTextLabel.new()
	lbl_region.bbcode_enabled = true
	lbl_region.fit_content = true
	lbl_region.scroll_active = false
	lbl_region.add_theme_font_size_override("normal_font_size", 14)
	lbl_region.add_theme_font_size_override("bold_font_size", 17)
	rv.add_child(lbl_region)
	rv.add_child(HSeparator.new())
	var acts := [
		["infiltrate", "渗透"],
		["auto", "⟳ 自动渗透"],
		["plant", "建/升电厂"],
		["dc", "建/升数据中心"],
		["fab", "升级晶圆厂"],
		["army_build", "组建军团"],
		["army_move", "调动军团 →"],
		["war", "⚔ 宣战"],
		["attack", "⚔ 进攻 →"],
	]
	for a in acts:
		var b := Button.new()
		b.text = a[1]
		b.add_theme_font_size_override("font_size", 14)
		b.pressed.connect(_on_action.bind(a[0]))
		rv.add_child(b)
		btn[a[0]] = b

	var bottom := PanelContainer.new()
	bottom.add_theme_stylebox_override("panel", _panel_style())
	bottom.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	bottom.offset_left = 8; bottom.offset_right = -8
	bottom.offset_top = -168; bottom.offset_bottom = -6
	ui.add_child(bottom)
	var bh := HBoxContainer.new()
	bh.add_theme_constant_override("separation", 16)
	bottom.add_child(bh)

	var sv := VBoxContainer.new()
	sv.custom_minimum_size = Vector2(430, 0)
	bh.add_child(sv)
	var alloc_title := Label.new()
	alloc_title.text = "算力分配（回合结算时生效）"
	alloc_title.add_theme_font_size_override("font_size", 13)
	sv.add_child(alloc_title)
	sl_train = _make_slider(sv, "训练", sim.train_pct, _on_train_changed)
	sl_infer = _make_slider(sv, "推理", sim.infer_pct, _on_infer_changed)
	lbl_alloc = Label.new()
	lbl_alloc.add_theme_font_size_override("font_size", 13)
	sv.add_child(lbl_alloc)
	lbl_preview = Label.new()
	lbl_preview.add_theme_font_size_override("font_size", 12)
	lbl_preview.add_theme_color_override("font_color", Color(0.65, 0.72, 0.82))
	sv.add_child(lbl_preview)

	var mv := VBoxContainer.new()
	mv.add_theme_constant_override("separation", 8)
	bh.add_child(mv)
	var end_btn := Button.new()
	end_btn.text = "  推进 1 月 ▶  "
	end_btn.add_theme_font_size_override("font_size", 18)
	end_btn.pressed.connect(_advance_month)
	mv.add_child(end_btn)

	log_box = RichTextLabel.new()
	log_box.bbcode_enabled = true
	log_box.scroll_following = true
	log_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	log_box.add_theme_font_size_override("normal_font_size", 13)
	bh.add_child(log_box)

func _make_slider(parent: VBoxContainer, name_: String, init: float, cb: Callable) -> HSlider:
	var row := HBoxContainer.new()
	parent.add_child(row)
	var l := Label.new()
	l.text = name_
	l.custom_minimum_size = Vector2(40, 0)
	l.add_theme_font_size_override("font_size", 14)
	row.add_child(l)
	var s := HSlider.new()
	s.max_value = 100
	s.step = 1
	s.value = init * 100
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.value_changed.connect(cb)
	row.add_child(s)
	return s

# ---------------- 交互 ----------------

func _unhandled_input(ev: InputEvent) -> void:
	if ev is InputEventKey and ev.pressed and not ev.echo:
		match ev.keycode:
			KEY_SPACE:
				_toggle_pause()
			KEY_ENTER, KEY_KP_ENTER:
				_advance_month()
			KEY_1, KEY_2, KEY_3, KEY_4:
				_set_speed(ev.keycode - KEY_1)
			KEY_HOME:
				cam.position = centers[_capital_id()]
			KEY_ESCAPE:
				if move_mode or attack_mode:
					move_mode = false
					attack_mode = false
					_log("已取消指令")
				else:
					selected = -1
					highlight.visible = false
				_refresh()
			KEY_F5:
				_save_game()
			KEY_F9:
				_load_game()
			KEY_M:
				_set_map_mode(not satellite_mode)
				_log("🗺 已切换到%s模式" % ("卫星影像" if satellite_mode else "政治地图"))
		return
	if ev is InputEventMagnifyGesture:        # 触控板捏合缩放
		_zoom(ev.factor)
		return
	if ev is InputEventPanGesture:            # 触控板双指平移
		_pan(-ev.delta * 2.0)
		return
	if ev is InputEventMouseButton:
		match ev.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				if ev.pressed: _zoom(1.1)
			MOUSE_BUTTON_WHEEL_DOWN:
				if ev.pressed: _zoom(1.0 / 1.1)
			MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE:
				panning = ev.pressed
			MOUSE_BUTTON_LEFT:
				if ev.pressed:
					maybe_select = true
					drag_accum = 0.0
				else:
					# 没怎么移动 → 视为点击选择；拖远了 → 只是拖图
					if maybe_select and drag_accum < 8.0:
						_pick(get_global_mouse_position())
					maybe_select = false
	elif ev is InputEventMouseMotion:
		if panning:
			_pan(ev.relative)
		elif maybe_select:
			drag_accum += ev.relative.length()
			if drag_accum >= 8.0:
				_pan(ev.relative)

func _pan(rel: Vector2) -> void:
	cam.position -= rel / cam.zoom.x
	_clamp_cam()
	_update_hd_tiles()

func _clamp_cam() -> void:
	cam.position = cam.position.clamp(map_rect.position, map_rect.end)

func _zoom(f: float) -> void:
	var z: float = clampf(cam.zoom.x * f, 0.35, 28.0)
	cam.zoom = Vector2(z, z)
	_apply_zoom_styles()
	_update_label_visibility()

## 文字缩放曲线：屏显尺寸 ≈ 基准 × zoom^0.55，夹在 [0.9×, cap×] 基准之间
func _text_scale(z: float, cap: float) -> float:
	return clampf(1.1 * pow(z, -0.45), 0.9 / z, cap / z)

## 大字号光栅化：字号/盒子/阴影 ×K，围绕原锚点缩回——高倍缩放下文字依然锐利
func _crispify(lab: Label) -> void:
	var anchor: Vector2 = lab.position + lab.pivot_offset
	for key in ["font_size", "normal_font_size"]:
		if lab.has_theme_font_size_override(key):
			lab.add_theme_font_size_override(key, int(lab.get_theme_font_size(key) * FONT_K))
	lab.size *= FONT_K
	lab.pivot_offset *= FONT_K
	lab.position = anchor - lab.pivot_offset
	lab.add_theme_constant_override("shadow_offset_x", int(FONT_K))
	lab.add_theme_constant_override("shadow_offset_y", int(FONT_K))
	lab.scale = Vector2(1.0 / FONT_K, 1.0 / FONT_K)

## 缩放自适应：拉近时线变细、字同步放大
func _apply_zoom_styles() -> void:
	var z := cam.zoom.x
	for l in border_lines:
		l.width = clampf(1.5 / z, 0.1, 2.2)
	for l in outline_lines:
		l.width = clampf(3.4 / z, 0.25, 4.5)
	for l in lane_lines:
		l.width = clampf(2.2 / z, 0.18, 3.0)
	# 卫星模式下，高倍缩放时叠回矢量河湖补偿影像分辨率极限
	var water_visible := (not satellite_mode) or z > 3.0
	for l in river_lines:
		l.width = clampf(1.1 / z, 0.07, 1.3)
		l.visible = water_visible
	for lp in lake_polys:
		lp["poly"].visible = water_visible
	highlight.width = clampf(3.0 / z, 0.22, 4.0)
	# 字体随缩放同步放大（次线性 + 上下限：拉近变大、拉远保底可读）
	var s := _text_scale(z, 3.6)
	var sv := Vector2(s / FONT_K, s / FONT_K)
	for id in labels:
		labels[id].scale = sv
		detail_labels[id].scale = sv
		army_badges[id].scale = sv
	for c in city_nodes:
		c["dot"].scale = sv
		c["label"].scale = sv
	for ml in range_labels:
		ml.scale = sv
		ml.visible = z >= 0.55
	for ol in ocean_labels:
		ol.scale = sv
	for sl in sea_labels:
		sl.scale = sv
		sl.visible = z >= 0.7
	# 大国名：远中景铺图，拉近让位给省名
	for bl in big_labels:
		bl.visible = z <= 2.2
		bl.modulate.a = clampf(0.7 - z * 0.18, 0.18, 0.6)
	_update_hd_tiles()

func _pick(pos: Vector2) -> void:
	for id in rings:
		for ring in rings[id]:
			if Geometry2D.is_point_in_polygon(pos, ring):
				if move_mode and selected >= 0:
					move_mode = false
					var why := sim.can_move_army(selected, id)
					if why == "":
						sim.do_move_army(selected, id)
						_flush_events()
					else:
						_log("🛡 无法调动：" + why)
					_refresh()
					return
				if attack_mode and selected >= 0:
					attack_mode = false
					var why2 := sim.can_attack(selected, id)
					if why2 == "":
						sim.do_attack(selected, id)
						_flush_events()
					else:
						_log("⚔ 无法进攻：" + why2)
					_refresh()
					return
				_select(id)
				_refresh()
				return

func _select(id: int) -> void:
	selected = id
	var best: PackedVector2Array
	var best_n := -1
	for ring in rings[id]:
		if ring.size() > best_n:
			best_n = ring.size()
			best = ring
	var pts := best.duplicate()
	pts.append(best[0])
	highlight.points = pts
	highlight.visible = true

func _on_train_changed(v: float) -> void:
	if v + sl_infer.value > 100:
		sl_infer.set_value_no_signal(100 - v)
	sim.set_allocation(v / 100.0, sl_infer.value / 100.0)
	_refresh_alloc()

func _on_infer_changed(v: float) -> void:
	if v + sl_train.value > 100:
		sl_train.set_value_no_signal(100 - v)
	sim.set_allocation(sl_train.value / 100.0, v / 100.0)
	_refresh_alloc()

func _on_action(kind: String) -> void:
	if selected < 0:
		return
	match kind:
		"infiltrate":
			if sim.do_infiltrate(selected):
				_flush_events()
		"auto":
			var on := sim.toggle_auto_infiltrate(selected)
			_log("⟳ 〔%s〕自动渗透：%s" % [sim.region(selected)["name"], "开" if on else "关"])
		"army_build":
			if sim.do_build_army(selected):
				_flush_events()
		"army_move":
			move_mode = true
			_log("🛡 调动模式：点击相邻的控制区作为目的地（Esc 取消）")
		"war":
			var owner := sim.owner_of(sim.region(selected))
			if owner > 0 and sim.declare_war(0, owner):
				_flush_events()
		"attack":
			attack_mode = true
			_log("⚔ 进攻模式：点击相邻的敌方区域发起攻击（Esc 取消）")
		_:
			if sim.do_build(selected, kind):
				_flush_events()
	_refresh()

## 卫星/纸图切换
func _set_map_mode(sat: bool) -> void:
	satellite_mode = sat
	sat_sprite.visible = sat
	for n in bathy_nodes:
		n["poly"].visible = not sat
		n["poly"].color = BATHY_PAPER.get(n["depth"], PAPER_OCEAN) if not sat \
			else BATHY_COLORS.get(n["depth"], Color(0.05, 0.09, 0.14))
	for tp in terra_polys: tp["poly"].visible = not sat
	for mp in mountain_polys: mp["poly"].visible = not sat
	for g in glacier_nodes: g.visible = not sat
	# 文字图例：纸图深字浅影，卫星浅字深影
	if daynight_mat:
		daynight_mat.set_shader_parameter("strength", 1.0 if sat else 0.35)
	var fc := SAT_TEXT if sat else PAPER_TEXT
	var sc := SAT_TEXT_SHADOW if sat else PAPER_TEXT_SHADOW
	for id in labels:
		labels[id].add_theme_color_override("font_color", fc)
		labels[id].add_theme_color_override("font_shadow_color", sc)
		detail_labels[id].add_theme_color_override("font_color",
			Color(0.82, 0.9, 0.97) if sat else Color(0.16, 0.19, 0.26))
		detail_labels[id].add_theme_stylebox_override("normal", _chip_style(sat))
	for bl in big_labels:
		bl.add_theme_color_override("font_color",
			Color(0.95, 0.97, 1.0, 0.8) if sat else Color(0.16, 0.18, 0.26))
		bl.add_theme_color_override("font_shadow_color", sc)
	_apply_zoom_styles()  # 河流/湖泊的显隐由缩放级别细化
	_refresh()

func _update_satellite_texture() -> void:
	var m := sim.month_of_year()
	if m != sat_month:
		sat_month = m
		var tex: Texture2D = load("res://assets/earth/earth_%02d.jpg" % m)
		sat_sprite.texture = tex
		# 按贴图实际分辨率适配地图像素（2520×1260）
		sat_sprite.scale = Vector2(2520.0 / tex.get_width(), 1260.0 / tex.get_height())
	if daynight_mat:
		daynight_mat.set_shader_parameter("decl", DECL_BY_MONTH[m - 1])

## 高清瓦片装卸：只保留视野内的当季瓦片（两级金字塔）
func _update_hd_tiles() -> void:
	if cam == null or hd_layer == null:
		return
	var z := cam.zoom.x
	var q: int = HD_QUARTER[sim.month_of_year() - 1]
	var half: Vector2 = get_viewport_rect().size / (2.0 * z)
	var view := Rect2(cam.position - half - Vector2(40, 40), half * 2.0 + Vector2(80, 80))
	# L1：2km/像素 四季瓦片
	var want := {}
	if satellite_mode and z >= HD_ZOOM:
		for cy in range(HD_ROWS):
			for cx in range(HD_COLS):
				if view.intersects(Rect2(cx * HD_TILE_WORLD, cy * HD_TILE_WORLD, HD_TILE_WORLD, HD_TILE_WORLD)):
					want["%d_%d_%d" % [q, cx, cy]] = Vector2i(cx, cy)
	for key in hd_tiles.keys():
		if not want.has(key):
			hd_tiles[key].queue_free()
			hd_tiles.erase(key)
	for key in want:
		if hd_tiles.has(key):
			continue
		var v: Vector2i = want[key]
		var sp := Sprite2D.new()
		sp.centered = false
		sp.texture = load("res://assets/earth_hd/q%d/t_%d_%d.jpg" % [q, v.x, v.y])
		sp.position = Vector2(v.x * HD_TILE_WORLD, v.y * HD_TILE_WORLD)
		sp.scale = Vector2(HD_TILE_WORLD / 2700.0, HD_TILE_WORLD / 2700.0)
		hd_layer.add_child(sp)
		hd_tiles[key] = sp
	# L2：500m/像素 极限瓦片（四季全量，含海洋）
	var want2 := {}
	if satellite_mode and z >= HD2_ZOOM:
		for cy in range(HD2_ROWS):
			for cx in range(HD2_COLS):
				if not view.intersects(Rect2(cx * HD2_TILE_WORLD, cy * HD2_TILE_WORLD, HD2_TILE_WORLD, HD2_TILE_WORLD)):
					continue
				# 高清资产可选（克隆后未重建时由 L1 垫底）
				if ResourceLoader.exists("res://assets/earth_hd2/q%d/t_%d_%d.jpg" % [q, cx, cy]):
					want2["%d_%d_%d" % [q, cx, cy]] = Vector2i(cx, cy)
	for key in hd2_tiles.keys():
		if not want2.has(key):
			hd2_tiles[key].queue_free()
			hd2_tiles.erase(key)
	for key in want2:
		if hd2_tiles.has(key):
			continue
		var v: Vector2i = want2[key]
		var sp := Sprite2D.new()
		sp.centered = false
		sp.texture = load("res://assets/earth_hd2/q%d/t_%d_%d.jpg" % [q, v.x, v.y])
		sp.position = Vector2(v.x * HD2_TILE_WORLD, v.y * HD2_TILE_WORLD)
		sp.scale = Vector2(HD2_TILE_WORLD / 2700.0, HD2_TILE_WORLD / 2700.0)
		hd2_layer.add_child(sp)
		hd2_tiles[key] = sp

func _update_tod_label() -> void:
	var c: Vector2 = centers[_capital_id()]
	var lon := c.x / MAP_SCALE - 180.0
	var h := fposmod(12.0 + (lon - sun_lon) / 15.0, 24.0)
	var txt: String
	if h < 4.5: txt = "🌙 深夜"
	elif h < 6.5: txt = "🌅 黎明"
	elif h < 10.5: txt = "🌄 早晨"
	elif h < 13.5: txt = "☀️ 正午"
	elif h < 17.0: txt = "🌞 午后"
	elif h < 19.5: txt = "🌇 黄昏"
	else: txt = "🌙 夜晚"
	lbl_tod.text = txt + "（京）"

## 时间流动 + 键盘平移
func _process(delta: float) -> void:
	# 昼夜循环：晨昏线匀速西移（演出层，与游戏速度无关）
	sun_lon = fposmod(sun_lon - delta * 360.0 / DAY_CYCLE_SEC, 360.0)
	if daynight_mat:
		daynight_mat.set_shader_parameter("sun_lon", sun_lon)
	tod_accum += delta
	if tod_accum >= 0.5:
		tod_accum = 0.0
		_update_tod_label()
	var dir := Vector2.ZERO
	if Input.is_key_pressed(KEY_LEFT) or Input.is_key_pressed(KEY_A): dir.x -= 1
	if Input.is_key_pressed(KEY_RIGHT) or Input.is_key_pressed(KEY_D): dir.x += 1
	if Input.is_key_pressed(KEY_UP) or Input.is_key_pressed(KEY_W): dir.y -= 1
	if Input.is_key_pressed(KEY_DOWN) or Input.is_key_pressed(KEY_S): dir.y += 1
	if dir != Vector2.ZERO:
		cam.position += dir.normalized() * 900.0 * delta / cam.zoom.x
		_clamp_cam()
	if paused:
		return
	month_accum += delta
	month_bar.value = month_accum / SPEEDS[speed_idx]
	if month_accum >= SPEEDS[speed_idx]:
		month_accum = 0.0
		_advance_month()

func _toggle_pause() -> void:
	paused = not paused
	_refresh_time_controls()

func _set_speed(i: int) -> void:
	speed_idx = clampi(i, 0, SPEEDS.size() - 1)
	paused = false
	_refresh_time_controls()

func _refresh_time_controls() -> void:
	btn_pause.text = "  ▶ 继续  " if paused else "  ⏸ 暂停  "
	for i in range(btn_speeds.size()):
		btn_speeds[i].disabled = (not paused) and i == speed_idx
	if paused:
		month_bar.value = month_accum / SPEEDS[speed_idx]

## 演化事件在地图上的浮动标记
func _spawn_evo_marks() -> void:
	const ICONS := {"up": "📈", "down": "📉", "build": "🏗", "fab": "🏭", "flag": "🚩", "battle": "💥"}
	var ms := _text_scale(cam.zoom.x, 3.0)
	for m in sim.evo_marks:
		var lab := Label.new()
		lab.text = ICONS.get(m["kind"], "✦")
		lab.position = centers[int(m["id"])] + Vector2(-10, -26)
		lab.scale = Vector2(ms / FONT_K, ms / FONT_K)
		lab.add_theme_font_size_override("font_size", int(18 * FONT_K))
		lab.mouse_filter = Control.MOUSE_FILTER_IGNORE
		get_node("Map").add_child(lab)
		var tw := create_tween()
		tw.set_parallel(true)
		tw.tween_property(lab, "position:y", lab.position.y - 30.0, 1.8)
		tw.tween_property(lab, "modulate:a", 0.0, 1.8).set_ease(Tween.EASE_IN)
		tw.chain().tween_callback(lab.queue_free)

func _advance_month() -> void:
	_flush_events()
	var resolved := sim.date_str()
	month_accum = 0.0
	sim.end_turn()
	_log("[color=#8ab]── %s ──[/color]" % resolved)
	_spawn_evo_marks()
	var rp: Dictionary = sim.last_report
	if not rp.is_empty():
		_log("[color=#9ab]算力 %.0f（训 %.0f／研 %.0f／推 %.0f）｜ +%.0f🔶 +%.0f💾[/color]" % [
			rp["comp"], rp["train"], rp["research"], rp["infer"], rp["chips_in"], rp["data_in"]])
	_flush_events()
	_check_milestones()
	_refresh()

func _save_game() -> void:
	var f := FileAccess.open("user://m1_save.json", FileAccess.WRITE)
	f.store_string(JSON.stringify(sim.save_state()))
	f.close()
	_log("💾 已存档（F9 读取）")

func _load_game() -> void:
	if not FileAccess.file_exists("user://m1_save.json"):
		_log("⚠️ 没有存档")
		return
	var d = JSON.parse_string(FileAccess.get_file_as_string("user://m1_save.json"))
	if d == null:
		_log("⚠️ 存档损坏")
		return
	sim.load_state(d)
	sl_train.set_value_no_signal(sim.train_pct * 100)
	sl_infer.set_value_no_signal(sim.infer_pct * 100)
	_log("📂 已读档：回合 %d" % sim.turn)
	_refresh()

func _check_milestones() -> void:
	var n := sim.controlled().size()
	var checks := [
		["r8", n >= 8, "🏁 里程碑：控制 8 个区域"],
		["r20", n >= 20, "🏁 里程碑：控制 20 个区域"],
		["r45", n >= 45, "🏁 里程碑：控制 45 个区域——大国版图成形"],
		["fab2", sim.controlled().any(func(r): return int(r["fab"]) >= 2), "🏁 里程碑：高端晶圆厂到手，芯片不再卡脖子"],
		["c200", sim.compute_total() >= 200.0, "🏁 里程碑：算力突破 200"],
		["t5", sim.tech_level() >= 5, "🏁 里程碑：科技 Lv5"],
		["t10", sim.tech_level() >= 10, "🏁 里程碑：科技 Lv10"],
	]
	for c in checks:
		if c[1] and not milestones_done.has(c[0]):
			milestones_done[c[0]] = true
			_log("[color=#fc6]%s[/color]" % c[2])

func _flush_events() -> void:
	for e in sim.events:
		_log(e)
	sim.events.clear()

func _log(s: String) -> void:
	log_box.append_text(s + "\n")

# ---------------- 刷新 ----------------

func _refresh() -> void:
	for r in sim.regions:
		var id := int(r["id"])
		var col := _map_color(r)
		for poly in polynodes[id]:
			poly.color = col
		# 渗透中的区域：标签显示进度与自动标记
		var inf := sim.influence_of(r, 0)
		var suffix := ""
		if not sim.is_controlled(r):
			if sim.auto_infiltrate.has(id):
				suffix += " ⟳"
			if inf > 0:
				suffix += " %d%%" % inf
		labels[id].text = _region_caption(r) + suffix
		var dl: Label = detail_labels[id]
		dl.text = _detail_text(r)
		_fit_chip(dl, centers[id] + Vector2(0.0, 13.0))
		# 军团徽章：编成显示（⚙坦克 🪖装甲 🤖机器人 ✈战机 🛩无人机）；底色=所属势力；断补给标 ⛓
		army_badges[id].visible = sim.army_of(r) > 0
		if sim.army_of(r) > 0:
			var o := sim.owner_of(r)
			var chain := ""
			if o >= 0 and not sim.supplied(id, o):
				chain = " ⛓"
			army_badges[id].add_theme_stylebox_override("normal", _badge_style(o))
			army_badges[id].text = sim.units_str(r) + chain
			_fit_chip(army_badges[id], centers[id] + Vector2(0.0, 29.0))
	_apply_season()
	var th := sim.next_gen_threshold()
	lbl_top["turn"].text = "📅 %s %s" % [sim.date_str(), SEASON_ICON[sim.month_of_year() - 1]]
	var gen_txt := "Gen%d  %d/%s" % [sim.gen, int(sim.training), ("%d" % int(th)) if th > 0 else "MAX"]
	if th > 0:
		var rate: float = sim.compute_total() * sim.train_pct
		if rate > 0.5:
			gen_txt += "（约 %d 回合）" % maxi(1, ceili((th - sim.training) / rate))
	lbl_top["gen"].text = gen_txt
	lbl_top["compute"].text = "算力 %.0f%s（电力 %.0f）" % [sim.compute_total(), " ⚡受限" if sim.power_limited() else "", sim.power_total()]
	lbl_top["chips"].text = "🔶 %.0f（+%.0f/回）" % [sim.chips, sim.chip_rate()]
	lbl_top["data"].text = "💾 %.0f（+%.0f/回）" % [sim.data_pool, sim.data_rate()]
	var stance := ""
	if sim.contained_fid == 0:
		stance = " ｜ 🛑 被围堵"
	elif sim.contained_fid > 0:
		stance = " ｜ 🛑 围堵〔%s〕" % sim.faction_name(sim.contained_fid)
	var foes := sim.enemies_of(0)
	if not foes.is_empty():
		var names := []
		for e in foes:
			names.append(sim.faction_name(e))
		stance += " ｜ ⚔ 交战：" + "、".join(names)
	lbl_top["misc"].text = "科技 Lv%d ｜ 经济 %d%% ｜ 推理供给 %d%% ｜ 🛡 %d%s" % [sim.tech_level(), int(sim.eco_coef() * 100), int(sim.last_supply * 100), sim.army_total(), stance]
	_update_label_visibility()
	_refresh_alloc()
	_refresh_region()

## 季节渲染：逐月卫星影像、山脉积雪、湖泊结冰、海色冷暖
func _apply_season() -> void:
	_update_satellite_texture()
	_update_hd_tiles()
	var m := sim.month_of_year()
	for mp in mountain_polys:
		var snow := _snow01(mp["lat"] + 8.0, m)  # 山地雪线低 8°
		mp["poly"].color = Color(0.45, 0.36, 0.25, 0.15).lerp(Color(0.88, 0.91, 0.95, 0.32), snow)
	for lp in lake_polys:
		var ice := _snow01(lp["lat"] - 2.0, m)
		var lake_base := Color(0.055, 0.095, 0.155) if satellite_mode else Color(0.45, 0.58, 0.72)
		lp["poly"].color = lake_base.lerp(Color(0.78, 0.85, 0.9), ice * 0.8)
	for tp in terra_polys:
		var s2 := _snow01(tp["lat"], m)
		tp["poly"].color = tp["base"].lerp(Color(0.85, 0.88, 0.92, 0.3), s2)
	var north := cos(float(m - 1) / 12.0 * TAU) * 0.5 + 0.5
	# 清屏色 = 大陆架浅蓝（深海由水深分层覆盖），冬季微暗；纸图/卫星两套
	if satellite_mode:
		RenderingServer.set_default_clear_color(
			Color(0.10, 0.155, 0.225).lerp(Color(0.085, 0.13, 0.19), north))
	else:
		RenderingServer.set_default_clear_color(
			Color(0.66, 0.75, 0.84).lerp(Color(0.58, 0.68, 0.78), north))

func _refresh_alloc() -> void:
	lbl_alloc.text = "训练 %d%%  ｜  推理 %d%%  ｜  研发 %d%%（余量自动）" % [
		int(sim.train_pct * 100), int(sim.infer_pct * 100), int(round(sim.research_pct() * 100))]
	var comp := sim.compute_total()
	var demand := sim.infer_demand()
	lbl_preview.text = "本回合预计：训练 +%.0f ｜ 研发 +%.0f ｜ 推理 %.0f／需求 %.0f%s" % [
		comp * sim.train_pct, comp * sim.research_pct(), comp * sim.infer_pct, demand,
		"  ⚠️供给不足" if comp * sim.infer_pct < demand else ""]

func _refresh_region() -> void:
	if selected < 0:
		lbl_region.text = "点击地图选择区域"
		return
	var r := sim.region(selected)
	var star := "★ " if r["capital"] else ""
	var owner := sim.owner_of(r)
	var ctl: String
	if owner == 0:
		ctl = "[color=#6cf]已控制[/color]"
	elif owner > 0:
		ctl = "[color=#f86]〔%s〕控制[/color]" % sim.faction_name(owner)
	else:
		var parts := []
		for fid in range(sim.factions.size()):
			var v := sim.influence_of(r, fid)
			if v > 0:
				parts.append("%s %d" % ["你" if fid == 0 else sim.faction_name(fid), v])
		ctl = "中立" if parts.is_empty() else "渗透中：" + " ｜ ".join(parts)
	var t := "[b]%s%s[/b]（%s） %s\n" % [star, r["name"], r["arch"], ctl]
	t += "人口 %d ｜ 能源 %d ｜ 晶圆厂 %d ｜ 发射场 %d\n" % [int(r["pop"]), int(r["energy"]), int(r["fab"]), int(r["launch"])]
	t += "设施：电厂 %d/%d ｜ 数据中心 %d/%d\n" % [int(r["plant"]), int(sim.P["max_plant"]), int(r["dc"]), int(sim.P["max_dc"])]
	if sim.army_of(r) > 0:
		t += "驻军：%s（共 %d）\n" % [sim.units_str(r), sim.army_of(r)]
	if sim.is_controlled(r):
		var pw: float = r["energy"] * sim.P["region_power_per_energy"] + r["plant"] * r["energy"] * sim.P["plant_power_per_energy"]
		t += "贡献：⚡%.0f ｜ 💾%.0f ｜ 🔶%.0f ｜ 容量 %d" % [pw, r["pop"] * float(sim.P["pop_data"]), r["fab"] * float(sim.P["fab_chips"]), int(r["dc"]) * int(sim.P["dc_capacity"])]
	lbl_region.text = t
	var cost := sim.infiltrate_cost(selected)
	btn["infiltrate"].text = "渗透 +%d 影响（%d🔶 %d💾）" % [
		int(sim.P["infiltrate_gain"]), int(cost["chips"]), int(cost["data"])]
	btn["auto"].text = "⟳ 自动渗透：%s" % ("开" if sim.auto_infiltrate.has(selected) else "关")
	btn["plant"].text = "建/升电厂 ⚡+%d（%d🔶）" % [
		int(r["energy"]) * int(sim.P["plant_power_per_energy"]), int(sim.P["cost_plant"])]
	btn["dc"].text = "数据中心 容量+%d（%d🔶）" % [int(sim.P["dc_capacity"]), int(sim.P["cost_dc"])]
	btn["fab"].text = "升晶圆厂 🔶+%d/回（%d🔶）" % [int(sim.P["fab_chips"]), int(sim.P["cost_fab_upgrade"])]
	var nt := sim.next_unit_type(0)
	btn["army_build"].text = "组建%s%s（%d🔶，维护+%d）" % [
		Sim.UNIT_ICON[nt], sim.unit_name(nt), int(sim.P["army_cost_chips"]), int(sim.P["army_upkeep"])]
	var auto_why := ""
	if sim.is_controlled(r):
		auto_why = "已是控制区"
	var move_why := ""
	if not sim.is_controlled(r):
		move_why = "未控制该区域"
	elif sim.army_of(r) <= 0:
		move_why = "该区域没有军团"
	var war_why := ""
	var r_owner := sim.owner_of(r)
	if r_owner <= 0:
		war_why = "选中敌方势力的区域以宣战" if r_owner < 0 else "不能对自己宣战"
	elif sim.is_at_war(0, r_owner):
		war_why = "已与〔%s〕交战" % sim.faction_name(r_owner)
	var atk_why := move_why
	if atk_why == "" and not sim.at_war_any(0):
		atk_why = "未处于战争状态（先宣战）"
	var reasons := {
		"infiltrate": sim.can_infiltrate(selected),
		"auto": auto_why,
		"plant": sim.can_build(selected, "plant"),
		"dc": sim.can_build(selected, "dc"),
		"fab": sim.can_build(selected, "fab"),
		"army_build": sim.can_build_army(selected),
		"army_move": move_why,
		"war": war_why,
		"attack": atk_why,
	}
	for k in btn:
		var why: String = reasons[k]
		btn[k].disabled = why != ""
		btn[k].tooltip_text = why
