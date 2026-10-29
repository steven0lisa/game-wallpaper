#!/usr/bin/env node
'use strict';
// Bake bundled .h3m maps into an Android-ready scene bundle + atlas PNGs.
// Reuses the web engine parsers — the same semantics the mac Metal renderer and
// the web viewer implement — so all three renderers stay in lockstep.
//
// v2 (2026-10-29): ONE shared packer across all maps. AtlasPacker.blit is
// idempotent per frame key, so terrain/road/river/object frames reused by many
// maps are packed exactly once — the atlas stays small even for 100+ maps.
// Scene data is stored per-map with a byte-offset table so the Android side can
// load one map at a time and drop the previous map's arrays (OOM safety).
//
// Quality gates:
//   - a map whose .h3m fails to parse is SKIPPED (never enters the bundle);
//   - a map whose baked layers render blank/corrupt in the offline smoke test
//     is SKIPPED as well.
//
// Output (plaintext; encrypt before committing — see bundle_maps.sh):
//   <out>/scenes.bin    compact little-endian scene bundle (layout below)
//   <out>/atlas-N.png   RGBA atlas pages 2048², shared by every map
//
// scenes.bin layout (version 2, little-endian):
//   'H','3','B','2' | u16 version=2 | u16 mapCount | u16 atlasPageSize | u16 0
//   u32 frameCount
//   frames:  [u8 page, u16 x, u16 y, u16 w, u16 h, i16 ox, i16 oy, u16 fw, u16 fh]
//   u32 setCount
//   sets:    [u16 n, u16 id × n]                 // palette-rotation / animation variants
//   u32 mapCount offsets: absolute byte offset of each map segment
//   map segments:
//     u16 nameLen, name(utf8) | u16 size | u16 pageBase | u16 pageCount | u16 borderSetId
//     u32 n_terrain, cells:  [u16 x, u16 y, u16 setId, u8 flip]
//     u32 n_rivers,  cells:  [u16 x, u16 y, u16 setId, u8 flip]
//     u32 n_roads,   cells:  [u16 x, u16 y, u16 frameId, u8 flip]
//     u32 n_objects, cells:  [u16 x, u16 y, u16 setId, u32 phase, u16 fw, u16 fh]
//   frame id 0xFFFF = missing frame (skip draw).
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '../..');
const { LodFile } = require(path.join(ROOT, 'web/server/engines/heroes3/LodFile'));
const { H3mFile } = require(path.join(ROOT, 'web/server/engines/heroes3/H3mFile'));
const { AssetLibrary, buildScene, encodePng, AtlasPacker } =
  require(path.join(ROOT, 'web/server/engines/heroes3/Scene'));

const PAGE_SIZE = 2048;
const NO_FRAME = 0xffff;

function parseArgs(argv) {
  const a = { out: null, list: null, mapDir: null, maps: [] };
  for (let i = 2; i < argv.length; i++) {
    const k = argv[i];
    if (k === '--out') a.out = argv[++i];
    else if (k === '--list') a.list = argv[++i];
    else if (k === '--map-dir') a.mapDir = argv[++i];
    else if (k === '--map') a.maps.push(argv[++i]);
    else throw new Error('unknown arg ' + k);
  }
  if (!a.out) throw new Error('need --out <dir>');
  return a;
}

class W {
  constructor() { this.chunks = []; this.n = 0; }
  _b(b) { this.chunks.push(b); this.n += b.length; }
  u8(v) { this._b(Buffer.from([v & 0xff])); }
  u16(v) { const b = Buffer.alloc(2); b.writeUInt16LE(v & 0xffff, 0); this._b(b); }
  i16(v) { const b = Buffer.alloc(2); b.writeInt16LE(v, 0); this._b(b); }
  u32(v) { const b = Buffer.alloc(4); b.writeUInt32LE(v >>> 0, 0); this._b(b); }
  str(s) { const b = Buffer.from(s, 'utf8'); this.u16(b.length); this._b(b); }
  out() { return Buffer.concat(this.chunks, this.n); }
}

function readList(file) {
  return fs.readFileSync(file, 'utf8').split('\n')
    .map((s) => s.trim()).filter((s) => s && !s.startsWith('#'));
}

/**
 * Offline smoke test: paint the map's terrain + roads into a small canvas
 * straight from the packer pages and require real coverage. Catches corrupt
 * bakes (blank frames, zero-cell maps) before they ship in the APK.
 */
function renderSmokeTest(scene, packer) {
  const S = 4; // 4 world px per cell-row sample
  const W = 512, H = 512;
  const cov = new Uint8Array(W * H);
  const px = (page, sx, sy) => {
    const pg = packer.pages[page];
    if (!pg) return null;
    const i = (sy * PAGE_SIZE + sx) * 4;
    return pg.buf[i + 3] > 0;
  };
  const blit = (fid, dx, dy) => {
    const f = packer.frames.get('__byid' + fid); // placeholder, replaced below
    void f;
  };
  void blit;
  // build an id→frame list once
  const frameList = [...packer.frames.values()];
  const paint = (f, dx, dy, dw, dh) => {
    for (let r = 0; r < dh; r += S) {
      const sy = f.y + Math.floor(r * f.h / dh);
      const ty = Math.floor(dy + r);
      if (ty < 0 || ty >= H) continue;
      for (let c = 0; c < dw; c += S) {
        const sx = f.x + Math.floor(c * f.w / dw);
        const tx = Math.floor(dx + c);
        if (tx < 0 || tx >= W) continue;
        if (px(f.page, sx, sy)) cov[ty * W + tx] = 1;
      }
    }
  };
  // terrain cells sampled at their tile positions
  const scale = W / (scene.size * 32);
  for (const c of scene.terrain) {
    const key = `${c.def}:0:${c.i}:0`;
    const f = packer.frames.get(key);
    if (f) paint(f, c.x * 32 * scale, c.y * 32 * scale, 32 * scale, 32 * scale);
  }
  for (const c of scene.roads) {
    const key = `${c.def}:0:${c.i}:0`;
    const f = packer.frames.get(key);
    if (f) paint(f, c.x * 32 * scale, c.y * 32 * scale + 16 * scale, 32 * scale, 16 * scale);
    void c;
  }
  let hits = 0;
  for (let i = 0; i < cov.length; i++) hits += cov[i];
  const coverage = hits / cov.length;
  return coverage; // healthy maps cover 15-60% of the sample canvas
}

function main() {
  const args = parseArgs(process.argv);
  const mapPaths = args.maps.slice();
  if (args.list) {
    if (!args.mapDir) throw new Error('--list needs --map-dir');
    for (const name of readList(args.list)) mapPaths.push(path.join(args.mapDir, name));
  }
  if (!mapPaths.length) throw new Error('no maps');

  const lodPath = process.env.H3_LOD ||
    path.join(process.env.HOME, 'Library/Application Support/vcmi/Data/H3sprite.lod');
  const library = new AssetLibrary(new LodFile(lodPath));
  console.log(`[bake] lod=${library.lod.count} entries, maps=${mapPaths.length}`);

  fs.mkdirSync(args.out, { recursive: true });
  // stale outputs would linger from a previous run with fewer pages
  for (const f of fs.readdirSync(args.out)) {
    if (/^(atlas-\d+\.png|scenes\.bin)$/.test(f)) fs.unlinkSync(path.join(args.out, f));
  }

  // ---- pass 1: build every map through ONE shared packer (frame dedup) ----
  const packer = new AtlasPacker(PAGE_SIZE);
  const built = [];   // { path, name, scene }
  const skipped = []; // { path, reason }
  for (const p of mapPaths) {
    const t0 = Date.now();
    try {
      const { scene } = buildScene(new H3mFile(p), library, 0, packer);
      const cov = renderSmokeTest(scene, packer);
      if (cov < 0.02) {
        skipped.push({ path: p, reason: `smoke test blank (coverage ${(cov * 100).toFixed(1)}%)` });
        console.log(`[bake] SKIP ${path.basename(p)}: blank render (coverage ${(cov * 100).toFixed(1)}%)`);
        continue;
      }
      built.push({ path: p, name: path.basename(p, '.h3m'), scene, cov });
      console.log(`[bake] ok ${path.basename(p)}: size=${scene.size} objects=${scene.objects.length} cov=${(cov * 100).toFixed(0)}% (${Date.now() - t0}ms)`);
    } catch (e) {
      skipped.push({ path: p, reason: e.message });
      console.log(`[bake] SKIP ${path.basename(p)}: ${e.message}`);
    }
  }
  if (!built.length) throw new Error('all maps failed to bake');

  // ---- global frame/set id assignment ----
  const frames = [];
  const frameId = new Map(); // packer key -> global frame id
  for (const [key, f] of packer.frames) {
    frameId.set(key, frames.length);
    frames.push({ ...f }); // page already global (single packer)
  }
  const idOf = (key) => (frameId.has(key) ? frameId.get(key) : NO_FRAME);

  const sets = [];
  const setIndex = new Map(); // shared across maps: same key = same set
  const addSet = (key, ids) => {
    if (setIndex.has(key)) return setIndex.get(key);
    if (sets.length >= NO_FRAME) throw new Error('too many sets');
    const id = sets.length;
    sets.push(ids);
    setIndex.set(key, id);
    return id;
  };

  const mapMeta = [];
  for (const { name, scene } of built) {
    const borderIds = [];
    for (let i = 0; i < 36; i++) borderIds.push(idOf(`EDG:0:${i}:0`));
    const borderSetId = addSet('border', borderIds);

    const cellSet = (cells, kind) => cells.map((c) => {
      const key = `${kind}:${c.def}:${c.i}`;
      let sid = setIndex.get(key);
      if (sid === undefined) {
        const ids = [];
        for (let s = 0; s < c.steps; s++) ids.push(idOf(`${c.def}:0:${c.i}:${s}`));
        sid = addSet(key, ids);
      }
      return { x: c.x, y: c.y, sid, flip: c.f & 3 };
    });
    const terrain = cellSet(scene.terrain, 'T');
    const rivers = cellSet(scene.rivers, 'R');
    const roads = scene.roads.map((c) => ({
      x: c.x, y: c.y, fid: idOf(`${c.def}:0:${c.i}:0`), flip: c.f & 3,
    }));
    const objects = scene.objects.map((o) => {
      const key = `O:${o.def}`;
      let sid = setIndex.get(key);
      if (sid === undefined) {
        const ids = [];
        for (let i = 0; i < o.frames; i++) ids.push(idOf(`${o.def}:0:${i}:0`));
        sid = addSet(key, ids);
      }
      return { x: o.x, y: o.y, sid, phase: o.phase >>> 0, fw: o.fw, fh: o.fh };
    });

    mapMeta.push({ name, size: scene.size, pageBase: 0, pageCount: packer.pages.length, borderSetId, terrain, rivers, roads, objects });
  }

  // ---- serialize scenes.bin v2 (map segments behind an offset table) ----
  const w = new W();
  w._b(Buffer.from('H3B2', 'latin1'));
  w.u16(2); w.u16(mapMeta.length); w.u16(PAGE_SIZE); w.u16(0);
  if (frames.length >= NO_FRAME) throw new Error('too many frames for u16 ids');
  w.u32(frames.length);
  for (const f of frames) {
    w.u8(f.page); w.u16(f.x); w.u16(f.y); w.u16(f.w); w.u16(f.h);
    w.i16(f.ox); w.i16(f.oy); w.u16(f.fw); w.u16(f.fh);
    if (f.page > 255) throw new Error('page > 255 needs wider field');
  }
  w.u32(sets.length);
  for (const ids of sets) {
    w.u16(ids.length);
    for (const id of ids) w.u16(id);
  }
  const offsetTablePos = w.n;
  for (let i = 0; i < mapMeta.length; i++) w.u32(0); // patched below
  const offsetPatch = [];
  for (const m of mapMeta) {
    offsetPatch.push(w.n);
    w.str(m.name); w.u16(m.size); w.u16(m.pageBase); w.u16(m.pageCount); w.u16(m.borderSetId);
    w.u32(m.terrain.length);
    for (const c of m.terrain) { w.u16(c.x); w.u16(c.y); w.u16(c.sid); w.u8(c.flip); }
    w.u32(m.rivers.length);
    for (const c of m.rivers) { w.u16(c.x); w.u16(c.y); w.u16(c.sid); w.u8(c.flip); }
    w.u32(m.roads.length);
    for (const c of m.roads) { w.u16(c.x); w.u16(c.y); w.u16(c.fid); w.u8(c.flip); }
    w.u32(m.objects.length);
    for (const o of m.objects) { w.u16(o.x); w.u16(o.y); w.u16(o.sid); w.u32(o.phase); w.u16(o.fw); w.u16(o.fh); }
  }
  const bin = w.out();
  for (let i = 0; i < offsetPatch.length; i++) bin.writeUInt32LE(offsetPatch[i], offsetTablePos + i * 4);

  fs.writeFileSync(path.join(args.out, 'scenes.bin'), bin);

  // ---- atlas pages (shared) ----
  let pngBytes = 0;
  packer.pages.forEach((pg, j) => {
    const png = encodePng(PAGE_SIZE, PAGE_SIZE, pg.buf);
    fs.writeFileSync(path.join(args.out, `atlas-${j}.png`), png);
    pngBytes += png.length;
    console.log(`[bake]   atlas-${j}.png ${(png.length / 1024 / 1024).toFixed(1)}MB`);
  });

  console.log(`[bake] scenes.bin ${(bin.length / 1024).toFixed(0)}KB maps=${mapMeta.length}/${mapPaths.length} skipped=${skipped.length} frames=${frames.length} sets=${sets.length} pages=${packer.pages.length} atlasTotal=${(pngBytes / 1024 / 1024).toFixed(1)}MB`);
  for (const s of skipped) console.log(`[bake]   skipped: ${path.basename(s.path)} — ${s.reason}`);
  if (skipped.length) {
    fs.writeFileSync(path.join(args.out, 'skipped.json'), JSON.stringify(skipped, null, 2));
  }
}

main();
