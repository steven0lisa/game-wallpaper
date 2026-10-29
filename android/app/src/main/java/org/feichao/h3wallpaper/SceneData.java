package org.feichao.h3wallpaper;

import android.content.res.AssetManager;
import android.util.Log;

import org.feichao.h3wallpaper.util.BinReader;

import java.io.IOException;
import java.io.InputStream;

/**
 * Parsed scenes.bin bundle (v2): global frame table + per-map layer segments
 * behind an offset table. Memory layout is struct-of-arrays (primitive ints)
 * for cheap per-frame iteration.
 *
 * v2 (2026-10-29): 127 maps share one atlas, so the bundle stores map segments
 * at absolute offsets. Only the CURRENT map's layer arrays are materialized —
 * {@link #loadMap} parses one segment and drops the previous map's arrays, so
 * resident heap stays ~one map regardless of how many maps ship in the APK.
 *
 * One "set" = one logical sprite (terrain view / river view / object def) whose
 * entries are its animation or palette-rotation frames. Cell -> setId, frame index
 * chosen at draw time as (animStep + phase) % set.length or animStep % set.length.
 */
public final class SceneData {
    private static final String TAG = "H3WP";
    public static final short NO_FRAME = (short) 0xffff;

    // ---- bundle source (whole bin resident; segments parsed on demand) ----
    private byte[] raw;
    private int[] mapOffsets;
    private int curMap = -1;

    // ---- global frame table (struct of arrays) ----
    public int frameCount;
    public short[] fPage;
    public short[] fX, fY, fW, fH;
    public short[] fOx, fOy, fFw, fFh;

    // ---- sets ----
    public int setCount;
    public short[] setLen;      // per set: frame count
    public short[][] setIds;    // per set: frame ids

    // ---- maps ----
    public int mapCount;
    public String[] mapName;
    public int[] mapSize;
    public int[] mapPageBase, mapPageCount;
    public int[] mapBorderSet;
    // per-map layer cells — only the current map's slot is filled; loadMap()
    // drops the previous slot so heap tracks a single map.
    public int[] tCount;  public int[][] tX, tY, tSid; public byte[][] tFlip;
    public int[] rCount;  public int[][] rX, rY, rSid; public byte[][] rFlip;
    public int[] dCount;  public int[][] dX, dY, dFid; public byte[][] dFlip;
    public int[] oCount;  public int[][] oX, oY, oSid; public int[][] oPhase;
    public short[][] oFw, oFh;

    public int atlasPageSize;

    /** Load + parse the bundle index from assets ("scenes/scenes.bin"). */
    public static SceneData load(AssetManager assets) throws Exception {
        byte[] raw;
        try (InputStream in = assets.open("scenes/scenes.bin")) {
            raw = BinReader.readAll(in);
        }
        SceneData s = new SceneData();
        s.parseIndex(raw);
        return s;
    }

    private void parseIndex(byte[] raw) throws Exception {
        this.raw = raw;
        BinReader r = new BinReader(raw);
        int b0 = r.u8(), b1 = r.u8(), b2 = r.u8(), b3 = r.u8();
        if (b0 != 'H' || b1 != '3' || b2 != 'B' || b3 != '2')
            throw new IOException("bad scenes.bin magic");
        int version = r.u16();
        if (version != 2) throw new IOException("unsupported scenes.bin v" + version);
        mapCount = r.u16();
        atlasPageSize = r.u16();
        r.u16(); // reserved

        frameCount = r.u32();
        fPage = new short[frameCount];
        fX = new short[frameCount]; fY = new short[frameCount];
        fW = new short[frameCount]; fH = new short[frameCount];
        fOx = new short[frameCount]; fOy = new short[frameCount];
        fFw = new short[frameCount]; fFh = new short[frameCount];
        for (int i = 0; i < frameCount; i++) {
            fPage[i] = (short) r.u8();
            fX[i] = (short) r.u16(); fY[i] = (short) r.u16();
            fW[i] = (short) r.u16(); fH[i] = (short) r.u16();
            fOx[i] = (short) r.i16();  fOy[i] = (short) r.i16();
            fFw[i] = (short) r.u16(); fFh[i] = (short) r.u16();
        }

        setCount = r.u32();
        setLen = new short[setCount];
        setIds = new short[setCount][];
        for (int i = 0; i < setCount; i++) {
            int n = r.u16();
            setLen[i] = (short) n;
            short[] ids = new short[n];
            for (int j = 0; j < n; j++) ids[j] = (short) r.u16();
            setIds[i] = ids;
        }

        mapOffsets = new int[mapCount];
        for (int i = 0; i < mapCount; i++) mapOffsets[i] = r.u32();

        mapName = new String[mapCount];
        mapSize = new int[mapCount];
        mapPageBase = new int[mapCount];
        mapPageCount = new int[mapCount];
        mapBorderSet = new int[mapCount];
        tCount = new int[mapCount]; rCount = new int[mapCount];
        dCount = new int[mapCount]; oCount = new int[mapCount];
        tX = new int[mapCount][]; tY = new int[mapCount][]; tSid = new int[mapCount][]; tFlip = new byte[mapCount][];
        rX = new int[mapCount][]; rY = new int[mapCount][]; rSid = new int[mapCount][]; rFlip = new byte[mapCount][];
        dX = new int[mapCount][]; dY = new int[mapCount][]; dFid = new int[mapCount][]; dFlip = new byte[mapCount][];
        oX = new int[mapCount][]; oY = new int[mapCount][]; oSid = new int[mapCount][];
        oPhase = new int[mapCount][]; oFw = new short[mapCount][]; oFh = new short[mapCount][];

        Log.i(TAG, "scenes.bin index parsed: maps=" + mapCount + " frames=" + frameCount
                + " sets=" + setCount + " bytes=" + raw.length);
    }

    /**
     * Materialize one map's layer arrays and drop the previous map's.
     * Returns false (leaving the bundle usable) when the segment is corrupt,
     * so a bad map can be skipped instead of crashing the wallpaper.
     */
    public boolean loadMap(int idx) {
        if (idx == curMap) return true;
        if (idx < 0 || idx >= mapCount) return false;
        releaseMap();
        try {
            BinReader r = new BinReader(raw);
            r.seek(mapOffsets[idx]);
            mapName[idx] = r.str();
            mapSize[idx] = r.u16();
            mapPageBase[idx] = r.u16();
            mapPageCount[idx] = r.u16();
            mapBorderSet[idx] = r.u16();

            int n = r.u32();
            if (n < 0 || n > 4_000_000) throw new IOException("bad terrain count " + n);
            tCount[idx] = n;
            tX[idx] = new int[n]; tY[idx] = new int[n]; tSid[idx] = new int[n]; tFlip[idx] = new byte[n];
            for (int i = 0; i < n; i++) {
                tX[idx][i] = r.u16(); tY[idx][i] = r.u16(); tSid[idx][i] = r.u16(); tFlip[idx][i] = (byte) r.u8();
            }
            n = r.u32();
            if (n < 0 || n > 4_000_000) throw new IOException("bad rivers count " + n);
            rCount[idx] = n;
            rX[idx] = new int[n]; rY[idx] = new int[n]; rSid[idx] = new int[n]; rFlip[idx] = new byte[n];
            for (int i = 0; i < n; i++) {
                rX[idx][i] = r.u16(); rY[idx][i] = r.u16(); rSid[idx][i] = r.u16(); rFlip[idx][i] = (byte) r.u8();
            }
            n = r.u32();
            if (n < 0 || n > 4_000_000) throw new IOException("bad roads count " + n);
            dCount[idx] = n;
            dX[idx] = new int[n]; dY[idx] = new int[n]; dFid[idx] = new int[n]; dFlip[idx] = new byte[n];
            for (int i = 0; i < n; i++) {
                dX[idx][i] = r.u16(); dY[idx][i] = r.u16(); dFid[idx][i] = r.u16(); dFlip[idx][i] = (byte) r.u8();
            }
            n = r.u32();
            if (n < 0 || n > 4_000_000) throw new IOException("bad objects count " + n);
            oCount[idx] = n;
            oX[idx] = new int[n]; oY[idx] = new int[n]; oSid[idx] = new int[n];
            oPhase[idx] = new int[n]; oFw[idx] = new short[n]; oFh[idx] = new short[n];
            for (int i = 0; i < n; i++) {
                oX[idx][i] = r.u16(); oY[idx][i] = r.u16(); oSid[idx][i] = r.u16();
                oPhase[idx][i] = r.u32();
                oFw[idx][i] = (short) r.u16(); oFh[idx][i] = (short) r.u16();
            }
            curMap = idx;
            return true;
        } catch (Exception e) {
            Log.w(TAG, "map segment " + idx + " corrupt — skipping: " + e);
            releaseMap();
            return false;
        }
    }

    /** Drop the current map's layer arrays (map rotation / memory relief). */
    public void releaseMap() {
        if (curMap < 0) return;
        tX[curMap] = null; tY[curMap] = null; tSid[curMap] = null; tFlip[curMap] = null;
        rX[curMap] = null; rY[curMap] = null; rSid[curMap] = null; rFlip[curMap] = null;
        dX[curMap] = null; dY[curMap] = null; dFid[curMap] = null; dFlip[curMap] = null;
        oX[curMap] = null; oY[curMap] = null; oSid[curMap] = null; oPhase[curMap] = null;
        oFw[curMap] = null; oFh[curMap] = null;
        curMap = -1;
    }

    public int currentMap() { return curMap; }
}
