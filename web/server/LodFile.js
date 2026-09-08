'use strict';
// .lod 归档读取（VCMI CArchiveLoader 布局，详见 docs/formats.md §1）。
const fs = require('fs');
const zlib = require('zlib');

class LodFile {
  constructor(path) {
    this.data = fs.readFileSync(path);
    if (this.data.length < 0x60 || this.data.toString('latin1', 0, 3) !== 'LOD') {
      throw new Error('not a LOD archive: ' + path);
    }
    this.count = this.data.readUInt32LE(8);
    this.entries = new Map(); // UPPER(NAME.DEF) -> {offset,size,compressedSize}
    let pos = 0x5c;
    for (let i = 0; i < this.count; i++) {
      const nameEnd = this.data.indexOf(0, pos);
      const name = this.data.toString('latin1', pos, nameEnd < 0 || nameEnd > pos + 16 ? pos + 16 : nameEnd);
      const offset = this.data.readUInt32LE(pos + 16);
      const size = this.data.readUInt32LE(pos + 20);
      const compressedSize = this.data.readUInt32LE(pos + 28);
      if (name) this.entries.set(name.toUpperCase(), { name, offset, size, compressedSize });
      pos += 32;
    }
  }

  entry(name) {
    return this.entries.get(name.toUpperCase());
  }

  contents(name) {
    const e = typeof name === 'string' ? this.entry(name) : name;
    if (!e) return null;
    if (e.compressedSize > 0) {
      const slice = this.data.subarray(e.offset, e.offset + e.compressedSize);
      // LOD 条目是 raw deflate（无 zlib 头）；若检测到 zlib 头则按 zlib 解。
      const body = slice[0] === 0x78 ? slice : slice; // zlib.inflateSync 对 raw 需要手剥
      try {
        return zlib.inflateRawSync(body);
      } catch {
        try {
          return zlib.inflateSync(body);
        } catch {
          return null;
        }
      }
    }
    return this.data.subarray(e.offset, e.offset + e.size);
  }
}

module.exports = { LodFile };
