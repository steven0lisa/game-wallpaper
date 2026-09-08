'use strict';
// 场景构建：h3m + lod → 图集 PNG + 可 JSON 序列化的场景描述。
// 逻辑与 Swift GameMap.swift 一致（排序/边界/随机物件见 docs/rendering.md）。
const { DefFile, rotationStepCount, rotatedPalette, blitMode, TERRAIN_DEFS } = require('./DefFile');

const RIVER_DEFS = [null, 'CLRRVR', 'ICYRVR', 'MUDRVR', 'LAVRVR'];
const ROAD_DEFS = [null, 'DIRTRD', 'GRAVRD', 'COBBRD'];
const BORDER_DEF = 'EDG';

// 边界帧号（VCMI getIndexForTile；先判图外远处，负数取模取绝对值）。
function borderFrameIndex(x, y, size) {
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

// 随机物件具象化（移植自 APK ObjectsRandomizer，表见 GameMap.swift）。
const RANDOM_MONSTERS = {
  1: ['AVWPike', 'AVWpikx0', 'AVWcent0', 'AVWcenx0', 'AVWgrem0', 'AVWgrex0', 'AVWimp0', 'AVWimpx0', 'AVWskel0', 'AVWskex0', 'AVWtrog0', 'AvWInfr', 'AVWgobl0', 'AVWgobx0', 'AVWgnll0', 'AVWgnlx0', 'AVWpixie', 'AVWsprit', 'AVWhalf', 'AVWpeas'],
  2: ['AvWLCrs', 'AvWHCrs', 'AVWdwrf0', 'AVWdwrx0', 'AVWgarg0', 'AVWgarx0', 'AVWgog0', 'AVWgogx0', 'AVWzomb0', 'AVWzomx0', 'AVWharp0', 'AVWharx0', 'AVWwolf0', 'AVWwolx0', 'AvWLizr', 'AVWlizx0', 'AVWelmw0', 'AVWicee', 'AVWboar', 'AVWrog'],
  3: ['AvWGrif', 'AVWgrix0', 'AVWelfw0', 'AVWelfx0', 'AVWgolm0', 'AVWgolx0', 'AVWhoun0', 'AVWhoux0', 'AvWWigh', 'AVWwigx0', 'AVWbehl0', 'AVWbehx0', 'AVWorc0', 'AVWorcx0', 'AvWDFly', 'AvWDFir', 'AVWelme0', 'AVWstone', 'AVWmumy', 'AVWnomd'],
  4: ['AVWswrd0', 'AVWswrx0', 'AVWpega0', 'AVWpegx0', 'AVWmage0', 'AVWmagx0', 'AVWdemn0', 'AVWdemx0', 'AVWvamp0', 'AVWvamx0', 'AvWMeds', 'AVWmedx0', 'AVWogre0', 'AVWogrx0', 'AvWBasl', 'AvWGBas', 'AVWelma0', 'AVWstorm', 'AVWglmg0', 'AVWsharp'],
  5: ['AvWMonk', 'AVWmonx0', 'AVWtree0', 'AVWtrex0', 'AVWgeni0', 'AVWgenx0', 'AVWpitf0', 'AVWpitx0', 'AVWlich0', 'AVWlicx0', 'AvWMino', 'AVWminx0', 'AVWroc0', 'AVWrocx0', 'AvWGorg', 'AVWgorx0', 'AVWelmf0', 'AVWnrg', 'AVWglmd0'],
  6: ['AVWcvlr0', 'AVWcvlx0', 'AVWunic0', 'AVWunix0', 'AVWnaga0', 'AVWnagx0', 'AVWefre0', 'AVWefrx0', 'AVWbkni0', 'AVWbknx0', 'AVWmant0', 'AVWmanx0', 'AVWcycl0', 'AVWcycx0', 'AvWWyvr', 'AVWwyvx0', 'AVWpsye', 'AVWmagel', 'AVWench'],
  7: ['AvWAngl', 'AvWArch', 'AVWdrag0', 'AVWdrax0', 'AVWtitn0', 'AVWtitx0', 'AVWdevl0', 'AVWdevx0', 'AVWbone0', 'AVWbonx0', 'AvWRDrg', 'AVWddrx0', 'AVWbhmt0', 'AVWbhmx0', 'AvWHydr', 'AVWhydx0', 'AVWfbird', 'AVWphx'],
};
const TOWNS = ['avccasx0', 'avcramx0', 'avctowx0', 'avcinfx0', 'avcnecx0', 'avcdunx0', 'avcstrx0', 'avcftrx0', 'avchforx'];
const VILLAGES = ['avccast0', 'avcramp0', 'avctowr0', 'avcinfc0', 'avcnecr0', 'avcdung0', 'avcstro0', 'avcftrt0', 'avchfor0'];
const DWELLINGS = [
  ['AVGpike0', 'AVGcros0', 'AVGgrff0', 'AVGswor0', 'AVGmonk0', 'AVGcavl0', 'AVGangl0'],
  ['AVGcent0', 'AVGdwrf0', 'AVGelf0', 'AVGpega0', 'AVGtree0', 'AVGunic0', 'AVGgdrg0'],
  ['AVGgrem0', 'AVGgarg0', 'AVGgolm0', 'AVGmage0', 'AVGgeni0', 'AVGnaga0', 'AVGtitn0'],
  ['AVGimp0', 'AVGgogs0', 'AVGhell0', 'AVGdemn0', 'AVGpit0', 'AVGefre0', 'AVGdevl0'],
  ['AVGskel0', 'AVGzomb0', 'AVGwght0', 'AVGvamp0', 'AVGlich0', 'AVGbkni0', 'AVGbone0'],
  ['AVGtrog0', 'AVGharp0', 'AVGbhld0', 'AVGmdsa0', 'AVGmino0', 'AVGmant0', 'AVGrdrg0'],
  ['AVGgobl0', 'AVGwolf0', 'AVGorcg0', 'AVGogre0', 'AVGrocs0', 'AVGcycl0', 'AVGbhmt0'],
  ['AVGgnll0', 'AVGlzrd0', 'AVGdfly0', 'AVGbasl0', 'AVGgorg0', 'AVGwyvn0', 'AVGhydr0'],
  ['AVGpixie', 'AVGair0', 'AVGwatr0', 'AVGfire0', 'AVGerth0', 'AVGelp', 'AVGfbrd'],
];
const RESOURCES = ['avtwood0', 'avtore0', 'avtsulf0', 'avtmerc0', 'avtcrys0', 'avtgems0', 'avtgold0'];

const pick = (arr) => arr[Math.floor(Math.random() * arr.length)];

function resolvedSpriteName(obj) {
  const id = obj.def.objectId;
  const subId = obj.def.objectClassSubId;
  switch (id) {
    case 71: return pick(Object.values(RANDOM_MONSTERS).flat());
    case 72: case 73: case 74: case 75: case 162: case 163: case 164:
      return pick(RANDOM_MONSTERS[{ 72: 1, 73: 2, 74: 3, 75: 4, 162: 5, 163: 6, 164: 7 }[id]]);
    case 5: return 'ava' + String(subId).padStart(4, '0');
    case 65: case 66: case 67: case 68: return 'ava' + String(Math.floor(Math.random() * 131) + 10).padStart(4, '0');
    case 69: return 'ava' + String(Math.floor(Math.random() * 11) + 129).padStart(4, '0');
    case 76: return pick(RESOURCES);
    case 77: {
      const list = Math.random() < 0.5 ? TOWNS : VILLAGES;
      return subId >= 0 && subId < list.length ? list[subId] : pick(list);
    }
    case 216: case 217: case 218: return pick(pick(DWELLINGS));
    default: return obj.def.spriteName;
  }
}

// ---------- PNG 编码（无依赖，8-bit 调色板转 RGBA 直写） ----------
const CRC_TABLE = (() => {
  const t = new Int32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c;
  }
  return t;
})();
function crc32(buf) {
  let c = -1;
  for (let i = 0; i < buf.length; i++) c = CRC_TABLE[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  return (c ^ -1) >>> 0;
}
function chunk(type, data) {
  const out = Buffer.alloc(12 + data.length);
  out.writeUInt32BE(data.length, 0);
  out.write(type, 4, 'ascii');
  data.copy(out, 8);
  out.writeUInt32BE(crc32(Buffer.concat([Buffer.from(type, 'ascii'), data])), 8 + data.length);
  return out;
}
function encodePng(width, height, rgba) {
  const sig = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0);
  ihdr.writeUInt32BE(height, 4);
  ihdr[8] = 8; ihdr[9] = 6; // 8-bit RGBA
  const stride = width * 4;
  const raw = Buffer.alloc((stride + 1) * height);
  for (let y = 0; y < height; y++) {
    raw[y * (stride + 1)] = 0; // filter: none
    rgba.copy(raw, y * (stride + 1) + 1, y * stride, (y + 1) * stride);
  }
  const zlib = require('zlib');
  return Buffer.concat([sig, chunk('IHDR', ihdr), chunk('IDAT', zlib.deflateSync(raw, { level: 6 })), chunk('IEND', Buffer.alloc(0))]);
}

// ---------- 帧索引（key 唯一标识一个打包帧） ----------
// key 格式: def名:block:index:step  → atlas 坐标由打包器分配。
class AtlasPacker {
  constructor(pageSize = 2048) {
    this.pageSize = pageSize;
    this.pages = [];
    this.newPage();
    this.frames = new Map(); // key -> {page,x,y,w,h}
  }
  newPage() {
    this.pages.push({ buf: Buffer.alloc(this.pageSize * this.pageSize * 4), x: 0, y: 0, rowH: 0 });
  }
  place(w, h) {
    let pg = this.pages[this.pages.length - 1];
    if (pg.x + w > this.pageSize) { pg.x = 0; pg.y += pg.rowH; pg.rowH = 0; }
    if (pg.y + h > this.pageSize) { this.newPage(); pg = this.pages[this.pages.length - 1]; }
    const spot = { page: this.pages.length - 1, x: pg.x, y: pg.y };
    pg.x += w;
    pg.rowH = Math.max(pg.rowH, h);
    return spot;
  }
  blit(key, rgba, w, h, offsetX, offsetY, fullCanvasW, fullCanvasH) {
    if (w > this.pageSize || h > this.pageSize) return;
    if (this.frames.has(key)) return;
    const spot = this.place(w, h);
    const pg = this.pages[spot.page];
    for (let row = 0; row < h; row++) {
      rgba.copy(pg.buf, ((spot.y + row) * this.pageSize + spot.x) * 4, row * w * 4, (row + 1) * w * 4);
    }
    this.frames.set(key, { page: spot.page, x: spot.x, y: spot.y, w, h,
                           ox: offsetX, oy: offsetY,
                           fw: fullCanvasW, fh: fullCanvasH });
  }
}

function frameRgba(frame, palette, mode) {
  const out = Buffer.allocUnsafe(frame.width * frame.height * 4);
  let p = 0;
  for (let i = 0; i < frame.indices.length; i++) {
    const idx = frame.indices[i];
    let r = palette[idx * 3], g = palette[idx * 3 + 1], b = palette[idx * 3 + 2], a = 255;
    if (mode === 'colorKey') {
      if (idx === 0) a = 0;
    } else if (mode === 'shadows') {
      if (idx === 0) a = 0;
      else if (idx === 1 || idx === 7) { r = g = b = 0; a = 64; }
      else if (idx === 2 || idx === 3) a = 0;
      else if (idx === 4 || idx === 6) { r = g = b = 0; a = 128; }
      else if (idx === 5) { r = g = b = 128; }
    }
    out[p++] = r; out[p++] = g; out[p++] = b; out[p++] = a;
  }
  return out;
}

class AssetLibrary {
  constructor(lod) {
    this.lod = lod;
    this.cache = new Map();
    this.missing = new Set();
  }
  def(name) {
    let key = name.toUpperCase();
    if (!key.includes('.')) key += '.DEF';
    if (this.cache.has(key)) return this.cache.get(key);
    const data = this.lod.contents(key);
    if (!data) { this.missing.add(key); return null; }
    let def;
    try {
      def = new DefFile(data);
    } catch {
      this.missing.add(key);
      return null;
    }
    this.cache.set(key, def);
    return def;
  }
}

function buildScene(h3m, library, level = 0) {
  const size = h3m.size;
  const packer = new AtlasPacker(2048);
  const pack = (defName, block, index, step) => {
    const key = `${defName}:${block}:${index}:${step}`;
    if (packer.frames.has(key)) return key;
    const def = library.def(defName);
    if (!def || !def.blocks[block] || !def.blocks[block][index]) return null;
    const frame = def.blocks[block][index];
    const ranges = require('./DefFile').PALETTE_ANIMATION[defName.toUpperCase()];
    let palette = def.palette;
    if (step > 0 && ranges) palette = rotatedPalette(def.palette, ranges, step);
    const rgba = frameRgba(frame, palette, blitMode(defName));
    packer.blit(key, rgba, frame.width, frame.height, frame.x, frame.y,
                frame.fullWidth, frame.fullHeight);
    return key;
  };

  // 地形/河流/道路
  const terrain = [], rivers = [], roads = [];
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      const t = h3m.tile(x, y, level);
      if (!t) continue;
      const defName = TERRAIN_DEFS[t.terrain];
      if (defName) {
        const steps = rotationStepCount(defName);
        for (let s = 0; s < steps; s++) pack(defName, 0, t.terView, s);
        const flip = t.flags & 3;
        terrain.push({ x, y, def: defName, i: t.terView, f: flip, steps });
      }
      const river = RIVER_DEFS[t.river];
      if (river) {
        const steps = rotationStepCount(river);
        for (let s = 0; s < steps; s++) pack(river, 0, t.riverDir, s);
        rivers.push({ x, y, def: river, i: t.riverDir, f: (t.flags >> 2) & 3, steps });
      }
      const road = ROAD_DEFS[t.road];
      if (road) {
        pack(road, 0, t.roadDir, 0);
        roads.push({ x, y, def: road, i: t.roadDir, f: (t.flags >> 4) & 3 });
      }
    }
  }

  // 物件（排序：placementOrder ↓ → y ↑ → 英雄置顶 → x ↑ → 文件序）
  const objects = h3m.objects
    .filter((o) => o.z === level)
    .filter((o) => o.def.objectId !== 26 && o.def.objectId !== 36 && o.def.objectId !== 214)
    .map((o) => {
      const spriteName = resolvedSpriteName(o);
      const def = library.def(spriteName);
      if (!def || !def.blocks[0] || def.blocks[0].length === 0) return null;
      for (let i = 0; i < def.blocks[0].length; i++) pack(spriteName, 0, i, 0);
      return {
        x: o.x, y: o.y,
        def: spriteName,
        fw: def.fullWidth, fh: def.fullHeight,
        frames: def.blocks[0].length,
        priority: o.def.placementOrder,
        isHero: o.def.objectId === 34 || o.def.objectId === 70 || o.def.objectId === 62,
        seq: objects_seq++,
      };
    })
    .filter(Boolean)
    .sort((a, b) => {
      if (a.priority !== b.priority) return b.priority - a.priority;
      if (a.y !== b.y) return a.y - b.y;
      if (a.isHero !== b.isHero) return a.isHero ? 1 : -1;
      if (a.x !== b.x) return a.x - b.x;
      return a.seq - b.seq;
    })
    .map(({ seq, ...rest }) => rest) // seq 不进 JSON
    .map((o, i) => ({ ...o, phase: i * 7 }));

  // 边界帧（视口任意，全部 36 帧都备好）
  for (let i = 0; i < 36; i++) pack(BORDER_DEF, 0, i, 0);

  // 图集导出 + 场景描述
  const pages = packer.pages.map((pg, i) => ({ file: `atlas-${i}.png`, size: packer.pageSize }));
  const framesObj = {};
  for (const [key, f] of packer.frames) {
    framesObj[key] = { p: f.page, x: f.x, y: f.y, w: f.w, h: f.h, ox: f.ox, oy: f.oy, fw: f.fw, fh: f.fh };
  }

  return {
    scene: {
      title: h3m.title,
      size,
      level,
      pages,
      frames: framesObj,
      terrain, rivers, roads, objects,
      missingDefs: [...library.missing],
    },
    atlasPages: packer.pages.map((pg) => pg.buf),
  };
}

let objects_seq = 0;

module.exports = { AssetLibrary, buildScene, borderFrameIndex, encodePng };
