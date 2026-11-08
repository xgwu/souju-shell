package com.wuxiaogang.soujutv;

import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.graphics.Color;
import android.graphics.drawable.GradientDrawable;
import android.media.AudioManager;
import android.media.MediaPlayer;
import android.net.Uri;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.SurfaceHolder;
import android.view.SurfaceView;
import android.view.View;
import android.view.ViewGroup;
import android.view.WindowManager;
import android.widget.Button;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

import org.json.JSONArray;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;

/**
 * 阶段 5/6：遥控器可控的原生播放器。
 *
 * 用系统 MediaPlayer + SurfaceView 而不是 ExoPlayer / media3 —— 本工程是
 * aapt2 → javac → d8 的零依赖手工链路，ExoPlayer 需要 7 个 AAR + AndroidX
 * 资源合并，收益只有 DASH/DRM（站点目前给的是直链 mp4 / 标准 HLS）。
 * 系统 MediaPlayer 同样吃硬件解码，1080p 在 MT9653 上实测可用。
 *
 * 站点 H5 播放条是触摸设计，遥控器点不到进度条；这里把每个按键都显式接管：
 *   OK / 播放暂停键 → 播放/暂停，左/右 → ±10s，上/下 → 音量，MENU → 选集/控制条，返回 → 退出。
 *
 * 阶段 6 新增两件事：
 *   ① 选集面板：H5 把剧集标签一起传进来（extras.episodes），MENU 打开原生的
 *      网格面板，OK 换集后带着 pickIndex 返回 MainActivity，由 H5 点击站点那一集
 *      并重新拉起播放器（站点才掌握每集的播放地址，原生不猜 URL）。
 *   ② 进度回传：退出 / 播完时 setResult 带上 positionMs，H5 再静音真播 2 秒，
 *      让站点自己的 recorder 把「继续观看」写回去。
 */
public class PlayerActivity extends Activity
        implements SurfaceHolder.Callback, MediaPlayer.OnPreparedListener,
                   MediaPlayer.OnErrorListener, MediaPlayer.OnCompletionListener {

    private static final String EXTRA_URL = "url";
    private static final String EXTRA_TITLE = "title";
    private static final String EXTRA_POS = "positionMs";
    private static final String EXTRA_EPISODES = "episodes";
    private static final String EXTRA_EP_INDEX = "episodeIndex";

    public static final String RESULT_POSITION = "positionMs";
    public static final String RESULT_DURATION = "durationMs";
    public static final String RESULT_REASON = "reason";
    public static final String RESULT_EPISODE_INDEX = "episodeIndex";
    public static final String RESULT_PICK = "pickIndex";

    private SurfaceView surface;
    private MediaPlayer player;
    private TextView titleView;
    private TextView barView;
    private TextView errorView;
    private FrameLayout sheet;
    private ScrollView sheetScroll;
    private final Handler handler = new Handler(Looper.getMainLooper());

    private String url = "";
    private String title = "搜剧TV";
    private long positionMs = 0;
    private boolean prepared = false;
    private boolean barVisible = true;
    private boolean completed = false;
    private List<String> episodes = new ArrayList<>();
    private int episodeIndex = -1;

    public static Intent intent(Context ctx, String url, String title, long positionMs,
                                String[] episodes, int episodeIndex) {
        Intent i = new Intent(ctx, PlayerActivity.class);
        i.putExtra(EXTRA_URL, url);
        i.putExtra(EXTRA_TITLE, title);
        i.putExtra(EXTRA_POS, positionMs);
        i.putExtra(EXTRA_EP_INDEX, episodeIndex);
        if (episodes != null && episodes.length > 0) {
            JSONArray arr = new JSONArray();
            for (String e : episodes) { arr.put(e == null ? "" : e); }
            i.putExtra(EXTRA_EPISODES, arr.toString());
        }
        return i;
    }

    public static void launch(Context ctx, String url, String title, long positionMs) {
        ctx.startActivity(intent(ctx, url, title, positionMs, null, -1));
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
            episodeIndex = in.getIntExtra(EXTRA_EP_INDEX, -1);
            episodes = parseEpisodes(in.getStringExtra(EXTRA_EPISODES));
        }
        BridgeLog.i("player", "PLAYER_OPEN title=" + title + " pos=" + positionMs
                + " ep=" + episodeIndex + "/" + episodes.size()
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
        titleView.setTextSize(TypedValue.COMPLEX_UNIT_SP, 17);
        titleView.setBackgroundColor(0x88000000);
        titleView.setPadding(36, 18, 36, 18);
        FrameLayout.LayoutParams tp = new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        tp.gravity = Gravity.TOP;
        root.addView(titleView, tp);

        barView = new TextView(this);
        barView.setTextColor(0xFFF2F1ED);
        barView.setTextSize(TypedValue.COMPLEX_UNIT_SP, 15);
        barView.setBackgroundColor(0xAA0B0C0F);
        barView.setPadding(36, 18, 36, 18);
        barView.setGravity(Gravity.CENTER_VERTICAL);
        FrameLayout.LayoutParams bp = new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        bp.gravity = Gravity.BOTTOM;
        root.addView(barView, bp);

        errorView = new TextView(this);
        errorView.setTextColor(0xFFFFB08F);
        errorView.setTextSize(TypedValue.COMPLEX_UNIT_SP, 16);
        errorView.setGravity(Gravity.CENTER);
        errorView.setVisibility(View.GONE);
        root.addView(errorView, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));

        if (episodes.size() > 0) { buildSheet(root); }

        if (url.isEmpty()) { fail("没有可播放的地址"); }
        else { updateBar("正在准备播放…"); }
    }

    private static List<String> parseEpisodes(String json) {
        List<String> out = new ArrayList<>();
        if (json == null || json.isEmpty()) { return out; }
        try {
            JSONArray arr = new JSONArray(json);
            for (int i = 0; i < arr.length(); i++) {
                String s = arr.optString(i, "");
                if (!s.isEmpty()) { out.add(s); }
            }
        } catch (Throwable t) {
            BridgeLog.w("player", "EPISODES_PARSE_FAIL " + t.getMessage());
        }
        return out;
    }

    // MARK: - 选集面板

    private void buildSheet(FrameLayout root) {
        sheet = new FrameLayout(this);
        /* 半透明遮罩：面板只占下半屏，上面仍能看到画面在播，
           否则用户以为播放器退出了（MTK 的 screencap 拍不到 video 层，
           但真机上视频会透出来）。 */
        sheet.setBackgroundColor(0xA8000000);
        sheet.setVisibility(View.GONE);
        sheet.setFocusable(true);
        sheet.setClickable(true);

        LinearLayout col = new LinearLayout(this);
        col.setOrientation(LinearLayout.VERTICAL);
        int pad = dp(36);
        col.setPadding(pad, dp(28), pad, dp(20));

        /* 当前集在格子上只用橙色描边标（底不再上色），所以标题行补一句
           「当前 第8集」，不依赖颜色也能读出来。 */
        String headText = "选集 · 共 " + episodes.size() + " 集";
        if (episodeIndex >= 0 && episodeIndex < episodes.size()) {
            headText += " · 当前 " + episodes.get(episodeIndex);
        }
        TextView head = new TextView(this);
        head.setText(headText);
        head.setTextColor(0xFFF2F1ED);
        head.setTextSize(TypedValue.COMPLEX_UNIT_SP, 22);
        head.setPadding(0, 0, 0, dp(14));
        col.addView(head);

        sheetScroll = new ScrollView(this);
        sheetScroll.setFillViewport(false);
        LinearLayout grid = new LinearLayout(this);
        grid.setOrientation(LinearLayout.VERTICAL);

        final int perRow = 8;
        LinearLayout row = null;
        for (int i = 0; i < episodes.size(); i++) {
            if (i % perRow == 0) {
                row = new LinearLayout(this);
                row.setOrientation(LinearLayout.HORIZONTAL);
                LinearLayout.LayoutParams rlp = new LinearLayout.LayoutParams(
                        ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
                rlp.bottomMargin = dp(10);
                grid.addView(row, rlp);
            }
            final int index = i;
            final Button b = new Button(this);
            b.setText(episodes.get(i));
            b.setTextSize(TypedValue.COMPLEX_UNIT_SP, 16);
            b.setTextColor(0xFFF2F1ED);
            b.setAllCaps(false);
            b.setFocusable(true);
            paintCell(b, i, false);
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(0,
                    dp(58), 1f);
            lp.rightMargin = dp(10);
            row.addView(b, lp);
            b.setOnClickListener(new View.OnClickListener() {
                @Override public void onClick(View v) {
                    BridgeLog.i("player", "EPISODE_PICK " + index);
                    finishWithResult("episode", index);
                }
            });
            b.setOnFocusChangeListener(new View.OnFocusChangeListener() {
                @Override public void onFocusChange(View v, boolean hasFocus) {
                    paintCell(b, index, hasFocus);
                }
            });
        }
        sheetScroll.addView(grid);
        LinearLayout.LayoutParams slp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f);
        col.addView(sheetScroll, slp);

        TextView hint = new TextView(this);
        hint.setText("方向键选择 · OK 换集 · 返回键继续看当前集");
        hint.setTextColor(0xFFBCB9B3);
        hint.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13);
        hint.setPadding(0, dp(10), 0, 0);
        col.addView(hint);

        GradientDrawable panelBg = new GradientDrawable();
        panelBg.setColor(0xF00B0C0F);
        panelBg.setCornerRadii(new float[]{ dp(22), dp(22), dp(22), dp(22), 0, 0, 0, 0 });
        FrameLayout panel = new FrameLayout(this);
        panel.setBackground(panelBg);
        panel.addView(col, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));

        /* 面板高度按内容算：15 集两行就只占两行的高度，别留一大片黑。
           集数多时封顶 58% 屏高，里面滚动。 */
        int rows = (episodes.size() + 7) / 8;
        int want = dp(28 + 20 + 46) + rows * (dp(58) + dp(10)) + dp(26);
        int screenH = getResources().getDisplayMetrics().heightPixels;
        int cap = (int) (screenH * 0.58f);
        FrameLayout.LayoutParams plp = new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, Math.min(want, cap));
        plp.gravity = Gravity.BOTTOM;
        sheet.addView(panel, plp);
        root.addView(sheet, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
    }

    /** 格子背景：三种状态必须各有一套视觉，不能复用。
     *
     * 焦点 = 亮橙实心底（遥控器在哪一目了然）；
     * 当前播放集（未聚焦）= 只有橙色描边、底保持和其它格子一样；
     * 其它 = 深灰底 + 淡描边。
     *
     * 早期两态共用同一套亮橙底（`hasFocus || index == episodeIndex`），
     * 实测焦点移到别的集后旧格仍是橙色 —— 两格同时亮，看起来像焦点没跟过去。
     * 用户的原话是「遥控器选其他集后，背景没有去掉」。 */
    private GradientDrawable cellBg(boolean focused, boolean current) {
        GradientDrawable d = new GradientDrawable();
        d.setCornerRadius(dp(10));
        if (focused) {
            d.setColor(0x44FF6B42);
            d.setStroke(dp(2), 0xCCFF6B42);
        } else if (current) {
            d.setColor(0x14FFFFFF);
            d.setStroke(dp(2), 0x99FF6B42);
        } else {
            d.setColor(0x14FFFFFF);
            d.setStroke(dp(1), 0x33FFFFFF);
        }
        return d;
    }

    /** 背景与文字色一起刷，避免只换底、文字色还留着上一态的颜色。 */
    private void paintCell(Button b, int index, boolean focused) {
        boolean current = (index == episodeIndex);
        b.setBackground(cellBg(focused, current));
        b.setTextColor(current && !focused ? 0xFFFFD3C2 : 0xFFF2F1ED);
    }

    private int dp(int v) {
        return (int) (v * getResources().getDisplayMetrics().density + 0.5f);
    }

    private boolean sheetVisible() {
        return sheet != null && sheet.getVisibility() == View.VISIBLE;
    }

    private void toggleSheet() {
        if (sheet == null) { return; }
        if (sheetVisible()) { hideSheet(); return; }
        sheet.setVisibility(View.VISIBLE);
        titleView.setVisibility(View.GONE);
        barView.setVisibility(View.GONE);
        // 滚动到当前集并让它拿到焦点，避免从第 1 集开始找
        View target = null;
        if (sheetScroll.getChildCount() > 0) {
            LinearLayout grid = (LinearLayout) sheetScroll.getChildAt(0);
            int flat = 0;
            int want = episodeIndex < 0 ? 0 : episodeIndex;
            for (int r = 0; r < grid.getChildCount() && target == null; r++) {
                LinearLayout row = (LinearLayout) grid.getChildAt(r);
                for (int c = 0; c < row.getChildCount(); c++) {
                    if (flat == want) { target = row.getChildAt(c); break; }
                    flat++;
                }
            }
        }
        final View focusTarget = target;
        if (focusTarget != null) {
            focusTarget.post(new Runnable() {
                @Override public void run() {
                    focusTarget.requestFocus();
                    // 让当前集落在可视区中部
                    int y = focusTarget.getTop();
                    sheetScroll.smoothScrollTo(0, Math.max(0, y - dp(80)));
                }
            });
        }
        BridgeLog.i("player", "SHEET_OPEN ep=" + episodeIndex);
    }

    private void hideSheet() {
        if (sheet == null) { return; }
        sheet.setVisibility(View.GONE);
        titleView.setVisibility(View.VISIBLE);
        barView.setVisibility(barVisible ? View.VISIBLE : View.GONE);
        BridgeLog.i("player", "SHEET_CLOSE");
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
            /* 带上解码出的画面尺寸：电视上 screencap/screenrecord 抓不到
               SurfaceView（硬件视频层），出问题是黑屏还是有画面只能靠这两个数
               判断 —— 非 0 就说明视频轨真的解出来了。 */
            BridgeLog.i("player", "PLAYING duration=" + mp.getDuration()
                    + " video=" + mp.getVideoWidth() + "x" + mp.getVideoHeight());
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
        completed = true;
        BridgeLog.i("player", "COMPLETED ep=" + episodeIndex + "/" + episodes.size());
        // 有下一集就自动续播：把选择权交回 H5（它才知道下一集的地址）
        if (episodeIndex >= 0 && episodeIndex + 1 < episodes.size()) {
            updateBar("播放结束，即将播放 " + episodes.get(episodeIndex + 1));
            handler.postDelayed(new Runnable() {
                @Override public void run() { finishWithResult("next", -1); }
            }, 1200);
            return;
        }
        updateBar("播放结束 · 按返回键退出");
    }

    // MARK: - 遥控器

    @Override
    public boolean dispatchKeyEvent(KeyEvent ev) {
        int code = ev.getKeyCode();
        // 选集面板打开时把方向键交回 View 体系，让原生焦点遍历自己走
        if (sheetVisible()) {
            if (ev.getAction() == KeyEvent.ACTION_DOWN && code == KeyEvent.KEYCODE_BACK) {
                hideSheet();
                return true;
            }
            return super.dispatchKeyEvent(ev);
        }
        if (ev.getAction() != KeyEvent.ACTION_DOWN) return true;
        switch (code) {
            case KeyEvent.KEYCODE_BACK:
            case KeyEvent.KEYCODE_ESCAPE:
                BridgeLog.i("player", "EXIT");
                finishWithResult("back", -1);
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
                if (episodes.size() > 0) { toggleSheet(); return true; }
                barVisible = !barVisible;
                barView.setVisibility(barVisible ? View.VISIBLE : View.GONE);
                titleView.setVisibility(barVisible ? View.VISIBLE : View.GONE);
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
        String tail = episodes.size() > 0
                ? "     ← →  ±10s     上/下  音量     OK  播放/暂停     MENU  选集     返回  退出"
                : "     ← →  ±10s     上/下  音量     OK  播放/暂停     返回  退出";
        updateBar(text + tail);
    }

    private static String mmss(int ms) {
        int s = Math.max(0, ms / 1000);
        return String.format(Locale.US, "%02d:%02d", s / 60, s % 60);
    }

    private void fail(String msg) {
        prepared = false;
        if (errorView != null) {
            errorView.setText(msg);
            errorView.setVisibility(View.VISIBLE);
        }
        updateBar(msg);
    }

    /** 退出前把进度交回 H5：站点靠它更新「继续观看」。 */
    private void finishWithResult(String reason, int pick) {
        long pos = 0;
        int dur = 0;
        if (player != null) {
            try {
                pos = player.getCurrentPosition();
                dur = player.getDuration();
            } catch (Throwable ignored) {}
        }
        Intent data = new Intent();
        data.putExtra(RESULT_POSITION, pos);
        data.putExtra(RESULT_DURATION, dur);
        data.putExtra(RESULT_REASON, reason);
        data.putExtra(RESULT_EPISODE_INDEX, episodeIndex);
        if (pick >= 0) { data.putExtra(RESULT_PICK, pick); }
        setResult(RESULT_OK, data);
        BridgeLog.i("player", "RETURN reason=" + reason + " pos=" + pos + "/" + dur
                + " ep=" + episodeIndex + (pick >= 0 ? " pick=" + pick : ""));
        finish();
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
