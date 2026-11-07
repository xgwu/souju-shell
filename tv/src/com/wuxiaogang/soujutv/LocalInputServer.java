package com.wuxiaogang.soujutv;

import java.io.BufferedReader;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.NetworkInterface;
import java.net.ServerSocket;
import java.net.Socket;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.util.Enumeration;
import java.util.Locale;

/**
 * 阶段 4：电视上的极简局域网 HTTP 服务，手机扫码后打开输入页。
 *
 * 只用 JDK + Android SDK 自带的类，零第三方依赖：
 *   GET  /?k=<pin>              手机输入页（自包含 HTML）
 *   POST /send?k=<pin>          表单提交文字
 *   GET  /api/send?k=&text=     供 curl / 自动化验收
 *   GET  /api/state             地址与配对码（诊断用）
 *
 * 安全边界：只监听局域网，所有请求必须带本次启动随机生成的 4 位配对码；
 * 二维码里就带这个码，同网段其它设备猜不到，也不会有外部服务参与。
 */
public final class LocalInputServer {

    public interface Callback {
        void onRemoteText(String text, long issuedAtMs);
    }

    private final int port;
    private final String pin;
    private final Callback callback;
    private volatile boolean running = false;
    private ServerSocket serverSocket;
    private String cachedQr = "";

    public LocalInputServer(int port, String pin, Callback callback) {
        this.port = port;
        this.pin = pin;
        this.callback = callback;
    }

    public String pin() { return pin; }

    public String ip() { return lanIpv4(); }

    public String url() { return "http://" + ip() + ":" + port + "/?k=" + pin; }

    public String qrDataUri() {
        if (cachedQr.isEmpty()) { cachedQr = QrGen.pngDataUri(url()); }
        return cachedQr;
    }

    public synchronized void start() {
        if (running) return;
        try {
            serverSocket = new ServerSocket(port);
            serverSocket.setReuseAddress(true);
            running = true;
            Thread t = new Thread(new Runnable() {
                @Override public void run() { acceptLoop(); }
            }, "souju-tv-input");
            t.setDaemon(true);
            t.start();
            BridgeLog.i("input", "INPUT_SERVER_START " + url());
        } catch (Throwable t) {
            BridgeLog.e("input", "INPUT_SERVER_FAIL " + t.getMessage());
        }
    }

    public synchronized void stop() {
        running = false;
        if (serverSocket != null) {
            try { serverSocket.close(); } catch (Throwable ignored) {}
            serverSocket = null;
        }
        BridgeLog.i("input", "INPUT_SERVER_STOP");
    }

    private void acceptLoop() {
        while (running && serverSocket != null) {
            try {
                final Socket socket = serverSocket.accept();
                socket.setSoTimeout(8000);
                Thread worker = new Thread(new Runnable() {
                    @Override public void run() { handle(socket); }
                }, "souju-tv-input-client");
                worker.setDaemon(true);
                worker.start();
            } catch (Throwable t) {
                if (running) { BridgeLog.w("input", "ACCEPT " + t.getClass().getSimpleName()); }
            }
        }
    }

    private void handle(Socket socket) {
        try {
            InputStream in = socket.getInputStream();
            BufferedReader reader = new BufferedReader(new InputStreamReader(in, "UTF-8"));
            String line = reader.readLine();
            if (line == null) { return; }
            int contentLength = 0;
            String header;
            while ((header = reader.readLine()) != null && !header.isEmpty()) {
                if (header.toLowerCase(Locale.US).startsWith("content-length:")) {
                    try {
                        contentLength = Integer.parseInt(header.substring(15).trim());
                    } catch (NumberFormatException ignored) {}
                }
            }
            String body = "";
            if (contentLength > 0 && contentLength < 8192) {
                char[] buf = new char[contentLength];
                int n = 0, r;
                while (n < contentLength && (r = reader.read(buf, n, contentLength - n)) > 0) {
                    n += r;
                }
                body = new String(buf, 0, n);
            }

            String[] parts = line.split(" ");
            String method = parts.length > 0 ? parts[0] : "GET";
            String target = parts.length > 1 ? parts[1] : "/";
            int qm = target.indexOf('?');
            String path = qm >= 0 ? target.substring(0, qm) : target;
            String query = qm >= 0 ? target.substring(qm + 1) : "";

            if (!pin.equals(param(query, "k"))) {
                write(socket, 403, "text/plain; charset=utf-8", "forbidden");
                return;
            }

            if (path.equals("/api/state")) {
                String json = "{\"ok\":true,\"url\":" + jstr(url())
                        + ",\"pin\":" + jstr(pin) + ",\"port\":" + port + "}";
                write(socket, 200, "application/json; charset=utf-8", json);
                return;
            }
            if (path.equals("/api/send")) {
                String text = param(query, "text");
                deliver(text);
                write(socket, 200, "application/json; charset=utf-8",
                        "{\"ok\":true,\"text\":" + jstr(text) + "}");
                return;
            }
            if (path.equals("/send") && "POST".equals(method)) {
                String text = param(body, "text");
                deliver(text);
                write(socket, 200, "text/html; charset=utf-8", okPage(text));
                return;
            }
            if (path.equals("/") || path.equals("/index.html")) {
                write(socket, 200, "text/html; charset=utf-8", inputPage());
                return;
            }
            write(socket, 404, "text/plain; charset=utf-8", "not found");
        } catch (Throwable t) {
            BridgeLog.w("input", "REQUEST " + t.getClass().getSimpleName());
        } finally {
            try { socket.close(); } catch (Throwable ignored) {}
        }
    }

    private void deliver(String text) {
        if (text == null) return;
        String v = text.replaceAll("\\s+", " ").trim();
        if (v.length() > 160) { v = v.substring(0, 160); }
        if (v.isEmpty()) return;
        final String safe = v;
        BridgeLog.i("input", "REMOTE_TEXT len=" + safe.length() + " " + safe);
        callback.onRemoteText(safe, System.currentTimeMillis());
    }

    private static void write(Socket socket, int code, String type, String body) {
        try {
            byte[] bytes = body.getBytes(StandardCharsets.UTF_8);
            OutputStream out = socket.getOutputStream();
            String status = code == 200 ? "OK" : (code == 403 ? "Forbidden" : "Not Found");
            out.write(("HTTP/1.1 " + code + " " + status + "\r\n"
                    + "Content-Type: " + type + "\r\n"
                    + "Content-Length: " + bytes.length + "\r\n"
                    + "Connection: close\r\n"
                    + "Cache-Control: no-store\r\n\r\n").getBytes("UTF-8"));
            out.write(bytes);
            out.flush();
        } catch (Throwable t) {
            BridgeLog.w("input", "WRITE " + t.getClass().getSimpleName());
        }
    }

    private String inputPage() {
        return "<!doctype html><html lang=\"zh-CN\"><head>"
                + "<meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
                + "<title>搜剧TV · 手机输入</title><style>"
                + "body{background:#0E0E10;color:#F2F1ED;font:17px/1.6 -apple-system,sans-serif;margin:0;padding:26px}"
                + "h1{font-size:22px;margin:0 0 6px}p{color:#BCB9B3;margin:0 0 20px}"
                + "textarea{width:100%;box-sizing:border-box;min-height:110px;background:#191A1D;color:#F2F1ED;"
                + "border:1px solid #3a3c42;border-radius:14px;padding:14px;font-size:18px}"
                + "button{margin-top:18px;width:100%;height:54px;border:0;border-radius:14px;"
                + "background:#FF6B42;color:#12100F;font-size:19px;font-weight:700}"
                + "</style></head><body>"
                + "<h1>搜剧TV · 手机输入</h1><p>输入后自动送到电视并搜索，不用在电视上打字。</p>"
                + "<form method=\"post\" action=\"/send?k=" + pin + "\">"
                + "<textarea name=\"text\" maxlength=\"160\" autofocus placeholder=\"例如：想看节奏快的悬疑剧\"></textarea>"
                + "<button type=\"submit\">发送到电视</button></form></body></html>";
    }

    private String okPage(String text) {
        return "<!doctype html><html lang=\"zh-CN\"><head><meta charset=\"utf-8\">"
                + "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
                + "<title>已发送</title><style>body{background:#0E0E10;color:#F2F1ED;"
                + "font:18px/1.6 -apple-system,sans-serif;padding:28px}"
                + "a{color:#FFB08F}</style></head><body>"
                + "<h2>已发送到电视</h2><p>" + escape(text) + "</p>"
                + "<p><a href=\"/?k=" + pin + "\">继续输入</a></p></body></html>";
    }

    private static String escape(String s) {
        if (s == null) return "";
        return s.replace("&", "&amp;").replace("<", "&lt;")
                .replace(">", "&gt;").replace("\"", "&quot;");
    }

    private static String jstr(String s) {
        return "\"" + (s == null ? "" : s.replace("\\", "\\\\").replace("\"", "\\\"")) + "\"";
    }

    private static String param(String src, String key) {
        if (src == null || src.isEmpty()) return "";
        for (String pair : src.split("&")) {
            int eq = pair.indexOf('=');
            String k = eq >= 0 ? pair.substring(0, eq) : pair;
            if (!k.equals(key)) continue;
            String v = eq >= 0 ? pair.substring(eq + 1) : "";
            try { return URLDecoder.decode(v, "UTF-8"); }
            catch (Throwable t) { return v; }
        }
        return "";
    }

    /** 取一个真实的局域网 IPv4（优先 wlan0 / eth0），不申请任何权限。 */
    private static String lanIpv4() {
        try {
            Enumeration<NetworkInterface> ifs = NetworkInterface.getNetworkInterfaces();
            String fallback = "";
            while (ifs != null && ifs.hasMoreElements()) {
                NetworkInterface ni = ifs.nextElement();
                if (!ni.isUp() || ni.isLoopback()) continue;
                String name = ni.getName().toLowerCase(Locale.US);
                Enumeration<InetAddress> addrs = ni.getInetAddresses();
                while (addrs.hasMoreElements()) {
                    InetAddress a = addrs.nextElement();
                    if (a.isLoopbackAddress() || a.getAddress().length != 4) continue;
                    String ip = a.getHostAddress();
                    if (ip == null || ip.isEmpty()) continue;
                    if (fallback.isEmpty()) fallback = ip;
                    if (name.startsWith("wlan") || name.startsWith("eth")) return ip;
                }
            }
            return fallback.isEmpty() ? "127.0.0.1" : fallback;
        } catch (Throwable t) {
            return "127.0.0.1";
        }
    }
}
