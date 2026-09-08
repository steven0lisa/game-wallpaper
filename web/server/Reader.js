'use strict';
// HoMM3 二进制读取器 — 与 Swift 版 Reader.swift 同语义（小端、u32 长度前缀字符串）。
class Reader {
  constructor(buf) {
    this.buf = buf;
    this.pos = 0;
  }
  get length() { return this.buf.length; }
  seek(p) { this.pos = Math.max(0, Math.min(p, this.buf.length)); }
  skip(n) { this.pos += n; }
  u8() { return this.pos < this.buf.length ? this.buf[this.pos++] : 0; }
  u16() {
    const v = (this.buf[this.pos] | (this.buf[this.pos + 1] << 8)) & 0xffff;
    this.pos += 2;
    return v;
  }
  u32() {
    const b = this.buf;
    let v = (b[this.pos] | (b[this.pos + 1] << 8) | (b[this.pos + 2] << 16)) >>> 0;
    v = (v + b[this.pos + 3] * 0x1000000) >>> 0;
    this.pos += 4;
    return v;
  }
  i32() { return this.u32() | 0; }
  bytes(n) {
    const end = Math.min(this.pos + n, this.buf.length);
    const out = this.buf.subarray(this.pos, Math.max(this.pos, end));
    this.pos += n;
    return out;
  }
  string32() {
    const len = this.u32();
    return this.fixedString(len);
  }
  fixedString(n) {
    const raw = this.bytes(n);
    let end = raw.indexOf(0);
    if (end < 0) end = raw.length;
    return Buffer.from(raw.subarray(0, end)).toString('utf8');
  }
}

module.exports = { Reader };
