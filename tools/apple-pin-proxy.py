#!/usr/bin/env python3
"""
给 Sideloadly 用的「钉 IP」本地代理。

背景：
    gsa.apple.com 是 akadns 的 CNAME，会在一组 Apple IP 之间轮询，
    其中有已经下线的地址（实测 17.32.194.2 完全不可达，SYN 直接黑洞）。
    Sideloadly 一旦解析到坏 IP，登录会永远停在 "Logging in ... 0%"，
    既不报错也不超时 —— 因为它卡在 TCP 握手，还没到应用层。

它做的事：
    本地起一个 HTTP CONNECT 代理。Apple 系域名用「钉死的可用 IP」连接，
    其它域名正常解析。Sideloadly 只要把 HTTPS_PROXY 指向本端口，
    就不再依赖本机 DNS 的运气。

用法：
    python3 tools/apple-pin-proxy.py            # 前台，Ctrl-C 结束
    python3 tools/apple-pin-proxy.py --port 18990

    # 另一个终端：
    export HTTPS_PROXY=http://127.0.0.1:18990
    export HTTP_PROXY=http://127.0.0.1:18990
    open -a /Applications/Sideloadly.app
"""

import argparse
import socket
import select
import sys
import threading
import time

# 实测可用的 Apple GSA 地址（2026-11 复测：TLS 正常，POST 返回 401）
PINNED = {
    "gsa.apple.com": "17.179.252.2",
    "gsa-alt.apple.com": "17.32.194.34",
}

# 这些域名下如果解析结果连不上，就换备用地址
APPLE_HOSTS = ("gsa.apple.com", "idmsa.apple.com", "developerservices2.apple.com")

FALLBACK = ["17.179.252.2", "17.32.194.34", "17.253.144.10"]

CONNECT_TIMEOUT = 6
BUF = 65536


def log(msg):
    sys.stderr.write("[%s] %s\n" % (time.strftime("%H:%M:%S"), msg))
    sys.stderr.flush()


def resolve_all(host):
    try:
        infos = socket.getaddrinfo(host, None, socket.AF_INET, socket.SOCK_STREAM)
        seen, out = set(), []
        for info in infos:
            ip = info[4][0]
            if ip not in seen:
                seen.add(ip)
                out.append(ip)
        return out
    except Exception as e:
        log("解析失败 %s: %s" % (host, e))
        return []


def try_connect(ip, port, timeout=CONNECT_TIMEOUT):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(timeout)
    try:
        s.connect((ip, port))
        s.settimeout(None)
        return s
    except Exception:
        try:
            s.close()
        except Exception:
            pass
        return None


def open_upstream(host, port):
    """按优先级尝试：钉死的 IP → 正常解析的全部地址 → 通用 Apple 备用 IP"""
    candidates = []

    if host in PINNED:
        candidates.append(PINNED[host])

    for ip in resolve_all(host):
        if ip not in candidates:
            candidates.append(ip)

    if any(host.endswith(h) for h in APPLE_HOSTS) or "apple.com" in host:
        for ip in FALLBACK:
            if ip not in candidates:
                candidates.append(ip)

    for ip in candidates:
        s = try_connect(ip, port)
        if s:
            if ip != candidates[0]:
                log("  %s:%d 走备用 %s" % (host, port, ip))
            return s, ip

    log("  ✗ %s:%d 所有地址都连不上 (%s)" % (host, port, ", ".join(candidates[:4])))
    return None, None


def pump(a, b):
    """双向转发直到任一端关闭"""
    socks = [a, b]
    try:
        while True:
            r, _, x = select.select(socks, [], socks, 300)
            if x or not r:
                break
            for s in r:
                other = b if s is a else a
                data = s.recv(BUF)
                if not data:
                    return
                other.sendall(data)
    except Exception:
        pass
    finally:
        for s in socks:
            try:
                s.close()
            except Exception:
                pass


def handle(conn, addr):
    try:
        conn.settimeout(30)
        # 读到请求头结束
        buf = b""
        while b"\r\n\r\n" not in buf:
            chunk = conn.recv(BUF)
            if not chunk:
                conn.close()
                return
            buf += chunk
            if len(buf) > 65536:
                conn.close()
                return

        head = buf.split(b"\r\n\r\n", 1)[0].decode("latin-1")
        lines = head.split("\r\n")
        parts = lines[0].split()
        if len(parts) < 2:
            conn.close()
            return

        method, target = parts[0], parts[1]

        if method.upper() == "CONNECT":
            host, _, port_s = target.partition(":")
            port = int(port_s or 443)
            upstream, ip = open_upstream(host, port)
            if not upstream:
                conn.sendall(b"HTTP/1.1 502 Bad Gateway\r\n\r\n")
                conn.close()
                return
            conn.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
            rest = buf.split(b"\r\n\r\n", 1)[1]
            if rest:
                upstream.sendall(rest)
            pump(conn, upstream)
            return

        # 普通 HTTP 转发（Sideloadly 会请求 http://gs.apple.com/TSS/... 之类）
        if not target.startswith("http://"):
            conn.sendall(b"HTTP/1.1 400 Bad Request\r\n\r\n")
            conn.close()
            return
        without_scheme = target[len("http://"):]
        hostport = without_scheme.split("/", 1)[0]
        host, _, port_s = hostport.partition(":")
        port = int(port_s or 80)
        path = "/" + without_scheme.split("/", 1)[1] if "/" in without_scheme else "/"

        upstream, _ = open_upstream(host, port)
        if not upstream:
            conn.sendall(b"HTTP/1.1 502 Bad Gateway\r\n\r\n")
            conn.close()
            return

        new_head = ["%s %s HTTP/1.1" % (method, path)]
        for ln in lines[1:]:
            if ln.lower().startswith("proxy-connection"):
                continue
            new_head.append(ln)
        upstream.sendall(("\r\n".join(new_head) + "\r\n\r\n").encode("latin-1"))
        rest = buf.split(b"\r\n\r\n", 1)[1]
        if rest:
            upstream.sendall(rest)
        pump(conn, upstream)
    except Exception as e:
        log("处理异常: %s" % e)
        try:
            conn.close()
        except Exception:
            pass


def serve(port):
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", port))
    srv.listen(64)
    log("监听 127.0.0.1:%d（Ctrl-C 结束）" % port)
    log("钉死: " + ", ".join("%s → %s" % kv for kv in PINNED.items()))
    while True:
        conn, addr = srv.accept()
        threading.Thread(target=handle, args=(conn, addr), daemon=True).start()


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=18990)
    args = ap.parse_args()
    try:
        serve(args.port)
    except KeyboardInterrupt:
        log("已停止")
