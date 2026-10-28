package org.feichao.h3wallpaper.wp;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.util.Log;

/**
 * Debug-only receiver (registered in src/debug/AndroidManifest.xml, absent from
 * release builds): pin the wallpaper camera to a world position so screenshots
 * can be compared 1:1 against the web viewer.
 *
 *   adb shell am broadcast -a org.feichao.h3wallpaper.DEBUG_CAM \
 *       --ef cx 2200 --ef cy 1900 [--ef zoom 3.5] [--ei clear 1]
 */
public class DebugReceiver extends BroadcastReceiver {
    private static final String TAG = "H3WP";

    @Override
    public void onReceive(Context context, Intent intent) {
        H3WallpaperService.H3Engine engine = H3WallpaperService.H3Engine.lastInstance;
        if (engine == null) { Log.w(TAG, "debug: no engine"); return; }
        if (intent.getIntExtra("clear", 0) != 0) { engine.setDebugCam(null); return; }
        float cx = intent.getFloatExtra("cx", Float.NaN);
        float cy = intent.getFloatExtra("cy", Float.NaN);
        float zoom = intent.getFloatExtra("zoom", Float.NaN);
        if (Float.isNaN(cx) || Float.isNaN(cy)) return;
        engine.setDebugCam(new float[]{cx, cy, zoom});
        Log.i(TAG, "debug cam pinned to " + cx + "," + cy + " zoom=" + zoom);
    }
}
