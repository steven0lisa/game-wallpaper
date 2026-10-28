package org.feichao.h3wallpaper.ui;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.ComponentName;
import android.content.Intent;
import android.content.SharedPreferences;
import android.net.Uri;
import android.os.Bundle;
import android.app.WallpaperManager;
import android.text.Html;
import android.util.Log;
import android.view.Gravity;
import android.view.View;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

import org.feichao.h3wallpaper.R;
import org.feichao.h3wallpaper.wp.H3WallpaperService;

import static org.feichao.h3wallpaper.wp.H3WallpaperService.prefs;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * The only screen: start/open the wallpaper, About, check for updates.
 * No settings — the wallpaper is configured to just work (bundled maps, defaults).
 */
public class MainActivity extends Activity {
    private static final String TAG = "H3WP";
    private static final String RELEASES_URL =
            "https://github.com/steven0lisa/game-wallpaper/releases/latest";

    private TextView statusView;
    private Button pauseBtn;
    private final ExecutorService io = Executors.newSingleThreadExecutor();

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setGravity(Gravity.CENTER_HORIZONTAL);
        root.setBackgroundColor(0xff14171d);
        int pad = dp(24);
        root.setPadding(pad, pad, pad, pad);

        TextView title = new TextView(this);
        title.setText(R.string.main_title);
        title.setTextSize(28);
        title.setTextColor(0xfff0ece2);
        title.setGravity(Gravity.CENTER);
        root.addView(title, matchWrap());

        TextView hint = new TextView(this);
        hint.setText(R.string.hint_first_run);
        hint.setTextSize(14);
        hint.setTextColor(0xff9aa0aa);
        hint.setGravity(Gravity.CENTER);
        LinearLayout.LayoutParams hp = matchWrap();
        hp.topMargin = dp(8);
        hp.bottomMargin = dp(24);
        root.addView(hint, hp);

        Button openBtn = new Button(this);
        openBtn.setText(R.string.btn_open_wallpaper);
        openBtn.setOnClickListener(v -> openWallpaperPicker());
        root.addView(openBtn, matchWrap());

        pauseBtn = new Button(this);
        pauseBtn.setOnClickListener(v -> togglePause());
        root.addView(pauseBtn, matchWrap());

        Button aboutBtn = new Button(this);
        aboutBtn.setText(R.string.btn_about);
        aboutBtn.setOnClickListener(v -> showAbout());
        root.addView(aboutBtn, matchWrap());

        Button updBtn = new Button(this);
        updBtn.setText(R.string.btn_update);
        updBtn.setOnClickListener(v -> checkUpdate());
        root.addView(updBtn, matchWrap());

        statusView = new TextView(this);
        statusView.setTextSize(13);
        statusView.setTextColor(0xff9aa0aa);
        statusView.setGravity(Gravity.CENTER);
        LinearLayout.LayoutParams sp = matchWrap();
        sp.topMargin = dp(24);
        root.addView(statusView, sp);

        ScrollView scroll = new ScrollView(this);
        scroll.setFillViewport(true);
        scroll.addView(root);
        setContentView(scroll);

        // targetSdk 35 enforces edge-to-edge: pad around the cutout/status bar/navigation
        // bar so the title never lands under the notch or the punch-hole camera.
        scroll.setOnApplyWindowInsetsListener((v, insets) -> {
            int top = insets.getInsets(android.view.WindowInsets.Type.statusBars()
                    | android.view.WindowInsets.Type.displayCutout()).top;
            int bottom = insets.getInsets(android.view.WindowInsets.Type.navigationBars()
                    | android.view.WindowInsets.Type.ime()).bottom;
            int left = insets.getInsets(android.view.WindowInsets.Type.displayCutout()).left;
            int right = insets.getInsets(android.view.WindowInsets.Type.displayCutout()).right;
            v.setPadding(Math.max(pad, left), Math.max(pad, top),
                    Math.max(pad, right), Math.max(pad, bottom));
            return insets;
        });
    }

    private LinearLayout.LayoutParams matchWrap() {
        return new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT);
    }

    private int dp(int v) { return Math.round(v * getResources().getDisplayMetrics().density); }

    @Override
    protected void onResume() {
        super.onResume();
        // adb debug hook: pin the wallpaper camera for 1:1 comparison with the web viewer
        //   am start -n org.feichao.h3wallpaper/.ui.MainActivity \
        //       --ef debugCamX 496 --ef debugCamY 3152 [--ef debugCamZoom 3.5] [--ei debugCamMap 2]
        //   am start -n org.feichao.h3wallpaper/.ui.MainActivity --ei debugCamClear 1   # release the pin
        SharedPreferences pf = H3WallpaperService.prefs(this);
        SharedPreferences.Editor ed = pf.edit();
        boolean touched = false;
        if (getIntent().hasExtra("debugCamX")) {
            ed.putFloat("debugCamX", getIntent().getFloatExtra("debugCamX", Float.NaN))
              .putFloat("debugCamY", getIntent().getFloatExtra("debugCamY", Float.NaN))
              .putFloat("debugCamZoom", getIntent().getFloatExtra("debugCamZoom", 3.5f))
              .putInt("debugCamMap", getIntent().getIntExtra("debugCamMap", -1));
            touched = true;
        }
        if (getIntent().hasExtra("debugCamClear")) {
            ed.remove("debugCamX").remove("debugCamY").remove("debugCamZoom").remove("debugCamMap");
            touched = true;
        }
        if (touched) {
            ed.commit();
            sendBroadcast(new Intent("org.feichao.h3wallpaper.PAUSE_CHANGED"));
        }
        refreshStatus();
    }

    private boolean isWallpaperSet() {
        WallpaperManager wm = WallpaperManager.getInstance(this);
        android.app.WallpaperInfo info = wm.getWallpaperInfo();
        return info != null && H3WallpaperService.class.getName()
                .equals(info.getComponent().getClassName());
    }

    private void refreshStatus() {
        boolean set = isWallpaperSet();
        boolean paused = H3WallpaperService.prefs(this).getBoolean("paused", false);
        statusView.setText(set
                ? getString(R.string.wallpaper_active)
                : getString(R.string.wallpaper_inactive));
        pauseBtn.setEnabled(set);
        pauseBtn.setText(paused ? R.string.btn_resume : R.string.btn_pause);
        pauseBtn.setVisibility(set ? View.VISIBLE : View.GONE);
    }

    private void openWallpaperPicker() {
        try {
            Intent i = new Intent(WallpaperManager.ACTION_CHANGE_LIVE_WALLPAPER);
            i.putExtra(WallpaperManager.EXTRA_LIVE_WALLPAPER_COMPONENT,
                    new ComponentName(this, H3WallpaperService.class));
            startActivity(i);
        } catch (Exception e) {
            // some launchers reject the extras: fall back to the generic picker
            try {
                startActivity(new Intent(WallpaperManager.ACTION_LIVE_WALLPAPER_CHOOSER));
            } catch (Exception e2) {
                Toast.makeText(this, R.string.wallpaper_inactive, Toast.LENGTH_LONG).show();
            }
        }
    }

    private void togglePause() {
        SharedPreferences p = H3WallpaperService.prefs(this);
        boolean next = !p.getBoolean("paused", false);
        p.edit().putBoolean("paused", next).apply();
        sendBroadcast(new Intent("org.feichao.h3wallpaper.PAUSE_CHANGED"));
        refreshStatus();
    }

    // ---------------------------------------------------------------- About
    private void showAbout() {
        String ver;
        try {
            ver = getPackageManager().getPackageInfo(getPackageName(), 0).versionName;
        } catch (Exception e) {
            ver = "?";
        }
        LinearLayout box = new LinearLayout(this);
        box.setOrientation(LinearLayout.VERTICAL);
        int pad = dp(20);
        box.setPadding(pad, pad / 2, pad, 0);

        TextView v = new TextView(this);
        v.setText(getString(R.string.about_version, ver));
        v.setTextSize(15);
        v.setTextColor(0xffe8b34b);
        box.addView(v, matchWrap());

        TextView body = new TextView(this);
        body.setText(Html.fromHtml(getString(R.string.about_engine) + "<br><br>"
                + getString(R.string.about_credits)));
        body.setTextSize(13);
        body.setTextColor(0xffc9cdd4);
        LinearLayout.LayoutParams bp = matchWrap();
        bp.topMargin = dp(10);
        box.addView(body, bp);

        TextView src = new TextView(this);
        src.setText(Html.fromHtml("<u>" + getString(R.string.about_source) + "</u>"));
        src.setTextColor(0xff6fa8dc);
        src.setTextSize(13);
        src.setOnClickListener(v2 -> openUrl("https://github.com/steven0lisa/game-wallpaper"));
        LinearLayout.LayoutParams scp = matchWrap();
        scp.topMargin = dp(14);
        box.addView(src, scp);

        TextView fb = new TextView(this);
        fb.setText(Html.fromHtml("<u>" + getString(R.string.about_feedback) + "</u>"));
        fb.setTextColor(0xff6fa8dc);
        fb.setTextSize(13);
        fb.setOnClickListener(v2 -> openUrl("https://github.com/steven0lisa/game-wallpaper/issues"));
        LinearLayout.LayoutParams fp = matchWrap();
        fp.topMargin = dp(8);
        box.addView(fb, fp);

        new AlertDialog.Builder(this)
                .setTitle(R.string.about_title)
                .setView(box)
                .setPositiveButton(R.string.ok, null)
                .show();
    }

    private void openUrl(String url) {
        try { startActivity(new Intent(Intent.ACTION_VIEW, Uri.parse(url))); }
        catch (Exception ignored) {}
    }

    // ---------------------------------------------------------------- update
    private void checkUpdate() {
        statusView.setText(R.string.checking_update);
        io.execute(() -> {
            String latest = null;
            try {
                HttpURLConnection c = (HttpURLConnection)
                        new URL("https://api.github.com/repos/steven0lisa/game-wallpaper/releases/latest")
                                .openConnection();
                c.setConnectTimeout(8000);
                c.setReadTimeout(8000);
                c.setRequestProperty("Accept", "application/vnd.github+json");
                c.setRequestProperty("User-Agent", "h3wallpaper");
                BufferedReader r = new BufferedReader(new InputStreamReader(c.getInputStream()));
                StringBuilder sb = new StringBuilder();
                String line;
                while ((line = r.readLine()) != null) sb.append(line);
                r.close();
                String json = sb.toString();
                int i = json.indexOf("\"tag_name\"");
                if (i >= 0) {
                    int a = json.indexOf(':', i) + 1;
                    int b = json.indexOf('"', a);
                    int c2 = json.indexOf('"', b + 1);
                    latest = json.substring(b + 1, c2);
                }
            } catch (Exception e) {
                Log.w(TAG, "update check failed", e);
            }
            final String lv = latest;
            runOnUiThread(() -> {
                if (lv == null) {
                    statusView.setText(R.string.update_failed);
                    return;
                }
                String cur = "v" + versionName();
                if (lv.equalsIgnoreCase(cur)) {
                    statusView.setText(getString(R.string.update_none, lv));
                } else {
                    statusView.setText(getString(R.string.update_available, lv));
                    openUrl(RELEASES_URL);
                }
            });
        });
    }

    private String versionName() {
        try { return getPackageManager().getPackageInfo(getPackageName(), 0).versionName; }
        catch (Exception e) { return "?"; }
    }

    @Override
    protected void onDestroy() {
        super.onDestroy();
        io.shutdownNow();
    }
}
