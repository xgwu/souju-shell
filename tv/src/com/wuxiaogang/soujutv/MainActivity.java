package com.wuxiaogang.soujutv;

import android.app.Activity;
import android.content.Intent;
import android.content.pm.PackageInfo;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.view.KeyEvent;
import android.view.View;
import android.view.ViewGroup;
import android.webkit.WebChromeClient;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.widget.FrameLayout;
import android.widget.Toast;

import java.util.Arrays;

/**
 * 搜剧 TV 阶段 1+2 宿主。
 *
 *   WebView（Chromium 83 / 1280×720 CSS 视口）
 *     ├── TvWebViewClient   导航边界、failover、注入挂钩
 *     ├── TvChromeClient    全屏、控制台、进度兜底
 *     ├── NativeBridge      RPC（令牌校验 + 能力上报）
 *     └── TvFocusEngine     遥控器焦点（原生接管按键 → 注入 JS 最近邻）
 *
 * 取证一律走 logcat + bridge.log，不依赖截屏（电视 FLAG_SECURE 时截屏全黑）。
 * 调试入口：adb shell am start -n com.wuxiaogang.soujutv/.MainActivity --es url "<url>"
 */
public class MainActivity extends Activity
        implements TvWebViewClient.Host, TvChromeClient.Host, NativeBridge.Host {

    private static final long KEY_REPEAT_MIN_MS = 110;
    private static final long DOUBLE_BACK_MS = 2000;

    private WebView web;
    private NativeBridge bridge;
    private final Handler handler = new Handler(Looper.getMainLooper());

    private String[] lines = ShellConfig.BUILTIN_LINES.clone();
    private int lineIndex = 0;
    private boolean failureHandledForLoad = false;
    private boolean pageFinishedForLoad = false;
    private long lastKeyAt = 0;
    private long lastBackAt = 0;
    private long lastFinishAt = 0;
    private String lastFinishUrl = "";

    private FrameLayout content;
    private View customView;
    private WebChromeClient.CustomViewCallback customViewCallback;

    private final Runnable loadTimeout = new Runnable() {
        @Override public void run() {
            if (!pageFinishedForLoad && !failureHandledForLoad) {
                onMainFrameFailed(web.getUrl(), "timeout_" + ShellConfig.LOAD_TIMEOUT_MS + "ms");
            }
        }
    };

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        BridgeLog.init(this);
        BridgeLog.i("boot", "BOOT sdk=" + Build.VERSION.SDK_INT
                + " abi=" + (Build.SUPPORTED_ABIS.length > 0 ? Build.SUPPORTED_ABIS[0] : "?")
                + " model=" + Build.MODEL
                + " webview=" + webViewPackageName()
                + " log=" + BridgeLog.path());

        applyIntentConfig(getIntent());

        content = new FrameLayout(this);
        content.setBackgroundColor(0xFF0E0E10);
        setContentView(content);

        web = new WebView(this);
        content.addView(web, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));

        WebView.setWebContentsDebuggingEnabled(true);
        WebSettings s = web.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        s.setDatabaseEnabled(true);
        s.setUseWideViewPort(true);
        s.setLoadWithOverviewMode(false);
        s.setMediaPlaybackRequiresUserGesture(false);
        s.setAllowFileAccess(true);
        s.setJavaScriptCanOpenWindowsAutomatically(false);
        s.setSupportMultipleWindows(false);
        s.setCacheMode(WebSettings.LOAD_DEFAULT);
        s.setMixedContentMode(WebSettings.MIXED_CONTENT_COMPATIBILITY_MODE);
        s.setUserAgentString(ShellConfig.UA);

        bridge = new NativeBridge(web, this);
        web.addJavascriptInterface(bridge, "SoujuTvNative");
        web.setWebViewClient(new TvWebViewClient(this));
        web.setWebChromeClient(new TvChromeClient(this));

        BridgeLog.i("boot", "UA " + s.getUserAgentString());
        BridgeLog.i("boot", "LINES " + Arrays.toString(lines));
        loadFromIntent(getIntent());
    }

    private void applyIntentConfig(Intent intent) {
        if (intent == null) return;
        String domains = intent.getStringExtra("domains");
        if (domains != null && domains.trim().length() > 0) {
            String[] parts = domains.split(",");
            String[] normalized = new String[parts.length];
            int n = 0;
            for (String p : parts) {
                String v = ShellConfig.normalize(p);
                if (v != null) normalized[n++] = v;
            }
            if (n > 0) lines = Arrays.copyOf(normalized, n);
        }
        ShellConfig.addTrustedHosts(intent.getStringExtra("trusted"));
    }

    private void loadFromIntent(Intent intent) {
        String url = intent == null ? null : intent.getStringExtra("url");
        if (url != null && url.trim().length() > 0) {
            String u = ShellConfig.normalize(url);
            BridgeLog.i("boot", "LOAD_EXPLICIT " + u);
            loadUrl(u);
        } else {
            loadLine(0);
        }
    }

    private void loadLine(int idx) {
        lineIndex = idx % lines.length;
        BridgeLog.i("line", "LOAD_LINE " + lineIndex + " / " + lines[lineIndex]);
        loadUrl(lines[lineIndex]);
    }

    private void loadUrl(String url) {
        failureHandledForLoad = false;
        pageFinishedForLoad = false;
        handler.removeCallbacks(loadTimeout);
        handler.postDelayed(loadTimeout, ShellConfig.LOAD_TIMEOUT_MS);
        web.loadUrl(url);
    }

    // MARK: - TvWebViewClient.Host

    @Override
    public void onMainFrameStarted(String url) {
        boolean trusted = ShellConfig.isTrustedHost(ShellConfig.hostOf(url));
        if (trusted) {
            bridge.rotateToken();
        } else {
            bridge.invalidateToken();
            BridgeLog.w("bridge", "UNTRUSTED 主文档，不下发桥令牌：" + url);
        }
        TvFocusEngine.inject(web, this, bridge, url, "start", trusted);
    }

    @Override
    public void onInjectChance(String url, String phase) {
        // 同一 URL 会在一次导航里触发两轮 onPageFinished，800ms 内只处理一次。
        // 必须按 URL 去重：failover 可能在 600ms 后就加载新线路，纯时间窗会吞掉新页的自检。
        if ("finish".equals(phase)) {
            long now = System.currentTimeMillis();
            String u = url == null ? "" : url;
            if (u.equals(lastFinishUrl) && now - lastFinishAt < 800) return;
            lastFinishUrl = u;
            lastFinishAt = now;
        }
        boolean trusted = ShellConfig.isTrustedHost(ShellConfig.hostOf(url));
        TvFocusEngine.inject(web, this, bridge, url, phase, trusted);
        if ("finish".equals(phase)) {
            pageFinishedForLoad = true;
            handler.removeCallbacks(loadTimeout);
            handler.postDelayed(new Runnable() {
                @Override public void run() {
                    TvFocusEngine.state(web);
                    TvFocusEngine.verify(web);
                    dumpDom();
                }
            }, 3500);
        }
    }

    @Override
    public void onMainFrameFailed(String url, String reason) {
        if (failureHandledForLoad) return;   // 新旧两个 onReceivedError 重载可能都触发
        failureHandledForLoad = true;
        handler.removeCallbacks(loadTimeout);
        BridgeLog.e("line", "FAILOVER_TRIGGER " + reason + " @ " + url);
        if (lineIndex + 1 < lines.length) {
            handler.postDelayed(new Runnable() {
                @Override public void run() { loadLine(lineIndex + 1); }
            }, 600);
        } else {
            BridgeLog.e("line", "ALL_LINES_FAILED → 错误页");
            web.loadUrl("file:///android_asset/error.html");
        }
    }

    @Override
    public void onNavigationBlocked(String url, String reason) {
        BridgeLog.w("nav", "BLOCKED " + reason + " " + url);
    }

    // MARK: - TvChromeClient.Host

    @Override
    public void onShowCustomView(View view, WebChromeClient.CustomViewCallback callback) {
        if (customView != null) { callback.onCustomViewHidden(); return; }
        customView = view;
        customViewCallback = callback;
        web.setVisibility(View.GONE);
        content.addView(view, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
        BridgeLog.i("fullscreen", "SHOW_CUSTOM_VIEW（按键交给播放器，停止注入）");
    }

    @Override
    public void onHideCustomView() {
        if (customView == null) return;
        content.removeView(customView);
        if (customViewCallback != null) {
            try { customViewCallback.onCustomViewHidden(); } catch (Throwable ignored) {}
        }
        customView = null;
        customViewCallback = null;
        web.setVisibility(View.VISIBLE);
        BridgeLog.i("fullscreen", "HIDE_CUSTOM_VIEW");
    }

    @Override
    public boolean isCustomViewShowing() { return customView != null; }

    // MARK: - NativeBridge.Host

    @Override
    public void onExternalUrl(String url, String title) {
        BridgeLog.i("bridge", "EXTERNAL_URL 允许 " + url + "（TV 端仅站内）");
        // TV 上跳出去遥控器回不来；只记日志，不真的 startActivity。
    }

    @Override
    public void onThemeChange(String mode) {
        BridgeLog.i("bridge", "THEME " + mode + "（阶段 3 接 TV 皮肤）");
    }

    @Override
    public void onHealth(String missing, String skin, String path) {
        BridgeLog.w("skin", "HEALTH missing=" + missing + " skin=" + skin + " path=" + path);
    }

    // MARK: - 遥控器

    @Override
    public boolean dispatchKeyEvent(KeyEvent ev) {
        int code = ev.getKeyCode();
        if (!TvFocusEngine.isRemoteKey(code)) return super.dispatchKeyEvent(ev);

        // 原生播放器/全屏视频期间把按键完整交回系统，否则会和播放条抢事件。
        if (customView != null) return super.dispatchKeyEvent(ev);

        if (ev.getAction() == KeyEvent.ACTION_DOWN) {
            if (code == KeyEvent.KEYCODE_BACK) return handleBack();
            if (code == KeyEvent.KEYCODE_MENU) return handleMenu();

            long now = System.currentTimeMillis();
            if (ev.getRepeatCount() > 0 && now - lastKeyAt < KEY_REPEAT_MIN_MS) return true;
            lastKeyAt = now;
            String action = TvFocusEngine.actionFor(code);
            if (action != null) TvFocusEngine.key(web, action);
        }
        // UP 也一并消费，避免半对按键漏给 WebView 触发它自己的焦点遍历
        return true;
    }

    private boolean handleBack() {
        if (customView != null) { onHideCustomView(); return true; }
        // failover 会把失败线路留在历史栈里，直接 goBack 会让用户退回错误页再触发一次 failover。
        // 只回退到可信站点的历史项；找不到就走双击退出。
        android.webkit.WebBackForwardList list = web.copyBackForwardList();
        int idx = list.getCurrentIndex();
        for (int i = idx - 1; i >= 0; i--) {
            android.webkit.WebHistoryItem item = list.getItemAtIndex(i);
            if (item == null) continue;
            String u = item.getUrl();
            if (ShellConfig.isTrustedHost(ShellConfig.hostOf(u))) {
                int steps = i - idx;
                BridgeLog.i("key", "BACK → goBack(" + steps + ") " + u);
                web.goBackOrForward(steps);
                lastBackAt = 0;
                return true;
            }
            BridgeLog.w("key", "BACK 跳过非站内历史 " + u);
        }
        long now = System.currentTimeMillis();
        if (now - lastBackAt < DOUBLE_BACK_MS) {
            BridgeLog.i("key", "BACK → finish");
            finish();
        } else {
            lastBackAt = now;
            Toast.makeText(this, "再按一次返回键退出搜剧TV", Toast.LENGTH_SHORT).show();
        }
        return true;
    }

    /** MENU：手动切下一条线路并重载。failover 的人工触发口，也是现场换域名的应急入口。 */
    private boolean handleMenu() {
        if (lines.length < 2) {
            TvFocusEngine.state(web);
            Toast.makeText(this, "搜剧TV · v" + ShellConfig.APP_VERSION, Toast.LENGTH_SHORT).show();
            return true;
        }
        loadLine((lineIndex + 1) % lines.length);
        Toast.makeText(this, "已切换线路：" + ShellConfig.hostOf(lines[lineIndex]),
                Toast.LENGTH_SHORT).show();
        return true;
    }

    // MARK: - 取证

    private void dumpDom() {
        String js = "(function(){try{return JSON.stringify({"
                + "title:document.title,url:location.href,"
                + "viewport:[innerWidth,innerHeight,devicePixelRatio],"
                + "bodyChars:document.body?document.body.innerText.length:-1,"
                + "imgs:document.querySelectorAll('img').length,"
                + "links:document.querySelectorAll('a').length,"
                + "buttons:document.querySelectorAll('button').length,"
                + "nodes:document.querySelectorAll('*').length,"
                + "bridge:!!(window.H5ShellNativeBridge&&window.H5ShellNativeBridge.call),"
                + "focusjs:!!window.__tvKey,"
                + "atPolyfill:typeof Array.prototype.at==='function'"
                + "});}catch(e){return JSON.stringify({error:String(e)});}})()";
        web.evaluateJavascript(js, new android.webkit.ValueCallback<String>() {
            @Override public void onReceiveValue(String value) {
                BridgeLog.i("dom", "DOM " + value);
            }
        });
    }

    private String webViewPackageName() {
        try {
            PackageInfo pi = WebView.getCurrentWebViewPackage();
            return pi == null ? "null" : pi.packageName + " / " + pi.versionName;
        } catch (Throwable t) {
            return "error:" + t.getClass().getSimpleName();
        }
    }

    // MARK: - 生命周期

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        applyIntentConfig(intent);
        loadFromIntent(intent);
    }

    @Override protected void onResume() { super.onResume(); web.onResume(); }
    @Override protected void onPause()  { web.onPause(); super.onPause(); }

    @Override
    protected void onDestroy() {
        handler.removeCallbacksAndMessages(null);
        if (customView != null) onHideCustomView();
        web.destroy();
        super.onDestroy();
    }
}
