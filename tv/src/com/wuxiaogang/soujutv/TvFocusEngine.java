package com.wuxiaogang.soujutv;

import android.content.Context;
import android.view.KeyEvent;
import android.webkit.ValueCallback;
import android.webkit.WebView;

import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;

/** 注入器（assets → evaluateJavascript）与遥控器按键映射。 */
public final class TvFocusEngine {

    private TvFocusEngine() {}

    public static String readAsset(Context ctx, String name) {
        try {
            InputStream in = ctx.getAssets().open(name);
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            byte[] buf = new byte[4096];
            int n;
            while ((n = in.read(buf)) > 0) { out.write(buf, 0, n); }
            in.close();
            return out.toString("UTF-8");
        } catch (Exception e) {
            BridgeLog.e("inject", "读取 asset 失败 " + name + ": " + e.getMessage());
            return "";
        }
    }

    /**
     * 一次把三层脚本注入当前文档。所有层都幂等，可被 start / progress / finish 重复调用。
     * 可信 host 才下发桥（令牌藏在其中），不可信 host 只给焦点引擎，让遥控器还能按返回。
     */
    public static void inject(WebView web, Context ctx, NativeBridge bridge,
                              String url, String phase, boolean trusted) {
        if (web == null) return;
        final String u = url == null ? "" : url;

        if (trusted) {
            String src = readAsset(ctx, "bridge.js")
                    .replace("__SOUJU_TOKEN__", bridge.token());
            if (!src.isEmpty()) {
                web.evaluateJavascript(src, new ValueCallback<String>() {
                    @Override public void onReceiveValue(String value) { /* 无返回 */ }
                });
            }
        }

        String focus = readAsset(ctx, "focus.js");
        if (!focus.isEmpty()) web.evaluateJavascript(focus, null);

        String css = readAsset(ctx, "focus.css");
        if (!css.isEmpty()) {
            // onPageStarted 时文档可能刚创建、document.head 还是 null。
            // 不能直接 appendChild，否则每次启动都抛一次 Uncaught TypeError。
            // 挂 DOMContentLoaded 兜底；finish 阶段再调用时 head 已存在，会直接成功。
            String js = "(function(){"
                    + "function add(){"
                    + "  if(document.getElementById('__tvFocusCss'))return true;"
                    + "  var host=document.head||document.documentElement;"
                    + "  if(!host)return false;"
                    + "  var s=document.createElement('style');s.id='__tvFocusCss';"
                    + "  s.textContent=" + JSONObject.quote(css) + ";"
                    + "  host.appendChild(s);return true;"
                    + "}"
                    + "if(!add()&&document.addEventListener){"
                    + "  document.addEventListener('DOMContentLoaded',add,false);"
                    + "}"
                    + "})();";
            web.evaluateJavascript(js, null);
        }

        if ("start".equals(phase) || "finish".equals(phase)) {
            BridgeLog.i("inject", "INJECT " + phase + " trusted=" + trusted + " @ " + u);
        }
    }

    /** 把 Android keyCode 映射成引擎动作；返回 null 表示不接管。 */
    public static String actionFor(int keyCode) {
        switch (keyCode) {
            case KeyEvent.KEYCODE_DPAD_UP:    return "up";
            case KeyEvent.KEYCODE_DPAD_DOWN:  return "down";
            case KeyEvent.KEYCODE_DPAD_LEFT:  return "left";
            case KeyEvent.KEYCODE_DPAD_RIGHT: return "right";
            case KeyEvent.KEYCODE_DPAD_CENTER:
            case KeyEvent.KEYCODE_ENTER:
            case KeyEvent.KEYCODE_NUMPAD_ENTER: return "ok";
            default: return null;
        }
    }

    public static boolean isRemoteKey(int keyCode) {
        return actionFor(keyCode) != null
                || keyCode == KeyEvent.KEYCODE_BACK
                || keyCode == KeyEvent.KEYCODE_MENU;
    }

    /** 按键转发。回包带焦点轨迹 + 焦点环计算样式，用来在不看屏幕的情况下验证「有没有斜跳」「焦点环是否可见」。 */
    public static void key(final WebView web, final String action) {
        String js = "(function(){try{"
                + "var r=window.__tvKey?window.__tvKey(" + JSONObject.quote(action) + ")"
                + ":'{\"note\":\"not-installed\"}';"
                + "var el=document.querySelector('.tv-focused');"
                + "var ring='none',inline='none',tag='none',cls='';"
                + "if(el){var st=window.getComputedStyle(el);"
                + " ring=st.outlineWidth+' '+st.outlineStyle+' '+st.outlineColor;"
                + " inline=el.style.getPropertyValue('outline')||'none';"
                + " tag=el.tagName;cls=(el.className||'').toString().slice(0,60);}"
                + "var k;try{k=JSON.parse(r);}catch(e){k={note:'bad-json',raw:r};}"
                + "return JSON.stringify({key:k,ring:ring,inline:inline,tag:tag,cls:cls});"
                + "}catch(e){return JSON.stringify({error:String(e)});}})()";
        web.evaluateJavascript(js, new ValueCallback<String>() {
            @Override public void onReceiveValue(String value) {
                String v = value == null ? "null" : value;
                BridgeLog.i("key", action.toUpperCase() + " " + v);
            }
        });
    }

    /** 取证：读当前文档里的焦点与桥状态。 */
    public static void state(WebView web) {
        web.evaluateJavascript(
                "window.__tvState ? window.__tvState() : '{\"installed\":false}'",
                new ValueCallback<String>() {
                    @Override public void onReceiveValue(String value) {
                        BridgeLog.i("state", "STATE " + (value == null ? "null" : value));
                    }
                });
    }

    /**
     * 自检：不光看 style 标签在不在，而是造一个临时元素读计算样式，
     * 证明 `.tv-focused` 的焦点环真的被浏览器应用了。
     * 站点 CSP 是 script-src 'self' https:，注入失效时这里会立刻露出来。
     */
    public static void verify(WebView web) {
        String js = "(function(){try{"
                + "var css=!!document.getElementById('__tvFocusCss');"
                + "var p=document.createElement('div');p.className='tv-focused';"
                + "p.style.cssText='position:absolute;left:-9999px;width:12px;height:12px';"
                + "(document.body||document.documentElement).appendChild(p);"
                + "var st=window.getComputedStyle(p);"
                + "var ring=st.outlineWidth+' '+st.outlineStyle+' '+st.outlineColor;"
                + "p.parentNode.removeChild(p);"
                + "return JSON.stringify({cssInjected:css,focusRing:ring,"
                + "bridge:!!(window.H5ShellNativeBridge&&window.H5ShellNativeBridge.call),"
                + "focusEngine:!!window.__tvKey,"
                + "atPolyfill:typeof Array.prototype.at==='function',"
                + "replaceAllPolyfill:typeof String.prototype.replaceAll==='function',"
                + "randomUUID:!!(window.crypto&&crypto.randomUUID)});"
                + "}catch(e){return JSON.stringify({error:String(e)});}})()";
        web.evaluateJavascript(js, new ValueCallback<String>() {
            @Override public void onReceiveValue(String value) {
                BridgeLog.i("verify", "VERIFY " + (value == null ? "null" : value));
            }
        });
    }
}
