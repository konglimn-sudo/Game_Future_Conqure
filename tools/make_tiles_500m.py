# 500m/像素第三级金字塔（全量版）：四季 × 8 块 21600² 巨图 → 各 32×16=512 片 2700² 瓦片
# 海洋瓦片全部保留
import os, gc, sys
from PIL import Image

Image.MAX_IMAGE_PIXELS = None
SUB, TS = 8, 2700
QUARTERS = {"01": 1, "04": 2, "07": 3, "10": 4}

months = sys.argv[1:] or list(QUARTERS.keys())
for mm in months:
    q = QUARTERS[mm]
    dst = os.path.join(os.path.dirname(__file__), "..", "game", "assets", "earth_hd2", f"q{q}")
    os.makedirs(dst, exist_ok=True)
    for col, colname in enumerate("ABCD"):
        for row in (1, 2):
            img = Image.open(f"/tmp/bmng_500m/{mm}/{colname}{row}.jpg")
            assert img.size == (21600, 21600), (mm, colname, row, img.size)
            for sy in range(SUB):
                for sx in range(SUB):
                    gx = col * SUB + sx
                    gy = (row - 1) * SUB + sy
                    img.crop((sx * TS, sy * TS, (sx + 1) * TS, (sy + 1) * TS)) \
                       .save(f"{dst}/t_{gx}_{gy}.jpg", quality=80)
            img.close()
            gc.collect()
            print(f"q{q} {colname}{row} 完成", flush=True)
    n = len(os.listdir(dst))
    size = sum(os.path.getsize(os.path.join(dst, f)) for f in os.listdir(dst)) // 1024 // 1024
    print(f"== q{q}: {n} 片 / {size}MB ==", flush=True)
