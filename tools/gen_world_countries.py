# 生成 HOI4 颗粒度世界地图 game/data/world.json（Natural Earth 10m，公有领域）
# 大国拆省级（中国/美国/印度/加拿大），俄罗斯并成 6 大区，其余整国
import json, os
from shapely.geometry import shape, MultiPolygon, Polygon
from shapely.ops import unary_union
from shapely.prepared import prep

SRC0 = "/tmp/ne_countries_10m.geojson"
SRC1 = "/tmp/ne_admin1.geojson"
SCALE = 7.0
MIN_POP = 1_400_000
SIMPLIFY = 0.015     # 高倍缩放下仍平滑
MIN_RING_AREA = 0.2       # 整国
MIN_RING_AREA_PROV = 0.04 # 省级（保留上海/天津等小而重要的省）
DROP = {"ATA", "FLK", "ATF"}
KEEP_SMALL = {"GRL"}
SPLIT = {"CHN", "USA", "IND", "CAN", "RUS"}
SPLIT_CN = {"CHN": "中国", "USA": "美国", "IND": "印度", "CAN": "加拿大", "RUS": "俄罗斯"}

# 俄罗斯省份按经度并成 6 大区（85 个联邦主体太碎）
RUS_BUCKETS = [("西部", -180, 44), ("伏尔加-南部", 44, 55), ("乌拉尔", 55, 66),
               ("西西伯利亚", 66, 90), ("东西伯利亚", 90, 125), ("远东", 125, 180)]

CN_STRIP = ["维吾尔自治区", "壮族自治区", "回族自治区", "自治区", "特别行政区", "省", "市"]

# ---- 属性钉死表（键 = "A3:省名" 或 国家 A3）----
POP_P = {
    "CHN:广东": 5, "CHN:江苏": 5, "CHN:山东": 5, "CHN:河南": 5, "CHN:四川": 4, "CHN:浙江": 4,
    "CHN:北京": 4, "CHN:上海": 4, "CHN:河北": 4, "CHN:湖南": 4, "CHN:湖北": 4, "CHN:安徽": 4,
    "CHN:天津": 3, "CHN:福建": 3, "CHN:辽宁": 3, "CHN:陕西": 3, "CHN:广西": 3, "CHN:云南": 3,
    "CHN:江西": 3, "CHN:贵州": 3, "CHN:山西": 3, "CHN:重庆": 3, "CHN:黑龙江": 3, "CHN:吉林": 2,
    "CHN:甘肃": 2, "CHN:内蒙古": 2, "CHN:新疆": 2, "CHN:海南": 2, "CHN:宁夏": 1, "CHN:青海": 1,
    "CHN:西藏": 1,
    "USA:加利福尼亚州": 5, "USA:得克萨斯州": 5, "USA:纽约州": 4, "USA:佛罗里达州": 4,
    "USA:伊利诺伊州": 3, "USA:宾夕法尼亚州": 3, "USA:俄亥俄州": 3,
    "IND:北方邦": 5, "IND:马哈拉施特拉邦": 5, "IND:比哈尔邦": 4, "IND:西孟加拉邦": 4,
    "IND:卡纳塔克邦": 3, "IND:泰米尔纳德邦": 3, "IND:古吉拉特邦": 3,
    "CAN:安大略省": 3, "CAN:魁北克": 3,
    "RUS:西部": 4, "RUS:伏尔加-南部": 3, "RUS:乌拉尔": 3, "RUS:西西伯利亚": 2,
    "RUS:东西伯利亚": 1, "RUS:远东": 1,
}
POP_DEFAULT = {"CHN": 2, "USA": 2, "IND": 2, "CAN": 1, "RUS": 1}
ENERGY_P = {
    "CHN:山西": 5, "CHN:内蒙古": 5, "CHN:新疆": 5, "CHN:陕西": 4, "CHN:四川": 4, "CHN:云南": 4,
    "CHN:青海": 3, "USA:得克萨斯州": 5, "USA:阿拉斯加州": 4, "USA:加利福尼亚州": 3,
    "USA:怀俄明州": 3, "CAN:阿尔伯塔省": 5, "IND:拉贾斯坦邦": 3,
    "RUS:乌拉尔": 5, "RUS:西西伯利亚": 5, "RUS:东西伯利亚": 4, "RUS:远东": 4,
    "RUS:伏尔加-南部": 3, "RUS:西部": 3,
}
ENERGY = {"SAU": 5, "IRN": 5, "IRQ": 4, "KWT": 4, "ARE": 4, "QAT": 5, "OMN": 3, "AUS": 5,
          "NOR": 4, "DZA": 4, "LBY": 4, "EGY": 3, "MAR": 3, "NGA": 4, "AGO": 3, "VEN": 4,
          "BRA": 4, "KAZ": 4, "TKM": 4, "UZB": 3, "AZE": 4, "MNG": 3, "COD": 3, "CHL": 3,
          "MEX": 3, "IDN": 3, "MYS": 3, "GRL": 2, "ISL": 3, "ARG": 3, "BOL": 3, "PRY": 3,
          "ETH": 3, "ZMB": 3, "SWE": 3, "FIN": 2, "UKR": 3}
FABS = {"TWN": 4, "KOR": 3, "JPN": 2, "NLD": 2, "ISR": 1,
        "CHN:北京": 1, "CHN:上海": 1, "USA:亚利桑那州": 2, "IND:卡纳塔克邦": 1}
LAUNCH = {"KAZ": 2, "BRA": 2, "JPN": 1,
          "CHN:海南": 1, "CHN:甘肃": 1, "USA:佛罗里达州": 2, "IND:安得拉邦": 1}
CONT_CN = {"Asia": "亚洲", "Europe": "欧洲", "Africa": "非洲", "North America": "北美",
           "South America": "南美", "Oceania": "大洋洲", "Seven seas (open ocean)": "海洋"}
NAME_OVERRIDE = {"TWN": "台湾", "KOR": "韩国", "PRK": "朝鲜", "COD": "刚果（金）",
                 "COG": "刚果（布）", "CAF": "中非", "DOM": "多米尼加", "BIH": "波黑",
                 "MKD": "北马其顿", "PNG": "巴布亚新几内亚", "ARE": "阿联酋", "SSD": "南苏丹"}
# 跨海航线（国家码，拆省国自动解析到最近省份）
SEA_LANES = [
    ("GBR", "FRA"), ("GBR", "IRL"), ("GBR", "ISL"), ("GBR", "NOR"), ("ISL", "GRL"),
    ("GRL", "CAN"), ("USA", "GBR"), ("ESP", "MAR"), ("BRA", "NGA"), ("ITA", "LBY"),
    ("JPN", "KOR"), ("JPN", "USA"), ("JPN", "RUS"), ("TWN", "CHN"), ("TWN", "PHL"),
    ("PHL", "IDN"), ("PHL", "VNM"), ("LKA", "IND"), ("MDG", "MOZ"), ("NZL", "AUS"),
    ("AUS", "IDN"), ("PNG", "AUS"), ("CUB", "USA"), ("CUB", "MEX"), ("CUB", "HTI"),
    ("JAM", "CUB"), ("DOM", "PRI"), ("SAU", "EGY"), ("IRN", "ARE"), ("SWE", "POL"),
    ("FIN", "EST"), ("USA", "RUS"), ("DNK", "SWE"), ("MYS", "IDN"), ("SGP", "IDN"),
    ("OMN", "IRN"), ("TUR", "UKR"),
    ("USA:夏威夷州", "USA:加利福尼亚州"), ("IND:安达曼-尼科巴群岛", "MMR"),
]
START = {"capital": "CHN:北京", "others": ["CHN:天津", "CHN:河北"]}

def lvl_pop(pop):
    for lv, th in ((5, 9e7), (4, 4e7), (3, 1.2e7), (2, 4e6), (1, 0)):
        if pop >= th:
            return lv
    return 0

def to_px(lon, lat):
    return (round((lon + 180) * SCALE, 2), round((90 - lat) * SCALE, 2))

def only_polys(geom):
    if isinstance(geom, Polygon):
        return [geom]
    if hasattr(geom, "geoms"):
        out = []
        for g in geom.geoms:
            out += only_polys(g)
        return out
    return []

def rings_of(geom, min_area):
    out = []
    for p in only_polys(geom):
        if p.area < min_area:
            continue
        ext = p.exterior.simplify(SIMPLIFY)
        out.append([to_px(x, y) for x, y in ext.coords])
    return out

def short_cn(name):
    for s in CN_STRIP:
        if name.endswith(s) and len(name) > len(s):
            return name[: -len(s)]
    return name

# ---- 整国层 ----
feats0 = json.load(open(SRC0))["features"]
entries = []  # (key, name, arch, geom, pop_lv, min_area)
for f in feats0:
    p = f["properties"]
    a3 = p.get("ADM0_A3") or p.get("ISO_A3")
    if a3 in DROP or a3 in SPLIT:
        continue
    if p["POP_EST"] < MIN_POP and a3 not in KEEP_SMALL:
        continue
    geom = shape(f["geometry"])
    name = NAME_OVERRIDE.get(a3) or p.get("NAME_ZH") or p["NAME"]
    arch = CONT_CN.get(p.get("CONTINENT", ""), "")
    pop = 0 if a3 == "GRL" else lvl_pop(p["POP_EST"])
    entries.append((a3, name, arch, geom, pop, MIN_RING_AREA))

# ---- 省级层 ----
feats1 = json.load(open(SRC1))["features"]
rus_parts = {b[0]: [] for b in RUS_BUCKETS}
for f in feats1:
    p = f["properties"]
    a3 = p.get("adm0_a3")
    if a3 not in SPLIT:
        continue
    geom = shape(f["geometry"])
    if a3 == "RUS":
        lon = p.get("longitude") or geom.representative_point().x
        for bname, lo, hi in RUS_BUCKETS:
            if lo <= float(lon) < hi:
                rus_parts[bname].append(geom)
                break
        continue
    raw = p.get("name_zh") or p.get("name") or "?"
    name = short_cn(raw) if a3 == "CHN" else raw
    key = f"{a3}:{name}"
    pop = POP_P.get(key, POP_DEFAULT[a3])
    entries.append((key, name, SPLIT_CN[a3], geom, pop, MIN_RING_AREA_PROV))
for bname, _, _ in RUS_BUCKETS:
    if rus_parts[bname]:
        key = f"RUS:{bname}"
        geom = unary_union(rus_parts[bname])
        entries.append((key, "俄·" + bname, "俄罗斯", geom, POP_P.get(key, 1), MIN_RING_AREA))

# ---- 区域构建 ----
regions, key2id, geoms = [], {}, []
for key, name, arch, geom, pop, min_area in entries:
    rings = rings_of(geom, min_area)
    if not rings:
        continue
    i = len(regions)
    lab = geom.representative_point()
    regions.append({
        "id": i, "key": key, "name": name, "arch": arch,
        "polys": rings, "label": list(to_px(lab.x, lab.y)),
        "pop": pop,
        "energy": ENERGY_P.get(key, ENERGY.get(key, 2)),
        "fab": FABS.get(key, 0), "launch": LAUNCH.get(key, 0),
        "capital": key == START["capital"],
        "influence": 100 if (key == START["capital"] or key in START["others"]) else 0,
        "plant": 1 if key == START["capital"] else 0,
        "dc": 2 if key == START["capital"] else 0,
    })
    key2id[key] = i
    geoms.append(geom.buffer(0.15))

missing_pins = [k for d in (POP_P, ENERGY_P, FABS, LAUNCH) for k in d
                if ":" in k and k not in key2id]
country_ids = {}
for k, i in key2id.items():
    country_ids.setdefault(k.split(":")[0], []).append(i)

adj = {str(r["id"]): set() for r in regions}
prepped = [prep(g) for g in geoms]
for i in range(len(regions)):
    for j in range(i + 1, len(regions)):
        if prepped[i].intersects(geoms[j]):
            adj[str(i)].add(j)
            adj[str(j)].add(i)

# 航线端点解析：精确键直接用；国家码取离对端最近的省
def _ids_of(spec):
    if ":" in spec:
        return [key2id[spec]] if spec in key2id else []
    return country_ids.get(spec, [])

def resolve_pair(a, b):
    ids_a, ids_b = _ids_of(a), _ids_of(b)
    if not ids_a or not ids_b:
        return None
    best, bd = None, 1e18
    for ia in ids_a:
        for ib in ids_b:
            d = geoms[ia].distance(geoms[ib])
            if d < bd:
                bd, best = d, (ia, ib)
    return best

sea_links = []
for a, b in SEA_LANES:
    pair = resolve_pair(a, b)
    if pair and pair[1] not in adj[str(pair[0])]:
        sea_links.append(list(pair))
adj = {k: sorted(v) for k, v in adj.items()}

# 拆省国家的国界轮廓（UI 粗描边）
country_outlines = []
for a3 in SPLIT:
    parts = [geoms[i] for i in country_ids.get(a3, [])]
    if parts:
        for ring in rings_of(unary_union(parts).buffer(-0.15), MIN_RING_AREA):
            country_outlines.append(ring)

out = {"map_kind": "poly", "regions": regions, "adjacency": adj, "sea_links": sea_links,
       "country_outlines": country_outlines}
path = os.path.join(os.path.dirname(__file__), "..", "game", "data", "world.json")
json.dump(out, open(path, "w", encoding="utf8"), ensure_ascii=False)

iso = [r["name"] for r in regions
       if not adj[str(r["id"])] and not any(r["id"] in l for l in sea_links)]
print(f"regions={len(regions)} sea_links={len(sea_links)} json={os.path.getsize(path)//1024}KB")
print("fabs:", [(r['name'], r['fab']) for r in regions if r['fab']])
print("launch:", [r['name'] for r in regions if r['launch']])
print("start:", [r['name'] for r in regions if r['influence'] >= 60])
print("孤立:", iso)
print("未命中的钉死键:", missing_pins)