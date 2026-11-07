package com.wuxiaogang.soujutv;

import android.annotation.TargetApi;
import android.graphics.Bitmap;
import android.net.http.SslError;
import android.os.Build;
import android.webkit.SslErrorHandler;
import android.webkit.WebResourceError;
import android.webkit.WebResourceRequest;
import android.webkit.WebResourceResponse;
import android.webkit.WebView;
import android.webkit.WebViewClient;

/** 导航边界 + 线路 failover + 注入时机挂钩。 */
public final class TvWebViewClient extends WebViewClient {

    public interface Host {
        /** 主文档开始：换令牌 + documentStart 级注入。 */
        void onMainFrameStarted(String url);
        /** 注入兜底：进度与 onPageFinished 各补一次，全部幂等。 */
        void onInjectChance(String url, String phase);
        /** 主 frame 加载失败，交给 Activity 决定是否换线路。 */
        void onMainFrameFailed(String url, String reason);
        void onNavigationBlocked(String url, String reason);
    }

    private final Host host;

    public TvWebViewClient(Host host) { this.host = host; }

    // MARK: - 导航边界

    @Override
    public boolean shouldOverrideUrlLoading(WebView view, String url) {
        return decide(url);
    }

    @TargetApi(Build.VERSION_CODES.N)
    @Override
    public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest req) {
        if (!req.isForMainFrame()) {
            // 子 frame 不允许跳出到任意站点：它们是 @JavascriptInterface 的主要攻击面。
            String u = req.getUrl().toString();
            if (!ShellConfig.allowNavigation(u)) {
                host.onNavigationBlocked(u, "subframe");
                return true;
            }
            return false;
        }
        return decide(req.getUrl().toString());
    }

    private boolean decide(String url) {
        if (!ShellConfig.allowNavigation(url)) {
            host.onNavigationBlocked(url, "scheme");
            return true;
        }
        // 站点是域名轮换架构，顶层 https 导航必须放行，否则中转域一换就打不开。
        // 真正的权限边界是「可信 host 才下发桥令牌」，不在这道拦截上。
        BridgeLog.i("nav", "TOP " + url + (ShellConfig.isTrustedHost(ShellConfig.hostOf(url))
                ? " [trusted]" : " [untrusted → 不下发桥令牌]"));
        return false;
    }

    // MARK: - 生命周期挂钩

    @Override
    public void onPageStarted(WebView view, String url, Bitmap favicon) {
        super.onPageStarted(view, url, favicon);
        BridgeLog.i("nav", "PAGE_START " + url);
        host.onMainFrameStarted(url);
    }

    @Override
    public void onPageFinished(WebView view, String url) {
        super.onPageFinished(view, url);
        BridgeLog.i("nav", "PAGE_FINISHED " + url);
        host.onInjectChance(url, "finish");
    }

    // MARK: - 失败 → failover

    @TargetApi(Build.VERSION_CODES.M)
    @Override
    public void onReceivedError(WebView view, WebResourceRequest req, WebResourceError err) {
        super.onReceivedError(view, req, err);
        if (!req.isForMainFrame()) return;
        String code = Build.VERSION.SDK_INT >= Build.VERSION_CODES.M
                ? String.valueOf(err.getErrorCode()) : "?";
        String desc = Build.VERSION.SDK_INT >= Build.VERSION_CODES.M
                ? String.valueOf(err.getDescription()) : "";
        report(req.getUrl().toString(), code + " " + desc);
    }

    @SuppressWarnings("deprecation")
    @Override
    public void onReceivedError(WebView view, int errorCode, String description, String failingUrl) {
        super.onReceivedError(view, errorCode, description, failingUrl);
        report(failingUrl, errorCode + " " + description);
    }

    @TargetApi(Build.VERSION_CODES.M)
    @Override
    public void onReceivedHttpError(WebView view, WebResourceRequest req, WebResourceResponse resp) {
        super.onReceivedHttpError(view, req, resp);
        if (req.isForMainFrame() && resp.getStatusCode() >= 500) {
            report(req.getUrl().toString(), "HTTP " + resp.getStatusCode());
        }
    }

    @Override
    public void onReceivedSslError(WebView view, SslErrorHandler handler, SslError error) {
        // 不为了「能用」而 proceed()：那会让桥的令牌校验失去意义。
        BridgeLog.e("nav", "SSL_ERROR " + error.getPrimaryError() + " @ " + error.getUrl());
        handler.cancel();
        report(error.getUrl(), "ssl_error");
    }

    private void report(String url, String reason) {
        BridgeLog.e("nav", "MAIN_FRAME_FAILED " + reason + " @ " + url);
        host.onMainFrameFailed(url, reason);
    }
}
