#!/usr/bin/env node
'use strict';
// Road-rendering equivalence test:
//   A) reference = scene JSON drawn with the web viewer's drawFrameCanvas math
//   B) candidate = scenes.bin (baked data) drawn with the Android Renderer's math
// Both render the roads layer only, 1 world px = 1 px, then pixel-diff.
// A diff proves a bake-data or port-math bug; no diff clears algorithm+data.
const fs = require('fs');
const path = require('path');
const zlib = require('zlib');

const ROOT = path.resolve(__dirname, '../..');
const { LodFile } = require(ROOT + '/web/server/engines/heroes3/LodFile');
const { H3mFile } = require(ROOT + '/web/server/engines/heroes3/H3mFile');
const { AssetLibrary, buildScene, encodePng } = require(ROOT + '/web/server/engines/heroes3/Scene');

const MAP = process.argv[2] || 'Back For Revenge';
const BIN = process.argv[3] || path.join(ROOT, 'android/app/src/main/assets/scenes/scenes.bin');
const REGION = 48; // tiles per side of the compared patch
const OUTA = '/tmp/roads_ref.png';
let traceBox = null;
const OUTB = '/tmp/roads_cand.png';

// ---------------- frame lookup helpers ----------------
// pixel fetch from an atlas page buffer (RGBA, 2048²)
function fetchPage(buffers, page) {
  return buffers[page];
}

// draw a flipped/cropped rect with NEAREST semantics into rgba canvas
function blit(cnv, W, img, sx, sy, sw, sh, dx, dy, dw, dh, flipH, flipV) {
  for (let r = 0; r < dh; r++) {
    const ty = dy + r;
    if (ty < 0 || ty >= cnv.height) continue;
    const syv = flipV ? (sy + sh - 1 - Math.floor(r * sh / dh)) : (sy + Math.floor(r * sh / dh));
    for (let c = 0; c < dw; c++) {
      const tx = dx + c;
      if (tx < 0 || tx >= W) continue;
      const sxc = flipH ? (sx + sw - 1 - Math.floor(c * sw / dw)) : (sx + Math.floor(c * sw / dw));
      const si = (syv * 2048 + sxc) * 4;
      if (img[si + 3] === 0) continue; // transparent
      const di = (ty * W + tx) * 4;
      cnv.data[di] = img[si];
      cnv.data[di + 1] = img[si + 1];
      cnv.data[di + 2] = img[si + 2];
      cnv.data[di + 3] = 255;
    }
  }
}

// viewer.js drawFrameCanvas → {sx,sy,w,h,px,py,pw,ph}
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

// ---------------- load trusted scene + atlas ----------------
const lib = new AssetLibrary(new LodFile(process.env.HOME + '/Library/Application Support/vcmi/Data/H3sprite.lod'));
const { scene, atlasPages } = buildScene(new H3mFile(`/tmp/h3wallpaper-maps/${MAP}.h3m`), lib, 0);
console.log(`[A] trusted scene: roads=${scene.roads.length} frames=${Object.keys(scene.frames).length}`);

// ---------------- parse scenes.bin (mirror of Java BinReader flow) ----------------
class R {
  constructor(buf) { this.b = buf; this.p = 0; }
  u8() { return this.b[this.p++]; }
  u16() { const v = this.b.readUInt16LE(this.p); this.p += 2; return v; }
  i16() { const v = this.b.readInt16LE(this.p); this.p += 2; return v; }
  u32() { const v = this.b.readUInt32LE(this.p); this.p += 4; return v; }
  str() { const n = this.u16(); const s = this.b.toString('utf8', this.p, this.p + n); this.p += n; return s; }
}
const raw = fs.readFileSync(BIN);
const r = new R(raw);
if (r.b.toString('latin1', 0, 4) !== 'H3B1') throw new Error('bad bin magic');
r.p = 4;
r.u16(); // version
const mapCount = r.u16(), pageSize = r.u16();
r.u16();
const frameCount = r.u32();
const frames = [];
for (let i = 0; i < frameCount; i++) {
  frames.push({ page: r.u8(), x: r.u16(), y: r.u16(), w: r.u16(), h: r.u16(), ox: r.i16(), oy: r.i16(), fw: r.u16(), fh: r.u16() });
}
const setCount = r.u32();
const sets = [];
for (let i = 0; i < setCount; i++) { const n = r.u16(); const ids = []; for (let j = 0; j < n; j++) ids.push(r.u16()); sets.push(ids); }
let target = null;
for (let m = 0; m < mapCount; m++) {
  const name = r.str(); const size = r.u16(); const pageBase = r.u16(); const pageCount = r.u16(); const borderSet = r.u16();
  const layers = {};
  for (const k of ['terrain', 'rivers', 'roads']) {
    const n = r.u32(); const cells = [];
    for (let i = 0; i < n; i++) {
      const x = r.u16(), y = r.u16(), ref = r.u16(), flip = r.u8();
      cells.push({ x, y, ref, flip });
    }
    layers[k] = cells;
  }
  const on = r.u32(); const objects = [];
  for (let i = 0; i < on; i++) {
    objects.push({ x: r.u16(), y: r.u16(), sid: r.u16(), phase: r.u32(), fw: r.u16(), fh: r.u16() });
  }
  if (name === MAP) target = { name, size, pageBase, pageCount, borderSet, layers, objects };
  void pageCount;
}
if (!target) throw new Error('map not found in bin: ' + MAP);
console.log(`[B] baked scene: roads=${target.layers.roads.length} (map "${target.name}", pages ${target.pageBase}..+${target.pageCount})`);

// candidate atlas pages are PNG files on disk; decode via zlib-less trick:
// we already have trusted atlasPages for the same bake? NO — different run.
// Instead decode the PNG pages from the assets dir with a minimal decoder (filter 0 rows? no—) 
// Easier: read PNG via Node zlib full inflate + defilter:
function decodePng(file) {
  const buf = fs.readFileSync(file);
  let p = 8; const idat = []; let w = 0, h = 0;
  while (p < buf.length) {
    const len = buf.readUInt32BE(p); const type = buf.toString('latin1', p + 4, p + 8);
    if (type === 'IHDR') { w = buf.readUInt32BE(p + 8); h = buf.readUInt32BE(p + 12); }
    if (type === 'IDAT') idat.push(buf.subarray(p + 8, p + 8 + len));
    p += 12 + len;
  }
  const data = zlib.inflateSync(Buffer.concat(idat));
  const stride = w * 4;
  const out = Buffer.alloc(w * h * 4);
  let prev = Buffer.alloc(stride);
  for (let y = 0; y < h; y++) {
    const filter = data[y * (stride + 1)];
    const row = data.subarray(y * (stride + 1) + 1, (y + 1) * (stride + 1));
    const cur = Buffer.from(row);
    for (let i = 0; i < stride; i++) {
      const a = i >= 4 ? cur[i - 4] : 0, bb = prev[i], c = i >= 4 ? prev[i - 4] : 0;
      let v = cur[i];
      if (filter === 1) v += a;
      else if (filter === 2) v += bb;
      else if (filter === 3) v += (a + bb) >> 1;
      else if (filter === 4) {
        const pa = Math.abs(bb - c), pb = Math.abs(a - c), pc = Math.abs(a + bb - 2 * c);
        v += (pa <= pb && pa <= pc) ? a : (pb <= pc ? bb : c);
      }
      cur[i] = v & 0xff;
    }
    cur.copy(out, y * stride);
    prev = cur;
  }
  return { w, h, data: out };
}

// candidate atlas: PNG files written by bake (atlas-<gid>.png)
const candAtlas = [];
for (let i = 0; i < target.pageCount; i++) candAtlas.push(decodePng(path.join(ROOT, `android/app/src/main/assets/scenes/atlas-${target.pageBase + i}.png`)));
// trusted atlas: raw buffers from buildScene of the SAME map/bake-run — note bake reruns
// randomize objects but NOT roads (roads are deterministic), so pages differ in layout
// between runs; we therefore render each side against ITS OWN atlas. Road pixels are
// what we diff — layout-independent.
const trustAtlas = atlasPages.map((b) => ({ w: 2048, h: 2048, data: b }));

// ---------------- render roads layer, both sides ----------------
let lastDraws = [];
function renderRoads(withCandidate) {
  const size = withCandidate ? target.size : scene.size;
  const x0 = 40, y0 = 40; // patch origin in tiles
  const W = REGION * 32, H = REGION * 32;
  const cnv = { width: W, height: H, data: Buffer.alloc(W * H * 4) };

  const roadAt = new Map();
  if (withCandidate) {
    for (const c of target.layers.roads) roadAt.set(c.y * size + c.x, c);
  } else {
    for (const c of scene.roads) roadAt.set(c.y * size + c.x, c);
  }

  const draws = [];
  const put = (img, sx, sy, sw, sh, dx, dy, dw, dh, flipH, flipV, wx, wy, part) => {
    draws.push({ wx, wy, part, dx, dy, dw, dh, sx, sy, sw, sh, flipH: flipH ? 1 : 0, flipV: flipV ? 1 : 0 });
    blit(cnv, W, img.data, sx, sy, sw, sh, dx, dy, dw, dh, flipH, flipV);
  };

  for (let y = y0; y < y0 + H; y++) {
    for (let x = x0; x < x0 + W; x++) {
      const tx = x - x0, ty = y - y0;
      if (y > 0) {
        const cell = roadAt.get((y - 1) * size + x);
        if (cell) {
          const f = withCandidate ? frames[cell.ref] : scene.frames[`${cell.def}:0:${cell.i}:0`];
          if (f) {
            const fb = withCandidate ? cell.flip : cell.f;
          const flipH = (fb & 1) !== 0, flipV = (fb & 2) !== 0;
            const g = viewerCrop(f, 0, 16, 32, 16, flipH, flipV);
            if (g) {
              const img = withCandidate ? candAtlas[f.page - target.pageBase] : trustAtlas[f.p];
              put(img, g.sx, g.sy, g.w, g.h, tx + g.ox, ty + g.oy, g.w, g.h, flipH, flipV, x, y, 'above');
            }
          }
        }
      }
      const cell = roadAt.get(y * size + x);
      if (cell) {
        const f = withCandidate ? frames[cell.ref] : scene.frames[`${cell.def}:0:${cell.i}:0`];
        if (f) {
          const fb = withCandidate ? cell.flip : cell.f;
          const flipH = (fb & 1) !== 0, flipV = (fb & 2) !== 0;
          const g = viewerCrop(f, 0, 0, 32, 16, flipH, flipV);
          if (g) {
            const img = withCandidate ? candAtlas[f.page - target.pageBase] : trustAtlas[f.p];
            put(img, g.sx, g.sy, g.w, g.h, tx + g.ox, ty + 16 + g.oy, g.w, g.h, flipH, flipV, x, y, 'own');
          }
        }
      }
    }
  }
  lastDraws = draws;
  return cnv;
}

// wait — the candidate path above indexes `above.ref` through roadAt cells which
// for the candidate side are {x,y,ref,flip} already. Clean up by re-mapping:
// (kept as-is because roadAt values ARE the layer cells on the candidate side)


// ---- data-level comparison: scene.roads vs bin roads ----
const refSorted = scene.roads.map(c => ({ x: c.x, y: c.y, i: c.i, f: c.f & 3 })).sort((a, b) => (a.y - b.y) || (a.x - b.x));
const map0 = { name: null };
// re-walk bin to grab THIS map's road cells with their resolved frames' identity via a second pass:
// frames were stored without def/i, so instead compare (x,y,flip) and rendered row-shift:
const candSorted = target.layers.roads.map(c => ({ x: c.x, y: c.y, f: c.flip })).sort((a, b) => (a.y - b.y) || (a.x - b.x));
let mism = 0;
for (let i = 0; i < Math.max(refSorted.length, candSorted.length); i++) {
  const a = refSorted[i], b = candSorted[i];
  if (!a || !b || a.x !== b.x || a.y !== b.y || a.f !== b.f) {
    mism++;
    if (mism <= 5) console.log('[cell-mismatch]', JSON.stringify(a), 'vs', JSON.stringify(b));
  }
}
console.log('[cells] ref=' + refSorted.length + ' cand=' + candSorted.length + ' mismatches=' + mism);
// also compare one road frame's rect: find a COBBRD frame in bin (x:51,y:60 from earlier log)
// trust side:
const trustCOBBRD = scene.frames['COBBRD:0:14:0'];
// bin side: scan frames for the one used by that cell
const cell5160 = target.layers.roads.find(c => c.x === 51 && c.y === 60);
if (cell5160 && trustCOBBRD) {
  const bf = frames[cell5160.ref];
  console.log('[frame COBBRD:14] trust=', JSON.stringify(trustCOBBRD), ' bin=', JSON.stringify(bf));
}


// ---- atlas content check: COBBRD frame rect on both atlases ----
(function () {
  const t = trustAtlas[0]; // trusted page 0
  const c = candAtlas[0];  // bin page 10 -> local 0
  const x0 = 1920, y0 = 416, w = 13, h = 20;
  let same = 0, diffp = 0;
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
    const ti = ((y0 + y) * 2048 + (x0 + x)) * 4;
    const ci = ((y0 + y) * c.w + (x0 + x)) * 4;
    if (t.data[ti] === c.data[ci] && t.data[ti+1] === c.data[ci+1] && t.data[ti+2] === c.data[ci+2] && t.data[ti+3] === c.data[ci+3]) same++;
    else diffp++;
  }
  console.log('[atlas COBBRD rect] same=' + same + ' diff=' + diffp);
  // maybe the same content sits at a DIFFERENT location in the candidate atlas — scan for it
  const probe = (x0 + 0) + (y0 + 5) * 2048 * 4;
  const pr = t.data[probe], pg = t.data[probe+1], pb = t.data[probe+2], pa = t.data[probe+3];
  outer:
  for (let py = 0; py < 2048 - h; py += 1) {
    for (let px = 0; px < 2048 - w; px += 1) {
      const ii = (py * 2048 + px) * 4;
      if (c.data[ii] === pr && c.data[ii+1] === pg && c.data[ii+2] === pb && c.data[ii+3] === pa) {
        // verify a second probe point
        const p2t = (y0 + 12) * 2048 * 4 + (x0 + 6) * 4;
        const p2c = ((py + 7) * c.w + (px + 6)) * 4;
        if (c.data[p2c] === t.data[p2t] && c.data[p2c+1] === t.data[p2t+1]) {
          console.log('[atlas scan] trusted COBBRD content found in candidate page0 at', px, py);
          break outer;
        }
      }
    }
  }
})();


// ---- scan ALL road frames: compare atlas content for every referenced frame ----
(function () {
  const seen = new Map(); // trust frame key -> {page, rect}
  let checked = 0, bad = 0;
  const badList = [];
  for (const c of scene.roads) {
    const key = `${c.def}:0:${c.i}:0`;
    if (seen.has(key)) continue;
    const tf = scene.frames[key];
    if (!tf) continue;
    seen.set(key, true);
    // find the same rect in candidate frames: rect identity = same x/y/w/h/ox/oy
    // candidate pages differ; locate via the bin cell at the same (x,y)
    // (road cell -> fid -> frame rect)
    const bc = target.layers.roads.find((b) => b.x === c.x && b.y === c.y);
    if (!bc) continue;
    const bf = frames[bc.ref];
    if (!bf) continue;
    const t = trustAtlas[tf.p];
    const cimg = candAtlas[bf.page - target.pageBase];
    let ok = true;
    for (let y = 0; y < tf.h && ok; y += 2) {
      for (let x = 0; x < tf.w; x += 2) {
        const ti = ((tf.y + y) * 2048 + (tf.x + x)) * 4;
        const ci = ((bf.y + y) * cimg.w + (bf.x + x)) * 4;
        if (t.data[ti] !== cimg.data[ci] || t.data[ti+3] !== cimg.data[ci+3]) { ok = false; break; }
      }
    }
    checked++;
    if (!ok) {
      bad++;
      if (badList.length < 8) badList.push({ key, trustRect: [tf.x, tf.y, tf.w, tf.h], candRect: [bf.x, bf.y, bf.w, bf.h], page: bf.page });
    }
  }
  console.log('[frames] checked=' + checked + ' content-mismatch=' + bad);
  for (const b of badList) console.log('[frame-mismatch]', JSON.stringify(b));
})();






// ---- raw flip bytes for specific cells ----
(function () {
  for (const [wx, wy] of [[130, 40], [131, 39], [131, 40], [275, 40], [276, 40]]) {
    const rc = scene.roads.find((c) => c.x === wx && c.y === wy);
    const bc = target.layers.roads.find((b) => b.x === wx && b.y === wy);
    console.log(`[flip] (${wx},${wy}) ref=${rc ? (rc.f & 3) : 'none'} cand=${bc ? bc.flip : 'none'}`);
  }
})();

const A = renderRoads(false);
const drawsA = lastDraws;
const B = renderRoads(true);
const drawsB = lastDraws;

// ---- raw pixel dump around first diff ----
(function () {
  const dx0 = 91 - 4, dy0 = 0;
  console.log('--- ref rows (RGBA) y=0..3, x=88..100 ---');
  for (let y = 0; y < 4; y++) {
    let row = 'y' + y + ': ';
    for (let x = dx0; x < dx0 + 12; x++) {
      const i = (y * A.width + x) * 4;
      row += A.data[i] + ',' + A.data[i + 1] + ',' + A.data[i + 2] + ',' + A.data[i + 3] + ' | ';
    }
    console.log(row);
  }
  console.log('--- cand rows ---');
  for (let y = 0; y < 4; y++) {
    let row = 'y' + y + ': ';
    for (let x = dx0; x < dx0 + 12; x++) {
      const i = (y * B.width + x) * 4;
      row += B.data[i] + ',' + B.data[i + 1] + ',' + B.data[i + 2] + ',' + B.data[i + 3] + ' | ';
    }
    console.log(row);
  }
})();

let diff = 0, first = null;
for (let i = 0; i < A.data.length; i += 4) {
  if (A.data[i] !== B.data[i] || A.data[i + 1] !== B.data[i + 1] || A.data[i + 2] !== B.data[i + 2] || A.data[i + 3] !== B.data[i + 3]) {
    diff++;
    if (!first) first = { x: (i / 4) % A.width, y: Math.floor(i / 4 / A.width) };
  }
}
// ---- inspect cells at the first-diff location ----
(function () {
  const tx = 40 + Math.floor(first.x / 32); // world tile x
  console.log('[inspect] patch-px', first.x, first.y, '-> world tile', tx, ' rows y=39/40/41');
  for (const wy of [39, 40, 41]) {
    const rc = scene.roads.find((c) => c.x === tx && c.y === wy);
    const key = rc ? `${rc.def}:0:${rc.i}:0` : null;
    const sf = key ? scene.frames[key] : null;
    const bc = target.layers.roads.find((b) => b.x === tx && b.y === wy);
    const bf = bc ? frames[bc.ref] : null;
    console.log(`(${tx},${wy}) ref:`, rc ? `${rc.def} i=${rc.i} f=${rc.f & 3} frame=${key} -> ${sf ? JSON.stringify({ p: sf.p, x: sf.x, y: sf.y, w: sf.w, h: sf.h, ox: sf.ox, oy: sf.oy }) : 'MISSING'}` : 'no road',
      '| cand:', bc ? `fid=${bc.ref} flip=${bc.flip} -> ${bf ? JSON.stringify({ page: bf.page, x: bf.x, y: bf.y, w: bf.w, h: bf.h, ox: bf.ox, oy: bf.oy }) : 'UNDEF'}` : 'no road');
  }
  // how many COBBRD frames does the DEF actually have?
  const def = lib.def('COBBRD');
  console.log('[COBBRD] block0 frames =', def && def.blocks[0] ? def.blocks[0].length : 'n/a');
})();

console.log('[draws] ref=' + drawsA.length + ' cand=' + drawsB.length);
const ma = new Map(drawsA.map(d => [d.wx + ':' + d.wy + ':' + d.part, d]));
let dm = 0;
for (const d of drawsB) {
  const a = ma.get(d.wx + ':' + d.wy + ':' + d.part);
  if (!a) { dm++; if (dm <= 8) console.log('[draw-extra]', JSON.stringify(d)); continue; }
  const fields = ['dx','dy','dw','dh','flipH','flipV'];
  const bad = fields.filter(f => a[f] !== d[f]);
  // src rect only comparable via SIZE (atlas layouts differ); dest+flip+size must match
  if (bad.length || a.sw !== d.sw || a.sh !== d.sh) {
    dm++;
    if (dm <= 8) console.log('[draw-mismatch]', JSON.stringify({ cell: d.wx + ',' + d.wy + ':' + d.part, ref: { dx: a.dx, dy: a.dy, dw: a.dw, dh: a.dh, sw: a.sw, sh: a.sh, fH: a.flipH, fV: a.flipV }, cand: { dx: d.dx, dy: d.dy, dw: d.dw, dh: d.dh, sw: d.sw, sh: d.sh, fH: d.flipH, fV: d.flipV } }));
  }
}
console.log('[draw-mismatches] ' + dm);
fs.writeFileSync(OUTA, encodePng(A.width, A.height, A.data));
fs.writeFileSync(OUTB, encodePng(B.width, B.height, B.data));
console.log(`[diff] pixels=${diff} of ${A.width * A.height} first=${JSON.stringify(first)}`);
console.log(`[out] ${OUTA} ${OUTB}`);
