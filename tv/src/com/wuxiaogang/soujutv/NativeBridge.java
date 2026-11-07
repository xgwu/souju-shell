package com.wuxiaogang.soujutv;

import android.webkit.JavascriptInterface;
import android.webkit.WebView;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.util.HashSet;
import java.util.Locale;
import java.util.Set;

/**
 * 桥的 RPC 路由器。协议与 iOS 版 NativeBridge.swift 完全一致：
 *
 *   上行 payload  { operation_id | operationId, module, method | action, params | payload }
 *   下行           window.__nativeReply(operation_id, resultObject)
 *   事件           window.__nativeEvent(name, payload) → CustomEvent("h5shell:native-event")
 *
 * 安全边界（Android 版特有）：WebView 83 用不了 addWebMessageListener（需 88+），
 * `@JavascriptInterface` 对该 WebView 的**所有 frame** 都暴露。所以两道校验必须同时成立：
 *   1. TvWebViewClient 拦掉非 https / 非顶层导航；
 *   2. 每个可信主文档下发一个一次性会话令牌，post() 校验令牌后才执行。
 * 令牌由 documentStart 阶段的注入脚本持有，第三方 frame 与不可信主文档都拿不到。
 */
public final class NativeBridge {

    public interface Host {
        void onExternalUrl(String url, String title);
        void onThemeChange(String mode);
        void onHealth(String missing, String skin, String path);
        /** 阶段 4：浮层开关。原生必须知道，BACK 才知道该关浮层还是回历史。 */
        void onOverlayState(boolean open, String mode);
        /** 阶段 4：手机输入页地址 / 配对码 / 二维码 data URI。 */
        JSONObject inputServerInfo();
        /** 阶段 5：启动原生播放器。 */
        void onPlayNative(String url, String title, long positionMs);
    }

    private final WebView web;
    private final Host host;
    private volatile String sessionToken = "";
    private int rejectedCount = 0;
    /** 站点会轮询探测未实现的能力（auth.getState 一秒一次），只记首次，避免刷屏。 */
    private final Set<String> notImplOnce = new HashSet<>();

    public NativeBridge(WebView web, Host host) {
        this.web = web;
        this.host = host;
    }

    /** 每次可信主文档开始加载时换一个令牌；整个文档生命周期内不变。 */
    public void rotateToken() {
        sessionToken = Long.toHexString(System.nanoTime())
                + Long.toHexString((long) (Math.random() * Long.MAX_VALUE));
        BridgeLog.i("bridge", "TOKEN_ROTATED " + sessionToken.substring(0, 8) + "…");
    }

    public String token() { return sessionToken; }

    public void invalidateToken() { sessionToken = ""; }

    // MARK: - 上行入口

    @JavascriptInterface
    public void post(String payloadJson, String token) {
        if (token == null || token.isEmpty() || !token.equals(sessionToken)) {
            rejectedCount++;
            if (rejectedCount <= 5) {
                BridgeLog.w("bridge", "REJECT 令牌不匹配（第 " + rejectedCount + " 次）");
            }
            return;
        }
        JSONObject body;
        try {
            body = new JSONObject(payloadJson == null ? "{}" : payloadJson);
        } catch (JSONException e) {
            BridgeLog.e("bridge", "REJECT 非法 JSON: " + payloadJson);
            return;
        }

        final String oid = firstString(body, "operation_id", "operationId");
        final String module = firstString(body, "module");
        final String method = firstString(body, "method", "action");
        final JSONObject params = firstObject(body, "params", "payload");

        BridgeLog.i("bridge", "← " + module + "." + method + "  " + compact(params));
        route(oid, module.toLowerCase(Locale.US), method, params);
    }

    /** 环境探针用：站点 native-environment 会检查这个对象的 postMessage 是否为函数。 */
    @JavascriptInterface
    public void ping() {
        BridgeLog.i("bridge", "PING (AiMovieAndroidBridge.postMessage 兼容通道)");
    }

    // MARK: - 路由

    private void route(String oid, String module, String method, JSONObject p) {
        try {
            switch (module + "." + method) {

                case "app.getCapabilities":
                    JSONObject caps = capabilities();
                    BridgeLog.i("bridge", "→ capabilities " + compact(caps));
                    reply(oid, caps);
                    return;

                case "app.getSystemInsets":
                    // 站点 Ku() 只认 platform == "android" 的数值型 insets。
                    // TV 全屏无刘海无导航栏，全部回 0 是真实值，不是占位。
                    reply(oid, new JSONObject()
                            .put("platform", "android")
                            .put("top", 0).put("right", 0)
                            .put("bottom", 0).put("left", 0)
                            .put("edgeToEdge", true));
                    return;

                case "app.ready":
                case "app.ping":
                    BridgeLog.i("bridge", "BRIDGE_OK " + module + "." + method);
                    reply(oid, ok());
                    return;

                case "statusBar.setStyle":
                    // 电视没有状态栏；如实回 ok，不要让站点 retry。
                    reply(oid, ok().put("style", p.optString("style", p.optString("value", ""))));
                    return;

                case "browser.openExternalURL":
                case "app.openExternalBrowser": {
                    String url = p.optString("url", "");
                    String h = ShellConfig.hostOf(url);
                    if (url.startsWith("https://") && ShellConfig.isTrustedHost(h)) {
                        host.onExternalUrl(url, p.optString("title", ""));
                        reply(oid, ok().put("opened", true).put("mode", "external"));
                    } else {
                        // TV 上跳出到无关站点，遥控器回不来；明确拒绝而不是静默失败。
                        BridgeLog.w("bridge", "DENY 外部打开 " + url);
                        reply(oid, fail("NOT_ALLOWED", "TV 端只允许打开站内链接"));
                    }
                    return;
                }

                case "shell.getTheme":
                    reply(oid, ok().put("mode", "dark").put("skin", "souju-dark"));
                    return;

                case "shell.setTheme":
                case "shell.toggleTheme": {
                    // 阶段 3 的 TV 皮肤固定深色：电视环境光暗，不提供日/夜切换。
                    // 保留协议位并如实回 dark，别让站点的 toggle 逻辑陷入等待。
                    BridgeLog.i("bridge", "THEME_REQUEST " + p.optString("mode", "toggle") + "（TV 固定 dark）");
                    host.onThemeChange(p.optString("mode", "dark"));
                    reply(oid, ok().put("mode", "dark").put("skin", "souju-dark"));
                    return;
                }

                case "shell.reportHealth":
                    // 阶段 3：tv-skin.js 在每次 SPA 同步后上报锚点自检与版式指标。
                    String missing = p.optString("missing", "");
                    host.onHealth(missing, p.optString("skin", ""), p.optString("path", ""));
                    BridgeLog.i("bridge", "HEALTH checked=" + p.optInt("checked", 0)
                            + " columns=" + p.optInt("columns", 0)
                            + " overflowX=" + p.optBoolean("overflowX", false)
                            + " missing=" + missing + " @ " + p.optString("path", ""));
                    reply(oid, ok());
                    return;

                case "shell.setOverlay": {
                    boolean open = p.optBoolean("open", false);
                    String overlayMode = p.optString("mode", "");
                    host.onOverlayState(open, overlayMode);
                    BridgeLog.i("overlay", "OVERLAY " + (open ? "OPEN " : "CLOSE ") + overlayMode);
                    reply(oid, ok());
                    return;
                }

                case "shell.getInputServerInfo":
                    reply(oid, host.inputServerInfo());
                    return;

                case "playback.playNative": {
                    String u = p.optString("url", "");
                    if (!u.startsWith("http://") && !u.startsWith("https://")) {
                        BridgeLog.w("player", "DENY 非 http(s) 播放地址 " + u.substring(0, Math.min(60, u.length())));
                        reply(oid, fail("BAD_URL", "只接受 http(s) 直链"));
                        return;
                    }
                    host.onPlayNative(u, p.optString("title", "搜剧TV"),
                            p.optLong("positionMs", 0));
                    BridgeLog.i("player", "PLAY_NATIVE title=" + p.optString("title", "")
                            + " pos=" + p.optLong("positionMs", 0));
                    reply(oid, ok().put("launched", true));
                    return;
                }

                case "playback.getNativePlayerState":
                    // 站点用自己的 capabilities.actions 决定要不要走 nativePlayer 协议。
                    // 这里刻意仍报 idle + null：阶段 5 的播放器是「壳层独立入口」，
                    // 不伪装成站点期望的 embedded native player，避免触发它没实现的 slot 协议。
                    reply(oid, ok().put("state", "idle").put("nativePlayer", JSONObject.NULL)
                            .put("standalonePlayer", true));
                    return;

                case "cast.getState":
                    reply(oid, ok().put("state", "idle").put("connected", false)
                            .put("devices", new JSONArray())
                            .put("route", new JSONObject().put("name", "").put("type", "none")));
                    return;

                default:
                    // 站点按 capabilities.actions 判定能力，未列出的仍会被探测调用。
                    // 回 NOT_IMPL 是协议里明确的「不支持」信号，不是错误。
                    String key = module + "." + method;
                    if (notImplOnce.add(key)) {
                        BridgeLog.w("bridge", "NOT_IMPL " + key + "（后续同方法不再重复记录）");
                    }
                    reply(oid, fail("NOT_IMPL", key + " 未实现"));
            }
        } catch (JSONException e) {
            BridgeLog.e("bridge", "ROUTE_ERROR " + e.getMessage());
            try { reply(oid, fail("INTERNAL", e.getMessage())); } catch (JSONException ignored) {}
        }
    }

    /**
     * 能力清单必须如实上报：站点把 `capabilities.actions` 当作「这个壳支持什么」的唯一依据，
     * 谎报会让它调用不存在的方法然后静默降级 —— 比不支持更难排查。
     * TV 阶段 1 刻意不报 download.* / cast.*：离线下载与投屏在电视上没有对应实现。
     */
    private JSONObject capabilities() throws JSONException {
        JSONArray actions = new JSONArray()
                .put("app.getSystemInsets")
                .put("app.ready")
                .put("app.ping")
                .put("statusBar.setStyle")
                .put("shell.getTheme")
                .put("shell.setTheme")
                .put("shell.reportHealth")
                .put("shell.setOverlay")
                .put("shell.getInputServerInfo")
                .put("playback.playNative");

        return new JSONObject()
                .put("platform", "android")
                .put("actions", actions)
                .put("aimovieNativeClientVersion", 0)
                .put("nativePlayer", new JSONObject()
                        .put("supportsNativePlayer", false)
                        .put("profile", "aimovie_native_player_v1"))
                .put("download", new JSONObject()
                        .put("supportsOfflineDanmakuSnapshot", false)
                        .put("supportsManager", false))
                .put("app", new JSONObject()
                        .put("version", ShellConfig.APP_VERSION)
                        .put("build", ShellConfig.APP_BUILD)
                        .put("bridge", ShellConfig.BRIDGE_VERSION));
    }

    // MARK: - 下行

    private void reply(String oid, JSONObject payload) {
        if (oid == null || oid.isEmpty()) return;
        final String js = "window.__nativeReply && window.__nativeReply("
                + JSONObject.quote(oid) + "," + payload.toString() + ");";
        eval(js);
    }

    public void emit(String name, JSONObject payload) {
        final String js = "window.__nativeEvent && window.__nativeEvent("
                + JSONObject.quote(name) + "," + payload.toString() + ");";
        eval(js);
    }

    /** JS 接口运行在 WebView 的 JavaBridge 线程，evaluateJavascript 必须切回主线程。 */
    private void eval(final String js) {
        web.post(new Runnable() {
            @Override public void run() {
                try { web.evaluateJavascript(js, null); }
                catch (Throwable t) { BridgeLog.e("bridge", "EVAL_FAIL " + t.getMessage()); }
            }
        });
    }

    // MARK: - JSON 小工具

    private static JSONObject ok() throws JSONException {
        return new JSONObject().put("ok", true);
    }

    private static JSONObject fail(String code, String message) throws JSONException {
        return new JSONObject().put("ok", false).put("code", code).put("message", message);
    }

    private static String firstString(JSONObject o, String... keys) {
        for (String k : keys) {
            String v = o.optString(k, "");
            if (!v.isEmpty() && !"null".equals(v)) return v;
        }
        return "";
    }

    private static JSONObject firstObject(JSONObject o, String... keys) {
        for (String k : keys) {
            JSONObject v = o.optJSONObject(k);
            if (v != null) return v;
        }
        return new JSONObject();
    }

    private static String compact(JSONObject o) {
        String s = o.toString();
        return s.length() > 480 ? s.substring(0, 480) + "…" : s;
    }
}
