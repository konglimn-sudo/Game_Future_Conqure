# 生成地形表现层 game/data/terrain.json（Natural Earth 10m 物理图层，公有领域）
# 湖泊面、主要河流线、山脉区域 + 大洋名称锚点
import json, os
from shapely.geometry import shape, Polygon, LineString

SCALE = 7.0
def to_px(lon, lat):
    return [round((lon + 180) * SCALE, 2), round((90 - lat) * SCALE, 2)]

def only_polys(geom):
    if isinstance(geom, Polygon):
        return [geom]
    if hasattr(geom, "geoms"):
        out = []
        for g in geom.geoms:
            out += only_polys(g)
        return out
    return []

def only_lines(geom):
    if isinstance(geom, LineString):
        return [geom]
    if hasattr(geom, "geoms"):
        out = []
        for g in geom.geoms:
            out += only_lines(g)
        return out
    return []

# ---- 湖泊：大中型湖（里海/五大湖/贝加尔/维多利亚等）----
lakes = []
for f in json.load(open("/tmp/ne_10m_lakes.geojson"))["features"]:
    if f["properties"].get("scalerank", 9) > 4:
        continue
    for p in only_polys(shape(f["geometry"])):
        if p.area < 0.04:
            continue
        ext = p.exterior.simplify(0.02)
        lakes.append([to_px(x, y) for x, y in ext.coords])

# ---- 河流：主要干流（长江/黄河/尼罗/亚马逊/密西西比等）----
rivers = []
for f in json.load(open("/tmp/ne_10m_rivers_lake_centerlines.geojson"))["features"]:
    pr = f["properties"]
    if pr.get("scalerank", 9) > 5 or "River" not in (pr.get("featurecla") or ""):
        continue
    for ln in only_lines(shape(f["geometry"])):
        ln = ln.simplify(0.03)
        if ln.length < 0.8:
            continue
        rivers.append([to_px(x, y) for x, y in ln.coords])

# ---- 山脉：地理区域面中的 Range/mtn ----
RANGE_ZH = {
    "HIMALAYAS": "喜马拉雅山脉", "ROCKY MOUNTAINS": "落基山脉", "ANDES": "安第斯山脉",
    "ALPS": "阿尔卑斯山脉", "TIAN SHAN": "天山", "KUNLUN MOUNTAINS": "昆仑山脉",
    "URAL MOUNTAINS": "乌拉尔山脉", "HINDU KUSH": "兴都库什山脉", "KARAKORAM": "喀喇昆仑山脉",
    "GREAT DIVIDING RANGE": "大分水岭", "ATLAS MOUNTAINS": "阿特拉斯山脉",
    "ZAGROS MOUNTAINS": "扎格罗斯山脉", "CAUCASUS MOUNTAINS": "高加索山脉",
    "APPALACHIAN MOUNTAINS": "阿巴拉契亚山脉", "ALTAY MOUNTAINS": "阿尔泰山脉",
    "PLATEAU OF TIBET": "青藏高原", "BRAZILIAN HIGHLANDS": "巴西高原",
    "ETHIOPIAN HIGHLANDS": "埃塞俄比亚高原", "DRAKENSBERG": "德拉肯斯山脉",
    "SIERRA MADRE": "马德雷山脉", "VERKHOYANSK RANGE": "上扬斯克山脉",
    "STANOVOY RANGE": "外兴安岭", "SAYAN MOUNTAINS": "萨彦岭",
}
# ---- 地貌填充：沙漠/绿地/冻原（着色匹配地貌）----
TERRA_CLS = {
    "desert": ("desert", "depression"),
    "green": ("plain", "delta", "basin", "valley", "lowland", "wetlands", "foothills"),
    "tundra": ("tundra",),
}
terras = []
geo_feats = json.load(open("/tmp/ne_10m_geography_regions_polys.geojson"))["features"]
for f in geo_feats:
    pr = f["properties"]
    cla = (pr.get("FEATURECLA") or "").lower()
    cls = next((k for k, v in TERRA_CLS.items() if cla in v), None)
    if cls is None:
        continue
    geom = shape(f["geometry"])
    if geom.area < 0.8 or geom.representative_point().y < -58:
        continue
    rings = []
    for p in only_polys(geom):
        if p.area < 0.5:
            continue
        ext = p.exterior.simplify(0.1)
        rings.append([to_px(x, y) for x, y in ext.coords])
    if rings:
        lab = geom.representative_point()
        terras.append({"cls": cls, "rings": rings, "lat": round(lab.y, 1)})

ranges = []
for f in geo_feats:
    pr = f["properties"]
    cla = (pr.get("FEATURECLA") or "").lower()
    if cla not in ("range/mtn", "plateau"):
        continue
    geom = shape(f["geometry"])
    if geom.area < 6.0:
        continue
    if geom.representative_point().y < -58:   # 南极洲不在地图上
        continue
    rings = []
    for p in only_polys(geom):
        if p.area < 2.0:
            continue
        ext = p.exterior.simplify(0.12)
        rings.append([to_px(x, y) for x, y in ext.coords])
    if not rings:
        continue
    name_en = (pr.get("NAME") or "").upper()
    lab = geom.representative_point()
    ranges.append({
        "rings": rings,
        "label": to_px(lab.x, lab.y),
        "name": RANGE_ZH.get(name_en) or pr.get("NAME_ZH") or "",
        "area": round(geom.area, 1),
    })
ranges.sort(key=lambda r: -r["area"])
ranges = ranges[:40]

# ---- 海洋水深分层（200m 大陆架坡折 / 2000m / 5000m 深海）----
bathy = []
for depth, fname, min_a in ((200, "ne_10m_bathymetry_K_200", 1.0),
                            (2000, "ne_10m_bathymetry_I_2000", 1.0),
                            (5000, "ne_10m_bathymetry_F_5000", 3.0)):
    rings = []
    for f in json.load(open(f"/tmp/{fname}.geojson"))["features"]:
        for p in only_polys(shape(f["geometry"])):
            if p.area < min_a:
                continue
            ext = p.exterior.simplify(0.15)
            rings.append([to_px(x, y) for x, y in ext.coords])
    bathy.append({"depth": depth, "rings": rings})

# ---- 主要海域名称（海/湾，按面积取前 20）----
seas = []
for f in json.load(open("/tmp/ne_10m_geography_marine_polys.geojson"))["features"]:
    pr = f["properties"]
    if (pr.get("featurecla") or "") not in ("sea", "gulf"):
        continue
    nz = pr.get("name_zh")
    if not nz:
        continue
    geom = shape(f["geometry"])
    lab = geom.representative_point()
    if lab.y < -58:
        continue
    seas.append({"name": nz, "p": to_px(lab.x, lab.y), "area": geom.area})
seas.sort(key=lambda s: -s["area"])
seas = [{"name": s["name"], "p": s["p"]} for s in seas[:20]]

# ---- 永久冰盖（格陵兰冰原等）----
glaciers = []
for f in json.load(open("/tmp/ne_10m_glaciated_areas.geojson"))["features"]:
    geom = shape(f["geometry"])
    if geom.representative_point().y < -58:
        continue
    for p in only_polys(geom):
        if p.area < 0.6:
            continue
        ext = p.exterior.simplify(0.08)
        glaciers.append([to_px(x, y) for x, y in ext.coords])

# ---- 大洋名称锚点 ----
oceans = [
    {"name": "太 平 洋", "p": to_px(-155, 5)}, {"name": "太 平 洋", "p": to_px(165, 8)},
    {"name": "大 西 洋", "p": to_px(-35, 20)}, {"name": "南大西洋", "p": to_px(-18, -28)},
    {"name": "印 度 洋", "p": to_px(78, -18)}, {"name": "北冰洋", "p": to_px(45, 83)},
]

out = {"lakes": lakes, "rivers": rivers, "ranges": ranges, "oceans": oceans, "terras": terras,
       "bathy": bathy, "seas": seas, "glaciers": glaciers}
path = os.path.join(os.path.dirname(__file__), "..", "game", "data", "terrain.json")
json.dump(out, open(path, "w", encoding="utf8"), ensure_ascii=False)
from collections import Counter
print(f"lakes={len(lakes)} rivers={len(rivers)} ranges={len(ranges)} "
      f"terras={Counter(t['cls'] for t in terras)} "
      f"bathy={[len(b['rings']) for b in bathy]} glaciers={len(glaciers)} json={os.path.getsize(path)//1024}KB")
print("海域:", [s["name"] for s in seas])
