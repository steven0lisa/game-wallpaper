'use strict';
// .h3m 地图解析 — 移植自 Swift H3mFile.swift（对象 payload 全表见 docs/formats.md §3.4）。
const zlib = require('zlib');
const fs = require('fs');
const { Reader } = require('./Reader');

class H3mFile {
  constructor(path) {
    const gz = fs.readFileSync(path);
    let raw;
    if (gz[0] === 0x1f && gz[1] === 0x8b) {
      raw = zlib.gunzipSync(gz);
    } else {
      raw = gz;
    }
    const r = new Reader(raw);

    const v = r.i32();
    if (v !== 14 && v !== 21 && v !== 28 && v !== 29) throw new Error('unsupported h3m version: ' + v);
    this.version = v === 14 ? 'roe' : v === 21 ? 'ab' : 'sod';
    const roe = this.version === 'roe';
    const ab = this.version === 'ab';
    const sod = this.version === 'sod';

    // ---- header ----
    r.u8();                       // hasPlayers
    this.size = r.u32();
    this.hasUnderground = r.u8() === 1;
    this.title = r.string32();
    r.string32();                 // description
    r.u8();                       // difficulty
    if (!roe) r.u8();
    this.readPlayerInfo(r);
    this.readVictoryLoss(r);
    if (r.u8() > 0) r.skip(8);    // teams
    r.skip(roe ? 16 : 20);        // allowed heroes bitmask
    if (!roe) r.skip(r.u32());    // placeholder heroes garbage
    if (sod) {
      let n = r.u8();
      while (n-- > 0) { r.skip(2); r.string32(); r.skip(1); }
    }
    r.skip(31);
    if (!roe) r.skip(ab ? 17 : 18); // allowed artifacts
    if (sod) { r.skip(9); r.skip(4); } // spells + skills
    let rumors = r.u32();
    while (rumors-- > 0) { r.string32(); r.string32(); }
    if (sod) {
      for (let i = 0; i < 156; i++) {
        if (r.u8() === 1) {
          if (r.u8() === 1) r.u32();
          if (r.u8() === 1) { let n = r.u32(); while (n-- > 0) r.skip(2); }
          this.readArtifactsOfHero(r);
          if (r.u8() === 1) r.string32();
          r.u8();
          if (r.u8() === 1) r.skip(9);
          if (r.u8() === 1) r.skip(4);
        }
      }
    }

    // ---- terrain ----
    const levels = this.hasUnderground ? 2 : 1;
    this.tiles = new Array(this.size * this.size * levels);
    for (let i = 0; i < this.tiles.length; i++) {
      this.tiles[i] = {
        terrain: r.u8(), terView: r.u8(),
        river: r.u8(), riverDir: r.u8(),
        road: r.u8(), roadDir: r.u8(),
        flags: r.u8(),
      };
    }

    // ---- def table ----
    let defCount = r.u32();
    this.defs = [];
    while (defCount-- > 0) {
      const spriteName = r.string32();
      r.u32(); r.u16();   // passable
      r.u32(); r.u16();   // active
      const terrainType = r.u16();
      const terrainGroup = r.u16();
      const objectId = r.u32();
      const subId = r.u32();
      const objectsGroup = r.u8();
      const placementOrder = r.u8();
      r.skip(16);
      this.defs.push({ spriteName, terrainType, terrainGroup, objectId, subId, objectsGroup, placementOrder });
    }

    // ---- objects ----
    let objectCount = r.u32();
    this.objects = [];
    while (objectCount-- > 0) {
      const x = r.u8(), y = r.u8(), z = r.u8();
      const defIndex = r.u32();
      r.skip(5);
      if (defIndex < 0 || defIndex >= this.defs.length) continue;
      const def = this.defs[defIndex];
      this.skipObjectPayload(r, def.objectId);
      this.objects.push({ x, y, z, defIndex, def });
    }
  }

  tile(x, y, level) {
    if (x < 0 || y < 0 || x >= this.size || y >= this.size) return null;
    const levels = this.hasUnderground ? 2 : 1;
    if (level < 0 || level >= levels) return null;
    return this.tiles[level * this.size * this.size + y * this.size + x];
  }

  readPlayerInfo(r) {
    const roe = this.version === 'roe', sod = this.version === 'sod';
    for (let i = 0; i < 8; i++) {
      const human = r.u8() === 1;
      const ai = r.u8() === 1;
      if (!human && !ai) {
        if (sod) r.skip(13);
        else if (this.version === 'ab') r.skip(12);
        else r.skip(6);
      } else {
        r.u8();
        if (sod) r.u8();
        r.u8();
        if (!roe) r.u8();
        r.u8();
        if (r.u8() === 1) { // hasMainTown
          if (!roe) { r.u8(); r.u8(); }
          r.skip(3);
        }
        r.u8();
        if (r.u8() !== 255) { r.u8(); r.string32(); }
        if (!roe) {
          r.u8();
          let n = r.u32();
          while (n-- > 0) { r.skip(1); r.string32(); }
        }
      }
    }
  }

  readVictoryLoss(r) {
    const roe = this.version === 'roe';
    const victory = r.u8();
    if (victory !== 255) r.skip(2);
    if (victory !== 10) {
      switch (victory) {
        case 0: r.skip(1); if (!roe) r.skip(1); break;
        case 1: r.skip(1); if (!roe) r.skip(1); r.skip(4); break;
        case 2: r.skip(1); r.skip(4); break;
        case 3: r.skip(5); break;
        case 4: case 5: case 6: case 7: r.skip(3); break;
      }
    } else {
      r.skip(1); r.skip(3);
    }
    const loss = r.u8();
    if (loss === 0 || loss === 1) r.skip(3);
    else if (loss === 2) r.skip(2);
  }

  readArtifactSlot(r) {
    if (this.version === 'roe') r.u8(); else r.u16();
  }

  readArtifactsOfHero(r) {
    const roe = this.version === 'roe', sod = this.version === 'sod';
    if (r.u8() === 1) {
      for (let i = 0; i <= 15; i++) this.readArtifactSlot(r);
      if (sod) this.readArtifactSlot(r);
      this.readArtifactSlot(r);
      if (!roe) this.readArtifactSlot(r); else r.u8();
      let n = r.u16();
      while (n-- > 0) this.readArtifactSlot(r);
    }
  }

  readCreatureSet(r, count) {
    const roe = this.version === 'roe';
    let n = count;
    while (n-- > 0) {
      r.skip(roe ? 1 : 2);
      r.skip(2);
    }
  }

  readMessageAndGuards(r) {
    if (r.u8() === 1) {
      r.string32();
      if (r.u8() === 1) this.readCreatureSet(r, 7);
      r.skip(4);
    }
  }

  readResources(r) { for (let i = 0; i < 7; i++) r.u32(); }

  readQuest(r, missionType) {
    switch (missionType) {
      case 0: return;
      case 1: case 2: case 3: case 4: r.skip(4); break;
      case 5: r.skip(r.u8() * 2); break;
      case 6: r.skip(r.u8() * 4); break;
      case 7: r.skip(28); break;
      case 8: case 9: r.skip(1); break;
    }
    r.skip(4);
    r.string32(); r.string32(); r.string32();
  }

  skipObjectPayload(r, id) {
    const roe = this.version === 'roe';
    switch (id) {
      case 26: // event
        this.readMessageAndGuards(r);
        r.skip(4); r.skip(4); r.skip(1); r.skip(1);
        this.readResources(r);
        r.skip(4);
        r.skip(r.u8() * 2);
        r.skip(r.u8() * (roe ? 1 : 2));
        r.skip(r.u8());
        this.readCreatureSet(r, r.u8());
        r.skip(8);
        r.skip(1); r.skip(1); r.skip(1);
        r.skip(4);
        break;
      case 34: case 70: case 62: this.readHero(r); break;
      case 54: case 71: case 72: case 73: case 74: case 75:
      case 162: case 163: case 164: this.readMonster(r); break;
      case 59: case 91: r.string32(); r.skip(4); break; // bottle/sign
      case 83: { // seer hut
        let hasQuest = true;
        if (!roe) {
          this.readQuest(r, r.u8());
        } else {
          hasQuest = r.u8() !== 255;
        }
        if (hasQuest) {
          const reward = r.u8();
          if (reward === 1 || reward === 2) r.u32();
          else if (reward === 3 || reward === 4) r.u8();
          else if (reward === 5) { r.u8(); r.u32(); }
          else if (reward === 6 || reward === 7) { r.u8(); r.u8(); }
          else if (reward === 8) { if (roe) r.u8(); else r.u16(); }
          else if (reward === 9) r.u8();
          else if (reward === 10) r.skip(roe ? 3 : 4);
          r.skip(2);
        } else {
          r.skip(3);
        }
        break;
      }
      case 113: if (!roe) r.skip(4); break; // witch hut
      case 81: r.skip(2); r.skip(6); break; // scholar
      case 33: case 219: // garrison
        r.skip(1); r.skip(3);
        this.readCreatureSet(r, 7);
        if (!roe) r.u8();
        r.skip(8);
        break;
      case 5: case 65: case 66: case 67: case 68: case 69: case 93: // artifacts + scroll
        this.readMessageAndGuards(r);
        if (id === 93) r.u32();
        break;
      case 76: case 79: // resources
        this.readMessageAndGuards(r);
        r.u32(); r.skip(4);
        break;
      case 77: case 98: this.readTown(r); break;
      case 53: case 220: case 88: case 89: case 90: case 87: case 42: case 36:
      case 17: case 18: case 19: case 20: r.skip(4); break;
      case 6: // pandora
        this.readMessageAndGuards(r);
        r.skip(4); r.skip(4); r.skip(1); r.skip(1);
        this.readResources(r);
        r.skip(4);
        r.skip(r.u8() * 2);
        r.skip(r.u8() * (roe ? 1 : 2));
        r.skip(r.u8());
        this.readCreatureSet(r, r.u8());
        r.skip(8);
        break;
      case 216: case 217: case 218: { // random dwellings
        r.skip(4);
        if (id === 216 || id === 217) {
          if (r.u32() === 0) r.u16();
        }
        if (id === 216 || id === 218) { r.u8(); r.u8(); }
        break;
      }
      case 215: this.readQuest(r, r.u8()); break; // quest guard
      case 214: r.u8(); if (r.u8() === 255) r.skip(1); break; // hero placeholder
      default: break;
    }
  }

  readHero(r) {
    const roe = this.version === 'roe', ab = this.version === 'ab';
    if (!roe) r.skip(4);
    r.skip(1); r.skip(1);
    if (r.u8() === 1) r.string32();
    if (!roe && !ab) { if (r.u8() === 1) r.u32(); } else r.u32();
    if (r.u8() === 1) r.u8();
    if (r.u8() === 1) r.skip(r.u32() * 2);
    if (r.u8() === 1) this.readCreatureSet(r, 7);
    r.u8();
    this.readArtifactsOfHero(r);
    r.u8();
    if (!roe) {
      if (r.u8() === 1) r.string32();
      r.u8();
    }
    if (!roe && !ab) { if (r.u8() === 1) r.skip(9); }
    else if (ab) r.skip(1);
    if (!roe && !ab && r.u8() === 1) r.skip(4);
    r.skip(16);
  }

  readMonster(r) {
    const roe = this.version === 'roe';
    if (!roe) r.skip(4);
    r.u16(); r.u8();
    if (r.u8() === 1) {
      r.string32();
      this.readResources(r);
      if (roe) r.u8(); else r.u16();
    }
    r.u8(); r.u8();
    r.skip(2);
  }

  readTown(r) {
    const roe = this.version === 'roe', ab = this.version === 'ab', sod = this.version === 'sod';
    if (!roe) r.u32();
    r.u8();
    if (r.u8() === 1) r.string32();
    if (r.u8() === 1) this.readCreatureSet(r, 7);
    r.u8();
    if (r.u8() === 1) { r.skip(6); r.skip(6); } else r.u8();
    if (!roe) r.skip(9);
    r.skip(9);
    let n = r.u32();
    while (n-- > 0) {
      r.string32(); r.string32();
      this.readResources(r);
      r.u8();
      if (sod) r.u8();
      r.skip(1); r.skip(2); r.skip(1);
      r.skip(17); r.skip(6); r.skip(14); r.skip(4);
    }
    if (!roe && !ab) r.skip(1);
    r.skip(3);
  }
}

module.exports = { H3mFile };
