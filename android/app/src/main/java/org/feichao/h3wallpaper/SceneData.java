package org.feichao.h3wallpaper;

import android.content.res.AssetManager;
import android.util.Log;

import org.feichao.h3wallpaper.util.BinReader;

import java.io.InputStream;

/**
 * Parsed scenes.bin bundle: per-map layers + a global frame table.
 * Memory layout is struct-of-arrays (primitive ints) for cheap per-frame iteration.
 *
 * One "set" = one logical sprite (terrain view / river view / object def) whose
 * entries are its animation or palette-rotation frames. Cell -> setId, frame index
 * chosen at draw time as (animStep + phase) % set.length or animStep % set.length.
 */
public final class SceneData {
    private static final String TAG = "H3WP";
    public static final short NO_FRAME = (short) 0xffff;

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
    // per-map layer cells (struct-of-arrays per map): x,y,setId,flip
    public int[] tCount;  public int[][] tX, tY, tSid; public byte[][] tFlip;
    public int[] rCount;  public int[][] rX, rY, rSid; public byte[][] rFlip;
    public int[] dCount;  public int[][] dX, dY, dFid; public byte[][] dFlip;
    public int[] oCount;  public int[][] oX, oY, oSid; public int[][] oPhase;
    public short[][] oFw, oFh;

    public int atlasPageSize;

    /** Load + parse the bundle from assets ("scenes.bin"). */
    public static SceneData load(AssetManager assets) throws Exception {
        byte[] raw;
        try (InputStream in = assets.open("scenes/scenes.bin")) {
            raw = BinReader.readAll(in);
        }
        SceneData s = new SceneData();
        s.parse(raw);
        return s;
    }

    private void parse(byte[] raw) throws Exception {
        BinReader r = new BinReader(raw);
        if (r.u8() != 'H' || r.u8() != '3' || r.u8() != 'B' || r.u8() != '1')
            throw new java.io.IOException("bad scenes.bin magic");
        int version = r.u16();
        if (version != 1) throw new java.io.IOException("unsupported scenes.bin v" + version);
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

        for (int m = 0; m < mapCount; m++) {
            mapName[m] = r.str();
            mapSize[m] = r.u16();
            mapPageBase[m] = r.u16();
            mapPageCount[m] = r.u16();
            mapBorderSet[m] = r.u16();

            int n = r.u32();
            tCount[m] = n;
            tX[m] = new int[n]; tY[m] = new int[n]; tSid[m] = new int[n]; tFlip[m] = new byte[n];
            for (int i = 0; i < n; i++) {
                tX[m][i] = r.u16(); tY[m][i] = r.u16(); tSid[m][i] = r.u16(); tFlip[m][i] = (byte) r.u8();
            }
            n = r.u32();
            rCount[m] = n;
            rX[m] = new int[n]; rY[m] = new int[n]; rSid[m] = new int[n]; rFlip[m] = new byte[n];
            for (int i = 0; i < n; i++) {
                rX[m][i] = r.u16(); rY[m][i] = r.u16(); rSid[m][i] = r.u16(); rFlip[m][i] = (byte) r.u8();
            }
            n = r.u32();
            dCount[m] = n;
            dX[m] = new int[n]; dY[m] = new int[n]; dFid[m] = new int[n]; dFlip[m] = new byte[n];
            for (int i = 0; i < n; i++) {
                dX[m][i] = r.u16(); dY[m][i] = r.u16(); dFid[m][i] = r.u16(); dFlip[m][i] = (byte) r.u8();
            }
            n = r.u32();
            oCount[m] = n;
            oX[m] = new int[n]; oY[m] = new int[n]; oSid[m] = new int[n];
            oPhase[m] = new int[n]; oFw[m] = new short[n]; oFh[m] = new short[n];
            for (int i = 0; i < n; i++) {
                oX[m][i] = r.u16(); oY[m][i] = r.u16(); oSid[m][i] = r.u16();
                oPhase[m][i] = r.u32();
                oFw[m][i] = (short) r.u16(); oFh[m][i] = (short) r.u16();
            }
        }
        Log.i(TAG, "scenes.bin parsed: maps=" + mapCount + " frames=" + frameCount
                + " sets=" + setCount + " bytes=" + raw.length);
    }
}
