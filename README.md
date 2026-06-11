# Future Conquer

近未来全球大战略游戏：以算力为权力，以电力为命脉，以数据为弹药。

玩家扮演一个「智能体文明」的掌控者，通过**芯片、电力、数据**三大资源驱动 AI 模型的
代际进化，在真实国界的世界地图上以渗透与建设扩张版图。完整设计见
[GAME_DESIGN.md](GAME_DESIGN.md)。

当前进度：**M1 经济沙盒**（时间按月流动、世界自演化、省级行政区划地图、卫星真彩底图、
昼夜与四季渲染、军团部署雏形）。战争（M2）、AI 大国（M3）开发中。

## 运行

依赖：[Godot 4.6+](https://godotengine.org)（`brew install --cask godot`）

```bash
godot --path game
```

操作：左键拖动/点选 ｜ 滚轮或双指缩放 ｜ 空格暂停/继续 ｜ 1~4 调速 ｜ 回车单步
｜ M 卫星/政治图层 ｜ Home 回首都 ｜ F5/F9 存读档

## 高清卫星资产（可选）

仓库自带 8km 与 2km 级影像，开箱即玩。500m 级四季高清瓦片（约 875MB）未入库，
需要时一键重建：

```bash
pip3 install pillow shapely
bash tools/fetch_500m.sh
```

## 地图数据重建（可选）

```bash
python3 tools/gen_world_countries.py   # 行政区划（需先下载 Natural Earth 源数据）
python3 tools/gen_terrain.py           # 地形图层
python3 tools/add_cities.py            # 城市图层
```

## 测试

```bash
godot --headless --path game --script res://tests/run_sim.gd
```

机器人自动玩 42 个月，校验资源循环不变量、扩张、代际推进与存读档一致性。

## 数据致谢

- 国界/省界/地形矢量：[Natural Earth](https://www.naturalearthdata.com/)（公有领域）
- 卫星影像：[NASA Blue Marble Next Generation](https://visibleearth.nasa.gov/collection/1484/blue-marble)（公有领域）
