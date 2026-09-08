# 环境与资产说明

本机（steven0lisa 的 Mac）上本项目依赖的资源位置与探测结论。

---

## 游戏资产（必需，来自原版 HoMM3）

| 路径 | 用途 |
|---|---|
| `~/Library/Application Support/vcmi/Data/H3sprite.lod` | **地图渲染唯一素材来源**：地形/河流/道路/边界/全部冒险物件 def（4013 条目，2565 def）；About 窗口的天使动画（cangel.def）、DIALGBOX、IOKAY32 也从这里导出 |
| 同目录 `H3bitmap.lod` | PCX/界面素材。**构建期需要**：About 对话框内部纸底 `DIBOXBCK.PCX`、玩家色表 `PLAYERS.PAL`（暂未导出，见 formats.md §2.7/§2.8） |
| 同目录 `H3ab_bmp.lod` / `H3ab_spr.lod` | 其余 PCX/MSK，本项目不用 |

这些是 VCMI 安装时复制的原版游戏文件（版权属 Ubisoft/NWC，本仓库不含）。
换机器时把任意一份 HoMM3 Complete 的 `H3sprite.lod` 放到上述位置，或通过菜单栏
指定其他目录（读取 `<dataDir>/Data/H3sprite.lod`）。

## 地图（默认 `~/Library/Application Support/vcmi/Maps/`）

- VCMI 自带 189 个 `.h3m`（含 RoE/AB/SoD 各版本）+ `.h3c` 战役（本项目不读 h3c）。
- `base.apk`（h3lwp 3.0.7）内还带两张小图：`discovery-by-prometheus.h3m`、
  `invasion.h3m`，已解出存于 `base.apk_assets_maps/` 并打进 app Resources 作兜底
  （地图目录为空时使用）。

## 参考代码库

| 路径 | 说明 |
|---|---|
| `~/work/personal/vcmi` | VCMI 引擎源码（v1.7.3 checkout），格式与渲染语义的权威参考；关键文件：`lib/mapping/MapFormatH3M.cpp`、`lib/constants/EntityIdentifiers.h`（Obj 枚举）、`client/render/CDefFile.cpp`、`client/mapView/MapRenderer.cpp`、`config/terrains.json`/`rivers.json`（调色板动画区间） |
| `/Applications/VCMI.app` | 已安装的 VCMI，`vcmieditor` 可从命令行带地图路径启动，用于渲染对比基准 |
| `base.apk`（本仓库） | Android 动态壁纸产物，jadx 反编译源码在 `/tmp/apk_jadx`（临时）；上游仓库 https://github.com/IlyaPomaskin/h3lwp |

## 工具链

- Xcode 26.3 / Swift 6.2.4 / macOS 26.2 SDK；构建用 SPM（`Package.swift`，macOS 13+）。
- 验证工具：jadx（APK 反编译）、Python Pillow（差分比对）、Quartz（离屏窗口合成）、
  `screencapture`。

## 命令速查

```bash
./scripts/build_app.sh            # 构建 release 并打包 .app（含 About 资源导出 + i18n + dmg）
open build/Heroes3Wallpaper.app   # 启动壁纸（菜单栏 🏰）

# About 窗口无头验证：启动后 0.9s 自动弹出 About（配合 Quartz 枚举窗口 + screencapture -l<id> 截图）
open build/Heroes3Wallpaper.app --args --about

# 手动重导 About 精灵（一般由 build_app.sh 调用；需 H3sprite.lod 同目录有 H3bitmap.lod）
python3 scripts/export_about_assets.py \
    "$HOME/Library/Application Support/vcmi/Data/H3sprite.lod" \
    build/Heroes3Wallpaper.app/Contents/Resources/about

# 无头渲染单帧（验证/调试）
.build/release/Heroes3Wallpaper --snapshot "<map.h3m>" --out out.png \
    [--data-dir <dir>] [--width W --height H] [--time-ms ms] [--zoom z] \
    [--center-x 0..1 --center-y 0..1] [--level 0|1]

# 诊断探针
.build/release/Heroes3Wallpaper --probe-def GRASTL.DEF          # def 结构/调色板
.build/release/Heroes3Wallpaper --tile 6 1 --snapshot <map>     # 某格 h3m 数据

# 渲染对比基准（编辑器与游戏共用渲染器）
/Applications/VCMI.app/Contents/MacOS/vcmieditor "<map.h3m>"
```

版本号机制：`CFBundleShortVersionString=x.y.z`（默认 1.0.0，可 `MARKETING_VERSION=` 覆盖）
+ `CFBundleVersion=<build_number>`（默认 `date +%Y%m%d%H%M`，可 `BUILD_NUMBER=` 覆盖）；
About 窗口显示 `x.y.z-build_number`。i18n：`Resources/{en,zh-Hans}.lproj/Localizable.strings`，
菜单/About 文案走 NSLocalizedString 跟随系统语言。
