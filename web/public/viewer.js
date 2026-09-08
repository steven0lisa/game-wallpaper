'use strict';
// Canvas 渲染器：与 Swift/Metal 版同语义（图层顺序、道路半格错位、180ms 动画、物件排序由后端预排）。
(() => {
  const TILE = 32;
  const FRAME_MS = 180;

  const canvas = document.getElementById('map');
  const ctx = canvas.getContext('2d');
  const loading = document.getElementById('loading');
  const statEl = document.getElementById('stat');

  let scene = null;          // /api/scene JSON
  let images = [];           // HTMLImageElement per atlas page
  let camera = { x: 0, y: 0, zoom: 1 }; // x,y = 地图左上角（含边界偏移）在地图像素坐标
  let paused = false;
  let startTs = performance.now();
  // ?t=ms 固定动画时间（自动化对比用）；缺省实时。
  let fixedTime = null;
  {
    const q = new URLSearchParams(location.search);
    if (q.has('t')) fixedTime = parseFloat(q.get('t'));
  }

  const borderCache = new Map(); // tileKey -> frame index（公式与后端一致，前端只做查询）
  function borderFrame(x, y, size) {
    if (x < -1 || x > size || y < -1 || y > size) return Math.abs(x) % 4 + 4 * (Math.abs(y) % 4);
    if (x === -1 && y === -1) return 16;
    if (x === size && y === -1) return 17;
    if (x === size && y === size) return 18;
    if (x === -1 && y === size) return 19;
    if (y === -1) return 20 + (x % 4);
    if (x === size) return 24 + (y % 4);
    if (y === size) return 28 + (x % 4);
    if (x === -1) return 32 + (y % 4);
    return Math.abs(x) % 4 + 4 * (Math.abs(y) % 4);
  }

  // ---------- 场景加载 ----------
  async function loadScene(map, level) {
    loading.classList.remove('hidden');
    const res = await fetch(`/api/scene?map=${encodeURIComponent(map)}&level=${level}`);
    if (!res.ok) throw new Error('scene ' + res.status);
    scene = await res.json();
    images = await Promise.all(scene.pages.map((p) => new Promise((ok, err) => {
      const img = new Image();
      img.onload = () => ok(img);
      img.onerror = err;
      img.src = `/atlas/${encodeURIComponent(map)}/level${level}-${scene.atlasVersion}/${p.file}`;
    })));
    fitView();
    loading.classList.add('hidden');
  }

  function fitView() {
    if (!scene) return;
    // URL 参数（?cx=0.5&cy=0.5&zoom=1）优先，供自动化对比用；cx/cy 是地图 0..1 归一化中心。
    const q = new URLSearchParams(location.search);
    if (q.has('cx') || q.has('cy') || q.has('zoom')) {
      camera.zoom = parseFloat(q.get('zoom') || '1');
      const cx = (parseFloat(q.get('cx') || '0.5')) * scene.size * TILE;
      const cy = (parseFloat(q.get('cy') || '0.5')) * scene.size * TILE;
      const vw = fixedWin ? fixedWin.w : window.innerWidth;
      const vh = fixedWin ? fixedWin.h : window.innerHeight;
      camera.x = cx - vw / camera.zoom / 2;
      camera.y = cy - vh / camera.zoom / 2;
      return;
    }
    const margin = TILE * 4; // 露一点边界
    const vw = fixedWin ? fixedWin.w : window.innerWidth;
    const vh = fixedWin ? fixedWin.h : window.innerHeight;
    const world = scene.size * TILE + margin * 2;
    const z = Math.min(vw, vh) / world * 2;
    camera.zoom = z;
    camera.x = -margin + (scene.size * TILE - (vw / z - margin * 2)) / 2;
    camera.y = -margin + (scene.size * TILE - (vh / z - margin * 2)) / 2;
  }

  // ---------- 绘制 ----------
  function drawFrame(key, dx, dy, dw, dh, flipH, flipV, cropY = 0, cropH = -1) {
    const f = scene.frames[key];
    if (!f) return;
    const img = images[f.p];
    if (!img) return;
    let sw = f.w, sh = cropH >= 0 ? cropH : f.h;
    let sx = f.x, sy = f.y + cropY;
    if (flipH) { sx = f.x + (f.w - sw); }
    if (flipV) { sy = f.y + (f.h - (cropY + sh)); }
    const saveCtx = flipH || flipV;
    if (saveCtx) {
      ctx.save();
      ctx.translate(flipH ? dx + dw : dx, flipV ? dy + dh : dy);
      ctx.scale(flipH ? -1 : 1, flipV ? -1 : 1);
      ctx.drawImage(img, sx, sy, sw, sh, 0, 0, dw, dh);
      ctx.restore();
    } else {
      ctx.drawImage(img, sx, sy, sw, sh, dx, dy, dw, dh);
    }
  }

  // Canvas-coordinate crop with VCMI order (MapTileStorage pre-flips the WHOLE frame,
  // then MapRendererRoad crops a plain Rect from the flipped image): mirror the data
  // rect into flipped-canvas space, intersect with the requested rect, and draw the
  // unflipped atlas pixels mirrored inside the destination rect.
  function drawFrameCanvas(key, dx, dy, dw, dh, canvasX, canvasY, canvasW, canvasH, flipH, flipV) {
    const f = scene.frames[key];
    if (!f) return;
    const img = images[f.p];
    if (!img) return;
    // True canvas size from the def frame (margins may be asymmetric; do NOT derive
    // from ox+w — e.g. DIRTRD frame 10 has margin (9,0) with data 14x32 on a 32x32 canvas).
    const fullW = f.fw || (f.ox + f.w), fullH = f.fh || (f.oy + f.h);
    const dxF = flipH ? fullW - f.ox - f.w : f.ox;
    const dyF = flipV ? fullH - f.oy - f.h : f.oy;
    // intersect requested canvas rect with the (flipped) data rect
    const ix0 = Math.max(canvasX, dxF), iy0 = Math.max(canvasY, dyF);
    const ix1 = Math.min(canvasX + canvasW, dxF + f.w), iy1 = Math.min(canvasY + canvasH, dyF + f.h);
    if (ix1 <= ix0 || iy1 <= iy0) return;
    const w = ix1 - ix0, h = iy1 - iy0;
    // data-local range within the flipped frame → unflipped atlas source range
    const lx0 = ix0 - dxF, ly0 = iy0 - dyF;
    const sx = f.x + (flipH ? (f.w - lx0 - w) : lx0);
    const sy = f.y + (flipV ? (f.h - ly0 - h) : ly0);
    const kx = dw / canvasW, ky = dh / canvasH;
    const px = dx + (ix0 - canvasX) * kx, py = dy + (iy0 - canvasY) * ky;
    if (!flipH && !flipV) {
      ctx.drawImage(img, sx, sy, w, h, px, py, w * kx, h * ky);
    } else {
      ctx.save();
      ctx.translate(px + (flipH ? w * kx : 0), py + (flipV ? h * ky : 0));
      ctx.scale(flipH ? -1 : 1, flipV ? -1 : 1);
      ctx.drawImage(img, sx, sy, w, h, 0, 0, w * kx, h * ky);
      ctx.restore();
    }
  }

  function render(now) {
    requestAnimationFrame(render);
    if (!scene || images.length === 0) return;
    const t = fixedTime !== null ? fixedTime : (paused ? 0 : now - startTs);
    const animStep = Math.floor(t / FRAME_MS);
    const z = camera.zoom * dpr; // zoom 以 CSS 像素计；画布是物理像素

    // ?ui=0 隐藏控制面板（自动化截图用）
    const uiHidden = new URLSearchParams(location.search).get('ui') === '0';
    document.querySelectorAll('.panel, .hud, header, nav').forEach((el) => {
      if (uiHidden) el.style.display = 'none';
    });

    ctx.imageSmoothingEnabled = false;
    ctx.fillStyle = '#000';
    ctx.fillRect(0, 0, canvas.width, canvas.height);

    const mapPx = scene.size * TILE;
    // 视口覆盖的 tile 范围（含图外边界）
    const x0 = Math.floor(camera.x / TILE) - 1;
    const x1 = Math.ceil((camera.x + canvas.width / z) / TILE) + 1;
    const y0 = Math.floor(camera.y / TILE) - 1;
    const y1 = Math.ceil((camera.y + canvas.height / z) / TILE) + 1;

    const S = (v) => v * z - camera.x * z; // world→screen helper（仅 x 用；y 同理）
    const toScreenX = (wx) => wx * z - camera.x * z;
    const toScreenY = (wy) => wy * z - camera.y * z;
    const ts = TILE * z;

    // ---- 边界 ----
    const borderDebug = new URLSearchParams(location.search).has('debugborder');
    let debugDrawn = 0;
    for (let y = y0; y <= y1; y++) {
      for (let x = x0; x <= x1; x++) {
        if (x >= 0 && y >= 0 && x < scene.size && y < scene.size) continue;
        const idx = borderFrame(x, y, scene.size);
        drawFrame(`EDG:0:${idx}:0`, toScreenX(x * TILE), toScreenY(y * TILE), ts, ts, false, false);
        if (borderDebug && debugDrawn++ < 40) {
          ctx.fillStyle = '#f0f';
          ctx.fillRect(toScreenX(x * TILE), toScreenY(y * TILE), 3, 3);
          if (ts > 24) {
            ctx.fillStyle = '#fff';
            ctx.font = '10px monospace';
            ctx.fillText(`${x},${y}→${idx}`, toScreenX(x * TILE), toScreenY(y * TILE) + 10);
          }
        }
      }
    }

    // ---- 地形 ----
    // f 为 h3m mirrorConfig 的 2-bit 翻转字段：bit0=左右镜像，bit1=上下镜像
    // （VCMI MapTileStorage 槽位实测语义，非按命名望文生义）
    for (const c of scene.terrain) {
      if (c.x < x0 || c.x > x1 || c.y < y0 || c.y > y1) continue;
      const step = c.steps > 1 ? animStep % c.steps : 0;
      drawFrame(`${c.def}:0:${c.i}:${step}`,
        toScreenX(c.x * TILE), toScreenY(c.y * TILE), ts, ts,
        (c.f & 1) !== 0, (c.f & 2) !== 0);
    }

    // ---- 河流 ----
    for (const c of scene.rivers) {
      if (c.x < x0 || c.x > x1 || c.y < y0 || c.y > y1) continue;
      const step = c.steps > 1 ? animStep % c.steps : 0;
      drawFrame(`${c.def}:0:${c.i}:${step}`,
        toScreenX(c.x * TILE), toScreenY(c.y * TILE), ts, ts,
        (c.f & 1) !== 0, (c.f & 2) !== 0);
    }

    // ---- 道路（VCMI 语义：对【每个可视格】渲染；画布坐标裁剪带 margin 语义） ----
    const roadAt = new Map();
    for (const c of scene.roads) roadAt.set(c.y * scene.size + c.x, c);
    for (let y = Math.max(y0, 0); y <= Math.min(y1, scene.size - 1); y++) {
      for (let x = Math.max(x0, 0); x <= Math.min(x1, scene.size - 1); x++) {
        // 上方格有路 → 其道路画布下半(0,16,32,16)画到本格上半
        if (y > 0) {
          const above = roadAt.get((y - 1) * scene.size + x);
          if (above) {
            drawFrameCanvas(`${above.def}:0:${above.i}:0`,
              toScreenX(x * TILE), toScreenY(y * TILE), ts, ts / 2,
              0, TILE / 2, TILE, TILE / 2,
              (above.f & 1) !== 0, (above.f & 2) !== 0);
          }
        }
        // 本格有路 → 其道路画布上半(0,0,32,16)画到本格下半
        const c = roadAt.get(y * scene.size + x);
        if (c) {
          drawFrameCanvas(`${c.def}:0:${c.i}:0`,
            toScreenX(x * TILE), toScreenY(y * TILE) + ts / 2, ts, ts / 2,
            0, 0, TILE, TILE / 2,
            (c.f & 1) !== 0, (c.f & 2) !== 0);
        }
      }
    }

    // ---- 物件（画布右下角锚定 anchor 格；已按绘制序预排） ----
    for (const o of scene.objects) {
      const canvasLeft = (o.x + 1) * TILE - o.fw;
      const canvasTop = (o.y + 1) * TILE - o.fh;
      if (canvasLeft + o.fw < x0 * TILE || canvasLeft > x1 * TILE) continue;
      if (canvasTop + o.fh < y0 * TILE || canvasTop > y1 * TILE) continue;
      const frameIdx = (animStep + o.phase) % o.frames;
      const f = scene.frames[`${o.def}:0:${frameIdx}:0`];
      if (!f) continue;
      const img = images[f.p];
      if (!img) continue;
      ctx.drawImage(img, f.x, f.y, f.w, f.h,
        toScreenX(canvasLeft + f.ox), toScreenY(canvasTop + f.oy), f.w * z, f.h * z);
    }

    statEl.textContent = `${scene.size}×${scene.size} · ${scene.objects.length} 物件 · zoom ${z.toFixed(2)}`;
  }

  // ---------- 交互 ----------
  let drag = null;
  canvas.addEventListener('mousedown', (e) => {
    drag = { x: e.clientX, y: e.clientY, cx: camera.x, cy: camera.y };
    canvas.classList.add('dragging');
  });
  window.addEventListener('mousemove', (e) => {
    if (!drag) return;
    camera.x = drag.cx - (e.clientX - drag.x) / camera.zoom;
    camera.y = drag.cy - (e.clientY - drag.y) / camera.zoom;
  });
  window.addEventListener('mouseup', () => { drag = null; canvas.classList.remove('dragging'); });
  canvas.addEventListener('wheel', (e) => {
    e.preventDefault();
    const factor = Math.exp(-e.deltaY * 0.0015);
    const nz = Math.min(8, Math.max(0.15, camera.zoom * factor));
    // 以鼠标为中心缩放（client 坐标即 CSS 像素，与 zoom 同尺度）
    const wx = camera.x + e.clientX / camera.zoom, wy = camera.y + e.clientY / camera.zoom;
    camera.zoom = nz;
    camera.x = wx - e.clientX / nz;
    camera.y = wy - e.clientY / nz;
  }, { passive: false });

  document.getElementById('zoomIn').onclick = () => { camera.zoom = Math.min(8, camera.zoom * 1.3); };
  document.getElementById('zoomOut').onclick = () => { camera.zoom = Math.max(0.15, camera.zoom / 1.3); };
  document.getElementById('fit').onclick = fitView;
  document.getElementById('pause').onclick = (e) => {
    paused = !paused;
    e.target.textContent = paused ? '播放' : '暂停';
  };

  // ---------- 初始化 ----------
  const dpr = window.devicePixelRatio || 1;
  // 固定视口模式（&win=WxH）：canvas 尺寸不随窗口变化，供自动化精确对比
  // （headless Chrome 的 innerHeight 受 chrome UI 高度影响且不稳定）。
  const winParam = new URLSearchParams(location.search).get('win');
  const fixedWin = winParam && /^(\d+)x(\d+)$/.test(winParam)
    ? { w: parseInt(winParam.split('x')[0]), h: parseInt(winParam.split('x')[1]) }
    : null;
  function resize() {
    canvas.width = (fixedWin ? fixedWin.w : window.innerWidth) * dpr;
    canvas.height = (fixedWin ? fixedWin.h : window.innerHeight) * dpr;
    if (fixedWin) {
      canvas.style.width = fixedWin.w + 'px';
      canvas.style.height = fixedWin.h + 'px';
    }
  }
  window.addEventListener('resize', () => { if (!fixedWin) resize(); });
  resize();

  const mapSelect = document.getElementById('mapSelect');
  const levelSelect = document.getElementById('levelSelect');

  (async () => {
    const res = await fetch('/api/maps');
    const { maps } = await res.json();
    for (const m of maps) {
      const opt = document.createElement('option');
      opt.value = m; opt.textContent = m.replace(/\.h3m$/i, '');
      mapSelect.appendChild(opt);
    }
    // URL ?map= 参数优先，其次默认选一张大小适中的地图
    const wanted = new URLSearchParams(location.search).get('map');
    const preferred = (wanted && maps.includes(wanted))
      ? wanted
      : (maps.find((m) => /emerald isles\.h3m$/i.test(m)) || maps[0]);
    if (preferred) mapSelect.value = preferred;

    const reload = () => loadScene(mapSelect.value, levelSelect.value).catch((e) => {
      loading.textContent = '加载失败: ' + e.message;
    });
    // 心跳：告知内置服务端页面仍在使用（后端闲置超时会自动退出省内存）
    setInterval(() => fetch('/api/ping').catch(() => {}), 30000);
    // 心跳：告知内置服务端页面仍在使用（后端闲置超时会自动退出省内存）
    setInterval(() => fetch('/api/ping').catch(() => {}), 30000);
    mapSelect.onchange = reload;
    levelSelect.onchange = reload;
    await reload();
    requestAnimationFrame(render);
  })();
})();
