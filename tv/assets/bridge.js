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

  /* isAvailable 刻意写 false：站点 native-environment 的 i() 读到 false 会把整个
   * 桥对象当成「不存在」，从而把所有请求都按浏览器处理。
   *
   * 为什么必须这样（2026-11-08 实机定位「AI 搜索：会话没有打开成功」）：
   * 站点 movie-card-runtime 的 Ct() 用 owner 字段决定会话归属：
   *     owner = kind ∈ {native_v3, native_project_jwt_v1} ? "native"
   *           : 有 state ? (rt(state) ? "web" : "unavailable")
   *           : 有桥 ? "unavailable" : "web"
   * 我们只实现了 shell./playback.，没有 auth.getState / auth.restoreSession，
   * 于是桥被判定为 legacy_no_auth，两次 auth 探测都回 NOT_IMPL → kind 变成
   * restore_failed 且没有 state → rt() 为假 → owner = "unavailable"。
   * 之后所有 auth:"session" 的请求（/v1/threads 等）在发出去之前就被
   * Uo() 抛成「会话尚未就绪」，页面只显示一句「连接失败，请稍后重试」。
   * 站点那条 createAnonymous 分支（POST /v1/users/anonymous）也就永远走不到。
   * 让站点以为这是普通浏览器后，它会自己建匿名会话，AI 搜索、收藏、评论全部恢复。
   *
   * 我们自己的代码（tv-skin.js / tv-overlay.js）只读 .call，不读 isAvailable，
   * 所以壳层的 native 播放、手机输入、远程配置都不受影响。 */
  window.H5ShellNativeBridge = {
    isAvailable: false,
    platform: 'android',
    version: VERSION,
    call: call,
    getNativePlayerState: function () { return Promise.resolve(null); },
    __pendingCount: function () { return Object.keys(pending).length; }
  };

  /* 曾经为了「让环境判定稳定」挂过 window.AiMovieAndroidBridge —— 恰恰是它让
   * 站点 native-environment 的 s() 返回 true（`typeof postMessage == "function"`），
   * 把上面 isAvailable:false 的效果抵消掉。站点对这个对象只有这一处用途，
   * 因此这里不再暴露。 */

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

  /* Chrome 86 才有 ParentNode.replaceChildren（Chrome 83 没有）。
   * 站点的 React Router hydrate 在 /player/:id 路由上直接调它，缺了会抛
   * "re.replaceChildren is not a function"，播放页整页退化成「页面加载失败」。
   * 阶段 5 的实机探测就是被这个挡住的：补齐后播放页 1879 节点、<video src> 正常出现。
   * 必须挂在三个原型上：React 会对 div、document 和 fragment 分别调用。 */
  if (window.Element || window.Document || window.DocumentFragment) {
    var replaceChildren = function () {
      var nodes = arguments;
      while (this.firstChild) { this.removeChild(this.firstChild); }
      for (var i = 0; i < nodes.length; i++) {
        var n = nodes[i];
        if (n === null || n === undefined) { continue; }
        this.appendChild(typeof n === 'string' ? document.createTextNode(n) : n);
      }
    };
    var protos = [window.Element && Element.prototype,
                  window.Document && Document.prototype,
                  window.DocumentFragment && DocumentFragment.prototype];
    for (var pi = 0; pi < protos.length; pi++) {
      if (protos[pi] && !protos[pi].replaceChildren) {
        protos[pi].replaceChildren = replaceChildren;
      }
    }
  }

  window.__soujuTvBridgeReady = true;
})();
