package org.feichao.h3wallpaper.wp;

import android.opengl.EGL14;
import android.opengl.EGLConfig;
import android.opengl.EGLContext;
import android.opengl.EGLDisplay;
import android.opengl.EGLSurface;
import android.os.Build;
import android.os.SystemClock;
import android.util.Log;
import android.view.Surface;

import org.feichao.h3wallpaper.SceneData;

/**
 * Owns the EGL context/surface, the scene, and the on-demand frame loop.
 * Every GL call happens on this thread.
 *
 * Frame pacing (the battery design, vs the original's continuous 60fps libGDX loop):
 *   - STOPPED : invisible / paused / no surface → wait indefinitely (0 fps, CPU 0)
 *   - DWELL   : camera parked                    → wake only on 180ms animation-step
 *               boundaries (≈5.5fps — the minimum that plays sprites correctly)
 *   - GLIDE   : camera interpolating a hop       → 30fps for the 1.6s transition
 * Extra redraws fire on: first frame, surface (re)create/resize, brightness change,
 * explicit invalidate. Map rotation (15 min, mac parity) also reloads here.
 */
public final class RenderThread extends Thread {
    private static final String TAG = "H3WP";
    static final long FRAME_MS = 180;           // H3 sprite frame period
    private static final long GLIDE_MS = 33;    // ~30fps while gliding
    private static final long MAP_SWITCH_MS = 15 * 60 * 1000L;
    public static final float FPS_DWELL = 1000f / FRAME_MS;

    /** Supplied by the wallpaper engine (calls arrive on this thread). */
    public interface Host {
        /** Scene bundle for this engine (parsed once, cached). */
        SceneData scene();
        /** true → keep rendering (visible & not paused); false → sleep at 0fps. */
        boolean shouldRender();
    }

    private final Renderer renderer;
    private final Camera camera = new Camera();
    private final Host host;

    private EGLDisplay display = EGL14.EGL_NO_DISPLAY;
    private EGLContext context = EGL14.EGL_NO_CONTEXT;
    private EGLSurface eglSurface = EGL14.EGL_NO_SURFACE;

    private final Object lock = new Object();
    private Surface pendingSurface;
    private boolean surfaceDirty, exit, running, invalidate;
    private int surfW = 1, surfH = 1;
    private float brightness;

    private long animOriginMs;       // animation clock origin (shifted by pauses)
    private int lastStep = -1;
    private long lastLoopMs;
    private long logCamAt;
    private long nextMapSwitchMs;
    private float lastFps = -1;

    public RenderThread(Host host, android.content.res.AssetManager assets) {
        super("H3Render");
        this.host = host;
        this.renderer = new Renderer(assets);
        setPriority(Thread.NORM_PRIORITY - 1);
    }

    // ------------------------------------------------------------- control API
    public void attachSurface(Surface s, int w, int h) {
        synchronized (lock) {
            pendingSurface = s;
            surfW = Math.max(1, w);
            surfH = Math.max(1, h);
            surfaceDirty = true;
            running = true;
            lock.notifyAll();
        }
    }

    public void surfaceResized(int w, int h) {
        synchronized (lock) {
            surfW = Math.max(1, w);
            surfH = Math.max(1, h);
            invalidate = true;
            lock.notifyAll();
        }
    }

    public void detachSurface() {
        synchronized (lock) {
            pendingSurface = null;
            surfaceDirty = true;
            lock.notifyAll();
        }
    }

    /** Force one redraw (camera event, brightness, explicit user refresh). */
    public void invalidate() {
        synchronized (lock) {
            invalidate = true;
            lock.notifyAll();
        }
    }

    public void setBrightness(float b) {
        brightness = b;
        invalidate();
    }

    /** Used by the engine to jump the camera now (e.g. service rebind). */
    public void randomizeCamera() {
        synchronized (lock) { invalidate = true; lock.notifyAll(); }
    }

    public void shutdown() {
        synchronized (lock) {
            exit = true;
            lock.notifyAll();
        }
        interrupt();
        try { join(2000); } catch (InterruptedException ignored) {}
    }

    public Camera camera() { return camera; }

    private float[] debugCam; // {cx, cy, zoom, mapIdx} — pins the camera (verification only)

    /** Any thread: stage a camera pin; GL work happens on the render thread. */
    public void setDebugCam(float[] cam) {
        synchronized (lock) {
            debugCam = cam;
            invalidate = true;
            lastStep = -1;
            lock.notifyAll();
        }
    }

    /** GL thread: apply a staged camera pin (map load needs the GL context). */
    private void applyDebugCam() {
        if (debugCam == null) return;
        float[] cam = debugCam;
        if (cam.length >= 3 && !Float.isNaN(cam[2])) renderer.setZoomPref(cam[2]);
        if (cam.length >= 4 && cam[3] >= 0 && cam[3] != renderer.mapIndex()) {
            renderer.loadScene(host.scene(), (int) cam[3]);
            camera.reset(renderer.worldSizePx(), renderer.viewW(), renderer.viewH(), 180);
        }
        camera.cx = cam[0];
        camera.cy = cam[1];
        renderer.centerOn(camera.cx, camera.cy);
        lastStep = -1;
        Log.i(TAG, "debug cam applied: " + cam[0] + "," + cam[1] + " map=" + (int) cam[3]);
    }

    // ------------------------------------------------------------------ loop
    @Override
    public void run() {
        boolean prevVisible = false;
        while (true) {
            boolean should;
            synchronized (lock) {
                if (exit) break;
                if (surfaceDirty) {
                    // (re)create EGL on this thread
                    if (pendingSurface != null) {
                        boolean fresh = (display == EGL14.EGL_NO_DISPLAY);
                        if (fresh) createEgl(pendingSurface);
                        else {
                            // new surface, same context: swap the window surface
                            EGL14.eglMakeCurrent(display, EGL14.EGL_NO_SURFACE,
                                    EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT);
                            if (eglSurface != EGL14.EGL_NO_SURFACE)
                                EGL14.eglDestroySurface(display, eglSurface);
                            int[] attr = { EGL14.EGL_NONE };
                            eglSurface = EGL14.eglCreateWindowSurface(display, currentConfig,
                                    pendingSurface, attr, 0);
                            if (!EGL14.eglMakeCurrent(display, eglSurface, eglSurface, context))
                                throw new RuntimeException("eglMakeCurrent(new surface)");
                        }
                        renderer.setViewport(surfW, surfH);
                        invalidate = true;
                        lastStep = -1;
                        surfaceDirty = false;
                    } else {
                        // detached: destroy the window surface but keep the context
                        if (display != EGL14.EGL_NO_DISPLAY) {
                            EGL14.eglMakeCurrent(display, EGL14.EGL_NO_SURFACE,
                                    EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT);
                            if (eglSurface != EGL14.EGL_NO_SURFACE)
                                EGL14.eglDestroySurface(display, eglSurface);
                            eglSurface = EGL14.EGL_NO_SURFACE;
                        }
                        surfaceDirty = false;
                    }
                }
                should = running && pendingSurface != null && host.shouldRender();
                if (!should) {
                    try { lock.wait(); } catch (InterruptedException ignored) {}
                    continue;
                }
                if (!EGL14.eglMakeCurrent(display, eglSurface, eglSurface, context)) {
                    Log.w(TAG, "makeCurrent failed; waiting for new surface");
                    try { lock.wait(500); } catch (InterruptedException ignored) {}
                    continue;
                }
            }

            try {
                long now = SystemClock.uptimeMillis();

                // pause boundary: shift the animation clock so resume does not jump
                boolean visible = should;
                if (!prevVisible) {
                    if (animOriginMs == 0) animOriginMs = now;
                    else animOriginMs = now - ((lastStep < 0 ? 0 : (long) lastStep * FRAME_MS));
                    camera.setFrozen(false);
                }
                prevVisible = visible;

                // scene load (host may provide lazily)
                if (!renderer.hasMap()) {
                    SceneData sc = host.scene();
                    renderer.loadScene(sc, 0);
                    camera.reset(renderer.worldSizePx(), renderer.viewW(), renderer.viewH(), 180);
                    renderer.centerOn(camera.cx, camera.cy);
                    nextMapSwitchMs = now + MAP_SWITCH_MS;
                    invalidate = true;
                }

                // map rotation (mac parity: a fresh view every 15 min)
                if (now >= nextMapSwitchMs && renderer.scene().mapCount > 1) {
                    int next = (renderer.mapIndex() + 1) % renderer.scene().mapCount;
                    renderer.loadScene(renderer.scene(), next);
                    camera.reset(renderer.worldSizePx(), renderer.viewW(), renderer.viewH(), 180);
                    camera.jumpToRandomPoint(renderer.worldSizePx(), renderer.viewW(), renderer.viewH());
                    renderer.centerOn(camera.cx, camera.cy);
                    nextMapSwitchMs = now + MAP_SWITCH_MS;
                    invalidate = true;
                }

                // staged debug camera pin (may switch maps; must run on GL thread)
                if (debugCam != null) applyDebugCam();

                // camera advance
                double dt = Math.min(0.25, (now - lastLoopMs) / 1000.0);
                lastLoopMs = now;
                camera.update(dt, renderer.worldSizePx(), renderer.viewW(), renderer.viewH());
                if (debugCam != null) {
                    camera.cx = debugCam[0];
                    camera.cy = debugCam[1];
                }
                renderer.centerOn(camera.cx, camera.cy);
                if (logCamAt <= now) {
                    logCamAt = now + 30_000;
                    Log.i(TAG, "cam center=(" + Math.round(camera.cx) + "," + Math.round(camera.cy)
                            + ") zoom=" + renderer.zoomNow());
                }

                // animation clock
                int step = (int) ((now - animOriginMs) / FRAME_MS);
                boolean stepChanged = step != lastStep;
                if (stepChanged) renderer.setAnimStep(step);

                boolean moving = camera.isMoving();
                if (invalidate || stepChanged || moving) {
                    renderer.setBrightness(brightness);
                    renderer.draw();
                    EGL14.eglSwapBuffers(display, eglSurface);
                    lastStep = step;
                    invalidate = false;
                    setFrameRate(moving ? 30f : FPS_DWELL);
                }

                // ---- next wake ----
                long next;
                if (moving) {
                    next = now + GLIDE_MS;
                } else {
                    long elapsed = now - animOriginMs;
                    next = animOriginMs + (elapsed / FRAME_MS + 1) * FRAME_MS;
                    if (next <= now) next = now + FRAME_MS;
                }
                synchronized (lock) {
                    long d = next - SystemClock.uptimeMillis();
                    if (d > 0 && !invalidate && !surfaceDirty && !exit)
                        lock.wait(d);
                }
            } catch (Throwable t) {
                Log.e(TAG, "render error", t);
                synchronized (lock) {
                    try { lock.wait(1000); } catch (InterruptedException ignored) {}
                }
            }
        }
        releaseEgl();
    }

    // ---------------------------------------------------------------- EGL
    private EGLConfig currentConfig;

    private void createEgl(Surface s) {
        display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY);
        if (display == EGL14.EGL_NO_DISPLAY) throw new RuntimeException("eglGetDisplay");
        int[] ver = new int[2];
        if (!EGL14.eglInitialize(display, ver, 0, ver, 1)) throw new RuntimeException("eglInitialize");

        // Opaque RGB565: wallpaper has no alpha; halves fill bandwidth vs RGBA8888.
        int[] cfgAttr = {
                EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
                EGL14.EGL_SURFACE_TYPE, EGL14.EGL_WINDOW_BIT,
                EGL14.EGL_RED_SIZE, 5, EGL14.EGL_GREEN_SIZE, 6, EGL14.EGL_BLUE_SIZE, 5,
                EGL14.EGL_ALPHA_SIZE, 0, EGL14.EGL_DEPTH_SIZE, 0,
                EGL14.EGL_NONE
        };
        EGLConfig[] cfgs = new EGLConfig[1];
        int[] n = new int[1];
        if (!EGL14.eglChooseConfig(display, cfgAttr, 0, cfgs, 0, 1, n, 0) || n[0] == 0)
            throw new RuntimeException("eglChooseConfig");
        currentConfig = cfgs[0];

        int[] ctxAttr = { EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE };
        context = EGL14.eglCreateContext(display, cfgs[0], EGL14.EGL_NO_CONTEXT, ctxAttr, 0);
        if (context == EGL14.EGL_NO_CONTEXT) throw new RuntimeException("eglCreateContext");

        int[] attr = { EGL14.EGL_NONE };
        eglSurface = EGL14.eglCreateWindowSurface(display, cfgs[0], s, attr, 0);
        if (eglSurface == EGL14.EGL_NO_SURFACE) throw new RuntimeException("eglCreateWindowSurface");
        if (!EGL14.eglMakeCurrent(display, eglSurface, eglSurface, context))
            throw new RuntimeException("eglMakeCurrent");
        EGL14.eglSwapInterval(display, 0); // self-paced; never block on vsync
        renderer.initGl();
        renderer.setViewport(surfW, surfH);
        Log.i(TAG, "EGL ready " + surfW + "x" + surfH);
    }

    private void releaseEgl() {
        if (display == EGL14.EGL_NO_DISPLAY) return;
        EGL14.eglMakeCurrent(display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE,
                EGL14.EGL_NO_CONTEXT);
        if (eglSurface != EGL14.EGL_NO_SURFACE) EGL14.eglDestroySurface(display, eglSurface);
        if (context != EGL14.EGL_NO_CONTEXT) EGL14.eglDestroyContext(display, context);
        EGL14.eglTerminate(display);
        display = EGL14.EGL_NO_DISPLAY;
        context = EGL14.EGL_NO_CONTEXT;
        eglSurface = EGL14.EGL_NO_SURFACE;
    }

    /** Tell the compositor the cadence (let LTPO panels downclock). */
    private void setFrameRate(float fps) {
        if (Build.VERSION.SDK_INT < 30) return;
        Surface s;
        synchronized (lock) { s = pendingSurface; }
        if (s == null || Math.abs(lastFps - fps) < 0.01f) return;
        lastFps = fps;
        try {
            s.setFrameRate(fps, Surface.FRAME_RATE_COMPATIBILITY_FIXED_SOURCE,
                    Surface.CHANGE_FRAME_RATE_ONLY_IF_SEAMLESS);
        } catch (Throwable ignored) {}
    }
}
