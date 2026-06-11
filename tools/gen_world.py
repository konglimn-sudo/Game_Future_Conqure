# 生成 M1 世界数据 game/data/world.json：六边形区域大陆 + 属性 + 邻接
import json, random, math, os

random.seed(42)
COLS, ROWS = 20, 11
TARGET_LAND = 62

def axial(col, row):
    return (col, row - col // 2)

def neighbors(h):
    q, r = h
    return [(q+1, r), (q-1, r), (q, r+1), (q, r-1), (q+1, r-1), (q-1, r+1)]

ALL = {axial(c, r) for c in range(COLS) for r in range(ROWS)}

def grow_continent(seed_hex, size):
    blob, frontier = {seed_hex}, [seed_hex]
    while len(blob) < size and frontier:
        cur = random.choice(frontier)
        cands = [n for n in neighbors(cur) if n in ALL and n not in blob]
        if not cands:
            frontier.remove(cur)
            continue
        nxt = random.choice(cands)
        blob.add(nxt)
        frontier.append(nxt)
    return blob

# 三块大陆，避免重叠：种子分散
seeds = [axial(3, 5), axial(10, 3), axial(16, 7)]
sizes = [24, 22, 20]
land = set()
for s, sz in zip(seeds, sizes):
    land |= grow_continent(s, sz)
land = set(list(land)[:TARGET_LAND + 6])

# 原型区域属性
ARCHETYPES = [
    ("都市", 0.18, (4, 5), (1, 2)),
    ("工业", 0.20, (2, 3), (2, 3)),
    ("能源", 0.18, (1, 2), (4, 5)),
    ("荒原", 0.14, (0, 1), (1, 3)),
    ("均衡", 0.30, (2, 3), (2, 3)),
]

def pick_archetype():
    x, acc = random.random(), 0
    for name, w, p, e in ARCHETYPES:
        acc += w
        if x <= acc:
            return name, random.randint(*p), random.randint(*e)
    return ARCHETYPES[-1][0], 2, 2

C1 = list("青铁沙雪黑金云赤苍白风星岚荒凛曦澜岩汀霜玄翠")
C2 = list("岭湾原漠港角屿川谷崖滩洲峡林泽峰碛")
names = set()
def gen_name():
    for _ in range(200):
        n = random.choice(C1) + random.choice(C2)
        if n not in names:
            names.add(n)
            return n
    n = f"区{len(names)}"
    names.add(n)
    return n

hexes = sorted(land)
regions, by_hex = [], {}
for i, h in enumerate(hexes):
    arch, pop, energy = pick_archetype()
    regions.append({
        "id": i, "name": gen_name(), "q": h[0], "r": h[1], "arch": arch,
        "pop": pop, "energy": energy, "fab": 0, "launch": 0,
        "capital": False, "influence": 0, "plant": 0, "dc": 0,
    })
    by_hex[h] = regions[-1]

def hdist(a, b):
    aq, ar = a; bq, br = b
    return (abs(aq-bq) + abs(ar-br) + abs(aq+ar-bq-br)) // 2

# 晶圆厂：6 个，彼此距离 ≥3，偏好工业/都市
fab_levels = [3, 2, 2, 1, 1, 1]
cands = sorted(hexes, key=lambda h: (-(by_hex[h]["pop"] + by_hex[h]["energy"]), random.random()))
placed = []
for lv in fab_levels:
    for h in cands:
        if by_hex[h]["fab"] == 0 and all(hdist(h, p) >= 3 for p in placed):
            by_hex[h]["fab"] = lv
            placed.append(h)
            break

# 发射场：3 个，取最接近"赤道"（地图垂直中线）的区域
def y_of(h):
    q, r = h
    return math.sqrt(3) * (r + q / 2)
mid = (min(map(y_of, hexes)) + max(map(y_of, hexes))) / 2
for h in sorted(hexes, key=lambda h: abs(y_of(h) - mid))[:3]:
    by_hex[h]["launch"] = random.choice([1, 2])

# 起始区：一个 fab=1 的区域 + 两个陆地邻居
start = None
for h in hexes:
    if by_hex[h]["fab"] == 1:
        nbs = [n for n in neighbors(h) if n in land]
        if len(nbs) >= 2:
            start = [h] + nbs[:2]
            break
assert start
for j, h in enumerate(start):
    rg = by_hex[h]
    rg["influence"] = 100
    if j == 0:
        rg.update(capital=True, dc=2, plant=1)

adj = {str(r["id"]): sorted(by_hex[n]["id"] for n in neighbors((r["q"], r["r"])) if n in land)
       for r in regions}

out = {"hex_size": 46, "regions": regions, "adjacency": adj}
path = os.path.join(os.path.dirname(__file__), "..", "game", "data", "world.json")
os.makedirs(os.path.dirname(path), exist_ok=True)
json.dump(out, open(path, "w", encoding="utf8"), ensure_ascii=False, indent=1)
caps = [r for r in regions if r["capital"]]
print(f"regions={len(regions)} fabs={[r['name']+str(r['fab']) for r in regions if r['fab']]} "
      f"launch={[r['name'] for r in regions if r['launch']]} capital={caps[0]['name']}")
