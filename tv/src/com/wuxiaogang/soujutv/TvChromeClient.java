package com.wuxiaogang.soujutv;

import android.webkit.ConsoleMessage;
import android.webkit.WebChromeClient;
import android.webkit.WebView;

/** 全屏回调（H5 播放器必需）+ 控制台日志转发 + 注入时机兜底。 */
public final class TvChromeClient extends WebChromeClient {

    public interface Host {
        void onShowCustomView(android.view.View view, CustomViewCallback callback);
        void onHideCustomView();
        boolean isCustomViewShowing();
        void onInjectChance(String url, String phase);
    }

    private final Host host;
    private boolean progressInjected = false;

    public TvChromeClient(Host host) { this.host = host; }

    @Override
    public void onShowCustomView(android.view.View view, CustomViewCallback callback) {
        // 不实现这两个回调，WebChromeClient 会告诉网页「不支持全屏」，
        // 站点的 requestFullscreen 会静默失效。
        host.onShowCustomView(view, callback);
    }

    @Override
    public void onHideCustomView() { host.onHideCustomView(); }

    @Override
    public void onProgressChanged(WebView view, int newProgress) {
        super.onProgressChanged(view, newProgress);
        // onPageStarted 时 evaluateJavascript 可能作用在旧 document 上而被丢弃。
        // 进度到 15% 时文档已就位，补注一次；站点自身还有 0/120/320/700ms 四轮重试。
        if (!progressInjected && newProgress >= 15) {
            progressInjected = true;
            host.onInjectChance(view.getUrl(), "progress15");
        }
        if (newProgress >= 100) { progressInjected = false; }
    }

    @Override
    public boolean onConsoleMessage(ConsoleMessage cm) {
        String msg = cm.message();
        if (msg.startsWith("TVFOCUS") || msg.startsWith("SOUJUTV") ||
                cm.messageLevel() == ConsoleMessage.MessageLevel.ERROR) {
            BridgeLog.i("console", cm.messageLevel() + " " + msg);
            return true;
        }
        return false;
    }
}
