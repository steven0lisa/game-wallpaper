# Web 版地图查看器（Node + HTML Canvas）

与 macOS 壁纸应用同源同语义的浏览器版：Node 后端解析原版游戏文件生成场景数据与图集，
Canvas 前端渲染**完整地图**（可平移/缩放/切图/看动画），已与 Swift/Metal 渲染做过像素级对比
（同视角平均差 5.7/765，差异来自 Canvas 双线性滤波，内容一致）。

## 运行

```bash
cd web
npm start            # 或 node server/Server.js
# 打开 http://localhost:8765/
```

- 素材与地图默认取自 `~/Library/Application Support/vcmi/`（`Data/H3sprite.lod` + `Maps/`），
  可用环境变量 `H3_DATA_DIR` 指向其他 VCMI 数据目录，`PORT` 改端口。
- 无任何 npm 依赖（纯 Node 内置模块 + 原生 Canvas）。

## 交互

- 拖拽平移、滚轮缩放（以鼠标为中心）、＋/− 按钮、适配窗口
- 地图下拉框切换（158 张）、Surface/Underground 层切换（有地下层的地图）
- 暂停/播放动画（水面/岩浆/河流调色板动画 180ms/步，物件待机动画）

## API

| 路由 | 说明 |
|---|---|
| `GET /` | 查看器页面 |
| `GET /api/maps` | 可用地图列表 |
| `GET /api/scene?map=X.h3m&level=0` | 场景 JSON（地形/河流/道路/物件数组 + 帧表） |
| `GET /atlas/<map>/<levelVer>/atlas-N.png` | 图集页（2048² RGBA PNG；`levelVer` 含内容指纹 `level0-<mtime>-<帧数>-<对象数>`，内容变化 URL 即变化，浏览器永不使用过期图集） |

URL 参数（自动化对比用）：`?map=`、`&level=`、`&cx=0.5&cy=0.5`（视口中心 0..1）、
`&zoom=1`（CSS px/地图像素）、`&t=0`（固定动画时间 ms）、`&win=WxH`
（固定 canvas 视口尺寸，规避 headless Chrome 的 innerHeight 波动；注意此模式下
`--screenshot` 可能抓不到 canvas 内容，验证用 canvas dump）。

缓存策略：图集 URL 含【内容+代码指纹】（`level0-<地图mtime>-<帧数>-<对象数>-<代码hash>`），
响应 `immutable, max-age=31536000`——地图数据或生成代码任一变化，URL 即变，
浏览器永不使用过期图集（详见 docs/pitfalls.md #10）。

## 架构

```
web/
├── server/            纯 Node，零依赖
│   ├── Reader.js      二进制读取器（对应 Swift Reader.swift）
│   ├── LodFile.js     .lod 归档（对应 LodFile.swift）
│   ├── DefFile.js     .def 解码 + 调色板动画（对应 DefFile.swift）
│   ├── H3mFile.js     .h3m 解析（对应 H3mFile.swift）
│   ├── Scene.js       场景构建：图集打包/边界/随机物件/排序（对应 GameMap.swift + AssetLibrary.swift）
│   └── Server.js      HTTP 服务 + 场景缓存（cache/ 下按 map/level 分目录）
└── public/
    ├── index.html     查看器页面
    └── viewer.js      Canvas 渲染器（图层顺序/道路半格错位/动画时序与 Swift 版一致）
```

格式与渲染语义的完整文档见仓库 [docs/](../docs/)（formats.md / rendering.md）。

## 验证（headless Chrome）

```bash
# 固定视口与动画时间截图，与 Swift CLI 渲染同参数对比
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new \
  --window-size=1280,832 --virtual-time-budget=8000 --screenshot=web.png \
  "http://localhost:8765/?map=Emerald%20Isles.h3m&cx=0.5&cy=0.5&zoom=1&t=0"
# 注意 headless 下 innerHeight = 832-87（chrome UI），Swift 侧用 --height 745 匹配；
# 结果：mean diff 5.7/765，>60 差异像素 2.2%（面板遮挡 + 滤波）。
```
