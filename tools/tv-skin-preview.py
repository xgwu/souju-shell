#!/usr/bin/env python3
"""装机前试跑 TV 皮肤：唤醒 → 前台重载 → 注入本地 CSS/JS → CDP 截图 + 几何自检。

改一版 CSS 不用重编译 APK：这个脚本直接把 tv/assets/tv-skin.css 和
tv-skin.js 通过 CDP 注入电视上正在运行的 WebView，截图看效果。
正式装机后由 App 自己注入，这个工具只用于开发迭代。

用法：
  python3 tools/tv-skin-preview.py                    # 输出 /tmp/tv-skin-preview.png
  python3 tools/tv-skin-preview.py --out /tmp/a.png
  python3 tools/tv-skin-preview.py --no-reload       # App 已前台时跳过重载（更快）
  python3 tools/tv-skin-preview.py --off             # 移除皮肤，回到原始版式
"""
import argparse
import json
import pathlib
import subprocess
import sys
import time
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]
PKG = "com.wuxiaogang.soujutv/.MainActivity"
CDP = ROOT / "tools/tv-cdp.py"


def adb(*args):
    return subprocess.run(["adb", "shell", *args], capture_output=True, text=True, timeout=30)


def cdp(expr, screenshot=None):
    expr_file = pathlib.Path("/tmp/tv-skin-preview-expr.js")
    expr_file.write_text(expr, encoding="utf-8")
    cmd = [sys.executable, str(CDP), "--expr-file", str(expr_file)]
    if screenshot:
        cmd += ["--screenshot", str(screenshot)]
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=75)
    if r.returncode != 0:
        print(r.stderr[-800:], file=sys.stderr)
    return r.stdout.strip()


def report_expr():
    return """(function(){
function B(s){var e=document.querySelector(s);if(!e)return null;var r=e.getBoundingClientRect();
 return [Math.round(r.left),Math.round(r.top),Math.round(r.width),Math.round(r.height)];}
function F(s,p){var e=document.querySelector(s);if(!e)return '(missing)';
 try{return getComputedStyle(e)[p];}catch(e2){return '(err)';}}
var st={};try{st=JSON.parse(window.__tvSkinState?window.__tvSkinState():'{}');}catch(e){st={error:String(e)};}
var w=document.querySelector('.movie-page-body > div');var blocks=[];
if(w){for(var i=0;i<w.children.length;i++){var c=w.children[i];var r=c.getBoundingClientRect();
 blocks.push([i,Math.round(r.top),Math.round(r.height),getComputedStyle(c).order,(c.innerText||'').trim().slice(0,14)]);}}
return JSON.stringify({
 skin:document.documentElement.getAttribute('data-tv-skin'),state:st,
 vp:[innerWidth,innerHeight],
 docScroll:[document.documentElement.scrollWidth,document.documentElement.scrollHeight],
 shellPad:F('.movie-main-shell','paddingLeft'),
 side:F('.movie-side-menu-panel','display'),
 nav:B('.app-primary-nav-desktop'),composer:B('.movie-composer-root'),
 chips:B('.movie-home-prompt-groups'),tonight:B('.tv-tonight-card'),
 track:B('.home-feed-rail-track'),card:B('.home-feed-card'),
 cardTitleFont:F('.home-feed-card-title','fontSize'),
 inputFont:F('.movie-composer-text-input','fontSize'),
 navFont:F('.app-primary-nav-link','fontSize'),
 blocks:blocks
},null,1);})()"""


def inject_expr():
    css = (ROOT / "tv/assets/tv-skin.css").read_text(encoding="utf-8")
    js = (ROOT / "tv/assets/tv-skin.js").read_text(encoding="utf-8")
    head = """(function(){
var s=document.getElementById('__tvSkinCss');
if(!s){s=document.createElement('style');s.id='__tvSkinCss';document.head.appendChild(s);}
s.textContent=%s;
})();
""" % json.dumps(css, ensure_ascii=False)
    # 注入这一步不取几何：站点 SPA 的首屏是懒加载的，等 3 秒再单独量
    return head + js + "\n'TVSKIN_PREVIEW_INJECTED'"


def off_expr():
    return """(function(){
var s=document.getElementById('__tvSkinCss');if(s&&s.parentNode){s.parentNode.removeChild(s);}
document.documentElement.removeAttribute('data-tv-skin');
document.documentElement.style.removeProperty('--movie-sidebar-width');
var m=['data-tv-nav-host','data-tv-hero','data-tv-secondary-chips','data-tv-feed','data-tv-late','data-tv-tail'];
for(var i=0;i<m.length;i++){var l=document.querySelectorAll('['+m[i]+']');
 for(var j=0;j<l.length;j++){l[j].removeAttribute(m[i]);}}
var t=document.querySelector('.tv-tonight-card');if(t&&t.parentNode){t.parentNode.removeChild(t);}
return 'skin=off';})()"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="/tmp/tv-skin-preview.png")
    ap.add_argument("--no-reload", action="store_true")
    ap.add_argument("--off", action="store_true")
    args = ap.parse_args()

    if not args.no_reload:
        adb("input", "keyevent", "224")          # WAKEUP，避开 Dreaming
        adb("am", "start", "-n", PKG)            # 带 Activity 到前台（会重载页面）
        time.sleep(6)
    else:
        adb("input", "keyevent", "224")

    print(cdp(off_expr() if args.off else inject_expr()), flush=True)
    if not args.off:
        time.sleep(3)
        # 截图与几何报告同一次 CDP 连接完成，避免中途睡眠导致 WebView 又不可见
        print(cdp(report_expr(), screenshot=args.out), flush=True)
        print("截图: " + args.out, flush=True)


if __name__ == "__main__":
    main()
