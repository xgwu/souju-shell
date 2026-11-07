/* tv-overlay.js — 顶部工具栏 + 搜索浮层 + 手机扫码输入 + 原生播放入口
 *
 * 阶段 4 / 5 的 H5 侧。全部挂到 body（站点 React 根节点之外），
 * 不搬动站点自己的 DOM 节点：composer 是 <form>，React 持有引用，
 * 一旦 appendChild 到别处，站点换页时会抛 removeChild 错误。
 *
 * 与 focus.js 的约定：
 *   html[data-tv-overlay="search"|"qr"] 决定候选集范围（scopeRoots）
 *   window.__tvFocusElement(el|selector) 由浮层负责把焦点交回图标
 *   window.__tvCloseOverlay() 供 MainActivity 的 BACK 直接调用
 * 与 Java 侧的约定：
 *   shell.setOverlay {open,mode}          让原生知道 BACK 该关浮层还是回历史
 *   shell.getInputServerInfo {}           返回 {url,pin,qr,port}
 *   playback.playNative {url,title,pos}   启动 PlayerActivity
 *   event tv.remoteInput {text,at}        手机端文字回传
 *
 * 约束：Chromium 83。不用 ?. / ??= / :has / Array.at / replaceAll / inset。
 */
(function () {
  if (window.__tvOverlayInstalled) { return; }
  window.__tvOverlayInstalled = true;

  /* onPageStarted 的 documentStart 阶段 documentElement 可能还是 null，
     不能在模块初始化时缓存；每次用的时候现取。 */
  function root() { return document.documentElement || document.body; }

  var mode = '';
  var returnBtn = null;
  var overlayAt = 0;
  var lastPath = location.pathname;
  var mediaUrls = [];
  var playUrl = '';
  var qrInfo = null;
  var toastTimer = null;

  var ICONS = {
    search: '<svg viewBox="0 0 24 24"><circle cx="10.5" cy="10.5" r="6.5"></circle>' +
            '<path d="M15.5 15.5L21 21"></path></svg>',
    qr: '<svg viewBox="0 0 24 24">' +
        '<path d="M4 4h6v6H4zM14 4h6v6h-6zM4 14h6v6H4z"></path>' +
        '<path d="M14 14h3v3h-3zM18 18h2v2h-2zM14 18h2v2h-2zM18 14h2v2h-2z"></path>' +
        '</svg>',
    play: '<svg viewBox="0 0 24 24"><path d="M7 4.5L19.5 12 7 19.5z"></path></svg>'
  };

  /* ── 小工具 ─────────────────────────────────────────────────── */

  function q(sel) { try { return document.querySelector(sel); } catch (e) { return null; } }

  function make(tag, cls, text) {
    var e = document.createElement(tag);
    if (cls) { e.className = cls; }
    if (text) { e.textContent = text; }
    return e;
  }

  function call(module, method, params) {
    try {
      if (window.H5ShellNativeBridge && window.H5ShellNativeBridge.call) {
        return window.H5ShellNativeBridge.call(module, method, params || {});
      }
    } catch (e) { /* 桥没就绪时静默降级 */ }
    return null;
  }

  function done(p, fn) {
    if (p && typeof p.then === 'function') {
      p.then(fn)['catch'](function () {});
    }
  }

  function toast(msg, ms) {
    var t = q('.tv-toast');
    if (!t) { return; }
    t.textContent = msg;
    t.classList.remove('tv-hidden');
    if (toastTimer) { clearTimeout(toastTimer); }
    toastTimer = setTimeout(function () { t.classList.add('tv-hidden'); }, ms || 3200);
  }

  /* ── 媒体地址嗅探（阶段 5） ───────────────────────────────────
     hls.js 会把 video.src 设成 blob:，原生播放器没法读。documentStart
     就包住 fetch / XHR.open，把站点请求过的 .m3u8 / .mp4 记下来。 */
  /* ArtPlayer 会先把 <video src> 设成一张 JPEG 封面图占位，
     真正起播后才换成 mp4 直链或 hls.js 的 blob:。不区分会把图片交给播放器。 */
  function isImageUrl(u) {
    return /\.(jpe?g|png|webp|gif|avif|bmp|svg)(\?|#|$)/i.test(u) ||
           /image\.image|~tplv-/i.test(u);
  }

  function isMediaUrl(u) {
    return /m3u8/i.test(u) || /\.(mp4|m4v|mov|ts)(\?|#|$)/i.test(u) ||
           (/bytetos\.com/i.test(u) && /\/tos-cn-v-/i.test(u));
  }

  function recordMedia(u) {
    if (typeof u !== 'string' || u.indexOf('http') !== 0) { return; }
    if (isImageUrl(u) || !isMediaUrl(u)) { return; }
    if (mediaUrls.indexOf(u) === 0) { return; }
    mediaUrls.unshift(u);
    if (mediaUrls.length > 8) { mediaUrls.pop(); }
  }
  if (window.fetch) {
    var origFetch = window.fetch;
    window.fetch = function (a, b) {
      try { recordMedia(typeof a === 'string' ? a : (a && a.url)); } catch (e) {}
      return origFetch.apply(this, arguments);
    };
  }
  if (window.XMLHttpRequest && XMLHttpRequest.prototype.open) {
    var origOpen = XMLHttpRequest.prototype.open;
    XMLHttpRequest.prototype.open = function (m, u) {
      try { recordMedia(u); } catch (e) {}
      return origOpen.apply(this, arguments);
    };
  }

  function currentMedia() {
    var v = q('video');
    if (!v) { return ''; }
    var src = v.currentSrc || v.getAttribute('src') || '';
    /* 实测（2026-11-07）：站点把整部 mp4 存在 .jpg 路径下伪装（CDN 回包
       ftyp isom/avc1，content-type 谎报 image/jpeg，532MB、支持 Range）。
       所以判据不是扩展名，而是「video 真的在播」：duration>0 即媒体流，
       currentSrc 无论长得像什么都可信。 */
    if (src.indexOf('http') === 0 &&
        typeof v.duration === 'number' && v.duration > 0) { return src; }
    if (src.indexOf('http') === 0 && !isImageUrl(src) &&
        (v.readyState >= 2 || /m3u8|mp4/i.test(src))) { return src; }
    if (mediaUrls.length) { return mediaUrls[0]; }
    var s = v.querySelector('source');
    var ss = s ? (s.getAttribute('src') || '') : '';
    if (ss.indexOf('http') === 0 && !isImageUrl(ss)) { return ss; }
    return '';
  }

  /* ── 构建浮层 ───────────────────────────────────────────────── */

  function build() {
    if (!document.body) { return false; }
    if (q('.tv-toolbar')) { return true; }

    var tools = make('div', 'tv-toolbar');
    tools.setAttribute('data-tv-toolbar', '');

    var searchBtn = make('button', 'tv-tool-btn');
    searchBtn.type = 'button';
    searchBtn.setAttribute('aria-label', '搜索');
    searchBtn.setAttribute('title', '搜索');
    searchBtn.innerHTML = ICONS.search;
    searchBtn.addEventListener('click', function () { openSearch(searchBtn); }, false);

    var qrBtn = make('button', 'tv-tool-btn');
    qrBtn.type = 'button';
    qrBtn.setAttribute('aria-label', '手机扫码输入');
    qrBtn.setAttribute('title', '手机扫码输入');
    qrBtn.innerHTML = ICONS.qr;
    qrBtn.addEventListener('click', function () { open('qr', qrBtn); }, false);

    var playerBtn = make('button', 'tv-tool-btn tv-tool-accent tv-hidden');
    playerBtn.type = 'button';
    playerBtn.setAttribute('aria-label', '原生播放');
    playerBtn.setAttribute('title', '用原生播放器播放');
    playerBtn.innerHTML = ICONS.play;
    playerBtn.addEventListener('click', function () { startNativePlay(); }, false);

    tools.appendChild(searchBtn);
    tools.appendChild(qrBtn);
    tools.appendChild(playerBtn);
    document.body.appendChild(tools);

    var shade = make('div', 'tv-overlay-shade');
    shade.setAttribute('aria-hidden', 'true');
    document.body.appendChild(shade);

    /* 搜索浮层：自建输入框。站点自己的 form 常驻隐藏，提交时把值写回去并点它的发送。
       这样完全不依赖站点 DOM 的堆叠上下文（实测 .keepalive-route-container 有
       isolation:isolate，任何 body 级遮罩都会压住站点里的 fixed 元素）。 */
    var panel = make('div', 'tv-search-panel');
    panel.setAttribute('data-tv-overlay-root', 'search');
    panel.setAttribute('role', 'dialog');
    panel.setAttribute('aria-modal', 'true');
    panel.appendChild(make('h2', '', '搜索想看的内容'));
    panel.appendChild(make('div', 'tv-overlay-hint',
      '遥控器按 OK 提交 · 手机扫码可直接输入 · 按返回键关闭'));

    var input = make('input', 'tv-search-input');
    input.type = 'text';
    input.maxLength = 160;
    input.setAttribute('placeholder', '今天你想看什么？');
    input.setAttribute('aria-label', '搜索内容');
    input.setAttribute('data-tv-overlay-input', '');
    input.addEventListener('keydown', function (e) {
      if (e && (e.keyCode === 13 || e.key === 'Enter')) { submitSearch(); }
    }, false);
    panel.appendChild(input);

    var actions = make('div', 'tv-search-actions');
    var submitBtn = make('button', 'tv-dialog-btn tv-search-submit', '搜索');
    submitBtn.type = 'button';
    submitBtn.setAttribute('aria-label', '提交搜索');
    submitBtn.addEventListener('click', function () { submitSearch(); }, false);
    var toQrBtn = make('button', 'tv-dialog-btn tv-search-qr', '手机输入');
    toQrBtn.type = 'button';
    toQrBtn.setAttribute('aria-label', '打开手机扫码输入');
    toQrBtn.addEventListener('click', function () {
      open('qr', window.__tvUi && window.__tvUi.searchBtn);
    }, false);
    var closeSearch = make('button', 'tv-dialog-btn tv-search-close', '返回');
    closeSearch.type = 'button';
    closeSearch.setAttribute('aria-label', '关闭搜索浮层');
    closeSearch.addEventListener('click', function () { close(); }, false);
    actions.appendChild(submitBtn);
    actions.appendChild(toQrBtn);
    actions.appendChild(closeSearch);
    panel.appendChild(actions);
    document.body.appendChild(panel);

    /* 手机输入浮层：二维码由 Java 侧 ZXing 生成后以 data:image/png 下发 */
    var dlg = make('div', 'tv-qr-dialog');
    dlg.setAttribute('data-tv-overlay-root', 'qr');
    dlg.setAttribute('role', 'dialog');
    dlg.setAttribute('aria-modal', 'true');
    dlg.appendChild(make('h2', '', '手机扫码输入'));
    dlg.appendChild(make('div', 'tv-overlay-hint', '同一 Wi-Fi 下用手机扫码，输入后自动送到电视'));
    var body = make('div', 'tv-qr-body');
    var img = make('img', 'tv-qr-img');
    img.setAttribute('alt', '搜剧TV 输入页二维码');
    body.appendChild(img);
    var copy = make('div', 'tv-qr-copy');
    copy.appendChild(make('div', '', '扫码后输入想看的剧名'));
    var urlLine = make('div', 'tv-qr-url', '正在获取地址…');
    copy.appendChild(urlLine);
    var pinLine = make('div', '', '');
    copy.appendChild(pinLine);
    body.appendChild(copy);
    dlg.appendChild(body);
    var closeQr = make('button', 'tv-dialog-btn tv-qr-close', '关闭');
    closeQr.type = 'button';
    closeQr.setAttribute('aria-label', '关闭扫码浮层');
    closeQr.addEventListener('click', function () { close(); }, false);
    dlg.appendChild(closeQr);
    var refresh = make('button', 'tv-dialog-btn tv-qr-refresh', '刷新');
    refresh.type = 'button';
    refresh.setAttribute('aria-label', '刷新二维码');
    refresh.addEventListener('click', function () { loadQr(); }, false);
    dlg.appendChild(refresh);
    document.body.appendChild(dlg);

    var t = make('div', 'tv-toast tv-hidden');
    document.body.appendChild(t);

    window.__tvUi = {
      searchBtn: searchBtn, qrBtn: qrBtn, playerBtn: playerBtn,
      shade: shade, panel: panel, dialog: dlg, searchInput: input,
      qrImg: img, qrUrl: urlLine, qrPin: pinLine, toast: t
    };
    return true;
  }

  /* ── 开 / 关 ────────────────────────────────────────────────── */

  function setMode(m) {
    mode = m || '';
    var host = root();
    if (host && host.setAttribute) {
      if (mode) { host.setAttribute('data-tv-overlay', mode); }
      else { host.removeAttribute('data-tv-overlay'); }
    }
    overlayAt = Date.now();
    call('shell', 'setOverlay', { open: !!mode, mode: mode });
  }

  function open(m, btn) {
    if (!build()) { return false; }
    returnBtn = btn || null;
    setMode(m);
    if (m === 'search') {
      setTimeout(function () {
        if (mode === 'search') { window.__tvFocusElement('.tv-search-input'); }
      }, 80);
    } else if (m === 'qr') {
      loadQr();
      setTimeout(function () {
        if (mode === 'qr') { window.__tvFocusElement('.tv-qr-close'); }
      }, 100);
    }
    return true;
  }

  /** 站点 SPA 换页时，搜索框可能整块消失；换页就自动收起浮层，
      否则 html 上残留 data-tv-overlay 会把 focus.js 的候选域锁死。 */
  function close() {
    if (!mode) { return false; }
    var btn = returnBtn;
    setMode('');
    setTimeout(function () {
      if (btn && btn.isConnected && window.__tvFocusElement) {
        window.__tvFocusElement(btn);
      }
    }, 70);
    return true;
  }

  window.__tvCloseOverlay = close;
  window.__tvOpenOverlay = open;

  /** 非首页没有 composer（播放页/片单页）：先走站点自己的 SPA 导航回首页，
      再打开搜索浮层。不能用 location.href —— 整页重载会卡在 readyState=loading。 */
  function openSearch(btn) {
    if (q('.movie-composer-text-input')) { open('search', btn); return; }
    var home = q('.app-primary-nav-link[href="/"]');
    if (home) {
      home.click();
      setTimeout(function () { open('search', btn); }, 900);
    } else {
      open('qr', btn);
      toast('当前页没有搜索框，可用手机扫码输入');
    }
  }

  /* ── 二维码 / 手机输入 ───────────────────────────────────────── */

  function renderQr(info) {
    if (!info || !window.__tvUi) { return; }
    qrInfo = info;
    var u = window.__tvUi;
    if (info.qr) { u.qrImg.setAttribute('src', info.qr); }
    u.qrUrl.textContent = info.url || '（未获取到局域网地址）';
    u.qrPin.textContent = info.pin ? '配对码 ' + info.pin : '';
  }

  function loadQr() {
    done(call('shell', 'getInputServerInfo', {}), function (r) {
      if (r && r.url) { renderQr(r); }
    });
  }

  /** React 受控 textarea 必须用原型上的 setter 写值，否则站点 state 不更新。
      同时把值同步到我们自己的浮层输入框，方便用户看到「电视收到了什么」。 */
  function fillInput(text) {
    var own = q('.tv-search-input');
    if (own) { own.value = text; }
    var ta = q('.movie-composer-text-input');
    if (!ta) { return false; }
    try {
      var proto = window.HTMLTextAreaElement ? HTMLTextAreaElement.prototype
                : (window.HTMLInputElement ? HTMLInputElement.prototype : null);
      var setter = proto && Object.getOwnPropertyDescriptor(proto, 'value');
      if (setter && setter.set) { setter.set.call(ta, text); }
      else { ta.value = text; }
      ta.dispatchEvent(new Event('input', { bubbles: true }));
      ta.dispatchEvent(new Event('change', { bubbles: true }));
      return true;
    } catch (e) { return false; }
  }

  /** 唯一的搜索提交口：写回站点输入框 → 点站点发送按钮 → 收浮层。
      站点 form 虽然 display:none，click() 仍会走它的 React onSubmit。 */
  function submitSearch() {
    var own = q('.tv-search-input');
    var text = own ? String(own.value || '').replace(/\s+/g, ' ').trim().slice(0, 160) : '';
    if (!text) { toast('请先输入想看的内容'); return false; }
    if (!fillInput(text)) { toast('站点搜索框暂不可用'); return false; }
    var form = q('.movie-composer-root');
    var btn = form ? form.querySelector('button[type="submit"],[aria-label="发送搜索"]') : null;
    close();
    if (btn) {
      setTimeout(function () { btn.click(); }, 40);
      toast('正在搜索：' + text);
    } else {
      toast('未找到站点的发送按钮');
    }
    return true;
  }

  window.__tvSubmitSearch = submitSearch;

  function onRemoteText(text, at) {
    text = String(text || '').replace(/\s+/g, ' ').trim().slice(0, 160);
    if (!text) { return; }
    var lag = at ? (Date.now() - at) : -1;
    if (!q('.movie-composer-text-input')) {
      toast('手机输入已收到，正在回到首页…');
      var home = q('.app-primary-nav-link[href="/"]');
      if (home) { home.click(); }
      setTimeout(function () { onRemoteText(text, at); }, 1000);
      return;
    }
    if (mode !== 'search') { open('search', window.__tvUi && window.__tvUi.searchBtn); }
    fillInput(text);
    toast('已收到：' + text + '（' + (lag >= 0 ? lag + 'ms' : '手机输入') + '）');
    /* 200ms 内出结果：写完值就自动提交，用户不用在电视上再按一次 OK。 */
    setTimeout(submitSearch, 150);
    try {
      console.log('TVINPUT ' + JSON.stringify({ text: text, lagMs: lag }));
    } catch (e) {}
  }

  /* ── 原生播放（阶段 5） ──────────────────────────────────────── */

  function startNativePlay() {
    var url = playUrl || currentMedia();
    if (!url) { toast('当前页没有可直接播放的地址'); return; }
    var v = q('video');
    var pos = v && typeof v.currentTime === 'number' ? Math.round(v.currentTime * 1000) : 0;
    var h1 = q('h1');
    var title = (h1 && h1.textContent ? h1.textContent : document.title || '搜剧TV').trim().slice(0, 60);
    if (v) { try { v.pause(); } catch (e) {} }   // 避免网页与原生同时出声
    call('playback', 'playNative', { url: url, title: title, positionMs: pos });
    toast('已交给原生播放器：' + title);
  }

  function scanVideo() {
    if (!window.__tvUi) { return; }
    playUrl = currentMedia();
    if (playUrl) { window.__tvUi.playerBtn.classList.remove('tv-hidden'); }
    else { window.__tvUi.playerBtn.classList.add('tv-hidden'); }
  }

  window.__tvPlayerState = function () {
    return JSON.stringify({
      url: playUrl, mediaUrls: mediaUrls.slice(0, 3),
      video: !!q('video'), buttonVisible: !!window.__tvUi &&
        !window.__tvUi.playerBtn.classList.contains('tv-hidden')
    });
  };

  /* ── 事件 / 自同步 ───────────────────────────────────────────── */

  window.addEventListener('h5shell:native-event', function (ev) {
    var d = ev && ev.detail ? ev.detail : {};
    var p = d.payload || {};
    if (d.name === 'tv.remoteInput') { onRemoteText(p.text, p.at); }
    else if (d.name === 'tv.qrReady') { renderQr(p); }
    else if (d.name === 'tv.inputServerState') { renderQr(p); }
  }, false);

  window.addEventListener('popstate', function () { close(); }, false);
  window.addEventListener('hashchange', function () { close(); }, false);

  function tick() {
    build();
    if (location.pathname !== lastPath) {
      lastPath = location.pathname;
      if (mode) { setMode(''); }
    }
    scanVideo();
    /* 只上报一次状态：原生侧启动时会主动 emit qrReady，这里做兜底 */
    if (!qrInfo && mode === 'qr') { loadQr(); }
  }

  document.addEventListener('DOMContentLoaded', build, false);
  build();
  setInterval(tick, 1500);
  setTimeout(tick, 600);
  console.log('TVOVERLAY_INSTALLED');
})();
