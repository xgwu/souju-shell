package com.wuxiaogang.soujutv;

import android.os.Handler;
import android.webkit.ValueCallback;
import android.webkit.WebView;

/**
 * 揭幕门：整文档加载期间把 WebView 藏起来，等 TV 皮肤真正生效再渐入。
 *
 * 为什么需要它：站点是 SPA，主文档 onPageFinished 之后首页组件还要 2–3 秒才挂载，
 * 这段时间跑的是站点原生版式（11px 小字、横滑列表、侧栏），用户会先看到「闪一版」，
 * 皮肤生效后又跳成另一版。实测冷启动 PAGE_START 48.25 → PAGE_FINISHED 51.13，
 * 窗口约 2.9 秒。
 *
 * 做法：onMainFrameStarted 时 setAlpha(0)（底下 FrameLayout 已是 #0E0E10，
 * 用户只看到纯深色，不是白屏），每 120ms 问一次 JS 侧 window.__tvSkinReady()，
 * 就绪后 160ms 渐入。最坏 7 秒强制揭幕并打 timeout 日志，失败页 / 错误页立即揭幕，
 * 保证最坏情况只是「黑 6 秒」，不会把人挡在深色屏。
 *
 * 只 gate 整文档加载：SPA 站内换页不触发 onPageStarted，也不会被门挡住。
 */
final class RevealGate {

    private static final long POLL_MS = 600;
    private static final long FIRST_POLL_MS = 150;
    private static final long FADE_MS = 160;
    private static final long TIMEOUT_MS = 8000;

    /** 揭幕时回调（MainActivity 用它收起加载页）。 */
    interface OnReveal { void onReveal(String why); }

    private final WebView web;
    private final Handler handler;
    private OnReveal onReveal;

    /** 每次开门自增；回调里比对序号，旧门的轮询自动作废。 */
    private int seq = 0;
    private boolean closed = true;

    RevealGate(WebView web, Handler handler) {
        this.web = web;
        this.handler = handler;
    }

    void setOnReveal(OnReveal l) { this.onReveal = l; }

    /** 开一次新门：立刻藏起来并开始轮询。重复调用会重开（新文档 = 新序号）。 */
    void hide() {
        final int my = ++seq;
        closed = false;
        web.animate().cancel();
        web.setAlpha(0f);
        final long start = System.currentTimeMillis();
        handler.postDelayed(new Runnable() {
            @Override public void run() { poll(my, start); }
        }, FIRST_POLL_MS);
        BridgeLog.i("reveal", "HIDE seq=" + my);
    }

    /** 立即揭幕（错误页 / 非可信页 / 失败兜底）。没有门在开时是幂等的。 */
    void reveal(String why) {
        if (closed && web.getAlpha() >= 1f) { return; }
        seq++;
        closed = true;
        web.animate().cancel();
        web.animate().alpha(1f).setDuration(FADE_MS).start();
        BridgeLog.i("reveal", "SHOW " + why);
        if (onReveal != null) { onReveal.onReveal(why); }
    }

    /** 超时自述：把 JS 侧每个门槛的真实值写进日志。 */
    private void dumpWhy() {
        try {
            web.evaluateJavascript("(window.__tvSkinReadyWhy?window.__tvSkinReadyWhy():'no-why-fn')",
                    new ValueCallback<String>() {
                        @Override public void onReceiveValue(String v) {
                            BridgeLog.w("reveal", "TIMEOUT_WHY " + v);
                        }
                    });
        } catch (Throwable t) { /* 仅诊断用途 */ }
    }

    private void poll(final int my, final long start) {
        if (my != seq || closed) { return; }
        if (System.currentTimeMillis() - start > TIMEOUT_MS) {
            dumpWhy();
            reveal("timeout_" + TIMEOUT_MS + "ms");
            return;
        }
        try {
            web.evaluateJavascript("(window.__tvSkinReady?window.__tvSkinReady():0)",
                    new ValueCallback<String>() {
                        @Override public void onReceiveValue(String v) {
                            if (my != seq || closed) { return; }
                            if ("1".equals(v) || "true".equals(v)) {
                                /* 再等 140ms：这一帧皮肤刚打上，让浏览器先完成一次
                                   样式计算与重排，渐入时不会拍到「半成品」中间态。 */
                                handler.postDelayed(new Runnable() {
                                    @Override public void run() {
                                        if (my != seq || closed) { return; }
                                        long cost = System.currentTimeMillis() - start;
                                        reveal("ready_" + cost + "ms");
                                    }
                                }, 140);
                            } else {
                                handler.postDelayed(new Runnable() {
                                    @Override public void run() { poll(my, start); }
                                }, POLL_MS);
                            }
                        }
                    });
        } catch (Throwable t) {
            // WebView 正在销毁 / JS 上下文已失效：别把门卡死
            reveal("js_error");
        }
    }
}
