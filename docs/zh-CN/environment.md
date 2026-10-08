# 环境与资产说明
[English](../environment.md) | 中文

本项目运行/构建依赖的资产位置与获取方式。**原版游戏资源版权属 Ubisoft / New World
Computing，仓库不包含、Git 历史也不包含**，需自备。

---

## 游戏资产（Heroes3 引擎必需，来自原版 HoMM3）

| 路径 | 用途 |
|---|---|
| `<数据目录>/Data/H3sprite.lod` | **地图渲染唯一素材来源**：地形/河流/道路/边界/全部冒险物件 def（4013 条目，2565 def）；About 窗口的天使动画（cangel.def）、DIALGBOX、IOKAY32 也从这里导出 |
| 同目录 `H3bitmap.lod` | PCX/界面素材。**构建期需要**：About 对话框内部纸底 `DIBOXBCK.PCX`、玩家色表 `PLAYERS.PAL`（暂未导出，见 formats.md §2.7/§2.8） |
| `<数据目录>/Maps/*.h3m` | 地图。VCMI 自带 189 个 `.h3m`（RoE/AB/SoD） |

推荐通过 [VCMI](https://github.com/vcmi/vcmi) 安装获得上述文件（安装器会从原版游戏复制）。

**运行时数据目录解析顺序**（`AppDelegate.dataDir` / `Heroes3Engine.defaultDataDir`）：
1. 用户设置过的 `dataDir`（UserDefaults）；
2. **app 内置资源** `GameWallpaper.app/Contents/Resources/Data/H3sprite.lod`
   （本地打包时自动从 VCMI 目录拷入，自包含分发的前提）；
3. `~/Library/Application Support/vcmi`（开发机兜底）。

**打包策略**：`scripts/build_app.sh` 默认要求本机有上述资源（缺失即报错拒绝出空包）；
设 `REQUIRE_ASSETS=0` 时打包**无资源 lite 版**（CI 发布用），首次运行后由用户在
菜单里指定资源目录与地图目录。

## 参考代码库

| 路径 | 说明 |
|---|---|
| [VCMI](https://github.com/vcmi/vcmi)（v1.7.3 checkout） | 格式与渲染语义的权威参考；关键文件：`lib/mapping/MapFormatH3M.cpp`、`lib/constants/EntityIdentifiers.h`（Obj 枚举）、`client/render/CDefFile.cpp`、`client/mapView/MapRenderer.cpp`、`config/terrains.json`/`rivers.json`（调色板动画区间） |
| [IlyaPomaskin/h3lwp](https://github.com/IlyaPomaskin/h3lwp) | Android 版 Heroes 3 live wallpaper，本项目解析器/图层行为的基线（`base.apk` 即其构建产物，本地逆向参考用，不入库） |

## 工具链

- Xcode / SwiftPM（`Package.swift`，macOS 13+）；构建脚本 `scripts/build_app.sh`。
- Node（web 版地图查看器，零依赖）：`cd web && npm start`。
- 验证工具：jadx（APK 反编译，本地）、Python Pillow（差分比对）、Quartz（离屏窗口合成）、
  `screencapture`。

## 命令速查

```bash
./scripts/build_app.sh            # 构建 release 并打包 .app/.dmg（本机模式：内置 LOD + 地图 + About 资源）
REQUIRE_ASSETS=0 ./scripts/build_app.sh   # lite 模式（无内置资源，CI 发布用）
open build/GameWallpaper.app      # 启动壁纸（菜单栏 🎮）

# About 窗口无头验证：启动后 0.9s 自动弹出 About（配合 Quartz 枚举窗口 + screencapture -l<id> 截图）
open build/GameWallpaper.app --args --about

# 手动重导 About 精灵（一般由 build_app.sh 调用；需 H3sprite.lod 同目录有 H3bitmap.lod）
python3 scripts/export_about_assets.py \
    "$HOME/Library/Application Support/vcmi/Data/H3sprite.lod" \
    build/GameWallpaper.app/Contents/Resources/about

# 无头渲染单帧（验证/调试）
.build/release/GameWallpaper --snapshot "<map.h3m>" --out out.png \
    [--data-dir <dir>] [--width W --height H] [--time-ms ms] [--zoom z] \
    [--center-x 0..1 --center-y 0..1] [--level 0|1]

# 诊断探针
.build/release/GameWallpaper --probe-def GRASTL.DEF          # def 结构/调色板
.build/release/GameWallpaper --tile 6 1 --snapshot <map>     # 某格 h3m 数据

# 渲染对比基准（编辑器与游戏共用渲染器）
/Applications/VCMI.app/Contents/MacOS/vcmieditor "<map.h3m>"
```

## 版本号机制

- 发布版本 = **git tag `v<major>.<minor>`**（如 `v1.0`），push tag 触发 GitHub Actions
  自动构建 dmg 并发布 Release（`.github/workflows/release.yml`）。
- `CFBundleShortVersionString` = tag 去掉 `v`（如 `1.0`）；`CFBundleVersion` = 构建号
  （commit 数 + short sha），由 build_app.sh 从 git 推导，本地可 `MARKETING_VERSION=`
  / `BUILD_NUMBER=` 覆盖。About 窗口显示 `x.y-build`。
- Release 说明由 workflow 从上个 tag 以来的 commit log 自动分组生成（feat/fix/other）。
- i18n：`Resources/{en,zh-Hans}.lproj/Localizable.strings`，菜单/About 文案走
  NSLocalizedString 跟随系统语言。
