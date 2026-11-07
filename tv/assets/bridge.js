/* bridge.js — 由 MainActivity 在每次主文档开始时通过 evaluateJavascript 注入。
 *
 * 为什么不是塞进 HTML <script>：站点 CSP 是 `script-src 'self' https:`（无 unsafe-inline），
 * 内联脚本会被拦。evaluateJavascript 从 WebView 层执行，不受页面 CSP 约束。
 * 时序靠三道保险：onPageStarted / onProgressChanged(>=15) / onPageFinished 各注一次，
 * 加上站点 native-environment 自身的 [0,120,320,700]ms 四轮等桥重试。
 *
 * 占位 __SOUJU_TOKEN__ 由 Java 侧按主文档替换，第三方 frame 拿不到。
 */
(function () {
  if (window.__soujuTvBridgeInstalled) { return; }
  window.__soujuTvBridgeInstalled = true;

  var TOKEN = "__SOUJU_TOKEN__";
  var VERSION = "1.1.0-tv";
  var seq = 0;
  var pending = Object.create(null);
  var native = window.SoujuTvNative;

  function post(payload) {
    if (!native || typeof native.post !== 'function') {
      throw new Error('native_bridge_missing');
    }
    // @JavascriptInterface 只能传基本类型，必须自己序列化
    native.post(JSON.stringify(payload), TOKEN);
  }

  function call(module, method, params) {
    return new Promise(function (resolve, reject) {
      var oid = 'tv-' + (++seq) + '-' + Date.now();
      pending[oid] = { resolve: resolve, reject: reject, at: Date.now() };
      var body = params && typeof params === 'object' ? params : {};
      var payload = {
        // 双写：站点同时读 operation_id / operationId、method / action、params / payload
        operation_id: oid, operationId: oid,
        module: module, method: method, action: method,
        params: body, payload: body,
        protocol: 'h5shell.native-bridge.v1',
        bridgeVersion: VERSION,
        issued_at_ms: Date.now()
      };
      try { post(payload); }
      catch (e) { delete pending[oid]; reject(e); return; }
      // 20s 无回包就 reject，避免站点 await 永远挂住
      setTimeout(function () {
        if (pending[oid]) {
          delete pending[oid];
          reject(new Error('native_bridge_timeout:' + module + '.' + method));
        }
      }, 20000);
    });
  }

  window.__nativeReply = function (oid, result) {
    var slot = pending[oid];
    if (!slot) { return; }
    delete pending[oid];
    if (result && result.ok === false) {
      var err = new Error((result.error && result.error.code) || result.code || 'native_error');
      err.detail = result;
      slot.reject(err);
    } else {
      slot.resolve(result);
    }
  };

  window.__nativeEvent = function (name, payload) {
    try {
      window.dispatchEvent(new CustomEvent('h5shell:native-event', {
        detail: { name: name, payload: payload || {} }
      }));
    } catch (e) { /* CustomEvent 不可用时静默降级 */ }
  };

  window.H5ShellNativeBridge = {
    isAvailable: true,
    platform: 'android',
    version: VERSION,
    call: call,
    getNativePlayerState: function () { return Promise.resolve(null); },
    __pendingCount: function () { return Object.keys(pending).length; }
  };

  /* 站点 native-environment 会检查 window.AiMovieAndroidBridge.postMessage 是否为函数，
   * 用来判定「Android 原生壳」。它并不通过这个对象做 RPC，但补齐能让环境判定稳定。 */
  window.AiMovieAndroidBridge = {
    postMessage: function (payload) {
      try {
        if (typeof payload === 'string') { post(JSON.parse(payload)); }
        else if (payload && typeof payload === 'object') { post(payload); }
      } catch (e) { /* 只作环境标记，失败不影响主桥 */ }
    }
  };

  /* Chrome 83 缺失的运行时 API。站点首屏没用到，但懒加载分片里有真实调用：
   * Array.at(6 处，追剧日历) / String.replaceAll(1) / crypto.randomUUID(1)。
   * 只补这三个 —— 多补会改变站点库的特征检测分支（WeakRef / structuredClone 等）。 */
  if (!Array.prototype.at) {
    Object.defineProperty(Array.prototype, 'at', {
      value: function (n) {
        n = Math.trunc(n) || 0;
        if (n < 0) { n += this.length; }
        return (n >= 0 && n < this.length) ? this[n] : undefined;
      }, writable: true, configurable: true
    });
  }
  if (!String.prototype.replaceAll) {
    String.prototype.replaceAll = function (a, b) {
      return String(this).split(a).join(String(b));
    };
  }
  if (window.crypto && !crypto.randomUUID) {
    crypto.randomUUID = function () {
      return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, function (c) {
        var r = crypto.getRandomValues(new Uint8Array(1))[0] & 15;
        return (c === 'x' ? r : (r & 3 | 8)).toString(16);
      });
    };
  }

  window.__soujuTvBridgeReady = true;
})();
