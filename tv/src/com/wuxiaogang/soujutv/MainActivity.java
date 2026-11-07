package com.wuxiaogang.soujutv;

import android.app.Activity;
import android.content.Intent;
import android.content.pm.PackageInfo;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import android.view.KeyEvent;
import android.webkit.ConsoleMessage;
import android.webkit.JavascriptInterface;
import android.webkit.ValueCallback;
import android.webkit.WebChromeClient;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;

/**
 * 阶段 0 验证壳：一个全屏 WebView，用来证明四件事
 *   1. 自签名 APK 能装进电视、能启动、桌面能看到
 *   2. 第三方 App 的 WebView 内核版本 / CSS 视口，与系统浏览器是否一致
 *   3. 站点能否在这个 WebView 里真实渲染（不白屏）
 *   4. 遥控器 DPAD 事件能不能到达 Activity（焦点引擎的前提）
 *
 * 所有结论直接打进 logcat（TAG=SoujuTV），用 adb logcat -d -s SoujuTV 取回，
 * 不依赖屏幕截图 —— 电视若启用 FLAG_SECURE，截图是全黑的。
 *
 * 换页不用重编译：adb shell am start -n <pkg>/.MainActivity --es url "<url>"
 */
public class MainActivity extends Activity {

    private static final String TAG = "SoujuTV";
    private static final String DEFAULT_URL = "file:///android_asset/probe.html";

    /** 系统浏览器把 UA 伪造成 iPad Safari 5.0.2，会导致站点走错误的移动版分支，
     *  这里覆盖成一个与真实内核相符的 UA。后续正式版可再按站点需要调整。 */
    private static final String UA =
            "Mozilla/5.0 (X11; Linux armv7l) AppleWebKit/537.36 (KHTML, like Gecko) "
                    + "Chrome/83.0.4103.120 Safari/537.36 SoujuTV/0.1";

    private WebView web;
    private final Handler handler = new Handler(Looper.getMainLooper());

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        Log.i(TAG, "BOOT sdk=" + Build.VERSION.SDK_INT
                + " abi=" + (Build.SUPPORTED_ABIS.length > 0 ? Build.SUPPORTED_ABIS[0] : "?")
                + " model=" + Build.MODEL
                + " webview=" + webViewPackageName());

        web = new WebView(this);
        setContentView(web);

        WebSettings s = web.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        s.setDatabaseEnabled(true);
        s.setUseWideViewPort(true);
        s.setLoadWithOverviewMode(false);
        s.setMediaPlaybackRequiresUserGesture(false);
        s.setAllowFileAccess(true);
        s.setUserAgentString(UA);

        // 仅用于把探针结果打到 logcat。正式版的桥会换成带来源校验的 @JavascriptInterface。
        web.addJavascriptInterface(new JsLog(), "tvlog");

        web.setWebViewClient(new WebViewClient() {
            @Override
            public void onPageFinished(WebView view, String url) {
                Log.i(TAG, "PAGE_FINISHED " + url);
                handler.removeCallbacksAndMessages(null);
                handler.postDelayed(new Runnable() {
                    @Override public void run() { dumpDom(); }
                }, 5000);
            }

            @Override
            public void onReceivedError(WebView view, int errorCode,
                                        String description, String failingUrl) {
                Log.e(TAG, "PAGE_ERROR " + errorCode + " " + description + " @ " + failingUrl);
            }
        });

        web.setWebChromeClient(new WebChromeClient() {
            @Override
            public boolean onConsoleMessage(ConsoleMessage cm) {
                Log.i(TAG, "CONSOLE " + cm.messageLevel() + " " + cm.message());
                return true;
            }
        });

        Log.i(TAG, "UA " + web.getSettings().getUserAgentString());
        loadFromIntent(getIntent());
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        loadFromIntent(intent);
    }

    private void loadFromIntent(Intent intent) {
        String url = intent == null ? null : intent.getStringExtra("url");
        if (url == null || url.length() == 0) {
            url = DEFAULT_URL;
        }
        Log.i(TAG, "LOAD " + url);
        web.loadUrl(url);
    }

    /** 延时抓 DOM 摘要：即使拿不到截屏，也能用 innerText / 节点数证明页面真的渲染了。 */
    private void dumpDom() {
        String js = "(function(){try{return JSON.stringify({"
                + "title:document.title,"
                + "url:location.href,"
                + "viewport:[innerWidth,innerHeight,devicePixelRatio],"
                + "ua:navigator.userAgent,"
                + "bodyChars:document.body?document.body.innerText.length:-1,"
                + "text:document.body?document.body.innerText.slice(0,800):'',"
                + "imgs:document.querySelectorAll('img').length,"
                + "links:document.querySelectorAll('a').length,"
                + "buttons:document.querySelectorAll('button').length,"
                + "nodes:document.querySelectorAll('*').length"
                + "});}catch(e){return JSON.stringify({error:String(e)});}})()";

        web.evaluateJavascript(js, new ValueCallback<String>() {
            @Override public void onReceiveValue(String value) {
                Log.i(TAG, "DOM " + value);
            }
        });
    }

    @Override
    public boolean dispatchKeyEvent(KeyEvent ev) {
        if (ev.getAction() == KeyEvent.ACTION_DOWN) {
            Log.i(TAG, "KEY " + ev.getKeyCode() + " " + KeyEvent.keyCodeToString(ev.getKeyCode()));
        }
        return super.dispatchKeyEvent(ev);
    }

    /** WebView.getCurrentWebViewPackage() 是 API 26+ 公开方法，电视是 API 30。
     *  它给出的是「当前进程实际加载的 WebView 实现」，比 dumpsys 更贴近本 App 的真实情况。 */
    private String webViewPackageName() {
        try {
            PackageInfo pi = WebView.getCurrentWebViewPackage();
            return pi == null ? "null" : pi.packageName + " / " + pi.versionName;
        } catch (Throwable t) {
            return "error:" + t.getClass().getSimpleName();
        }
    }

    private static final class JsLog {
        @JavascriptInterface
        public void log(String msg) {
            Log.i(TAG, "JS " + msg);
        }
    }
}
