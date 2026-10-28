#!/usr/bin/env node
'use strict';
// Full-scene reference render for a pinned camera position, using the trusted
// web-viewer math, then pixel-compare against the device screenshot.
//
//   node render_reference.js <map.h3m> <cxWorld> <cyWorld> <zoom> <outW> <outH> <out.png>
//
// The device renders with NEAREST magnification at zoom screen-px per world-px,
// so the reference samples world texels at floor((px)/zoom + viewLeft) per
// device pixel — the same mapping GLES NEAREST produces.
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '../..');
const { LodFile } = require(ROOT + '/web/server/engines/heroes3/LodFile');
const { H3mFile } = require(ROOT + '/web/server/engines/heroes3/H3mFile');
const { AssetLibrary, buildScene } = require(ROOT + '/web/server/engines/heroes3/Scene');

const [, , mapFile, cxArg, cyArg, zoomArg, wArg, hArg, outArg] = process.argv;
const CX = parseFloat(cxArg), CY = parseFloat(cyArg), Z = parseFloat(zoomArg);
const W = parseInt(wArg), H = parseInt(hArg);

const lib = new AssetLibrary(new LodFile(process.env.HOME + '/Library/Application Support/vcmi/Data/H3sprite.lod'));
const { scene, atlasPages } = buildScene(new H3mFile(mapFile), lib, 0);

const TILE = 32, size = scene.size, world = size * TILE;
const viewW = W / Z, viewH = H / Z;
const viewLeft = CX - viewW / 2, viewTop = CY - viewH / 2;

const pages = atlasPages.map((b) => b);
function fetchPx(page, x, y) {
  const i = (y * 2048 + x) * 4;
  const d = pages[page];
  return [d[i], d[i + 1], d[i + 2], d[i + 3]];
}

const cnv = Buffer.alloc(W * H * 4); // starts transparent-black
function blit(f, dx, dy, flipH, flipV, scale = 1) {
  if (!Number.isFinite(dx) || !Number.isFinite(dy)) return;
  const img = pages[f.p];
  for (let r = 0; r < f.h * scale; r++) {
    const ty = Math.round(dy + r);
    if (ty < 0 || ty >= H) continue;
    const syv = flipV ? f.y + f.h - 1 - Math.floor(r / scale) : f.y + Math.floor(r / scale);
    for (let c = 0; c < f.w * scale; c++) {
      const tx = Math.round(dx + c);
      if (tx < 0 || tx >= W) continue;
      const sxc = flipH ? f.x + f.w - 1 - Math.floor(c / scale) : f.x + Math.floor(c / scale);
      const si = (syv * 2048 + sxc) * 4;
      if (img[si + 3] === 0) continue;
      const di = (ty * W + tx) * 4;
      cnv[di] = img[si]; cnv[di + 1] = img[si + 1]; cnv[di + 2] = img[si + 2]; cnv[di + 3] = 255;
    }
  }
}
// canvas-crop blit (roads): draw flipped-canvas rect crop, magnified `scale`
function blitCrop(f, sx, sy, sw, sh, px, py, flipH, flipV, scale = 1) {
  if (!Number.isFinite(px) || !Number.isFinite(py)) return;
  const img = pages[f.p];
  for (let r = 0; r < sh * scale; r++) {
    const ty = Math.round(py + r);
    if (ty < 0 || ty >= H) continue;
    const syv = flipV ? sy + sh - 1 - Math.floor(r / scale) : sy + Math.floor(r / scale);
    for (let c = 0; c < sw * scale; c++) {
      const tx = Math.round(px + c);
      if (tx < 0 || tx >= W) continue;
      const sxc = flipH ? sx + sw - 1 - Math.floor(c / scale) : sx + Math.floor(c / scale);
      const si = (syv * 2048 + sxc) * 4;
      if (img[si + 3] === 0) continue;
      const di = (ty * W + tx) * 4;
      cnv[di] = img[si]; cnv[di + 1] = img[si + 1]; cnv[di + 2] = img[si + 2]; cnv[di + 3] = 255;
    }
  }
}
function viewerCrop(f, canvasX, canvasY, canvasW, canvasH, flipH, flipV) {
  const fullW = f.fw || (f.ox + f.w), fullH = f.fh || (f.oy + f.h);
  const dxF = flipH ? fullW - f.ox - f.w : f.ox;
  const dyF = flipV ? fullH - f.oy - f.h : f.oy;
  const ix0 = Math.max(canvasX, dxF), iy0 = Math.max(canvasY, dyF);
  const ix1 = Math.min(canvasX + canvasW, dxF + f.w), iy1 = Math.min(canvasY + canvasH, dyF + f.h);
  if (ix1 <= ix0 || iy1 <= iy0) return null;
  const w = ix1 - ix0, h = iy1 - iy0;
  const lx0 = ix0 - dxF, ly0 = iy0 - dyF;
  const sx = f.x + (flipH ? (f.w - lx0 - w) : lx0);
  const sy = f.y + (flipV ? (f.h - ly0 - h) : ly0);
  return { sx, sy, w, h, ox: ix0 - canvasX, oy: iy0 - canvasY };
}
const S = Z; // screen px per world px
const X = (wx) => (wx - viewLeft) * S;
const Y = (wy) => (wy - viewTop) * S;

// ---- 1. border ----
for (let y = Math.floor(viewTop / TILE) - 1; y <= Math.ceil((viewTop + viewH) / TILE) + 1; y++) {
  for (let x = Math.floor(viewLeft / TILE) - 1; x <= Math.ceil((viewLeft + viewW) / TILE) + 1; x++) {
    if (x >= 0 && y >= 0 && x < size && y < size) continue;
    let bi;
    if (x < -1 || x > size || y < -1 || y > size) bi = Math.abs(x) % 4 + 4 * (Math.abs(y) % 4);
    else if (x === -1 && y === -1) bi = 16;
    else if (x === size && y === -1) bi = 17;
    else if (x === size && y === size) bi = 18;
    else if (x === -1 && y === size) bi = 19;
    else if (y === -1) bi = 20 + (((x % 4) + 4) % 4);
    else if (x === size) bi = 24 + (((y % 4) + 4) % 4);
    else if (y === size) bi = 28 + (((x % 4) + 4) % 4);
    else if (x === -1) bi = 32 + (((y % 4) + 4) % 4);
    else bi = Math.abs(x) % 4 + 4 * (Math.abs(y) % 4);
    const f = scene.frames[`EDG:0:${bi}:0`];
    if (f) blit(f, X(x * TILE), Y(y * TILE), false, false, S);
  }
}
// ---- 2. terrain ----
for (const c of scene.terrain) {
  const f = scene.frames[`${c.def}:0:${c.i}:${c.steps > 1 ? 0 : 0}`];
  if (f) blit(f, X(c.x * TILE), Y(c.y * TILE), (c.f & 1) !== 0, (c.f & 2) !== 0, S);
}
// ---- 3. rivers ----
for (const c of scene.rivers) {
  const f = scene.frames[`${c.def}:0:${c.i}:0`];
  if (f) blit(f, X(c.x * TILE), Y(c.y * TILE), (c.f & 1) !== 0, (c.f & 2) !== 0, S);
}
// ---- 4. roads ----
const roadAt = new Map();
for (const c of scene.roads) roadAt.set(c.y * size + c.x, c);
for (let y = Math.max(Math.floor(viewTop / TILE), 0); y <= Math.min(Math.ceil((viewTop + viewH) / TILE), size - 1); y++) {
  for (let x = Math.max(Math.floor(viewLeft / TILE), 0); x <= Math.min(Math.ceil((viewLeft + viewW) / TILE), size - 1); x++) {
    if (y > 0) {
      const a = roadAt.get((y - 1) * size + x);
      if (a) {
        const f = scene.frames[`${a.def}:0:${a.i}:0`];
        const g = f && viewerCrop(f, 0, 16, 32, 16, (a.f & 1) !== 0, (a.f & 2) !== 0);
        if (g) blitCrop(f, g.sx, g.sy, g.w, g.h, X(x * TILE) + g.ox * S, Y(y * TILE) + g.oy * S, (a.f & 1) !== 0, (a.f & 2) !== 0, S);
      }
    }
    const c = roadAt.get(y * size + x);
    if (c) {
      const f = scene.frames[`${c.def}:0:${c.i}:0`];
      const g = f && viewerCrop(f, 0, 0, 32, 16, (c.f & 1) !== 0, (c.f & 2) !== 0);
      if (g) blitCrop(f, g.sx, g.sy, g.w, g.h, X(x * TILE) + g.ox * S, Y(y * TILE) + 16 * S + g.oy * S, (c.f & 1) !== 0, (c.f & 2) !== 0, S);
    }
  }
}
// ---- 5. objects (anim step 0 for determinism) ----
for (const o of scene.objects) {
  const canvasLeft = (o.x + 1) * TILE - o.fw, canvasTop = (o.y + 1) * TILE - o.fh;
  if (canvasLeft + o.fw < viewLeft - TILE || canvasLeft > viewLeft + viewW + TILE) continue;
  if (canvasTop + o.fh < viewTop - TILE || canvasTop > viewTop + viewH + TILE) continue;
  const f = scene.frames[`${o.def}:0:0:0`];
  if (f) blit(f, X(canvasLeft + f.ox), Y(canvasTop + f.oy), false, false, S);
}

fs.writeFileSync(outArg, require(ROOT + '/web/server/engines/heroes3/Scene').encodePng(W, H, cnv));
console.log(`[ref] ${outArg} written: view=(${viewLeft.toFixed(1)},${viewTop.toFixed(1)}) zoom=${Z}`);
