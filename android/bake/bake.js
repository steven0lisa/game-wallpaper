#!/usr/bin/env node
'use strict';
// Bake bundled .h3m maps into an Android-ready scene bundle + atlas PNGs.
// Reuses the web engine parsers — the same semantics the mac Metal renderer and
// the web viewer implement — so all three renderers stay in lockstep.
//
// One packer PER MAP: the wallpaper only uploads the current map's pages
// (5-7 × 2048² ≈ 80-110MB VRAM) instead of one shared atlas for everything.
//
// Output (plaintext; encrypt before committing — see pack.sh):
//   <out>/scenes.bin    compact little-endian scene bundle (layout below)
//   <out>/atlas-N.png   RGBA atlas pages 2048²; N is a global counter,
//                       map range = [pageBase, pageBase + pageCount)
//
// scenes.bin layout (version 1, little-endian):
//   'H','3','B','1' | u16 version=1 | u16 mapCount | u16 atlasPageSize | u16 0
//   u32 frameCount
//   frames:  [u8 page, u16 x, u16 y, u16 w, u16 h, i16 ox, i16 oy, u16 fw, u16 fh]
//            (page already global: pageBase + localPage)
//   u32 setCount
//   sets:    [u16 n, u16 id × n]                 // palette-rotation / animation variants
//   maps ×mapCount:
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

  const w = new W();
  w._b(Buffer.from('H3B1', 'latin1'));
  w.u16(1); w.u16(mapPaths.length); w.u16(PAGE_SIZE); w.u16(0);

  const frames = [];    // global frame table; ids are globally unique (per-map, no cross-dedup)
  const sets = [];      // global set table
  const mapMeta = [];
  let pageCounter = 0;  // global page number for file naming

  for (const p of mapPaths) {
    const t0 = Date.now();
    const setIndex = new Map();  // per-map only: ids must point into THIS map's frames
    const packer = new AtlasPacker(PAGE_SIZE);
    const { scene } = buildScene(new H3mFile(p), library, 0, packer);

    // Append this map's frames to the global table; page remapped to global numbering.
    const localId = new Map();
    for (const [key, f] of packer.frames) {
      const gid = frames.length;
      localId.set(key, gid);
      frames.push({ ...f, page: pageCounter + f.page });
    }
    const idOf = (key) => (localId.has(key) ? localId.get(key) : NO_FRAME);

    const addSet = (key, ids) => {
      if (setIndex.has(key)) return setIndex.get(key);
      if (sets.length >= NO_FRAME) throw new Error('too many sets');
      const id = sets.length;
      sets.push(ids);
      setIndex.set(key, id);
      return id;
    };

    // border: 36 EDG frames in borderFrameIndex order
    const borderIds = [];
    for (let i = 0; i < 36; i++) borderIds.push(idOf(`EDG:0:${i}:0`));
    const borderSetId = addSet('border', borderIds);

    // terrain / rivers: one set per (def, view), ids = palette-rotation steps
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
    // roads: single frame, but with canvas-crop semantics at draw time
    const roads = scene.roads.map((c) => ({
      x: c.x, y: c.y, fid: idOf(`${c.def}:0:${c.i}:0`), flip: c.f & 3,
    }));
    // objects: one set per def (animation frames), phase from buildScene sort order
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

    // atlas pages for this map only
    packer.pages.forEach((pg, j) => {
      const png = encodePng(PAGE_SIZE, PAGE_SIZE, pg.buf);
      fs.writeFileSync(path.join(args.out, `atlas-${pageCounter + j}.png`), png);
      console.log(`[bake]   atlas-${pageCounter + j}.png ${(png.length / 1024 / 1024).toFixed(1)}MB`);
    });

    mapMeta.push({
      name: path.basename(p, '.h3m'), size: scene.size,
      pageBase: pageCounter, pageCount: packer.pages.length, borderSetId,
      terrain, rivers, roads, objects,
    });
    pageCounter += packer.pages.length;

    console.log(`[bake] ${path.basename(p)}: size=${scene.size} objects=${objects.length} frames=${localId.size} pages=${packer.pages.length} (${Date.now() - t0}ms) missing=${JSON.stringify(scene.missingDefs)}`);
  }

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
  for (const m of mapMeta) {
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
  fs.writeFileSync(path.join(args.out, 'scenes.bin'), bin);
  let pngBytes = 0;
  for (const f of fs.readdirSync(args.out)) pngBytes += fs.statSync(path.join(args.out, f)).size;
  console.log(`[bake] scenes.bin ${(bin.length / 1024).toFixed(0)}KB frames=${frames.length} sets=${sets.length} pages=${pageCounter} total=${(pngBytes / 1024 / 1024).toFixed(1)}MB`);
}

main();
