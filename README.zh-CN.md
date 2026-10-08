<h1 align="center">🎮 GameWallpaper</h1>

<p align="center">
  <strong>让你的桌面变成活的游戏世界。</strong><br>
  经典游戏地图实时渲染成 macOS 动态壁纸。<br>
  <a href="README.md">English</a> | 中文
</p>

<p align="center">
  <img src="docs/wallpaper_final.png" alt="GameWallpaper 真机桌面效果" width="720">
</p>

GameWallpaper 目前内置 **英雄无敌 III** 引擎：任选一张 `.h3m` 地图，它就在你的
桌面图标后面活起来——水面岩浆闪烁、物件待机动画、镜头缓缓巡视战场，与游戏内的
冒险地图画面完全一致。更多游戏引擎在路线图上（见[路线图](#-路线图)）。

## ✨ 特性

- **桌面活起来了，但绝不碍事** —— 壁纸位于桌面图标**之下**、不拦截任何鼠标点击，
  桌面照常使用；所有 Space、所有显示器都可见。
- **设置一次，不用再管** —— 每 15 分钟自动换一张地图，镜头每隔几分钟自动跳点；
  也可以在菜单栏随时暂停 / 切换 / 指定地图。
- **内置 3 张 XL 大地图** —— 装好就能看；随时加入自己的地图（选个文件夹即可）。
- **对电池友好** —— 显示器休眠即暂停渲染；电池供电时完全停止（0 fps）；
  相机静止时只有 5 fps，移动时才恢复。
- **随心定制** —— 缩放 1×–4×、夜间把画面压暗 0–60%、一键暂停；
  界面中英双语，跟随系统语言。
- **内置地图查看器** —— 一键在浏览器里查看完整地图（平移/缩放/切图/看动画）。

## 🚀 快速开始

**1. 下载**：从 [Releases 页面](https://github.com/steven0lisa/game-wallpaper/releases/latest)
下载最新的 `GameWallpaper.dmg`，打开后把 **GameWallpaper** 拖入**应用程序**。

**2. 指定游戏资源**（仅需一次）。启动后菜单栏出现 🎮 图标；首次运行点
**Choose Data Folder…**，选择包含 `Data/H3sprite.lod` 的文件夹。如果你装了
[VCMI](https://vcmi.eu)，直接选 `~/Library/Application Support/vcmi` 即可。

> 渲染需要原版英雄无敌3 的精灵文件（`H3sprite.lod`，约 65 MB），版权归
> Ubisoft / New World Computing 所有，因此**安装包里不含**——需要你已有的游戏
> 拷贝。安装免费的 [VCMI](https://vcmi.eu) 是把文件备齐的最简单方式。
> **地图是可选的**：不指定地图目录时，内置的 3 张 XL 大地图会自动开始播放。

**3. 尽情欣赏。** 桌面已变成活的战场地图。通过 🎮 菜单切换地图、调节缩放/亮度、
暂停，或打开地图查看器。

<details>
<summary><strong>系统要求与常见问题</strong></summary>

- macOS 13 及以上，Apple Silicon / Intel 均可。
- **“无法打开 GameWallpaper”（Gatekeeper 拦截）**：构建未签名。右键 App →
  **打开**，或执行 `xattr -d com.apple.quarantine /Applications/GameWallpaper.app`。
- **菜单栏图标在但画面不动**：没找到游戏资源——用 **Choose Data Folder…**
  选择包含 `Data/H3sprite.lod` 的目录。
- **晚上太晃眼**：菜单 → Brightness → 最多压暗 60%。
- **换地图**：**Choose Maps Folder…** 选一个 `.h3m` 文件夹，或 **Open Map…**（⌘O）
  打开单个地图。
- 退出：🎮 菜单 → Quit（⌘Q）。

</details>

## 💬 反馈

发现问题 bug，或希望接入某个游戏引擎？请到
[Issues 区](https://github.com/steven0lisa/game-wallpaper/issues) 反馈——也可以用
App 内 About 窗口的 **Feedback** 按钮。附上截图会大大方便定位。

## 🗺 路线图

- [x] 英雄无敌 III 引擎（macOS + Web 查看器）
- [ ] 更多引擎——如仙剑、星际争霸——基于插件式引擎接口
      （[架构指南](docs/zh-CN/architecture.md)）
- [ ] 地下层支持、英雄/旗帜的玩家色染色

## 🛠 开发者

壁纸运行时与引擎解耦（SwiftPM：`WallpaperCore` 壳 + 可插拔引擎 target）；
push `v<major>.<minor>` tag 即自动构建发布 Release。源码构建方法与渲染语义见文档：

| 文档 | 内容 |
|---|---|
| [docs/zh-CN/architecture.md](docs/zh-CN/architecture.md) | 引擎协议、如何接入新游戏 |
| [docs/zh-CN/environment.md](docs/zh-CN/environment.md) | 资产布局、工具链、命令速查 |
| [docs/zh-CN/rendering.md](docs/zh-CN/rendering.md) | 渲染语义与 VCMI 对照（一致性基线） |
| [docs/zh-CN/formats.md](docs/zh-CN/formats.md) | HoMM3 文件格式逆向笔记 |
| [docs/zh-CN/pitfalls.md](docs/zh-CN/pitfalls.md) | 29 条实战踩坑记录 |
| [web/README.zh-CN.md](web/README.zh-CN.md) | 浏览器版地图查看器 |

English docs: [docs/](docs/)（每篇文档顶部可互相跳转）。

## 🙏 致谢

- [VCMI](https://github.com/vcmi/vcmi) —— 本项目对齐的渲染语义与文件格式权威参考
- [IlyaPomaskin/h3lwp](https://github.com/IlyaPomaskin/h3lwp) —— 启发本项目解析器
  与图层行为的 Android 动态壁纸

## 📄 许可

代码以 [MIT License](LICENSE) 发布。游戏资源**不包含**在本仓库及其发布物中，
版权归各自权利人所有。
