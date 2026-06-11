#!/bin/bash
# 一键重建 500m/像素四季高清瓦片（game/assets/earth_hd2，约 875MB）
# 数据源：NASA Blue Marble Next Generation（公有领域）
# 用法：bash tools/fetch_500m.sh
set -e
cd "$(dirname "$0")/.."

declare -A IDS=([01]=73580 [04]=73655 [07]=73751 [10]=73826)
mkdir -p /tmp/bmng_500m

for mm in 01 04 07 10; do
  id=${IDS[$mm]}
  mkdir -p /tmp/bmng_500m/$mm
  for t in A1 B1 C1 D1 A2 B2 C2 D2; do
    url="https://eoimages.gsfc.nasa.gov/images/imagerecords/73000/$id/world.topo.bathy.2004$mm.3x21600x21600.$t.jpg"
    f="/tmp/bmng_500m/$mm/$t.jpg"
    # NASA 服务器常掐断大文件：断点续传循环直到能完整解码
    for i in $(seq 1 15); do
      curl -sL -C - -o "$f" "$url" || true
      if python3 -c "
from PIL import Image
Image.MAX_IMAGE_PIXELS = None
img = Image.open('$f'); img.load(); img.close()" 2>/dev/null; then
        echo "$mm/$t OK"
        break
      fi
    done
  done
done

python3 tools/make_tiles_500m.py
echo "完成。启动游戏前先执行: godot --headless --path game --import game"
