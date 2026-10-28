package org.feichao.h3wallpaper.util;

import java.io.EOFException;
import java.io.IOException;
import java.io.InputStream;

/** Little-endian reader for the baked scenes.bin bundle (see android/bake/bake.js). */
public final class BinReader {
    private final byte[] buf;
    private int pos;

    public BinReader(byte[] buf) { this.buf = buf; }

    public int pos() { return pos; }
    public void seek(int p) { pos = p; }
    public int remaining() { return buf.length - pos; }

    private void need(int n) throws EOFException {
        if (pos + n > buf.length) throw new EOFException("scenes.bin truncated at " + pos);
    }

    public int u8() throws IOException { need(1); return buf[pos++] & 0xff; }

    public int u16() throws IOException {
        need(2);
        int v = (buf[pos] & 0xff) | ((buf[pos + 1] & 0xff) << 8);
        pos += 2;
        return v;
    }

    public int i16() throws IOException {
        int v = u16();
        return (short) v;
    }

    public int u32() throws IOException {
        need(4);
        int v = (buf[pos] & 0xff) | ((buf[pos + 1] & 0xff) << 8)
                | ((buf[pos + 2] & 0xff) << 16) | ((buf[pos + 3] & 0xff) << 24);
        pos += 4;
        return v;
    }

    public byte[] bytes(int n) throws IOException {
        need(n);
        byte[] out = new byte[n];
        System.arraycopy(buf, pos, out, 0, n);
        pos += n;
        return out;
    }

    public String str() throws IOException {
        int n = u16();
        return new String(bytes(n), java.nio.charset.StandardCharsets.UTF_8);
    }

    public static byte[] readAll(InputStream in) throws IOException {
        java.io.ByteArrayOutputStream out = new java.io.ByteArrayOutputStream(1 << 20);
        byte[] tmp = new byte[1 << 16];
        int n;
        while ((n = in.read(tmp)) > 0) out.write(tmp, 0, n);
        return out.toByteArray();
    }
}
