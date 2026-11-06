import Foundation
import WebKit
import JavaScriptCore

/// 站点页面的自定义注入层。
///
/// 壳加载的是远端 SPA，它的 HTML/CSS/JS 都在服务端，本地改不了。
/// 但 `WKUserScript` 是 **WebKit 层**的注入，权限高于页面自己的 CSP ——
/// 这是我们把 `bridge-ok` 注进去的同一套机制，所以它同样能用来改外观。
///
/// 站点实测的 CSP（2026-11）：
///     style-src 'self' 'unsafe-inline'   → 内联样式放行，CSS 注入不会被拦
///     script-src 'self' https:           → 不放行 unsafe-inline / unsafe-eval
///
/// 因此这里有两条硬约束，代码里都绕开了：
///   1. **不能用 eval / new Function** —— 没有 `unsafe-eval`，会被 CSP 直接拒绝。
///      所以用户代码是**直接拼进函数体**的，不是运行时求值。
///      代价：语法错误会让整段脚本解析失败，故在原生侧先用 JavaScriptCore 预校验。
///   2. **不能引外部样式表** —— `style-src` 只有 `'self'`。
///      所以 CSS 一律内联成 `<style>`，不生成 `<link href="https://...">`。
///
/// SPA 的另一个坑：路由切换不重载页面，`atDocumentEnd` 只跑一次。
/// CSS 靠 MutationObserver 在 `<style>` 被移除时补回；
/// JS 靠 `popstate` / `hashchange` 重跑（同一页面内的 DOM 更新不重跑，避免重复绑定事件）。
enum CustomInjection {

    /// 注入的 `<style>` 元素 id，全局唯一，方便找回和移除
    static let styleElementID = "__shell_custom_css"

    // MARK: - 组装

    /// 生成要挂进 `WKUserContentController` 的脚本。
    /// 两者都是空串时返回空数组，不产生任何注入开销。
    static func makeUserScripts(css: String, js: String) -> [WKUserScript] {
        var scripts: [WKUserScript] = []

        let style = css.trimmingCharacters(in: .whitespacesAndNewlines)
        if !style.isEmpty {
            scripts.append(WKUserScript(
                source: cssSource(style),
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            ))
        }

        let script = js.trimmingCharacters(in: .whitespacesAndNewlines)
        if !script.isEmpty, syntaxError(in: script) == nil {
            scripts.append(WKUserScript(
                source: jsSource(script),
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            ))
        }

        return scripts
    }

    /// 拼一段"插 `<style>` 并守住它"的脚本。
    static func cssSource(_ css: String) -> String {
        let literal = jsLiteral(css)
        return #"""
        (function () {
          var CSS = \#(literal);
          if (!CSS) { return; }
          var ID = "\#(styleElementID)";

          function install() {
            var host = document.head || document.documentElement;
            if (!host) { return; }
            var el = document.getElementById(ID);
            if (!el) {
              el = document.createElement("style");
              el.id = ID;
              host.appendChild(el);
            }
            if (el.textContent !== CSS) { el.textContent = CSS; }
          }

          install();

          // SPA 路由切换不会丢 <style>，但站点的换肤/主题切换可能重写 head。
          // 只在元素真的不见时才补，节流 500ms —— 单次开销只是一次 getElementById。
          try {
            var last = 0;
            var mo = new MutationObserver(function () {
              var now = Date.now();
              if (now - last < 500) { return; }
              last = now;
              if (!document.getElementById(ID)) { install(); }
            });
            mo.observe(document.documentElement, { childList: true, subtree: true });
          } catch (e) {}

          window.__shellCustomCSS = {
            install: install,
            remove: function () {
              var el = document.getElementById(ID);
              if (el && el.parentNode) { el.parentNode.removeChild(el); }
            }
          };
        })();
        """#
    }

    /// 拼一段"执行用户脚本并在路由变化后重跑"的脚本。
    ///
    /// 用户代码原样落在函数体里，**不加缩进**：缩进会改变模板字符串（反引号）里的内容。
    static func jsSource(_ js: String) -> String {
        #"""
        (function () {
          function __shellCustomRun() {
        \#(js)
          }

          function __shellCustomSafeRun() {
            try {
              __shellCustomRun();
            } catch (e) {
              console.error("[shell-custom] " + ((e && e.message) || e));
            }
          }

          __shellCustomSafeRun();

          // history 模式 SPA：pushState 本身不发事件，但前进/后退会发 popstate。
          window.addEventListener("popstate", __shellCustomSafeRun);
          window.addEventListener("hashchange", __shellCustomSafeRun);

          window.__shellCustom = { rerun: __shellCustomSafeRun };
        })();
        """#
    }

    // MARK: - 语法预校验

    /// 用 JavaScriptCore 只解析、不执行，能提前抓出语法错误。
    ///
    /// 为什么不交给页面自己 try/catch：语法错误发生在**解析阶段**，
    /// 那时整段脚本还没开始执行，`try` 根本来不及兜住 —— 页面只会静默什么都不发生。
    /// 在这里拦下来，UI 才能给出人话提示。
    static func syntaxError(in js: String) -> String? {
        let trimmed = js.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let context = JSContext() else { return nil }

        // 包成函数表达式：合法则构造成功，非法则抛 SyntaxError。
        // 注意这里**不调用**它，所以用户代码不会被执行。
        context.evaluateScript("(function(){\n\(js)\n})")

        guard let exception = context.exception else { return nil }
        let message = exception.toString() ?? "语法错误"
        context.exception = nil
        return message
    }

    // MARK: - 转义

    /// 把 Swift 字符串变成可安全放进 JS 源码的双引号字面量。
    ///
    /// 不用 `JSONEncoder`，因为它不转义 U+2028 / U+2029 ——
    /// 这两个字符在 JSON 里合法，在 JS 里却是**行终止符**，会直接截断字符串导致语法错误。
    static func jsLiteral(_ text: String) -> String {
        var out = "\""
        out.reserveCapacity(text.count + 16)

        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{2028}": out += "\\u2028"
            case "\u{2029}": out += "\\u2029"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }

        out += "\""
        return out
    }
}
