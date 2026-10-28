[English](../android.md) | 中文

# Android 动态壁纸（org.feichao.h3wallpaper）

《魔法门之英雄无敌 III》动态壁纸的 Android 自包含重实现，与本仓库的地图渲染
语义完全一致（与 web 查看器、macOS Metal 渲染器共用同一套解析与绘制顺序）。

## 功能

- **零设置** — 三张 XL 地图已烘焙进 APK（`scenes.bin` + 17 张图集页）。安装 →
  系统选择器里选本壁纸 → 完成。没有任何设置页：启动页只有 **启动/暂停壁纸**、
  **关于**、**检查更新**（查询 GitHub Releases API 并跳转下载页）。
- **与 mac/web 同一套引擎语义** — `android/bake/bake.js` 复用 web 引擎解析器
  （h3m/lod/def + 场景构建）输出紧凑二进制；GLES2 渲染器逐行移植
  `web/public/viewer.js`（边界 → 地形 → 河流 → 道路半格裁剪 → 物件画序）。

## 省电设计（对比原版 h3lwp APK）

原版经 libGDX 持续渲染（可见时 ~60fps）。本实现**只在画面可能变化时绘制**：

| 状态 | 行为 |
|---|---|
| 壁纸不可见（灭屏 / 被 App 遮挡 / 锁屏） | **0 fps** — 渲染线程挂起，最后一帧保持 |
| 用户点了暂停 | **0 fps**（画面冻结） |
| 相机停留（每 180 秒里约 179 秒） | **只在 180ms 动画步进边界重绘** ≈ 5.5 fps — H3 精灵变化的最小速率 |
| 相机跳点滑动（1.6 秒） | 30 fps |
| `Surface.setFrameRate` 提示 | 告知合成器当前节奏，LTPO 屏幕可降刷新率 |

默认 DPI 缩放下可视区域仅 ~411×914 世界像素（约 13×29 格），每次重绘只有几百
个贴图 quad。两个 180ms 边界之间渲染线程休眠，CPU/GPU 零开销。

实测（小米 14 档机型，300 秒、亮屏、桌面、壁纸可见）：原版 APK ≈ 10.6% CPU，
本 APK ≈ 1%（见 `scripts/android_battery_bench.sh`）。

## 构建

```bash
# 开发机（需要游戏 H3sprite.lod + 解密后的内置地图）
./scripts/build_android.sh            # debug APK -> build/GameWallpaper.apk
./scripts/android_scenes.sh encrypt   # 渲染器/地图变更后刷新 Resources/AndroidScenes.enc

# CI（无游戏素材）：解密加密包后构建签名 APK
./scripts/android_scenes.sh unpack
BUNDLED_MAPS_PASS=... ./scripts/android_scenes.sh unpack
```

- **版权**：烘焙的场景数据源自原作精灵与地图。与 `Resources/BundledMaps/*.h3m.enc`
  相同，仓库内**只存 AES 加密副本**（`Resources/AndroidScenes.enc`，密码 =
  `BUNDLED_MAPS_PASS` secret），构建时解密；明文永不进 git。APK 本体必然包含
  渲染后的画面。
- 签名：release APK 用 GitHub secrets 中的 keystore 签名（`ANDROID_KEYSTORE_B64`
  / 密码）。debug 构建用 debug keystore。
- 发版：push `v{major}.{minor}` tag — CI 同时构建 dmg **和** APK，附到同一个
  GitHub Release。

## 源码结构

```
android/
├── bake/bake.js                  # h3m+LOD -> scenes.bin + 图集 PNG（复用 web 引擎）
├── app/src/main/java/org/feichao/h3wallpaper/
│   ├── SceneData.java            # scenes.bin 解析（struct-of-arrays）
│   ├── wp/Renderer.java          # GLES2 绘制（viewer.js 移植：图层、道路裁剪、翻转）
│   ├── wp/Camera.java            # 跳点相机（移植 Sources/WallpaperCore/Camera.swift）
│   ├── wp/RenderThread.java      # EGL + 按需帧循环（省电核心）
│   ├── wp/H3WallpaperService.java# WallpaperService 引擎（可见性/暂停接线）
│   └── ui/MainActivity.java      # 启动/暂停 + 关于 + 更新检查（零依赖，无 androidx）
└── app/src/main/assets/scenes/   # 烘焙产物（gitignore；入库的是加密副本）
```

运行时依赖：**零**（纯 framework API，无 androidx/libgdx）。
minSdk 26 / targetSdk 35；OpenGL ES 2.0。
