package org.feichao.h3wallpaper.wp;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.SharedPreferences;
import android.service.wallpaper.WallpaperService;
import android.util.Log;
import android.view.SurfaceHolder;

import org.feichao.h3wallpaper.SceneData;

/** The live wallpaper: one engine per surface; parse-once shared scene bundle. */
public class H3WallpaperService extends WallpaperService {
    private static final String TAG = "H3WP";
    static final String PREFS = "h3wallpaper";

    // parse-once per process
    private static volatile SceneData cachedScene;

    static SceneData scene(Context c) {
        SceneData s = cachedScene;
        if (s == null) {
            synchronized (H3WallpaperService.class) {
                s = cachedScene;
                if (s == null) {
                    try {
                        s = SceneData.load(c.getAssets());
                    } catch (Exception e) {
                        throw new RuntimeException("scenes.bin", e);
                    }
                    cachedScene = s;
                }
            }
        }
        return s;
    }

    public static boolean isPaused(Context c) {
        return prefs(c).getBoolean("paused", false);
    }

    public static SharedPreferences prefs(Context c) {
        return c.getSharedPreferences(PREFS, MODE_PRIVATE);
    }

    @Override
    public Engine onCreateEngine() {
        return new H3Engine();
    }

    final class H3Engine extends Engine {
        static H3Engine lastInstance; // debug receiver hook (single-engine in practice)
        private RenderThread thread;
        private boolean visible;
        private final SurfaceHolder.Callback cb = new SurfaceHolder.Callback() {
            @Override public void surfaceCreated(SurfaceHolder h) {
                if (thread != null) thread.attachSurface(h.getSurface(),
                        h.getSurfaceFrame().width(), h.getSurfaceFrame().height());
            }
            @Override public void surfaceChanged(SurfaceHolder h, int f, int w, int ht) {
                if (thread != null) thread.surfaceResized(w, ht);
            }
            @Override public void surfaceDestroyed(SurfaceHolder h) {
                if (thread != null) thread.detachSurface();
            }
        };

        // wake rendering on pause toggle; hot-reload debug camera prefs
        private final BroadcastReceiver pauseReceiver = new BroadcastReceiver() {
            @Override public void onReceive(Context c, Intent i) {
                if (thread == null) return;
                float dx = prefs(c).getFloat("debugCamX", Float.NaN);
                float dy = prefs(c).getFloat("debugCamY", Float.NaN);
                if (!Float.isNaN(dx) && !Float.isNaN(dy)) {
                    float[] cam = {dx, dy,
                            prefs(c).getFloat("debugCamZoom", 3.5f),
                            prefs(c).getInt("debugCamMap", -1)};
                    thread.setDebugCam(cam);
                    Log.i(TAG, "debug cam hot-reloaded: " + dx + "," + dy + " map=" + ((int) cam[3]));
                } else {
                    thread.setDebugCam(null); // release the pin, resume roaming
                }
            }
        };

        @Override
        public void onCreate(SurfaceHolder surfaceHolder) {
            super.onCreate(surfaceHolder);
            lastInstance = this;
            setTouchEventsEnabled(false); // wallpaper never eats input
            surfaceHolder.addCallback(cb);

            thread = new RenderThread(new RenderThread.Host() {
                @Override public SceneData scene() {
                    return H3WallpaperService.scene(H3WallpaperService.this);
                }
                @Override public boolean shouldRender() {
                    return visible && !isPaused(H3WallpaperService.this);
                }
            }, getAssets());
            // debug camera pin (written via `adb shell run-as`), read fresh at engine create
            SharedPreferences pf = prefs(H3WallpaperService.this);
            float dx = pf.getFloat("debugCamX", Float.NaN);
            float dy = pf.getFloat("debugCamY", Float.NaN);
            if (!Float.isNaN(dx) && !Float.isNaN(dy)) {
                thread.setDebugCam(new float[]{dx, dy,
                        pf.getFloat("debugCamZoom", 3.5f), pf.getInt("debugCamMap", -1)});
                Log.i(TAG, "debug cam from prefs: " + dx + "," + dy + " map=" + pf.getInt("debugCamMap", -1));
            }
            thread.start();

            int rxFlags = android.os.Build.VERSION.SDK_INT >= 33
                    ? Context.RECEIVER_NOT_EXPORTED : 0;
            registerReceiver(pauseReceiver,
                    new IntentFilter("org.feichao.h3wallpaper.PAUSE_CHANGED"), rxFlags);
        }

        /** Debug camera pin: {cx, cy, zoom} or null to release. */
        void setDebugCam(float[] cam) {
            if (thread != null) thread.setDebugCam(cam);
        }

        @Override
        public void onDestroy() {
            lastInstance = null;
            try { unregisterReceiver(pauseReceiver); } catch (Exception ignored) {}
            if (thread != null) { thread.shutdown(); thread = null; }
            getSurfaceHolder().removeCallback(cb);
            super.onDestroy();
        }

        @Override
        public void onVisibilityChanged(boolean vis) {
            visible = vis;
            if (thread != null) thread.invalidate(); // wake, or sleep at once
            Log.i(TAG, "visibility=" + vis);
        }

        @Override
        public void onSurfaceChanged(SurfaceHolder holder, int format, int w, int h) {
            if (thread != null) thread.surfaceResized(w, h);
        }

        @Override
        public void onSurfaceCreated(SurfaceHolder holder) {
            super.onSurfaceCreated(holder);
            if (thread != null) thread.attachSurface(holder.getSurface(),
                    holder.getSurfaceFrame().width(), holder.getSurfaceFrame().height());
        }

        @Override
        public void onSurfaceDestroyed(SurfaceHolder holder) {
            if (thread != null) thread.detachSurface();
            super.onSurfaceDestroyed(holder);
        }
    }
}
