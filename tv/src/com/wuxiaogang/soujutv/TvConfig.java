package com.wuxiaogang.soujutv;

import android.content.Context;
import android.content.SharedPreferences;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.ArrayList;
import java.util.List;

/**
 * 阶段 6：远程线路配置。
 *
 * 站点是域名轮换架构，换域名时如果只能重装 APK，电视上就没法自救。这里让壳
 * 启动时异步拉一份 JSON，校验后落 SharedPreferences，下次启动即用新线路。
 *
 * 下发格式（放在任意静态托管上，Content-Type: application/json）：
 * <pre>
 * {
 *   "version": 3,
 *   "lines":   ["https://souju.ai", "https://hctd4.com"],
 *   "trusted": ["bpz2.com"],
 *   "notice":  "换域名说明",
 *   "minBuild": 6
 * }
 * </pre>
 *
 * 三条硬约束：
 *  - 只接受 http/https 且最多 8 条；不认识的字段全部忽略，不因为配置写错就崩。
 *  - 版本号不高于本地时不覆盖（避免把本地手工改的线路顶掉）。
 *  - 网络失败一律静默：电视断网是常态，拉不到配置不能影响起播。
 *
 * 备用通道：局域网输入页（LocalInputServer）的 /api/config 可以直接推 JSON，
 * 适合家里临时改线路，不用等公网托管。
 */
public final class TvConfig {

    public interface Callback {
        /** changed=true 表示线路确实变了；error 为 null 表示成功。 */
        void onConfig(JSONObject summary, boolean changed, String error);
    }

    private static final String PREFS = "souju_tv_config";
    private static final String K_LINES = "lines";          // 换行分隔
    private static final String K_TRUSTED = "trusted";      // 逗号分隔
    private static final String K_VERSION = "version";
    private static final String K_FETCHED = "fetchedAt";
    private static final String K_URL = "url";
    private static final String K_ETAG = "etag";
    private static final String K_SOURCE = "source";
    private static final String K_NOTICE = "notice";

    private static final int MAX_LINES = 8;

    private TvConfig() {}

    private static SharedPreferences prefs(Context c) {
        return c.getApplicationContext().getSharedPreferences(PREFS, Context.MODE_PRIVATE);
    }

    public static String url(Context c) {
        return prefs(c).getString(K_URL, ShellConfig.REMOTE_CONFIG_URL);
    }

    public static void setUrl(Context c, String u) {
        if (u == null) return;
        String v = u.trim();
        if (v.isEmpty()) return;
        prefs(c).edit().putString(K_URL, v).apply();
        BridgeLog.i("config", "CONFIG_URL_SET " + v);
    }

    /** 清掉远程地址（已应用过的线路保留，仍然有效）。 */
    public static void clearUrl(Context c) {
        prefs(c).edit().remove(K_URL).remove(K_ETAG).apply();
        BridgeLog.i("config", "CONFIG_URL_CLEARED");
    }

    /** 已缓存的线路；没有配置过返回 null（调用方回落到内置线路）。 */
    public static String[] lines(Context c) {
        String raw = prefs(c).getString(K_LINES, "");
        if (raw == null || raw.isEmpty()) return null;
        String[] parts = raw.split("\n");
        List<String> out = new ArrayList<>();
        for (String p : parts) {
            String v = ShellConfig.normalize(p);
            if (v != null) out.add(v);
        }
        return out.isEmpty() ? null : out.toArray(new String[0]);
    }

    public static String trustedCsv(Context c) {
        return prefs(c).getString(K_TRUSTED, "");
    }

    public static int version(Context c) {
        return prefs(c).getInt(K_VERSION, 0);
    }

    public static JSONObject summary(Context c) {
        JSONObject o = new JSONObject();
        try {
            String[] l = lines(c);
            JSONArray arr = new JSONArray();
            if (l != null) { for (String s : l) arr.put(s); }
            o.put("ok", true)
                    .put("version", version(c))
                    .put("lines", arr)
                    .put("trusted", prefs(c).getString(K_TRUSTED, ""))
                    .put("url", url(c))
                    .put("source", prefs(c).getString(K_SOURCE, ""))
                    .put("fetchedAt", prefs(c).getLong(K_FETCHED, 0))
                    .put("notice", prefs(c).getString(K_NOTICE, ""));
        } catch (Throwable t) {
            BridgeLog.w("config", "SUMMARY_FAIL " + t.getMessage());
        }
        return o;
    }

    /**
     * 应用一份配置文本。返回是否真的改了线路。
     * 手工通道（局域网推送 / adb）传 force=true，跳过版本号比较。
     */
    public static synchronized boolean applyJson(Context c, String json, String source, boolean force) {
        if (json == null || json.trim().isEmpty()) return false;
        try {
            JSONObject o = new JSONObject(json);
            int incoming = o.optInt("version", 0);
            int current = version(c);
            List<String> lines = new ArrayList<>();
            JSONArray arr = o.optJSONArray("lines");
            if (arr != null) {
                for (int i = 0; i < arr.length() && lines.size() < MAX_LINES; i++) {
                    String raw = arr.optString(i, "");
                    if (raw == null || raw.trim().isEmpty()) continue;
                    if (!raw.startsWith("http://") && !raw.startsWith("https://")) {
                        BridgeLog.w("config", "CONFIG_SKIP 非法线路 " + raw);
                        continue;
                    }
                    lines.add(raw.trim());
                }
            }
            if (lines.isEmpty()) {
                BridgeLog.w("config", "CONFIG_EMPTY 没有可用线路，忽略本次下发");
                return false;
            }
            if (!force && incoming > 0 && incoming <= current) {
                BridgeLog.i("config", "CONFIG_STALE v" + incoming + " <= v" + current + "，保留本地");
                return false;
            }

            StringBuilder sb = new StringBuilder();
            for (String l : lines) {
                if (sb.length() > 0) sb.append('\n');
                sb.append(l);
            }
            StringBuilder trusted = new StringBuilder();
            JSONArray tArr = o.optJSONArray("trusted");
            if (tArr != null) {
                for (int i = 0; i < tArr.length(); i++) {
                    String h = tArr.optString(i, "").trim();
                    if (h.isEmpty()) continue;
                    if (trusted.length() > 0) trusted.append(',');
                    trusted.append(h);
                }
            }

            String before = prefs(c).getString(K_LINES, "");
            SharedPreferences.Editor e = prefs(c).edit()
                    .putString(K_LINES, sb.toString())
                    .putInt(K_VERSION, incoming > 0 ? incoming : current + 1)
                    .putLong(K_FETCHED, System.currentTimeMillis())
                    .putString(K_SOURCE, source == null ? "" : source)
                    .putString(K_NOTICE, o.optString("notice", ""));
            if (trusted.length() > 0) e.putString(K_TRUSTED, trusted.toString());
            e.apply();

            boolean changed = !sb.toString().equals(before);
            BridgeLog.i("config", "CONFIG_APPLIED v" + incoming + " lines=" + lines.size()
                    + " trusted=" + trusted + " source=" + source + " changed=" + changed);
            return changed;
        } catch (Throwable t) {
            BridgeLog.e("config", "CONFIG_PARSE_FAIL " + t.getMessage());
            return false;
        }
    }

    /** 启动时异步拉一次。任何异常都只写日志，绝不影响起播。 */
    public static void fetchAsync(final Context ctx, final String cfgUrl, final Callback cb) {
        if (cfgUrl == null || cfgUrl.trim().isEmpty()) {
            BridgeLog.i("config", "CONFIG_SKIP 未配置远程地址（可用 --es config <url> 或手机页下发）");
            if (cb != null) cb.onConfig(summary(ctx), false, "no_url");
            return;
        }
        final String useUrl = cfgUrl.trim();
        Thread t = new Thread(new Runnable() {
            @Override public void run() {
                HttpURLConnection conn = null;
                String error = null;
                boolean changed = false;
                try {
                    URL u = new URL(useUrl);
                    if (!"http".equals(u.getProtocol()) && !"https".equals(u.getProtocol())) {
                        throw new IllegalArgumentException("only http(s)");
                    }
                    conn = (HttpURLConnection) u.openConnection();
                    conn.setConnectTimeout(4000);
                    conn.setReadTimeout(4500);
                    conn.setRequestMethod("GET");
                    conn.setRequestProperty("User-Agent", ShellConfig.UA);
                    conn.setRequestProperty("Accept", "application/json");
                    String etag = prefs(ctx).getString(K_ETAG, "");
                    if (!etag.isEmpty()) conn.setRequestProperty("If-None-Match", etag);

                    int code = conn.getResponseCode();
                    BridgeLog.i("config", "CONFIG_FETCH " + code + " " + useUrl);
                    if (code == HttpURLConnection.HTTP_NOT_MODIFIED) {
                        error = "not_modified";
                    } else if (code == HttpURLConnection.HTTP_OK) {
                        String body = readAll(conn.getInputStream());
                        changed = applyJson(ctx, body, useUrl, false);
                        String newEtag = conn.getHeaderField("ETag");
                        if (newEtag != null && !newEtag.isEmpty()) {
                            prefs(ctx).edit().putString(K_ETAG, newEtag).apply();
                        }
                    } else {
                        error = "http_" + code;
                    }
                } catch (Throwable e) {
                    error = e.getClass().getSimpleName() + ":" + e.getMessage();
                    BridgeLog.w("config", "CONFIG_FETCH_FAIL " + error);
                } finally {
                    if (conn != null) { try { conn.disconnect(); } catch (Throwable ignored) {} }
                }
                if (cb != null) cb.onConfig(summary(ctx), changed, error);
            }
        }, "souju-tv-config");
        t.setDaemon(true);
        t.start();
    }

    private static String readAll(InputStream in) throws Exception {
        BufferedReader r = new BufferedReader(new InputStreamReader(in, "UTF-8"));
        StringBuilder sb = new StringBuilder();
        String line;
        while ((line = r.readLine()) != null) {
            sb.append(line).append('\n');
            if (sb.length() > 64 * 1024) break;
        }
        r.close();
        return sb.toString();
    }
}
