package com.wuxiaogang.soujutv;

import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.media.AudioManager;
import android.media.MediaPlayer;
import android.net.Uri;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.SurfaceHolder;
import android.view.SurfaceView;
import android.view.ViewGroup;
import android.view.WindowManager;
import android.widget.FrameLayout;
import android.widget.TextView;

import java.util.HashMap;
import java.util.Map;

/**
 * 阶段 5：遥控器可控的原生播放器。
 *
 * 用系统 MediaPlayer + SurfaceView 而不是 ExoPlayer / media3 —— 本工程是
 * aapt2 → javac → d8 的零依赖手工链路，ExoPlayer 需要 7 个 AAR + AndroidX
 * 资源合并，收益只有 DASH/DRM（站点目前给的是直链 mp4 / 标准 HLS）。
 * 系统 MediaPlayer 同样吃硬件解码，1080p 在 MT9653 上实测可用。
 *
 * 站点 H5 播放条是触摸设计，遥控器点不到进度条；这里把每个按键都显式接管：
 *   OK / 播放暂停键 → 播放/暂停，左/右 → ±10s，上/下 → 音量，MENU → 显示/隐藏条，返回 → 退出。
 */
public class PlayerActivity extends Activity
        implements SurfaceHolder.Callback, MediaPlayer.OnPreparedListener,
                   MediaPlayer.OnErrorListener, MediaPlayer.OnCompletionListener {

    private static final String EXTRA_URL = "url";
    private static final String EXTRA_TITLE = "title";
    private static final String EXTRA_POS = "positionMs";

    private SurfaceView surface;
    private MediaPlayer player;
    private TextView titleView;
    private TextView barView;
    private TextView errorView;
    private final Handler handler = new Handler(Looper.getMainLooper());

    private String url = "";
    private String title = "搜剧TV";
    private long positionMs = 0;
    private boolean prepared = false;
    private boolean barVisible = true;

    public static void launch(Context ctx, String url, String title, long positionMs) {
        Intent i = new Intent(ctx, PlayerActivity.class);
        i.putExtra(EXTRA_URL, url);
        i.putExtra(EXTRA_TITLE, title);
        i.putExtra(EXTRA_POS, positionMs);
        ctx.startActivity(i);
    }

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        // 播放期间禁屏保/休眠：实测无操作 8 分钟会进 Dreaming 并把播放器暂停。
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        Intent in = getIntent();
        if (in != null) {
            url = in.getStringExtra(EXTRA_URL) == null ? "" : in.getStringExtra(EXTRA_URL);
            title = in.getStringExtra(EXTRA_TITLE) == null ? "搜剧TV" : in.getStringExtra(EXTRA_TITLE);
            positionMs = in.getLongExtra(EXTRA_POS, 0);
        }
        BridgeLog.i("player", "PLAYER_OPEN title=" + title + " pos=" + positionMs
                + " url=" + (url.length() > 110 ? url.substring(0, 110) + "…" : url));

        FrameLayout root = new FrameLayout(this);
        root.setBackgroundColor(0xFF000000);
        setContentView(root, new ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));

        surface = new SurfaceView(this);
        root.addView(surface, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
        surface.getHolder().addCallback(this);

        titleView = new TextView(this);
        titleView.setText(title);
        titleView.setTextColor(0xFFF2F1ED);
        titleView.setTextSize(26);
        titleView.setBackgroundColor(0x88000000);
        titleView.setPadding(36, 18, 36, 18);
        FrameLayout.LayoutParams tp = new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        tp.gravity = Gravity.TOP;
        root.addView(titleView, tp);

        barView = new TextView(this);
        barView.setTextColor(0xFFF2F1ED);
        barView.setTextSize(22);
        barView.setBackgroundColor(0xAA0B0C0F);
        barView.setPadding(36, 18, 36, 18);
        barView.setGravity(Gravity.CENTER_VERTICAL);
        FrameLayout.LayoutParams bp = new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        bp.gravity = Gravity.BOTTOM;
        root.addView(barView, bp);

        errorView = new TextView(this);
        errorView.setTextColor(0xFFFFB08F);
        errorView.setTextSize(24);
        errorView.setGravity(Gravity.CENTER);
        errorView.setVisibility(android.view.View.GONE);
        root.addView(errorView, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));

        if (url.isEmpty()) { fail("没有可播放的地址"); }
        else { updateBar("正在准备播放…"); }
    }

    // MARK: - SurfaceHolder.Callback

    @Override
    public void surfaceCreated(SurfaceHolder holder) { initPlayer(holder); }

    @Override
    public void surfaceChanged(SurfaceHolder holder, int format, int width, int height) {}

    @Override
    public void surfaceDestroyed(SurfaceHolder holder) {
        if (player != null) { try { player.setDisplay(null); } catch (Throwable ignored) {} }
    }

    private void initPlayer(SurfaceHolder holder) {
        if (url.isEmpty() || player != null) return;
        try {
            player = new MediaPlayer();
            player.setDisplay(holder);
            player.setOnPreparedListener(this);
            player.setOnErrorListener(this);
            player.setOnCompletionListener(this);
            player.setAudioStreamType(AudioManager.STREAM_MUSIC);
            Map<String, String> headers = new HashMap<>();
            headers.put("User-Agent", ShellConfig.UA);
            headers.put("Referer", "https://souju.ai/");
            player.setDataSource(getApplicationContext(), Uri.parse(url), headers);
            player.prepareAsync();
            BridgeLog.i("player", "PREPARE_ASYNC");
        } catch (Throwable t) {
            fail("打开播放地址失败：" + t.getClass().getSimpleName());
        }
    }

    @Override
    public void onPrepared(MediaPlayer mp) {
        prepared = true;
        try {
            if (positionMs > 0) mp.seekTo((int) positionMs);
            mp.start();
            BridgeLog.i("player", "PLAYING duration=" + mp.getDuration());
        } catch (Throwable t) {
            fail("起播失败：" + t.getClass().getSimpleName());
            return;
        }
        handler.post(progressTick);
    }

    @Override
    public boolean onError(MediaPlayer mp, int what, int extra) {
        BridgeLog.e("player", "MEDIA_ERROR what=" + what + " extra=" + extra);
        fail("播放器报错（" + what + "/" + extra + "），按返回键退出");
        return true;
    }

    @Override
    public void onCompletion(MediaPlayer mp) {
        updateBar("播放结束 · 按返回键退出");
        BridgeLog.i("player", "COMPLETED");
    }

    // MARK: - 遥控器

    @Override
    public boolean dispatchKeyEvent(KeyEvent ev) {
        int code = ev.getKeyCode();
        if (ev.getAction() != KeyEvent.ACTION_DOWN) return true;
        switch (code) {
            case KeyEvent.KEYCODE_BACK:
            case KeyEvent.KEYCODE_ESCAPE:
                BridgeLog.i("player", "EXIT");
                finish();
                return true;
            case KeyEvent.KEYCODE_DPAD_CENTER:
            case KeyEvent.KEYCODE_ENTER:
            case KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE:
            case KeyEvent.KEYCODE_MEDIA_PLAY:
            case KeyEvent.KEYCODE_MEDIA_PAUSE:
                togglePlay();
                return true;
            case KeyEvent.KEYCODE_DPAD_LEFT:
            case KeyEvent.KEYCODE_MEDIA_REWIND:
                seek(-10000);
                return true;
            case KeyEvent.KEYCODE_DPAD_RIGHT:
            case KeyEvent.KEYCODE_MEDIA_FAST_FORWARD:
                seek(10000);
                return true;
            case KeyEvent.KEYCODE_DPAD_UP:
                volume(AudioManager.ADJUST_RAISE);
                return true;
            case KeyEvent.KEYCODE_DPAD_DOWN:
                volume(AudioManager.ADJUST_LOWER);
                return true;
            case KeyEvent.KEYCODE_MENU:
                barVisible = !barVisible;
                barView.setVisibility(barVisible ? android.view.View.VISIBLE : android.view.View.GONE);
                titleView.setVisibility(barVisible ? android.view.View.VISIBLE : android.view.View.GONE);
                return true;
            default:
                return true;   // 播放器期间不把任何键漏给底层 WebView
        }
    }

    private void togglePlay() {
        if (player == null || !prepared) return;
        try {
            if (player.isPlaying()) { player.pause(); updateBar("已暂停"); }
            else { player.start(); handler.post(progressTick); }
            BridgeLog.i("player", "TOGGLE playing=" + player.isPlaying());
        } catch (Throwable t) {
            BridgeLog.w("player", "TOGGLE_FAIL " + t.getMessage());
        }
    }

    private void seek(int deltaMs) {
        if (player == null || !prepared) return;
        try {
            int target = player.getCurrentPosition() + deltaMs;
            if (target < 0) target = 0;
            int dur = player.getDuration();
            if (dur > 0 && target > dur - 1500) target = Math.max(0, dur - 1500);
            player.seekTo(target);
            BridgeLog.i("player", "SEEK " + target + "ms");
            updateBar();
        } catch (Throwable t) {
            BridgeLog.w("player", "SEEK_FAIL " + t.getMessage());
        }
    }

    private void volume(int direction) {
        AudioManager am = (AudioManager) getSystemService(Context.AUDIO_SERVICE);
        if (am != null) am.adjustStreamVolume(AudioManager.STREAM_MUSIC, direction,
                AudioManager.FLAG_SHOW_UI);
        updateBar();
    }

    private final Runnable progressTick = new Runnable() {
        @Override public void run() {
            if (player == null || !prepared) return;
            updateBar();
            handler.postDelayed(this, 500);
        }
    };

    private void updateBar(String text) {
        if (barView != null) barView.setText(text);
    }

    private void updateBar() {
        String text;
        try {
            int cur = player.getCurrentPosition();
            int dur = player.getDuration();
            text = (player.isPlaying() ? "[播放] " : "[暂停] ") + mmss(cur) + " / "
                    + (dur > 0 ? mmss(dur) : "--:--");
        } catch (Throwable t) { text = "播放中"; }
        updateBar(text + "     ← →  ±10s     上/下  音量     OK  播放/暂停     返回  退出");
    }

    private static String mmss(int ms) {
        int s = Math.max(0, ms / 1000);
        return String.format(java.util.Locale.US, "%02d:%02d", s / 60, s % 60);
    }

    private void fail(String msg) {
        prepared = false;
        if (errorView != null) {
            errorView.setText(msg);
            errorView.setVisibility(android.view.View.VISIBLE);
        }
        updateBar(msg);
    }

    @Override
    protected void onPause() {
        super.onPause();
        // 退到后台时暂停播放并停掉 500ms 的进度轮询，省电也不空转。
        if (player != null && prepared) { try { player.pause(); } catch (Throwable ignored) {} }
        handler.removeCallbacks(progressTick);
    }

    @Override
    protected void onResume() {
        super.onResume();
        // 从屏保/其它 Activity 回来：如果还是播放态（未被用户暂停）就继续轮询进度。
        if (player != null && prepared) {
            try {
                if (player.isPlaying()) { handler.post(progressTick); }
            } catch (Throwable ignored) {}
        }
    }

    @Override
    protected void onDestroy() {
        handler.removeCallbacksAndMessages(null);
        if (player != null) {
            try { player.stop(); } catch (Throwable ignored) {}
            player.release();
            player = null;
        }
        BridgeLog.i("player", "PLAYER_CLOSE");
        super.onDestroy();
    }
}
