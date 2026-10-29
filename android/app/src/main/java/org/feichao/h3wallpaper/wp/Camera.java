package org.feichao.h3wallpaper.wp;

/**
 * Hop camera — direct port of Sources/WallpaperCore/Camera.swift.
 * Every switchInterval seconds pick a random reachable point, glide there over
 * 1.6s (smoothstep), dwell; frozen while paused/invisible.
 */
public final class Camera {
    public float cx, cy;          // current center (world px)
    private float ox, oy;         // origin of current glide
    private float tx, ty;         // glide target
    private float t;              // 0 = at target, 1 = at origin
    private static final float TRANSITION = 1.6f;
    private double switchInterval = 180;
    private double switchRemaining;
    private boolean frozen;
    private boolean initialized;
    private static final float MIN_JUMP_FRACTION = 0.18f;

    public void reset(float mapSizePx, float viewW, float viewH, double interval) {
        switchInterval = Math.max(20, interval);
        cx = mapSizePx / 2; cy = mapSizePx / 2;
        ox = cx; oy = cy; tx = cx; ty = cy;
        t = 0;
        switchRemaining = switchInterval;
        initialized = true;
    }

    public void setFrozen(boolean f) { frozen = f; }
    public boolean isFrozen() { return frozen; }

    /** True while interpolating (renderer needs higher fps). */
    public boolean isMoving() { return t > 0; }

    /** Probability that a random-move opportunity actually moves (<30% per spec). */
    public static final float MOVE_PROBABILITY = 0.25f;
    /** Max jump distance = one screenful (small hop, keeps the view contextual). */
    private static final float MAX_JUMP_FACTOR = 1.0f;

    /**
     * Small hop around the current center: target lands within one screen
     * radius of the current view (clamped inside the map, never showing the
     * black void outside). Returns true when the dice roll made the move —
     * callers gate every random-move opportunity through this so only a
     * minority of events disturb the user (and cost a glide).
     */
    public boolean maybeJumpNearby(float mapSizePx, float viewW, float viewH) {
        if (Math.random() >= MOVE_PROBABILITY) return false;
        ox = cx; oy = cy;
        B b = bounds(mapSizePx, viewW, viewH);
        float minR = Math.min(viewW, viewH) * MIN_JUMP_FRACTION;
        float maxR = Math.max(viewW, viewH) * MAX_JUMP_FACTOR;
        for (int i = 0; i < 8; i++) {
            double ang = Math.random() * 2 * Math.PI;
            double r = minR + Math.random() * (maxR - minR);
            float px = clamp(cx + (float) (Math.cos(ang) * r), b.loX, b.hiX);
            float py = clamp(cy + (float) (Math.sin(ang) * r), b.loY, b.hiY);
            float dx = px - cx, dy = py - cy;
            if (dx * dx + dy * dy >= minR * minR) { tx = px; ty = py; t = 1; return true; }
        }
        tx = clamp(cx, b.loX, b.hiX); ty = clamp(cy, b.loY, b.hiY);
        t = 1;
        return true;
    }

    private static float clamp(float v, float lo, float hi) {
        return v < lo ? lo : (v > hi ? hi : v);
    }

    private static class B { float loX, hiX, loY, hiY; }

    private static B bounds(float mapSizePx, float viewW, float viewH) {
        B b = new B();
        float halfW = Math.min(viewW / 2, mapSizePx / 2);
        float halfH = Math.min(viewH / 2, mapSizePx / 2);
        b.loX = halfW; b.hiX = mapSizePx - halfW;
        b.loY = halfH; b.hiY = mapSizePx - halfH;
        if (b.loX > b.hiX) { b.loX = mapSizePx / 2; b.hiX = b.loX; }
        if (b.loY > b.hiY) { b.loY = mapSizePx / 2; b.hiY = b.loY; }
        return b;
    }

    public void update(double dt, float mapSizePx, float viewW, float viewH) {
        if (!initialized) reset(mapSizePx, viewW, viewH, switchInterval);
        if (frozen) return;
        if (t > 0) {
            float step = (float) (dt / TRANSITION);
            t = Math.max(0, t - step);
            float s = 1 - t;
            float e = s * s * (3 - 2 * s); // smoothstep
            cx = ox + (tx - ox) * e;
            cy = oy + (ty - oy) * e;
            return; // no new jump mid-glide
        }
        switchRemaining -= dt;
        if (switchRemaining <= 0) {
            // dwell hop: same probability gate — most ticks just reset the timer
            maybeJumpNearby(mapSizePx, viewW, viewH);
            switchRemaining = switchInterval;
        }
    }

    /** Anchor camera right after a fit so the first glide starts from the center. */
    public void syncIfUninitialized(float mapSizePx, float viewW, float viewH, double interval) {
        if (!initialized) reset(mapSizePx, viewW, viewH, interval);
    }
}
