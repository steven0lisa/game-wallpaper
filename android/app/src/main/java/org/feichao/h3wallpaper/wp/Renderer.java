package org.feichao.h3wallpaper.wp;

import android.content.res.AssetManager;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.opengl.EGL14;
import android.opengl.GLES20;
import android.opengl.GLUtils;
import android.util.Log;

import org.feichao.h3wallpaper.SceneData;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.FloatBuffer;

/**
 * GLES2 renderer — line-by-line port of web/public/viewer.js semantics:
 * border → terrain → rivers → roads (VCMI half-tile crop) → objects (painter order).
 *
 * Battery model (the core design):
 *   - Only the visible region (~411x914 world px at density zoom) is ever drawn;
 *   - Redraws happen ON DEMAND: at the next 180ms animation-step boundary while
 *     dwelling (≈5.5fps, the minimum to play sprite animation), at ~30fps only
 *     while the camera glides, once per surface/pause event otherwise, and never
 *     while invisible/paused (frozen 0fps — the last frame stays on screen).
 */
public final class Renderer {
    private static final String TAG = "H3WP";
    static final int TILE = 32;

    private final AssetManager assets;
    private SceneData sc;
    private int mapIndex = -1;

    // GL program
    private int program, aPos, aUv, uProj, uTex, uTint;

    // per-map atlas textures, indexed by (globalPage - pageBase)
    private int[] pageTex = new int[0];
    private int pageBase, pageCount;
    private int glEpoch; // bumped on every initGl so context loss forces a re-upload

    // interleaved quad: pos.xy, uv.xy (4 verts, triangle strip)
    private final FloatBuffer quad = ByteBuffer
            .allocateDirect(4 * 4 * 4 * 4).order(ByteOrder.nativeOrder()).asFloatBuffer();
    private final float[] proj = new float[16];
    private final float[] tint = {0f}; // brightness dim 0..0.6, default 0 (never darkens)

    // view state (world px)
    private float viewLeft, viewTop, viewW, viewH;
    private float zoomPref = 3.5f; // screen px per world px (density ≈ original's DPI scale)
    private float zoom = 3.5f;
    private int screenW, screenH;
    private int animStep;
    private int[] roadIndex; // y*size+x -> road cell index, -1

    public Renderer(AssetManager assets) { this.assets = assets; }

    // ------------------------------------------------------------------ GL init
    private static int compile(int type, String src) {
        int h = GLES20.glCreateShader(type);
        GLES20.glShaderSource(h, src);
        GLES20.glCompileShader(h);
        int[] st = new int[1];
        GLES20.glGetShaderiv(h, GLES20.GL_COMPILE_STATUS, st, 0);
        if (st[0] == 0) throw new RuntimeException("shader: " + GLES20.glGetShaderInfoLog(h));
        return h;
    }

    /** Called every time an EGL context is current (surface (re)create). */
    public void initGl() {
        String vs =
                "attribute vec2 aPos;\n" +
                "attribute vec2 aUv;\n" +
                "uniform mat4 uProj;\n" +
                "varying vec2 vUv;\n" +
                "void main(){ vUv=aUv; gl_Position=uProj*vec4(aPos,0.0,1.0); }";
        String fs =
                "precision mediump float;\n" +
                "varying vec2 vUv;\n" +
                "uniform sampler2D uTex;\n" +
                "uniform float uTint;\n" +
                "void main(){ gl_FragColor=vec4(texture2D(uTex,vUv).rgb*(1.0-uTint), texture2D(uTex,vUv).a); }";
        program = GLES20.glCreateProgram();
        GLES20.glAttachShader(program, compile(GLES20.GL_VERTEX_SHADER, vs));
        GLES20.glAttachShader(program, compile(GLES20.GL_FRAGMENT_SHADER, fs));
        GLES20.glLinkProgram(program);
        int[] st = new int[1];
        GLES20.glGetProgramiv(program, GLES20.GL_LINK_STATUS, st, 0);
        if (st[0] == 0) throw new RuntimeException("link: " + GLES20.glGetProgramInfoLog(program));
        aPos = GLES20.glGetAttribLocation(program, "aPos");
        aUv = GLES20.glGetAttribLocation(program, "aUv");
        uProj = GLES20.glGetUniformLocation(program, "uProj");
        uTex = GLES20.glGetUniformLocation(program, "uTex");
        uTint = GLES20.glGetUniformLocation(program, "uTint");

        GLES20.glDisable(GLES20.GL_DEPTH_TEST);
        GLES20.glEnable(GLES20.GL_BLEND);
        GLES20.glBlendFunc(GLES20.GL_SRC_ALPHA, GLES20.GL_ONE_MINUS_SRC_ALPHA);
        GLES20.glClearColor(0f, 0f, 0f, 1f);

        // old textures died with the old context
        glEpoch++;
        java.util.Arrays.fill(pageTex, 0);
        if (sc != null) uploadAtlas();
    }

    public void setViewport(int wPx, int hPx) {
        screenW = wPx;
        screenH = hPx;
        fit();
    }

    /** Cover zoom: effZoom = max(pref, cover) so the map always fills the screen (mac semantics). */
    private void fit() {
        if (sc == null || mapIndex < 0 || screenW == 0) return;
        float world = sc.mapSize[mapIndex] * TILE;
        float cover = Math.max(screenW / world, screenH / world);
        zoom = Math.max(zoomPref, cover);
        viewW = screenW / zoom;
        viewH = screenH / zoom;
        // y-down orthographic over the viewport, world units
        proj[0] = 2f / viewW;  proj[1] = 0;  proj[2] = 0;  proj[3] = 0;
        proj[4] = 0;  proj[5] = -2f / viewH;  proj[6] = 0;  proj[7] = 0;
        proj[8] = 0;  proj[9] = 0;  proj[10] = -1;  proj[11] = 0;
        proj[12] = -1;  proj[13] = 1;  proj[14] = 0;  proj[15] = 1;
    }

    // ------------------------------------------------------------ map / textures
    public void loadMap(SceneData data, int idx) {
        // free the previous map's textures (context may already be gone -> just drop refs)
        if (pageCount > 0 && pageTex.length > 0 && EGL14.eglGetCurrentContext() != null
                && EGL14.eglGetCurrentContext() != EGL14.EGL_NO_CONTEXT) {
            GLES20.glDeleteTextures(pageTex.length, pageTex, 0);
        }
        sc = data;
        mapIndex = idx;
        pageBase = data.mapPageBase[idx];
        pageCount = data.mapPageCount[idx];
        pageTex = new int[pageCount];

        int size = data.mapSize[idx];
        roadIndex = new int[size * size];
        java.util.Arrays.fill(roadIndex, -1);
        int[] rx = data.dX[idx], ry = data.dY[idx];
        for (int i = 0; i < data.dCount[idx]; i++) roadIndex[ry[i] * size + rx[i]] = i;

        fit();
        Log.i(TAG, "loadMap " + data.mapName[idx] + " pages=" + pageCount);
    }

    /** Alias used by RenderThread: (re)bind a scene bundle at map index. */
    public void loadScene(SceneData data, int idx) { loadMap(data, idx); }
    public SceneData scene() { return sc; }
    public int mapIndex() { return mapIndex; }

    /** Upload atlas pages for the current map (GL thread, after initGl). */
    private void uploadAtlas() {
        if (sc == null || pageCount == 0) return;
        for (int p : pageTex) if (p != 0) return; // already uploaded in this context
        GLES20.glGenTextures(pageCount, pageTex, 0);
        BitmapFactory.Options o = new BitmapFactory.Options();
        o.inScaled = false;
        o.inPreferredConfig = Bitmap.Config.ARGB_8888;
        for (int i = 0; i < pageCount; i++) {
            int gid = pageBase + i;
            Bitmap bmp;
            try (java.io.InputStream in = assets.open("scenes/atlas-" + gid + ".png")) {
                bmp = BitmapFactory.decodeStream(in, null, o);
            } catch (Exception e) {
                throw new RuntimeException("atlas-" + gid, e);
            }
            if (bmp == null) throw new RuntimeException("decode atlas-" + gid);
            GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, pageTex[i]);
            // NEAREST: pixel-art parity with the web viewer (imageSmoothingEnabled=false)
            // and no atlas bleed at frame boundaries (LINEAR smears neighbouring frames).
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_NEAREST);
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_NEAREST);
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE);
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE);
            GLUtils.texImage2D(GLES20.GL_TEXTURE_2D, 0, bmp, 0);
            bmp.recycle();
        }
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, 0);
        Log.i(TAG, "uploaded " + pageCount + " atlas pages (epoch " + glEpoch + ")");
    }

    // ------------------------------------------------------------------ access
    public boolean hasMap() { return sc != null && mapIndex >= 0; }
    public float worldSizePx() { return hasMap() ? sc.mapSize[mapIndex] * TILE : 0; }
    public float viewW() { return viewW; }
    public float viewH() { return viewH; }
    public void setAnimStep(int s) { animStep = s; }
    public float centerX() { return viewLeft + viewW / 2; }
    public float centerY() { return viewTop + viewH / 2; }
    public void setZoomPref(float z) { zoomPref = z; fit(); }
    public float zoomNow() { return zoom; }

    public void centerOn(float cx, float cy) {
        viewLeft = cx - viewW / 2;
        viewTop = cy - viewH / 2;
    }

    public void setBrightness(float b) { tint[0] = Math.max(0f, Math.min(0.6f, b)); }

    private void bindPage(int globalPage) {
        int i = globalPage - pageBase;
        if (i < 0 || i >= pageCount) { GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, 0); return; }
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, pageTex[i]);
    }

    // -------------------------------------------------------------- quad emit
    /**
     * One quad: atlas source rect (sx..) → screen-px dest (dx..), optional mirror.
     * Mirror flips the SOURCE sampling (u swap), which mirrors the content inside
     * the destination rect — same as viewer.js ctx.scale(-1).
     */
    private void drawQuad(int sx, int sy, int sw, int sh,
                          float dx, float dy, float dw, float dh,
                          boolean flipH, boolean flipV) {
        if (dw <= 0 || dh <= 0 || sw <= 0 || sh <= 0) return;
        float P = sc.atlasPageSize;
        // GLUtils.texImage2D uploads bitmap row 0 (image top) to texture v=0,
        // so v maps directly: v = y / atlasPageSize (no GL-style flip).
        float u0 = sx / P, v0 = sy / P;
        float u1 = (sx + sw) / P, v1 = (sy + sh) / P;
        if (flipH) { float t = u0; u0 = u1; u1 = t; }
        if (flipV) { float t = v0; v0 = v1; v1 = t; }
        float x0 = dx / zoom, y0 = dy / zoom;
        float x1 = (dx + dw) / zoom, y1 = (dy + dh) / zoom;
        quad.clear();
        quad.put(x0).put(y0).put(u0).put(v0);
        quad.put(x1).put(y0).put(u1).put(v0);
        quad.put(x0).put(y1).put(u0).put(v1);
        quad.put(x1).put(y1).put(u1).put(v1);
        quad.position(0);
        GLES20.glVertexAttribPointer(aPos, 2, GLES20.GL_FLOAT, false, 16, quad);
        quad.position(2);
        GLES20.glVertexAttribPointer(aUv, 2, GLES20.GL_FLOAT, false, 16, quad);
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4);
    }

    // ------------------------------------------------------------------- frame
    /** Full-tile draw (border/terrain/river): frame → 32×32 dest tile with mirror. */
    private void drawFrameAt(int fid, int x, int y, boolean flipH, boolean flipV) {
        float dx = (x * TILE - viewLeft) * zoom;
        float dy = (y * TILE - viewTop) * zoom;
        bindPage(sc.fPage[fid]);
        drawQuad(sc.fX[fid], sc.fY[fid], sc.fW[fid], sc.fH[fid],
                dx, dy, TILE * zoom, TILE * zoom, flipH, flipV);
    }

    /**
     * Road crop with VCMI semantics (viewer.js drawFrameCanvas): the whole frame
     * canvas is conceptually pre-mirrored, then a plain rect is cropped:
     *   fromAbove → canvas rows [16,32) into this cell's top half (road on the cell above);
     *   !fromAbove → canvas rows [0,16) into this cell's bottom half.
     */
    private void drawRoadCrop(int fid, int flipByte, int x, int y, boolean fromAbove) {
        if (fid == SceneData.NO_FRAME) return;
        int fW = sc.fW[fid], fH = sc.fH[fid];
        int oX = sc.fOx[fid], oY = sc.fOy[fid];
        int fw = sc.fFw[fid], fh = sc.fFh[fid];
        boolean flipH = (flipByte & 1) != 0, flipV = (flipByte & 2) != 0;

        int canvasX = 0, canvasW = TILE;
        int canvasY = fromAbove ? TILE / 2 : 0;
        int canvasH = TILE / 2;

        // data rect in (possibly flipped) canvas space
        int dxF = flipH ? fw - oX - fW : oX;
        int dyF = flipV ? fh - oY - fH : oY;
        int ix0 = Math.max(canvasX, dxF), iy0 = Math.max(canvasY, dyF);
        int ix1 = Math.min(canvasX + canvasW, dxF + fW);
        int iy1 = Math.min(canvasY + canvasH, dyF + fH);
        if (ix1 <= ix0 || iy1 <= iy0) return;
        int w = ix1 - ix0, h = iy1 - iy0;
        // canvas-local range → atlas source range (mirror the data rect, as viewer does)
        int lx0 = ix0 - dxF, ly0 = iy0 - dyF;
        int sx = sc.fX[fid] + (flipH ? (fW - lx0 - w) : lx0);
        int sy = sc.fY[fid] + (flipV ? (fH - ly0 - h) : ly0);

        float cellDx = (x * TILE - viewLeft) * zoom;
        float cellDy = (y * TILE - viewTop) * zoom;
        // own road: canvas rows [0,16) land on the cell's BOTTOM half (viewer: dy=Y(y)+ts/2)
        float destDy = cellDy + (fromAbove ? 0 : (TILE / 2) * zoom);
        float kx = (TILE * zoom) / canvasW, ky = (TILE * zoom) / canvasH;
        float px = cellDx + (ix0 - canvasX) * kx;
        float py = destDy + (iy0 - canvasY) * ky;

        bindPage(sc.fPage[fid]);
        drawQuad(sx, sy, w, h, px, py, w * kx, h * ky, flipH, flipV);
    }

    // -------------------------------------------------------------------- draw
    public void draw() {
        if (sc == null || screenW == 0) return;
        uploadAtlas(); // no-op unless textures missing (new context)
        GLES20.glViewport(0, 0, screenW, screenH);
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT);
        GLES20.glUseProgram(program);
        GLES20.glUniformMatrix4fv(uProj, 1, false, proj, 0);
        GLES20.glUniform1i(uTex, 0);
        GLES20.glUniform1f(uTint, tint[0]);
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0);
        GLES20.glEnableVertexAttribArray(aPos);
        GLES20.glEnableVertexAttribArray(aUv);

        int size = sc.mapSize[mapIndex];
        int x0 = (int) Math.floor(viewLeft / TILE) - 1;
        int x1 = (int) Math.ceil((viewLeft + viewW) / TILE) + 1;
        int y0 = (int) Math.floor(viewTop / TILE) - 1;
        int y1 = (int) Math.ceil((viewTop + viewH) / TILE) + 1;

        // ---- 1. border (outside the map) ----
        short[] bids = sc.setIds[sc.mapBorderSet[mapIndex]];
        for (int y = y0; y <= y1; y++) {
            for (int x = x0; x <= x1; x++) {
                if (x >= 0 && y >= 0 && x < size && y < size) continue;
                int bi = borderIndex(x, y, size);
                if (bi < 0 || bi >= bids.length) continue;
                int fid = bids[bi];
                if (fid != SceneData.NO_FRAME) drawFrameAt(fid, x, y, false, false);
            }
        }

        // ---- 2. terrain ----
        int[] tx = sc.tX[mapIndex], ty = sc.tY[mapIndex], ts = sc.tSid[mapIndex];
        byte[] tf = sc.tFlip[mapIndex];
        for (int i = 0, n = sc.tCount[mapIndex]; i < n; i++) {
            int y = ty[i]; if (y < y0 || y > y1) continue;
            int x = tx[i]; if (x < x0 || x > x1) continue;
            short[] set = sc.setIds[ts[i]];
            if (set.length == 0) continue;
            int step = set.length > 1 ? Math.floorMod(animStep, set.length) : 0;
            int fid = set[step];
            if (fid != SceneData.NO_FRAME)
                drawFrameAt(fid, x, y, (tf[i] & 1) != 0, (tf[i] & 2) != 0);
        }

        // ---- 3. rivers ----
        int[] rx = sc.rX[mapIndex], ry = sc.rY[mapIndex], rs = sc.rSid[mapIndex];
        byte[] rf = sc.rFlip[mapIndex];
        for (int i = 0, n = sc.rCount[mapIndex]; i < n; i++) {
            int y = ry[i]; if (y < y0 || y > y1) continue;
            int x = rx[i]; if (x < x0 || x > x1) continue;
            short[] set = sc.setIds[rs[i]];
            if (set.length == 0) continue;
            int step = set.length > 1 ? Math.floorMod(animStep, set.length) : 0;
            int fid = set[step];
            if (fid != SceneData.NO_FRAME)
                drawFrameAt(fid, x, y, (rf[i] & 1) != 0, (rf[i] & 2) != 0);
        }

        // ---- 4. roads: per visible cell, half-tile crop from the cell above ----
        int[] dX = sc.dX[mapIndex], dY = sc.dY[mapIndex], dF = sc.dFid[mapIndex];
        byte[] dFl = sc.dFlip[mapIndex];
        for (int y = Math.max(y0, 0); y <= Math.min(y1, size - 1); y++) {
            for (int x = Math.max(x0, 0); x <= Math.min(x1, size - 1); x++) {
                if (y > 0) {
                    int ai = roadIndex[(y - 1) * size + x];
                    if (ai >= 0) drawRoadCrop(dF[ai], dFl[ai], x, y, true);
                }
                int ci = roadIndex[y * size + x];
                if (ci >= 0) drawRoadCrop(dF[ci], dFl[ci], x, y, false);
            }
        }

        // ---- 5. objects (painter order preserved at bake time) ----
        int[] ox = sc.oX[mapIndex], oy = sc.oY[mapIndex], os = sc.oSid[mapIndex];
        int[] op = sc.oPhase[mapIndex];
        short[] ofw = sc.oFw[mapIndex], ofh = sc.oFh[mapIndex];
        for (int i = 0, n = sc.oCount[mapIndex]; i < n; i++) {
            int canvasTop = (oy[i] + 1) * TILE - ofh[i];
            if (canvasTop + ofh[i] < y0 * TILE || canvasTop > y1 * TILE) continue;
            int canvasLeft = (ox[i] + 1) * TILE - ofw[i];
            if (canvasLeft + ofw[i] < x0 * TILE || canvasLeft > x1 * TILE) continue;
            short[] set = sc.setIds[os[i]];
            if (set.length == 0) continue;
            int fid = set[Math.floorMod(animStep + op[i], set.length)];
            if (fid == SceneData.NO_FRAME) continue;
            int fw = sc.fW[fid], fh = sc.fH[fid];
            float dx = (canvasLeft + sc.fOx[fid] - viewLeft) * zoom;
            float dy = (canvasTop + sc.fOy[fid] - viewTop) * zoom;
            bindPage(sc.fPage[fid]);
            drawQuad(sc.fX[fid], sc.fY[fid], fw, fh,
                    dx, dy, fw * zoom, fh * zoom, false, false);
        }

        GLES20.glDisableVertexAttribArray(aPos);
        GLES20.glDisableVertexAttribArray(aUv);
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, 0);
    }

    /** VCMI border frame index (viewer.js borderFrame). */
    static int borderIndex(int x, int y, int size) {
        if (x < -1 || x > size || y < -1 || y > size)
            return Math.abs(x) % 4 + 4 * (Math.abs(y) % 4);
        if (x == -1 && y == -1) return 16;
        if (x == size && y == -1) return 17;
        if (x == size && y == size) return 18;
        if (x == -1 && y == size) return 19;
        if (y == -1) return 20 + (x % 4);
        if (x == size) return 24 + (y % 4);
        if (y == size) return 28 + (x % 4);
        if (x == -1) return 32 + (y % 4);
        return Math.abs(x) % 4 + 4 * (Math.abs(y) % 4);
    }
}
