# 开发过程踩坑记录

按时间顺序记录本项目实现过程中遇到的问题、定位方法与结论。
每条都已修复并验证；写下来避免重蹈。

---

## 1. DEF 块头 unknown 字段长度（最隐蔽）

**现象**：所有物件渲染正确，但地形帧整体"错一格"——(x,y) 格画出了邻格的内容，
部分格子颜色错乱。
**定位**：十六进制 dump GRASTL.DEF，手工算偏移表的两个候选位置：
unknown=8 时 79 个帧偏移全部有效；unknown=12 时偏移表整体左移一帧。
**结论**：块头 unknown 是 **8 字节**（VCMI 源码注释 "8 unknown bytes - skipping" 为准；
jadx 反编译的 Def.java 数据类声明误导）。

## 2. 阴影索引的品红占位色

**现象**：物件下方/周围出现品红（255,0,255 系）斑块，编辑器里同位置是深色阴影。
**定位**：提取品红像素颜色 → 查 def 调色板 → 1/4/6/7 号索引正是品红占位色。
**结论**：渲染时强制映射为半透明黑（VCMI ScalableImage 语义），见 formats.md §2.5。

## 3. 地形 def 名与 lod 条目名不匹配

**现象**：物件全对，地形全黑（terrainHit=0/1296）。
**定位**：日志显示 missingDefs 非空；发现渲染键是裸名 "GRASTL"，lod 条目是 "GRASTL.DEF"。
**结论**：AssetLibrary 查找时给不含 `.` 的键补 `.DEF` 后缀（大小写不敏感）。

## 4. 边界帧索引的负数取模与判断顺序

**现象**：地图四角金框断裂、(-2,-1) 等格子画错。
**定位**：对照 VCMI getIndexForTile 源码：先判"图外远处"，再判边缘；且 Swift `%`
对负数保留符号（-2 % 4 = -2），帧号变负。
**结论**：调整判断顺序 + `abs()`，见 formats.md §5。

## 5. 损坏 def 导致的 OOM / 死循环

**现象**：`--snapshot` 偶发 `failed to allocate 1.5e16 bytes`（OOM）或 99% CPU 卡死。
**定位**：lldb + sample 采样：DefFile.init 在 offsets 循环里；根因是上游解压失败
产生垃圾数据 → framesCount 解析成天文数字。
**结论**：三层防御——groupsCount ≤ 64、framesCount ≤ 100k、帧尺寸 1..4096；
legacy 探测的"逐帧复制整个字节流"改为 O(1) 直接索引读（原来是 O(N²) 卡死根源）。

## 6. MTKView 不自动 present（macOS 桌面层窗口）

**现象**：GUI 模式窗口全黑，但渲染循环正常（draw 计数增长、CPU 占用正常）。
**定位**：红屏测试（clearColor 改纯红）仍黑 → 排除绘制内容问题，锁定 drawable
未提交到窗口表面。
**结论**：`draw(in:)` 返回前显式 `view.currentDrawable?.present()`。
这是 MTKView 在特定配置（无 CAMetalLayer delegate 干预 + 桌面层窗口）下的行为，
加显式 present 后一切正常。
**注意**：`screencapture -l<winid>` 对被遮挡的 Metal 窗口拿不到内容（黑图），
需用 Quartz `CGWindowListCreateImage` 离屏合成，或临时把窗口提到 floating 层
（本仓库保留 `--level-floating` 启动参数作验证辅助）。

## 7. 被遮挡窗口的截屏验证方法论

桌面壁纸天然被所有应用窗口遮挡，验证链路：
1. **无头 CLI 渲染**（`--snapshot`）验证渲染正确性——与编辑器画布逐格比对；
2. **Quartz 离屏合成**（`CGWindowListCreateImage` + `kCGWindowListOptionIncludingWindow`）
   验证真实窗口位图内容；
3. **半透明菜单栏截屏**：菜单栏区域是系统强制半透明的，截图里能透出壁纸，
   作为"壁纸真实在桌面层显示"的最终证据；
4. `--level-floating` 临时提层直接目视（验证后关闭）。

## 8. 浏览器缓存的旧图集导致"地图边缘异常"（Web 版）

**现象**：用户反馈 Web 版地图边缘（图外区域）出现深绿植被+金色斑块纹理，L 形金框外不是暗岩。
**定位**：无痕模式（禁用缓存）渲染同一视角完全正确，与 Swift 版像素级一致（diff 4.45）；
且 EDG 0-15 帧经解码验证是纯岩石灰黑系（无绿色像素、无高饱和黄），不可能产生用户看到的纹理。
根因是开发过程中图集生成逻辑变更后，浏览器仍持有旧版 atlas PNG 的缓存
（当时设置了 max-age=3600）。
**修复**：图集 URL 带内容指纹 `/atlas/<map>/level<L>-<mtime>-<帧数>-<对象数>/atlas-N.png`，
缓存头改为 `immutable, max-age=31536000`——内容变化时 URL 必然变化，永不使用过期图集；
服务器端按指纹分目录，旧目录仅占磁盘不影响正确性。
**教训**：对"由构建流程生成的静态资产"必须用内容寻址（content-addressed）URL，
开发期尤其如此；否则任何生成端修复都会被浏览器缓存"回滚"。

## 9. 道路"接驳处断裂"——遍历对象搞错（道路下半丢失）

**现象**：道路在向下终止的格子处少画半格，视觉上路断在格边；连接处不连贯。
**定位**：与 VCMI `MapRendererRoad::renderTile` 逐行对照发现遍历语义差异：
VCMI 对视口内**每个格子**渲染（本格无路但上格有路 → 仍画上格道路图下半），
我的实现只遍历有路的格子 → "上格有路、本格无路"的格子漏画。
Viking 地图 601 格受影响，158 张地图共 20602 格。
**修复**：道路层改为视口 tile 双循环（Swift `Renderer.swift` / JS `viewer.js` 同步修改）。
**教训**：移植渲染循环时，"渲染哪些 tile"与"绘制什么"同样重要；
VCMI 的 per-tile renderTile 模型意味着每个子渲染器都要对全 tile 生效，
只在数据存在时跳过绘制，而不是用数据存在性驱动遍历。

## 10. 图集 immutable 缓存"中毒"（Web，最隐蔽）

**现象**：修复图集生成逻辑后，开发者验证通过（无痕/清缓存），但用户浏览器里
"依然没修复"——地图一半区域渲染成错误内容（地形错位成暗色）。
**根因链**：图集 URL 只含 `地图mtime-帧数-对象数`。生成代码变更后，同一地图的
帧数/对象数可能恰好不变 → URL 不变 → 而图集响应头是
`Cache-Control: public, max-age=31536000, immutable` → 浏览器【永久】复用旧图集。
场景 JSON（无缓存头）是新的、图集是旧的 → 帧坐标指向旧图集的错误内容。
**修复**：atlasVersion 追加【服务端代码指纹】（Scene/DefFile/H3m/Lod/Reader/Server
的 mtime+size 的 md5 前 8 位）——代码一变 URL 必变，缓存自动失效。
**教训**：内容寻址 URL 的"内容"必须涵盖**所有影响产物的输入**（数据 + 代码），
否则 immutable 缓存会把修复"回滚"。验证时务必用无痕窗口 + 服务器端内容抽查双保险。

## 11. headless Chrome 截图抓不到固定尺寸 canvas（验证工具坑）

**现象**：给 canvas 设置固定 CSS 尺寸（`&win=WxH` 自动化对比模式）后，
`--screenshot` 截图中 canvas 区域显示暗色残影，但页面实际渲染正确。
**定位**：在页面里 `canvas.toDataURL()` POST 回服务器（canvas dump）对比——
canvas 内容完全正确（diff 5.25 vs Swift），证明是截图管线问题而非渲染问题
（virtual-time 下固定尺寸 canvas 的呈现时机与截图不同步）。
**教训**：headless 截图与页面真实渲染可能不一致；自动化验证 canvas 内容
优先用 `toDataURL` 回传，截图只作为辅助；固定视口模式仅用于精确对齐计算。

## 12. 道路骑在格线上——帧 margin 的画布语义

**现象**：道路整体错位半格、贴图被拉伸，路面骑在两行格子中间，与地形网格对不齐。
**定位**：dump DIRTRD.DEF 帧结构发现画布 32×32 但数据带 margin（横向路 32×14@margin(0,9)、
纵向路 14×32@margin(9,0)）。我实现半格裁剪时把 VCMI 的 `Rect(0,16,32,16)` 当成了
**数据坐标**（裁数据下半 32×7 + 拉伸），而它是**画布坐标**（画布下半与数据的交集）。
**修复**：新增画布裁剪（求交）——画布矩形先按翻转位镜像，与数据矩形 [ox,oy,w,h] 求交，
交区 UV 直接取图集，屏幕位置 = 格原点 + 裁剪区原点 + 交区在裁剪区内的偏移。
Swift `Renderer.canvasCrop` / JS `viewer.drawFrameCanvas`，双端验证道路行分布偏移 0px。
**教训**：def 帧的 fullWidth/fullHeight 与数据 width/height 不等时（道路全部如此），
任何裁剪/定位都必须在画布坐标系里做；VCMI 所有 `Rect` 参数都是画布坐标。

## 13. h3m 解析的字节对账方法

h3m 格式段多且版本相关，解析走偏的定位手段是**检查点字节偏移**：
在 header/terrain/defs/objects 各段结束处记录 `reader.pos`，与文件总长比对。
- terrain 段结束位置 = 1296 格 × 7 字节（36×36 图），可直接验算；
- objects 段结束位置 ≈ 文件尾（后面只剩 events 等小段）。
任何一段算出来的"下一字节"与实际内容对不上（例如 defs 段开头不是合理的 defCount），
即可定位到具体对象类型的 payload 跳读错误。本项目曾用此法发现 victory condition
case 3 少跳了 1 字节（应为 5 字节：3 坐标 + 2 参数）。

## 14. extTileFlags 翻转位：bit0=左右镜像（VCMI 命名按"轴"不按"方向"）

**现象**：海岸线出现方块状错接（水格过渡帧方向错），道路拐角/斜向段断裂成悬空短条。
用户观察"贴图旋转 90°/180° 就能匹配"——实际是镜像用反：对 45° 斜向帧，H/V 镜像
用反的效果近似"转了 90°"。

**定位**：VCMI `MapTileStorage::load`（MapRenderer.cpp）把同一 def 加载 4 份槽位：
槽 1 调 `verticalFlip()`、槽 2 调 `horizontalFlip()`、槽 3 双翻转；渲染时
`rotationIndex = extTileFlags % 4`（terrain）/`>>2`（river）/`>>4`（road）直接当槽位号。
望文生义会读成"bit0=上下翻转"，但 VCMI 的 `verticalFlip()` 是**绕竖直轴翻转=左右镜像**。
实证方法：取一格（如 Viking 图 tile(94,28) dir=5 flags=0x2），穷举 16 帧 × 4 翻转
与 vcmieditor 同格像素比对，唯一 0.0 误差组合 = frame5 + 上下镜像 ⇒ bit1=上下镜像，
bit0=左右镜像（与地形/河流/道路三层一致，均经编辑器像素级验证归零）。

**修复**：`flipH = bits & 1`、`flipV = bits & 2`（三层相同）。

**教训**：开源代码的函数名是"抄作业"的第一手语义，但命名可能按轴/按方向各有理解，
涉及几何方向时务必用真实地图格做像素级穷举对账，一次定案。

## 15. 带翻转的子矩形裁剪必须"先翻转、后裁剪"

**现象**：翻转位语义改对后，直路完全正常，但斜向/拐角路仍断裂成两截错位短条。

**定位**：VCMI 的顺序是——`MapTileStorage::load` 先把**整张帧镜像**进 4 个槽位，
`MapRendererRoad::renderTile` 再对**已翻转的图**做普通 `Rect(0,16,32,16)` 裁剪。
我们的 `canvasCrop`/`drawFrameCanvas` 却是"镜像画布矩形 + 采样未翻转数据"：
镜像矩形后与数据求交，采样坐标却没跟着镜像，也没做像素镜像。直路条带左右对称
（14px 居中）侥幸不错位；斜向条带（22×22@(10,10)）镜像后换象限，立刻断裂。

**修复**：按 VCMI 顺序重写——把**数据矩形**镜像进翻转画布空间求交（交区坐标即屏幕
坐标），采样未翻转图集数据后：Metal 用 shader flags 在 quad 内镜像 UV（canvasCrop
返回 flags，替换原来写死的 0）；Canvas2D 用 `translate+scale(-1,1)` 包住 drawImage。
修完与编辑器同格 0.0 误差。

**教训**：`先翻转后裁剪`与`先裁剪后翻转`对**整帧**等价，对**子矩形**不等价
（矩形镜像后与数据的相对位置变了）。抄 VCMI 作业要抄完整条流水线，不能只抄裁剪公式。

## 16. 屏幕级验证的三种测量污染（差分/模板匹配）

给动态壁纸做"画面是否缓慢移动"的自动验证时，接连踩了三种坑：
1. **`screencapture` 截的是整个屏幕**——前台的 IDE/编辑器窗口一起进画面，测的位移
   其实是前台窗口（静态 UI → 相位相关恒 0.00 且 response 0.999，极具迷惑性）。
   必须用 `CGWindowListCreateImage` 按窗口 ID 截目标窗口本身。
2. **像素画的模板匹配伪峰**——草地纹理周期重复、地图上大量同贴图城堡，400px 模板
   能在 100~200px 偏移处拿到 score≈1.0 的"刚性位移"假象，且各次测量互相矛盾。
   锚点必须选**孤立且独特**的结构（如雪山城堡群、竞技场），并要求多点一致。
3. **对齐方向/符号反复出错**：np.roll 的 shift 语义与"内容位移"方向相反，先小图
   画箭头推一遍再用。最终闭环：日志输出 viewLeft/viewTop，截图前后各读一行，
   按日志增量 × effZoom 对齐两帧，残差应只剩水/物件动画。

## 17. Metal 单实例缓冲被下一帧覆盖 → 偶发一帧错误贴图（闪烁）

**现象**：壁纸偶发小面积闪烁/白杠（截到一次：路面上缘凭空一条白色横杠），闪一下即恢复，
位置不定。用户描述"像刷新过程里的贴图错误"。

**定位**：`Renderer` 只有一个 12.8MB 的 `instanceBuffer`（storageModeShared）+
`uniformBuffer`，每帧 CPU `memcpy` 覆盖，随后 `draw(wait:false)` 提交**不等 GPU**。
整幅地图几万实例 + 过度绘制时，GPU 执行一帧可能超过 16.7ms——下一帧的 memcpy 会在
GPU 仍在读缓冲时覆盖它，GPU 读到**新旧混合的撕裂数据**：某个 quad 的位置/UV 是旧帧
前半 + 新帧后半，于是把图集里别处的白色纹素画到了路面上，持续一帧。

**修复**：Apple 标准的三缓冲环 + 信号量背压——`instanceBuffers/uniformBuffers` 各 3 份，
`DispatchSemaphore(value:3)` 在 draw() 开头 wait、命令缓冲 `addCompletedHandler` 里
signal；slot 只有在其命令缓冲完成后才会被复用。构建（buildFrame）只填 CPU 侧数组与
pendingUniforms，memcpy 移到 draw() 选定 slot 之后。同视角双次渲染 diff 应为 0
（差异仅来自随机物件具象化的 randomElement，见 GameMap）。

**教训**：`waitUntilCompleted` 缺省（异步提交）时，CPU 侧每帧覆写的 shared buffer
都必须按"帧在飞"分组复用；这类竞态的症状是**低概率单帧伪影**，截图/录屏都难抓，
要靠审查"谁在 GPU 还没读完时就写"来定位。

## 18. 线性采样必须配预乘 alpha，否则所有精灵出现淡描边

**现象**：为平滑滚动启用 GPU 线性采样后，怪物/建筑/道路周围出现一圈淡暗描边
（正式游戏没有）。用户截图可复现。

**定位**：图集按**直通 alpha（straight alpha）**存储（RGB 不预乘），线性采样在
精灵不透明边缘与透明邻居（RGB=0, A=0）之间插值，得到 RGB 减半、A 减半的过渡像素；
再经 sourceAlpha 混合后，过渡像素比两侧都暗 → 每个精灵边缘一圈暗晕。
缩放 ≥2 时每个精灵边缘必然落在像素中间，描边恒定可见。

**修复**：图集写入时预乘（RGB×A/255），混合模式改为
`sourceRGB = ONE, destRGB = ONE_MINUS_SRC_ALPHA`（预乘合成标准式）。
黑色阴影像素（A=64/128, RGB=0）预乘后不变，视觉无回归。
Web 导出的 PNG 需要反预乘回直通 alpha（本项目图集阴影全黑，视觉无差）。

**教训**：启用纹理线性过滤的那一刻就要决定 alpha 预乘策略；"混色出暗边"是
非预乘 + 线性过滤的标志性伪影。

## 19. 远程验证 GUI 的三个坑（SSH + 虚拟会话）

1. **SSH 启动的 GUI 进程在 Services 会话**，桌面上不可见。要让它出现在用户桌面，
   用 `schtasks /create /it`（交互式令牌）+ `schtasks /run` 启动。
2. **session 0/远程上下文里 FindWindow/EnumWindows 看不到其他会话的窗口**，
   截图 API（CopyFromScreen）在断开/锁屏的会话里只能截到全黑。
   验证画面内容用应用**自带的能力**：触发文件（shot.flag）→ 进程自己导出帧缓冲。
3. **模板匹配在重复像素画上不可信**：草地纹理周期重复、同贴图城堡遍地都是，
   400px 模板能在 100~200px 错位处拿到 0.99+ 的假匹配。对齐要用孤立地标
   （独特建筑）多点一致才可信，且先排除"两次渲染随机物件不同"的干扰
   （RANDOM_* 物件每次启动随机具象化）。

## 20. RDP 远端/无人值守会话下 Progman 不存在

**现象**：在 `dev-box` 这台无人值守 RDP 会话里，调用
`FindWindowW(L"Progman", nullptr)` 总是返回 0；0x052C 之后也找不到 WorkerW；
`System.Windows.Forms.SystemInformation::UserInteractive` 报 `False`。
**后果**：WorkerW 注入失败，壁纸窗口只能走后备全屏路径，桌面会"开一个全屏窗口覆盖桌面"
—— 不是软件 bug，是该远程环境下无桌面层（Explorer 也没跑）。

**解决**：
- 主路径（标准）见源码 `wallpaper_win.cpp::attachToWorkerW`：豆包推荐模板，标准桌面会话下生效
- 后备路径：INI `[wallpaper] allowFallback=1` 时退化为最底层全屏窗口（HWND_BOTTOM + SWP_NOACTIVATE），
  不抢焦点、不进 Alt-Tab；后台每 5s 重试 WorkerW，Explorer 启动后自动迁移到桌面层
- 真机（用户日常桌面）验证：双屏 + Explorer 运行时，壁纸正确挂在 WorkerW 下

**教训**：在远端/无人值守机器上做 GUI 软件的功能验证，WorkerW 注入几乎不可能成功；
要"看到地图"必须用后备路径或直接验证渲染缓冲本身（如 shot.flag → bmp）。

## 21. h3m 头解析：size 字段偏移不是 0

**现象**：用 `struct.unpack("<iiI", raw)` 读 h3m 头（version, ?, size）时，得到的 size
是一两百万的荒唐值（远超过 h3m 实际地图边长 36~144），导致分组/排序全部错乱。

**定位**：对照 Swift `H3mFile.swift` —— 头是 i32 version, **i8** hasPlayers, i32 size, i8 hasUnder。
Python 用 `struct.unpack_from("<i", raw, 5)` 才对（i32 从偏移 5 开始读，越过 hasPlayers 字节）。

## 22. About 对话框青色网格——色键未透明 + 误把 box[8] 当内部背景（双根因）

**现象**：About 窗口对话框内部被青色 (0,255,255) 网格铺满；而原版 heroes3
对话框应是棕色纸底 + 蓝色雕花边框。用户截图直出。

**定位**（逐帧统计 + 对照 VCMI 源码三个文件）：
- 逐帧统计 DIALGBOX 11 帧：box[0..3] 青色占 59%、box[8] 占 58%、box[4..7] 为 0%
  → 青色集中在"边框外侧与框内"两处。
- `CBitmapHandler`/`CDefFile`：**青色 = DEF 调色板 index 0 的颜色**（DIALGBOX 的
  palette[0] 就是纯青），即色键；VCMI 以 `EImageBlitMode::COLORKEY` 加载使 idx0
  全透明。导出脚本的 `colorKey` 分支压根没实现（只有 shadows 语义），色键像素
  被画成不透明青色——这是"为什么青色可见"。
- `CMessage::drawBorder`（client/windows/CMessage.cpp）：**只画 box[0..7]**（四角
  box[0..3] + 四边 box[4/5] 左右 14×64、box[6/7] 上下 64×15），box[8..10] 不参与；
  `CInfoWindow` 的内部背景是 `CFilledTexture("DiBoxBck")`（InfoWindows.cpp），
  `showAll` 平铺 **DIBOXBCK.PCX** 棕纸纹理。把 box[8] 当"9-slice 内部"平铺是
  第一个想当然——box[8] 内部 58% 是色键，平铺必然出网格——这是"为什么铺满内部"。

**修复**：`frame_to_rgba` 补 `colorKey` 分支（idx0 → alpha 0）；新增 H3 式 PCX
解码（formats.md §2.8）从 H3bitmap.lod 导出 `background.png`；`Heroes3BorderView`
改为 background 平铺 + 只画 box[0..7]。截图复验棕底蓝框正常。

**教训**：
1. **占位色有两种**——品红系 (255,0,255) 是 index 1/4/6/7 阴影位，青色 (0,255,255)
   是 index 0 色键；UI 精灵（COLORKEY 模式）与物件精灵（WITH_SHADOW 模式）的
   透明语义不同，导出工具必须按精灵类型分支。
2. "9-slice"是想象，VCMI 的 `drawBorder` 用"4 角 + 4 边"拼框、内部另铺一张
   纹理；抄 UI 布局前先读渲染函数本体，别按通用图形学套路套。
3. 大面积"诡异纯色"出现时，第一时间反查调色板索引分布（哪个 index、占比多少），
   比"改代码试试"快得多。

## 23. PNG 导出黑图——每扫描行缺 filter byte（write_png）

**现象**：导出的 about PNG 被 PIL 报 `OSError: unrecognized data stream contents`
，NSImage 解码失败，About 窗口整体黑/空白。
**定位**：手写 PNG 的 IDAT 直接放了 RGBA 原始数据。PNG 规范要求**每个扫描行
前有一个 filter-type 字节**（0x00=None 即可），缺失即整流非法。
**修复**：逐行 `append(0)` 后再拼该行 RGBA；`zlib.compress(..., 9)`。
**教训**：手写 PNG 编码器时 filter byte 是最易漏的一环；漏掉的症状是
"解码器直接拒绝"而不是"图错"，用 PIL `Image.open(...).load()` 做导出自检
（顺带统计非透明像素数）能在打包前拦住。

## 24. NSWindow 内容约束崩溃——子视图未 addSubview 就进 NSLayoutConstraint

**现象**：`--about` 启动即崩、窗口不出现；直接跑二进制见
`NSGenericException: unable to satisfy constraints ... because they have no
common ancestor`。
**定位**：`logoView` 只被引用了约束（`logoView.centerXAnchor == centerXAnchor`），
漏了 `addSubview(logoView)`——无公共祖先的约束对在 activate 时抛异常。
**修复**：约束激活前补 `addSubview`（labels 循环里本来就有，唯独 logo 漏了）。
**教训**：AppKit 没有像 SwiftUI 那样的"声明即挂载"；NSView 层级是命令式累积的，
新控件先 addSubview 再上约束。LSUIElement 应用的崩溃日志不进 Console.app 的
常规位置，直接命令行跑二进制看 stderr 最快。
