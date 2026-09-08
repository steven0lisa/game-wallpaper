# docs/ 索引

本项目开发过程中的全部调研沉淀。阅读顺序建议：formats → rendering → pitfalls →
reference-h3lwp → environment。

| 文档 | 内容 |
|---|---|
| [formats.md](formats.md) | **HoMM3 文件格式逆向笔记**：.lod 归档布局、.def 精灵格式（头部/4 种 RLE/调色板语义/动画区间）、.h3m 地图格式（头部/地形 7 字节组/def 表/对象 payload 全表）、EDG 边界公式、各坑的字节级证据 |
| [rendering.md](rendering.md) | **渲染语义与 VCMI 对照**：图层顺序、地形/河流/道路（含道路半格错位算法）的精确绘制规则、物件锚定与排序、动画时序总表、相机行为、验证方法与结论 |
| [pitfalls.md](pitfalls.md) | **踩坑记录**：8 个实际遇到的问题（DEF 块头长度、品红阴影、负数取模、OOM 防御、MTKView present 等）的定位过程与修复，含被遮挡窗口的验证方法论 |
| [reference-h3lwp.md](reference-h3lwp.md) | **Android 参考实现逆向**：h3lwp（base.apk）的架构、资产离线转换管线、与本项目的差异对照、jadx 反编译陷阱 |
| [environment.md](environment.md) | **环境与资产**：本机素材位置、参考代码库关键文件、工具链、命令速查 |

 wallpapers 验证截图见 [wallpaper_final.png](wallpaper_final.png)（真机桌面层渲染）。
