# 生成近似世界地图的 game/data/world.json
# 行=纬度带(r0≈75N → r11≈45S)，列=经度(c0≈175W，每列+15°)，六边形近似各大洲轮廓
import json, random, os

random.seed(7)

# 每行的 (区划, 起始列, 结束列)
ROWS = {
    0:  [("G", 10, 10)],
    1:  [("N", 1, 4), ("G", 10, 10), ("E", 12, 13), ("R", 14, 21)],
    2:  [("N", 2, 6), ("E", 11, 13), ("R", 14, 21)],
    3:  [("N", 3, 6), ("E", 11, 13), ("C", 14, 16), ("H", 17, 20)],
    4:  [("N", 4, 6), ("E", 11, 13), ("M", 14, 16), ("H", 17, 19), ("J", 20, 21)],
    5:  [("N", 5, 6), ("A", 11, 14), ("M", 15, 16), ("I", 17, 17), ("H", 18, 20)],
    6:  [("N", 6, 6), ("A", 11, 15), ("M", 16, 16), ("I", 17, 18), ("T", 19, 20)],
    7:  [("S", 6, 7), ("A", 11, 15), ("T", 18, 21)],
    8:  [("S", 6, 8), ("A", 12, 14), ("T", 19, 21)],
    9:  [("S", 7, 8), ("A", 12, 13), ("O", 20, 22)],
    10: [("S", 7, 8), ("A", 12, 13), ("O", 20, 21)],
    11: [("S", 7, 7), ("O", 21, 21), ("O", 23, 23)],
}

ZONE_CN = {"N": "北美", "S": "南美", "E": "欧洲", "R": "北亚", "C": "中亚", "M": "中东",
           "A": "非洲", "I": "南亚", "H": "东亚", "J": "瀛海", "T": "南洋", "O": "澳洲", "G": "冰原"}
# (人口基准, 能源基准)
ZONE_BASE = {"N": (2, 3), "S": (2, 2), "E": (3, 2), "R": (1, 4), "C": (1, 3), "M": (1, 5),
             "A": (2, 3), "I": (4, 2), "H": (4, 2), "J": (4, 1), "T": (3, 2), "O": (1, 4), "G": (0, 2)}
ZONE_NAMES = {
    "N": ("枫岩鹰杉湖松狼汀", "原岭港湾林地谷"),
    "S": ("雨翡豹蕉河岚银", "林湾原崖谷滩"),
    "E": ("雾橡琥雪鸢石蓝", "峡原湾峰岸泽"),
    "R": ("霜针冻苔白寒玄", "原林海岭川带"),
    "C": ("草驼天碛风", "原漠山口谷"),
    "M": ("月星沙绿幼", "湾漠洲岸丘"),
    "A": ("金象狮椰赭曦塔", "漠原湾角丘川"),
    "I": ("恒香孟椰锡", "原岭湾滩林"),
    "H": ("青云潮岭海洛", "川原湾岭东南"),
    "J": ("瀛樱玄", "洲海滩"),
    "T": ("湄爪兰暹婆椰", "原洲滩港屿"),
    "O": ("珊桉赤翠岩", "湾原岩屿滩"),
    "G": ("冰", "盖原"),
}
# 钉死的特色区域：(col,row) -> 属性覆盖
PINNED = {
    (18, 4): dict(name="中原", pop=5, energy=2, fab=1, capital=True, start=True),
    (19, 4): dict(name="江南", pop=5, energy=2, start=True),
    (18, 3): dict(name="燕北", pop=4, energy=3, start=True),
    (17, 4): dict(name="羌原", pop=1, energy=4),
    (20, 5): dict(name="潮屿", pop=3, energy=1, fab=4),
    (21, 4): dict(name="瀛洲", pop=4, energy=1, fab=3),
    (12, 3): dict(name="雾峡", pop=4, energy=2, fab=2),
    (4, 4):  dict(name="赤漠", pop=2, energy=4, fab=2),
    (17, 5): dict(name="德干", pop=5, energy=2, fab=1),
    (6, 5):  dict(name="鹭角", pop=2, energy=2, launch=2),
    (7, 7):  dict(name="翠岸", pop=2, energy=2, launch=2),
    (19, 6): dict(name="椰湾", pop=3, energy=2, launch=1),
    (15, 5): dict(name="油洲", pop=1, energy=5),
    (16, 4): dict(name="月湾", pop=2, energy=5),
    (11, 5): dict(name="沙海", pop=1, energy=5),
    (12, 5): dict(name="金漠", pop=1, energy=5),
    (8, 8):  dict(name="雨洲", pop=4, energy=4),
    (6, 3):  dict(name="湾流", pop=4, energy=2),
    (5, 3):  dict(name="五湖", pop=4, energy=3),
    (21, 10): dict(name="盐原", pop=1, energy=5),
    (16, 1): dict(name="寒川", pop=0, energy=5),
    (12, 6): dict(name="棕岸", pop=4, energy=2),
    (13, 10): dict(name="望角", pop=2, energy=3),
}
# 跨洋航线（坐标对）：北航线两段、中/南大西洋、塔斯曼
SEA_LANES = [((5, 2), (10, 1)), ((10, 1), (12, 1)), ((6, 3), (11, 3)),
             ((8, 8), (12, 8)), ((22, 9), (23, 11))]

def axial(col, row):
    return (col, row - col // 2)

land = {}
for row, spans in ROWS.items():
    for zone, c0, c1 in spans:
        for col in range(c0, c1 + 1):
            land[(col, row)] = zone

names_used = set()
def gen_name(zone):
    p, s = ZONE_NAMES[zone]
    for _ in range(300):
        n = random.choice(p) + random.choice(s)
        if n not in names_used:
            names_used.add(n)
            return n
    n = ZONE_CN[zone] + str(len(names_used))
    names_used.add(n)
    return n

for v in PINNED.values():
    names_used.add(v["name"])

regions, by_hex = [], {}
for i, ((col, row), zone) in enumerate(sorted(land.items(), key=lambda kv: (kv[0][1], kv[0][0]))):
    bp, be = ZONE_BASE[zone]
    pin = PINNED.get((col, row), {})
    q, r = axial(col, row)
    rg = {
        "id": i,
        "name": pin.get("name") or gen_name(zone),
        "q": q, "r": r, "arch": ZONE_CN[zone],
        "pop": pin.get("pop", max(0, min(5, bp + random.randint(-1, 1)))),
        "energy": pin.get("energy", max(0, min(5, be + random.randint(-1, 1)))),
        "fab": pin.get("fab", 0),
        "launch": pin.get("launch", 0),
        "capital": pin.get("capital", False),
        "influence": 100 if pin.get("start") else 0,
        "plant": 1 if pin.get("capital") else 0,
        "dc": 2 if pin.get("capital") else 0,
    }
    regions.append(rg)
    by_hex[(col, row)] = rg

def neighbors_ax(h):
    q, r = h
    return [(q+1, r), (q-1, r), (q, r+1), (q, r-1), (q+1, r-1), (q-1, r+1)]

ax_index = {(r["q"], r["r"]): r["id"] for r in regions}
adj = {}
for r in regions:
    adj[str(r["id"])] = sorted(ax_index[n] for n in neighbors_ax((r["q"], r["r"])) if n in ax_index)

sea_links = []
for (a, b) in SEA_LANES:
    assert a in by_hex and b in by_hex, f"航线端点不在陆地: {a} {b}"
    sea_links.append([by_hex[a]["id"], by_hex[b]["id"]])

out = {"hex_size": 46, "regions": regions, "adjacency": adj, "sea_links": sea_links}
path = os.path.join(os.path.dirname(__file__), "..", "game", "data", "world.json")
json.dump(out, open(path, "w", encoding="utf8"), ensure_ascii=False, indent=1)

zones = {}
for r in regions:
    zones[r["arch"]] = zones.get(r["arch"], 0) + 1
print(f"regions={len(regions)} zones={zones}")
print("fabs:", [(r['name'], r['fab']) for r in regions if r['fab']])
print("launch:", [r['name'] for r in regions if r['launch']])
print("start:", [r['name'] for r in regions if r['influence'] >= 60])
