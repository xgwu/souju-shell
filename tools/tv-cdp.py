#!/usr/bin/env python3
"""通过 ADB + Chrome DevTools Protocol 在电视上执行 JS，取回 JSON 结果。

阶段 3 用来量首页真实几何 / 类名；也用来在不重新编译的情况下试跑 CSS 覆盖。
纯标准库实现 WebSocket 客户端（本机没装 websocket-client，也不想为一次探测装依赖）。

前置：App 已启动且 WebView.setWebContentsDebuggingEnabled(true)（MainActivity 已开启）。

用法：
  python3 tools/tv-cdp.py --expr "document.title"
  python3 tools/tv-cdp.py --expr-file /tmp/dom-probe.js --save /tmp/dom.json
  python3 tools/tv-cdp.py --expr "location.href" --page 0
"""
import argparse
import base64
import hashlib
import json
import os
import socket
import struct
import subprocess
import sys
import urllib.request

PORT = 9222


def sh(*args):
    return subprocess.run(args, capture_output=True, text=True, timeout=25)


def ensure_forward():
    r = sh("adb", "shell", "cat", "/proc/net/unix")
    pids = []
    for line in r.stdout.splitlines():
        if "webview_devtools_remote_" in line:
            pids.append(line.rsplit("_", 1)[-1].strip())
    if not pids:
        raise SystemExit("✗ 没有 webview_devtools_remote_* socket；先启动搜剧TV")
    socket_name = "webview_devtools_remote_" + pids[-1]
    sh("adb", "forward", "tcp:%d" % PORT, "localabstract:" + socket_name)
    return socket_name


def pages():
    with urllib.request.urlopen("http://127.0.0.1:%d/json/list" % PORT, timeout=5) as f:
        return [p for p in json.load(f) if p.get("type") == "page"]


class WS:
    """够用的最小 WebSocket 客户端：单帧文本、服务端 unmasked、支持 64 位长度。"""

    def __init__(self, url):
        rest = url.split("://", 1)[1]
        hostport, path = rest.split("/", 1)
        host, port = hostport.split(":")
        self.sock = socket.create_connection((host, int(port)), timeout=30)
        key = base64.b64encode(os.urandom(16)).decode()
        req = (
            "GET /%s HTTP/1.1\r\nHost: %s\r\nUpgrade: websocket\r\n"
            "Connection: Upgrade\r\nSec-WebSocket-Key: %s\r\n"
            "Sec-WebSocket-Version: 13\r\n\r\n" % (path, hostport, key)
        )
        self.sock.sendall(req.encode())
        buf = b""
        while b"\r\n\r\n" not in buf:
            buf += self.sock.recv(4096)
        head, self.buf = buf.split(b"\r\n\r\n", 1)
        if b"101" not in head.split(b"\r\n", 1)[0]:
            raise SystemExit("✗ WebSocket 握手失败: " + head.decode(errors="replace")[:300])
        accept = base64.b64encode(
            hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()
        ).decode()
        if accept not in head.decode(errors="replace"):
            raise SystemExit("✗ WebSocket accept 校验失败")

    def exact(self, n):
        while len(self.buf) < n:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise SystemExit("✗ WebSocket 连接提前关闭")
            self.buf += chunk
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def send(self, text):
        data = text.encode()
        mask = os.urandom(4)
        n = len(data)
        if n < 126:
            head = struct.pack("!BB", 0x81, 0x80 | n)
        elif n < 65536:
            head = struct.pack("!BBH", 0x81, 0x80 | 126, n)
        else:
            head = struct.pack("!BBQ", 0x81, 0x80 | 127, n)
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
        self.sock.sendall(head + mask + masked)

    def recv(self):
        while True:
            b1, b2 = struct.unpack("!BB", self.exact(2))
            opcode = b1 & 0x0F
            n = b2 & 0x7F
            if n == 126:
                n = struct.unpack("!H", self.exact(2))[0]
            elif n == 127:
                n = struct.unpack("!Q", self.exact(8))[0]
            if b2 & 0x80:
                mask = self.exact(4)
                payload = bytes(b ^ mask[i % 4] for i, b in enumerate(self.exact(n)))
            else:
                payload = self.exact(n)
            if opcode == 0x1:
                return payload.decode("utf-8", errors="replace")
            if opcode == 0x8:
                raise SystemExit("✗ WebSocket 被服务端关闭")
            # ping / 分片续帧：忽略，继续读下一帧

    def close(self):
        try:
            self.sock.close()
        except Exception:
            pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--expr", default=None)
    ap.add_argument("--expr-file", default=None)
    ap.add_argument("--save", default=None)
    ap.add_argument("--page", type=int, default=0, help="第几个 page（默认 0）")
    ap.add_argument("--raw", action="store_true", help="打印完整 CDP 回包")
    ap.add_argument("--screenshot", default=None,
                    help="额外截 WebView 内容图（PNG，不受 FLAG_SECURE 影响）")
    ap.add_argument("--await", dest="await_promise", action="store_true",
                    help="awaitPromise:true，等 Promise resolve 再取值")
    args = ap.parse_args()

    expr = args.expr
    if args.expr_file:
        with open(args.expr_file, "r", encoding="utf-8") as f:
            expr = f.read()
    if not expr:
        raise SystemExit("需要 --expr 或 --expr-file")

    name = ensure_forward()
    ps = pages()
    if not ps:
        raise SystemExit("✗ CDP 没有可调试的 page")
    target = ps[min(args.page, len(ps) - 1)]
    print("CDP %s → %s" % (name, target["url"]), file=sys.stderr)

    ws = WS(target["webSocketDebuggerUrl"])

    seq = [0]

    def call(method, params):
        # Chrome 83 的 CDP 只回整数 id 的请求；字符串 id 会被静默丢掉（实测会 30s 超时）
        seq[0] += 1
        rid = seq[0]
        ws.send(json.dumps({"id": rid, "method": method, "params": params}))
        while True:
            m = json.loads(ws.recv())
            if m.get("id") == rid:
                return m

    msg = call("Runtime.evaluate", {
        "expression": expr,
        "returnByValue": True,
        "awaitPromise": bool(args.await_promise),
        "userGesture": True,
    })

    # 截图放在 evaluate 之后：常用流程是「注入 CSS → 立刻看效果」
    if args.screenshot:
        shot = call("Page.captureScreenshot", {"format": "png", "captureBeyondViewport": False})
        data = shot.get("result", {}).get("data")
        if not data:
            print("截图失败: " + json.dumps(shot, ensure_ascii=False)[:400], file=sys.stderr)
        else:
            with open(args.screenshot, "wb") as f:
                f.write(base64.b64decode(data))
            print("截图已保存: " + args.screenshot, file=sys.stderr)
    ws.close()

    if args.raw:
        print(json.dumps(msg, ensure_ascii=False, indent=2))
        return
    result = msg.get("result", {})
    if "exceptionDetails" in result:
        print("JS 异常: " + json.dumps(result["exceptionDetails"], ensure_ascii=False, indent=2))
        sys.exit(2)
    value = result.get("result", {}).get("value")
    text = value if isinstance(value, str) else json.dumps(value, ensure_ascii=False, indent=2)
    print(text)
    if args.save:
        with open(args.save, "w", encoding="utf-8") as f:
            f.write(text if isinstance(text, str) else json.dumps(text))
        print("已保存: " + args.save, file=sys.stderr)


if __name__ == "__main__":
    main()
