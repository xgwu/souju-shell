#!/usr/bin/env python3
"""在雷鸟电视的系统 WebView 里实测 JS / CSS 能力边界。

前置：adb 已连上电视（bash tools/probe-tv.sh 可先跑一遍）。
原理：Mac 起一个一次性 HTTP 服务，用自带浏览器打开探针页，
      页面把能力检测结果 POST 回来，本进程打印 JSON 后退出。
      已验证 com.tcl.browser 用的就是系统 com.android.webview。

用法：
  python3 tools/tv-webview-probe.py [--port 8768] [--host 192.168.0.21] [--save 路径.json]
"""
import argparse
import json
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

HTML = r"""<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
<title>WebView capability probe</title></head>
<body style="background:#111;color:#eee;font:15px monospace;padding:16px">
<h2>WebView capability probe</h2><pre id="o">running</pre>
<script>
var R={ua:navigator.userAgent,viewport:[innerWidth,innerHeight,devicePixelRatio]};
function can(c){try{new Function(c);return true}catch(e){return false}}
R.syntax={optionalChaining:can('var a={};a?.b'),nullish:can('var a=null;a??1'),
 logicalNullishAssign:can('var a=1;a??=2'),logicalAndAssign:can('var a=1;a&&=2'),
 staticClassFields:can('class A{static x=1}'),privateFields:can('class A{#x=1}')};
R.js={
 Array_at:typeof Array.prototype.at,Array_findLast:typeof Array.prototype.findLast,
 Array_toSorted:typeof Array.prototype.toSorted,String_replaceAll:typeof ''.replaceAll,
 Object_hasOwn:typeof Object.hasOwn,Promise_any:typeof Promise.any,
 Promise_allSettled:typeof Promise.allSettled,structuredClone:typeof structuredClone,
 WeakRef:typeof WeakRef,FinalizationRegistry:typeof FinalizationRegistry,
 AggregateError:typeof AggregateError,Array_flatMap:typeof [].flatMap,
 crypto_randomUUID:(typeof crypto!=='undefined')?typeof crypto.randomUUID:'no-crypto',
 AbortSignal_timeout:(typeof AbortSignal!=='undefined')?typeof AbortSignal.timeout:'no-AbortSignal',
 Intl_Segmenter:(typeof Intl!=='undefined'&&Intl.Segmenter)?'function':'undefined',
 ResizeObserver:typeof ResizeObserver,IntersectionObserver:typeof IntersectionObserver,
 MediaSource:typeof MediaSource,
 mseH264:(typeof MediaSource!=='undefined')?MediaSource.isTypeSupported('video/mp4; codecs="avc1.42E01E"'):null,
 mseHEVC:(typeof MediaSource!=='undefined')?MediaSource.isTypeSupported('video/mp4; codecs="hev1.1.6.L93.B0"'):null};
var v=document.createElement('video');
R.video={hlsNative:v.canPlayType('application/vnd.apple.mpegurl'),
 h264:v.canPlayType('video/mp4; codecs="avc1.42E01E"'),
 hevc:v.canPlayType('video/mp4; codecs="hev1.1.6.L93.B0"'),
 vp9:v.canPlayType('video/webm; codecs="vp9"')};
function sup(p,x){try{return CSS.supports(p,x)}catch(e){return 'err'}}
function sel(s){try{return CSS.supports('selector('+s+')')}catch(e){return 'err'}}
R.css={
 flexGap:(function(){var d=document.createElement('div');
  d.style.cssText='display:flex;gap:10px;position:absolute;visibility:hidden';
  d.innerHTML='<div style="width:10px;height:10px"></div><div style="width:10px;height:10px"></div>';
  document.body.appendChild(d);var x=d.children[1].offsetLeft;d.remove();return x})(),
 aspectRatio:sup('aspect-ratio','1'),selector_has:sel(':has(*)'),
 selector_focusVisible:sel(':focus-visible'),inset:sup('inset','0'),
 clamp:sup('width','clamp(1px,2px,3px)'),backdropFilter:sup('backdrop-filter','blur(1px)'),
 contentVisibility:sup('content-visibility','auto'),gridGap:sup('grid-gap','1px'),
 objectPosition:sup('object-position','center 46%'),positionSticky:sup('position','sticky')};
document.getElementById('o').textContent=JSON.stringify(R,null,2);
fetch('/report',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(R)});
</script></body></html>"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8768)
    ap.add_argument("--host", default=None, help="Mac 的局域网 IP，默认自动探测 en0/en1")
    ap.add_argument("--save", default=None)
    args = ap.parse_args()

    host = args.host
    if not host:
        for iface in ("en0", "en1"):
            r = subprocess.run(["ipconfig", "getifaddr", iface], capture_output=True, text=True)
            if r.returncode == 0 and r.stdout.strip():
                host = r.stdout.strip()
                break
    if not host:
        raise SystemExit("无法自动取得本机局域网 IP，请用 --host 指定")

    done = threading.Event()
    report = {}
    log = []

    class H(BaseHTTPRequestHandler):
        def do_GET(self):
            log.append("GET " + self.path)
            b = HTML.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(b)))
            self.end_headers()
            self.wfile.write(b)

        def do_POST(self):
            n = int(self.headers.get("Content-Length", 0))
            log.append("POST " + self.path)
            try:
                report.update(json.loads(self.rfile.read(n).decode()))
            except Exception as e:
                print("parse error:", e)
            self.send_response(200)
            self.send_header("Content-Length", "2")
            self.end_headers()
            self.wfile.write(b"ok")
            done.set()

        def log_message(self, *a):
            pass

    srv = HTTPServer(("0.0.0.0", args.port), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    url = "http://%s:%d/probe.html" % (host, args.port)
    print("probe server: %s" % url, flush=True)

    def adb(*a):
        return subprocess.run(["adb", "shell", *a], capture_output=True, text=True, timeout=25)

    adb("input", "keyevent", "224")  # WAKEUP，避开屏保导致黑屏
    adb("am", "force-stop", "com.tcl.browser")  # 必须强停，否则 Intent 只交给前台实例不重新加载
    print(adb("am", "start", "-a", "android.intent.action.VIEW", "-d", url).stdout.strip())

    ok = done.wait(30)
    srv.shutdown()
    print("HTTP:", ", ".join(log) or "(无请求)")
    if not ok:
        raise SystemExit("✗ 30 秒内未收到报告；确认 adb devices 状态为 device，且电视与 Mac 同网段")
    print(json.dumps(report, ensure_ascii=False, indent=2))
    if args.save:
        with open(args.save, "w") as f:
            json.dump(report, f, ensure_ascii=False, indent=2)
        print("已保存:", args.save)


if __name__ == "__main__":
    main()
