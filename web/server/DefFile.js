'use strict';
// .def 精灵解码 — 移植自 Swift DefFile.swift（语义见 docs/formats.md §2）。
const { Reader } = require('./Reader');

// 调色板轮转区间（VCMI terrains.json / rivers.json）。
const PALETTE_ANIMATION = {
  LAVATL: [[246, 9]],
  WATRTL: [[229, 12], [242, 12]],
  CLRRVR: [[183, 12], [195, 6]],
  MUDRVR: [[228, 12], [183, 6], [240, 6]],
  LAVRVR: [[240, 9]],
};

function rotationStepCount(defName) {
  const ranges = PALETTE_ANIMATION[defName.toUpperCase()];
  if (!ranges) return 1;
  const lcm = (a, b) => (a / gcd(a, b)) * b;
  const gcd = (a, b) => (b ? gcd(b, a % b) : a);
  return ranges.reduce((acc, r) => lcm(acc, r[1]), 1);
}

function rotatedPalette(base, ranges, step) {
  if (step <= 0) return base;
  const out = Buffer.from(base);
  for (const [start, len] of ranges) {
    for (let i = 0; i < len; i++) {
      const target = (i + step) % len;
      for (let c = 0; c < 3; c++) out[start * 3 + target * 3 + c] = base[start * 3 + i * 3 + c];
    }
  }
  return out;
}

function blitMode(defName) {
  const n = defName.toUpperCase();
  if (TERRAIN_DEFS.includes(n) || n === 'EDG') return 'opaque';
  if (n.endsWith('RVR') || n.endsWith('RD')) return 'colorKey';
  return 'shadows';
}

const TERRAIN_DEFS = ['DIRTTL', 'SANDTL', 'GRASTL', 'SNOWTL', 'SWMPTL', 'ROUGTL', 'SUBBTL', 'LAVATL', 'WATRTL', 'ROCKTL'];

class DefFile {
  constructor(data) {
    const r = new Reader(data);
    this.type = r.u32();
    this.fullWidth = r.u32();
    this.fullHeight = r.u32();
    const groupsCount = r.u32();
    this.palette = Buffer.from(r.bytes(256 * 3));

    if (groupsCount < 0 || groupsCount > 64) {
      this.blocks = [];
      return;
    }
    const rawGroups = [];
    for (let g = 0; g < groupsCount; g++) {
      const groupType = r.u32();
      const framesCount = r.u32();
      if (framesCount < 0 || framesCount > 100000) {
        rawGroups.push({ offsets: [], legacy: false });
        continue;
      }
      r.skip(8);
      r.skip(framesCount * 13);
      const offsets = [];
      for (let i = 0; i < framesCount; i++) offsets.push(r.u32());

      let legacy = false;
      for (const off of offsets) {
        if (off + 36 <= r.length) {
          const declared = r.buf.readUInt32LE(off);
          if (off + 32 + declared > r.length) { legacy = true; break; }
        } else {
          legacy = true; break;
        }
      }
      rawGroups.push({ offsets, legacy, type: groupType });
    }

    this.blocks = rawGroups.map((group) => {
      const frames = [];
      for (const off of group.offsets) {
        r.seek(off);
        const size = r.u32();
        const compression = r.u32();
        const fw = r.u32();
        const fh = r.u32();
        let w, h, x, y;
        if (group.legacy) {
          w = fw; h = fh; x = 0; y = 0;
        } else {
          w = r.u32(); h = r.u32(); x = r.u32(); y = r.u32();
        }
        if (w <= 0 || h <= 0 || w > 4096 || h > 4096 || x > 4096 || y > 4096) {
          w = fw; h = fh; x = 0; y = 0;
        }
        if (w <= 0 || h <= 0 || w > 4096 || h > 4096) continue;
        const dataOffset = r.pos;
        const indices = decodeFrame(r, dataOffset, compression, w, h, size);
        frames.push({ fullWidth: fw, fullHeight: fh, width: w, height: h, x, y, indices });
      }
      return frames;
    });
  }
}

function decodeFrame(r, dataOffset, compression, width, height, size) {
  const out = Buffer.allocUnsafe(width * height);
  let p = 0;
  const emit = (count, value) => {
    const n = Math.min(count, width * height - p);
    out.fill(value, p, p + n);
    p += n;
  };

  switch (compression) {
    case 0: {
      const raw = r.bytes(width * height);
      raw.copy(out, 0);
      return out;
    }
    case 1: {
      const lineOffsets = [];
      for (let i = 0; i < height; i++) lineOffsets.push(r.u32());
      for (let line = 0; line < height; line++) {
        r.seek(dataOffset + lineOffsets[line]);
        let left = width;
        while (left > 0 && r.pos < r.length) {
          const code = r.u8();
          const len = r.u8() + 1;
          if (code === 0xff) {
            const raw = r.bytes(Math.min(len, left));
            raw.copy(out, p);
            p += raw.length;
          } else {
            emit(Math.min(len, left), code);
          }
          left -= len;
        }
      }
      return out;
    }
    case 2: {
      r.seek(dataOffset + r.buf.readUInt16LE(dataOffset));
      for (let line = 0; line < height; line++) {
        let left = width;
        while (left > 0 && r.pos < r.length) {
          const b = r.u8();
          const code = b >> 5;
          const len = (b & 31) + 1;
          if (code === 7) {
            const raw = r.bytes(Math.min(len, left));
            raw.copy(out, p);
            p += raw.length;
          } else {
            emit(Math.min(len, left), code);
          }
          left -= len;
        }
      }
      return out;
    }
    case 3: {
      const groups = Math.floor((height * width) / 32);
      const lineOffsets = [];
      for (let i = 0; i < groups; i++) lineOffsets.push(r.u16());
      for (let g = 0; g < groups; g++) {
        r.seek(dataOffset + lineOffsets[g]);
        let left = 32;
        while (left > 0 && r.pos < r.length) {
          const b = r.u8();
          const code = b >> 5;
          const len = (b & 31) + 1;
          if (code === 7) {
            const raw = r.bytes(Math.min(len, left));
            raw.copy(out, p);
            p += raw.length;
          } else {
            emit(Math.min(len, left), code);
          }
          left -= len;
        }
      }
      return out;
    }
    default:
      return out;
  }
}

module.exports = { DefFile, PALETTE_ANIMATION, rotationStepCount, rotatedPalette, blitMode, TERRAIN_DEFS };
