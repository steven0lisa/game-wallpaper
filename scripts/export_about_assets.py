#!/usr/bin/env python3
"""Exports About-window assets (angel logo animation + heroes3 dialog border + OK
button) from H3sprite.lod so the packaged app is self-contained (no vcmi needed at
runtime for the About window).

Mirrors the project's Swift DefFile decoder (Sources/Heroes3Wallpaper/DefFile.swift):
  - DEF header is [type u32][fullWidth u32][fullHeight u32][blockCount u32][palette 768]
  - block table: [blockID u32][totalEntries u32][unknown 8][frameNames 13*totalEntries]
                 [frameOffsets u32*totalEntries]
  - frame header (at frame offset): [size u32][format u32][fullWidth u32][fullHeight u32]
                 [width u32][height u32][leftMargin u32][topMargin u32][data...]
  - palette indices: 0 = transparent, 1 = 25% shadow, 4 = 50% shadow (rendered as
    translucent black), else opaque palette color.

Usage:
  python3 scripts/export_about_assets.py <H3sprite.lod> <output_dir>
"""
import struct
import sys
import zlib
import os


def u32(data, off):
    return struct.unpack_from("<I", data, off)[0]


def u16(data, off):
    return struct.unpack_from("<H", data, off)[0]


def parse_lod(path):
    with open(path, "rb") as f:
        data = f.read()
    if data[:3] != b"LOD":
        raise SystemExit("not a LOD file: " + path)
    count = u32(data, 8)
    entries = {}
    pos = 0x5C
    for _ in range(count):
        if pos + 32 > len(data):
            break
        name = data[pos:pos + 16].split(b"\x00")[0].decode("latin1")
        offset = u32(data, pos + 16)
        size = u32(data, pos + 20)
        unused = u32(data, pos + 24)
        compressed = u32(data, pos + 28)
        entries[name.upper()] = (offset, size, compressed)
        pos += 32
    return data, entries


def inflate(raw, out_size):
    # The lod stores zlib streams with a 2-byte RFC1950 header (e.g. 0x78 0x9c).
    # Python zlib.decompress expects that header, so use it directly. (Swift's
    # COMPRESSION_ZLIB wants a headerless deflate stream, hence its "strip 2 bytes",
    # but here we decode with Python zlib which wants the header present.)
    try:
        return zlib.decompress(bytes(raw))
    except Exception:
        return b""


def lod_contents(data, entry):
    offset, size, compressed = entry
    span = max(compressed, size)
    if offset + span > len(data):
        return b""
    raw = data[offset:offset + span]
    if compressed > 0:
        return inflate(raw, size)
    return raw


class DefBlock:
    pass


class DefFile:
    def __init__(self, blob):
        self.type = u32(blob, 0)
        self.full_width = u32(blob, 4)
        self.full_height = u32(blob, 8)
        groups_count = u32(blob, 12)
        self.palette = bytearray(blob[16:16 + 768])
        r = 16 + 768
        # Guard against corrupt counts (mirrors Swift DefFile).
        if groups_count < 0 or groups_count > 64:
            groups_count = 0
        raw_groups = []
        for _ in range(groups_count):
            group_type = u32(blob, r); r += 4
            frames_count = u32(blob, r); r += 4
            if frames_count < 0 or frames_count > 100_000:
                frames_count = 0
            r += 8  # unknown[8]
            r += frames_count * 13  # frameNames[13*totalEntries]
            offsets = []
            for _ in range(frames_count):
                offsets.append(u32(blob, r)); r += 4
            # Legacy heuristic: a frame whose header would run past the end of data.
            legacy = False
            for off in offsets:
                if off + 36 <= len(blob):
                    declared = u32(blob, off)
                    if off + 32 + declared > len(blob):
                        legacy = True
                        break
                else:
                    legacy = True
                    break
            raw_groups.append((group_type, offsets, legacy))
        self.blocks = []
        for group_type, offsets, legacy in raw_groups:
            frames = []
            for off in offsets:
                frames.append(self._parse_frame(blob, off, legacy))
            self.blocks.append(frames)

    def _parse_frame(self, blob, off, legacy):
        size = u32(blob, off)
        fmt = u32(blob, off + 4)
        fw = u32(blob, off + 8)
        fh = u32(blob, off + 12)
        if legacy:
            w, h, x, y = fw, fh, 0, 0
        else:
            w = u32(blob, off + 16)
            h = u32(blob, off + 20)
            x = u32(blob, off + 24)
            y = u32(blob, off + 28)
        if w <= 0 or h <= 0 or w > 4096 or h > 4096 or x > 4096 or y > 4096:
            w, h, x, y = fw, fh, 0, 0
        data_off = off + 32
        indices = self._decode_frame(blob, data_off, fmt, w, h, size)
        return {"w": w, "h": h, "x": x, "y": y, "fw": fw, "fh": fh, "indices": indices,
                "data_off": data_off, "fmt": fmt}

    def _decode_frame(self, blob, off, fmt, w, h, size):
        """Mirrors DefFile.decodeFrame (Swift) exactly — that is the verified decoder."""
        out = []
        if fmt == 0:
            return list(blob[off:off + w * h])

        if fmt == 1:
            # Line offsets: u32 array (one per row), relative to dataOffset.
            line_offsets = [u32(blob, off + i * 4) for i in range(h)]
            for line in range(h):
                lptr = off + line_offsets[line]
                left = w
                while left > 0 and lptr < len(blob):
                    code = blob[lptr]; lptr += 1
                    length = blob[lptr] + 1; lptr += 1
                    n = min(length, left)
                    if code == 0xFF:
                        out.extend(list(blob[lptr:lptr + n]))
                        lptr += n
                    else:
                        out.extend([code] * n)
                    left -= n
            return out[:w * h]

        if fmt == 2:
            # Line offsets: u16 array (one per row), data segments use 3-bit code.
            line_offsets = [u16(blob, off + i * 2) for i in range(h)]
            for line in range(h):
                lptr = off + line_offsets[line]
                left = w
                while left > 0 and lptr < len(blob):
                    b = blob[lptr]; lptr += 1
                    code = b >> 5
                    n = min((b & 31) + 1, left)
                    if code == 7:
                        out.extend(list(blob[lptr:lptr + n]))
                        lptr += n
                    else:
                        out.extend([code] * n)
                    left -= n
            return out[:w * h]

        if fmt == 3:
            # Group offsets: u16 array of length (w*h)/32; each group decodes 32 px.
            groups = (h * w) // 32
            line_offsets = [u16(blob, off + i * 2) for i in range(max(groups, 0))]
            for g in range(max(groups, 0)):
                lptr = off + line_offsets[g]
                left = 32
                while left > 0 and lptr < len(blob):
                    b = blob[lptr]; lptr += 1
                    code = b >> 5
                    n = min((b & 31) + 1, left)
                    if code == 7:
                        out.extend(list(blob[lptr:lptr + n]))
                        lptr += n
                    else:
                        out.extend([code] * n)
                    left -= n
            return out[:w * h]

        return []


def frame_to_rgba(fr, palette, blit="shadows"):
    """Convert a palette-indexed frame to premultiplied-ish RGBA using hero3 semantics.

    blit="colorKey": index 0 = transparent color key (VCMI EImageBlitMode::COLORKEY) —
    used by DIALGBOX/IOKAY32 UI sprites. Without this, palette[0] (cyan 0,255,255 in
    DIALGBOX) paints opaque and the About interior becomes a cyan grid.
    blit="shadows": indices 1/4 (+7/6) are translucent-black shadows (unit sprites).
    """
    w, h = fr["w"], fr["h"]
    indices = fr["indices"]
    out = bytearray(w * h * 4)
    p = 0
    for idx in indices[: w * h]:
        pi = idx * 3
        r = palette[pi] if pi + 2 < len(palette) else 0
        g = palette[pi + 1] if pi + 2 < len(palette) else 0
        b = palette[pi + 2] if pi + 2 < len(palette) else 0
        a = 255
        if blit == "colorKey":
            if idx == 0:
                a = 0
        elif blit == "shadows":
            if idx == 0:
                a = 0
            elif idx in (1, 7):
                r = g = b = 0; a = 64
            elif idx in (2, 3):
                a = 0
            elif idx in (4, 6):
                r = g = b = 0; a = 128
            elif idx == 5:
                r, g, b, a = 128, 128, 128, 255
        if a != 255:
            r = (r * a + 127) // 255
            g = (g * a + 127) // 255
            b = (b * a + 127) // 255
        out[p] = r; out[p + 1] = g; out[p + 2] = b; out[p + 3] = a
        p += 4
    return bytes(out)


def h3pcx_to_rgba(blob):
    """Decode an H3-style PCX (CBitmapHandler::loadH3PCX layout):
    header 12 bytes = [fSize u32][width u32][height u32]; raw 8-bit indices at 0xC;
    last 768 bytes = 256-color BGR palette. Index 0 is the color key (transparent).
    """
    fsize, w, h = struct.unpack_from("<3I", blob, 0)
    if fsize != w * h and fsize != w * h * 3:
        raise SystemExit(f"not an H3 PCX: fsize={fsize} {w}x{h}")
    pal_off = len(blob) - 768
    out = bytearray(w * h * 4)
    p = 0
    for y in range(h):
        row = 0xC + y * w * (3 if fsize == w * h * 3 else 1)
        for x in range(w):
            if fsize == w * h * 3:  # 24-bit: RGB triplets
                q = row + x * 3
                r, g, b = blob[q], blob[q + 1], blob[q + 2]
                out[p] = r; out[p + 1] = g; out[p + 2] = b; out[p + 3] = 255
            else:
                idx = blob[row + x]
                if idx == 0:
                    out[p + 3] = 0
                else:
                    q = pal_off + idx * 3
                    out[p] = blob[q]; out[p + 1] = blob[q + 1]
                    out[p + 2] = blob[q + 2]; out[p + 3] = 255
            p += 4
    return w, h, bytes(out)


def write_png(path, w, h, rgba):
    import struct as st
    def chunk(typ, data):
        c = st.pack(">I", len(data)) + typ + data
        crc = zlib.crc32(typ + data) & 0xFFFFFFFF
        return c + st.pack(">I", crc)
    # PNG: 8-bit RGBA, no interlace. Every scanline must be prefixed with a
    # filter-type byte (0x00 = None). Without it PNG/AppKit decoders reject the
    # data stream (black/blank views in the About window).
    sig = b"\x89PNG\r\n\x1a\n"
    ihdr = st.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)
    stride = w * 4
    filtered = bytearray()
    for row in range(h):
        filtered.append(0)                    # filter type: None
        filtered += rgba[row * stride:(row + 1) * stride]
    idat = zlib.compress(bytes(filtered), 9)
    with open(path, "wb") as f:
        f.write(sig + chunk(b"IHDR", ihdr) + chunk(b"IDAT", idat) + chunk(b"IEND", b""))


def main():
    if len(sys.argv) < 3:
        raise SystemExit("usage: export_about_assets.py <H3sprite.lod> <output_dir>")
    lod_path, out_dir = sys.argv[1], sys.argv[2]
    os.makedirs(out_dir, exist_ok=True)
    data, entries = parse_lod(lod_path)

    def get_def(name):
        entry = entries.get(name.upper())
        if not entry:
            print("  MISSING lod entry:", name)
            return None
        blob = lod_contents(data, entry)
        if not blob:
            print("  EMPTY:", name)
            return None
        try:
            return DefFile(blob)
        except Exception as e:
            print("  DEF FAIL:", name, e)
            return None

    # 1) Angel logo: cangel.def block 0 (idle standing animation, 7 frames)
    logo = get_def("cangel.def")
    if logo and logo.blocks:
        frames = logo.blocks[0]
        n = len(frames)
        print(f"  cangel.def block0: {n} frames")
        # Find tight bounding box across all frames for a consistent crop.
        minx = min(f["x"] for f in frames); miny = min(f["y"] for f in frames)
        maxx = max(f["x"] + f["w"] for f in frames); maxy = max(f["y"] + f["h"] for f in frames)
        crop_w = maxx - minx; crop_h = maxy - miny
        for i, fr in enumerate(frames):
            rgba = frame_to_rgba(fr, logo.palette, "shadows")
            # Crop to the tight union bbox: compose each frame into (crop_w x crop_h).
            canvas = bytearray(crop_w * crop_h * 4)
            ox = fr["x"] - minx; oy = fr["y"] - miny
            for row in range(fr["h"]):
                src = (row * fr["w"]) * 4
                dst = ((oy + row) * crop_w + ox) * 4
                canvas[dst:dst + fr["w"] * 4] = rgba[src:src + fr["w"] * 4]
            write_png(os.path.join(out_dir, f"logo_{i}.png"), crop_w, crop_h, bytes(canvas))
        print(f"  wrote logo_0..{n-1}.png ({crop_w}x{crop_h})")

    # 2) Dialog border: DIALGBOX.def block 0 (11 frames, each 64x64)
    dlg = get_def("DIALGBOX.def")
    if dlg and dlg.blocks:
        frames = dlg.blocks[0]
        print(f"  DIALGBOX.def block0: {len(frames)} frames")
        for i, fr in enumerate(frames):
            rgba = frame_to_rgba(fr, dlg.palette, "colorKey")
            write_png(os.path.join(out_dir, f"dialogbox_{i}.png"), fr["w"], fr["h"], rgba)
        print(f"  wrote dialogbox_0..{len(frames)-1}.png")

    # 3) OK button: IOKAY32.def block 0 (4 frames)
    ok = get_def("IOKAY32.def")
    if ok and ok.blocks:
        frames = ok.blocks[0]
        print(f"  IOKAY32.def block0: {len(frames)} frames")
        for i, fr in enumerate(frames):
            rgba = frame_to_rgba(fr, ok.palette, "colorKey")
            write_png(os.path.join(out_dir, f"iokay32_{i}.png"), fr["w"], fr["h"], rgba)
        print(f"  wrote iokay32_0..{len(frames)-1}.png")

    # 4) Dialog interior background: DIBOXBCK.PCX from H3bitmap.lod (VCMI CFilledTexture
    # tiles this brown paper texture inside CInfoWindow; drawBorder only draws the border).
    bitmap_lod = os.path.join(os.path.dirname(lod_path), "H3bitmap.lod")
    if os.path.isfile(bitmap_lod):
        bdata, bentries = parse_lod(bitmap_lod)
        entry = bentries.get("DIBOXBCK.PCX")
        if entry:
            blob = lod_contents(bdata, entry)
            w, h, rgba = h3pcx_to_rgba(blob)
            write_png(os.path.join(out_dir, "background.png"), w, h, rgba)
            print(f"  DIBOXBCK.PCX: wrote background.png ({w}x{h})")
        else:
            print("  MISSING lod entry: DIBOXBCK.PCX")
    else:
        print("  no H3bitmap.lod next to sprite lod, skip background")

    print("done ->", out_dir)


if __name__ == "__main__":
    main()
