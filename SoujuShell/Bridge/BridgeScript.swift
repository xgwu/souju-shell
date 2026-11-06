import Foundation

/// 注入到网页 documentStart 的 JS。
///
/// 为什么必须由壳端注入：抓 bundle 证实，`main.js` 里出现 5 次 `H5ShellNativeBridge`，
/// 全部是**读**（`window.H5ShellNativeBridge`、`.isAvailable`、`.call`），没有任何一处定义。
/// 也就是说这个对象由原生壳提供 —— 谁注入它，谁就掌握 RPC 的 resolve/reject 权。
///
/// 探测顺序（来自 native-environment 模块，原文逆向）：
///   1. `window.H5ShellNativeBridge` 存在且 `isAvailable !== false` → 视为原生容器
///   2. 否则看 `window.webkit.messageHandlers.nativeBridge` 是否存在
///   3. 若都失败，站点以 `[0, 120, 320, 700]ms` 四轮重试等待桥就绪
/// 因此我们要同时满足 1 和 2，且必须在 documentStart 就位，不能等页面加载完。
enum BridgeScript {

    /// 桥自己的版本号，进 console 日志方便排查
    static let version = "1.0.0"

    static var source: String {
        #"""
        (function () {
          if (window.__soujuShellBridgeInstalled) { return; }
          window.__soujuShellBridgeInstalled = true;

          var seq = 0;
          var pending = Object.create(null);
          var BRIDGE_VERSION = "__VERSION__";

          function nowMs() { return Date.now(); }

          function post(payload) {
            var handler = window.webkit && window.webkit.messageHandlers &&
                          window.webkit.messageHandlers.nativeBridge;
            if (!handler) { throw new Error("native_bridge_missing"); }
            handler.postMessage(payload);
          }

          function call(module, method, params) {
            return new Promise(function (resolve, reject) {
              var oid = "ios-" + (++seq) + "-" + nowMs();
              pending[oid] = { resolve: resolve, reject: reject, at: nowMs() };

              var body = params && typeof params === "object" ? params : {};
              var payload = {
                // 双写：站点同时读 operation_id 与 operationId
                operation_id: oid,
                operationId: oid,
                module: module,
                method: method,
                action: method,
                params: body,
                payload: body,
                protocol: "h5shell.native-bridge.v1",
                bridgeVersion: BRIDGE_VERSION,
                issued_at_ms: nowMs()
              };

              try {
                post(payload);
              } catch (e) {
                delete pending[oid];
                reject(new Error("native_bridge_post_failed"));
              }

              // 20s 没回包就 reject，避免站点侧 await 永远挂住
              setTimeout(function () {
                if (pending[oid]) {
                  delete pending[oid];
                  reject(new Error("native_bridge_timeout:" + module + "." + method));
                }
              }, 20000);
            });
          }

          // 壳 → JS 的唯一回包入口，名字与站点约定的 __nativeReply 对齐
          window.__nativeReply = function (oid, result) {
            var slot = pending[oid];
            if (!slot) { return; }
            delete pending[oid];
            if (result && result.ok === false) {
              var err = new Error(
                (result.error && result.error.code) || result.code || "native_error"
              );
              err.detail = result;
              slot.reject(err);
            } else {
              slot.resolve(result);
            }
          };

          // 原生 → 网页事件。站点监听 CustomEvent("h5shell:native-event", {detail:{name,payload}})
          window.__nativeEvent = function (name, payload) {
            try {
              window.dispatchEvent(new CustomEvent("h5shell:native-event", {
                detail: { name: name, payload: payload || {} }
              }));
            } catch (e) { /* CustomEvent 不可用时静默降级 */ }
          };

          window.H5ShellNativeBridge = {
            isAvailable: true,
            platform: "ios",
            version: BRIDGE_VERSION,
            call: call,
            // 原生播放器未启用，这个回包给站点一个明确的空态而不是 undefined
            getNativePlayerState: function () { return Promise.resolve(null); },
            __pendingCount: function () { return Object.keys(pending).length; }
          };
        })();
        """#
        .replacingOccurrences(of: "__VERSION__", with: version)
        .replacingOccurrences(of: "nativeBridge", with: ShellConfig.bridgeHandlerName)
    }
}
