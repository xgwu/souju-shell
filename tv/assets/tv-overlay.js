/* tv-overlay.js — 顶部工具栏 + 搜索/选集/登录浮层 + 手机扫码输入 + 原生播放
 *
 * 阶段 4 / 5 / 6 的 H5 侧。全部挂到 body（站点 React 根节点之外），
 * 不搬动站点自己的 DOM 节点：composer 是 <form>，React 持有引用，
 * 一旦 appendChild 到别处，站点换页时会抛 removeChild 错误。
 *
 * 与 focus.js 的约定：
 *   html[data-tv-overlay="search"|"qr"|"episodes"|"login"] 决定候选集范围（scopeRoots）
 *   window.__tvFocusElement(el|selector) 由浮层负责把焦点交回触发图标
 *   window.__tvCloseOverlay() 供 MainActivity 的 BACK 直接调用
 * 与 Java 侧的约定：
 *   shell.setOverlay {open,mode}          让原生知道 BACK 该关浮层还是回历史
 *   shell.getInputServerInfo {}           返回 {url,pin,qr,port}
 *   playback.playNative {url,title,positionMs,episodes,episodeIndex}
 *   event tv.remoteInput {text,at}        手机端文字回传
 *   原生播放器退出 → native 调 __tvPlaybackReturn({positionMs,reason,...})
 *
 * 阶段 6 的四件事：
 *   ① 选集：读站点的 .movie-episode-quick-tab / .movie-episode-expanded-grid，
 *      自建 8 列网格（站点侧栏在电视上只有 352px，遥控器根本点不动）。
 *   ② 进度回写：原生播放器用的是系统 MediaPlayer，站点看不到 timeupdate，
 *      「继续观看」会永远停在进播放器前的秒数。退出时把 H5 <video> 静音真播 2 秒，
 *      借站点自己的 recorder 写回 localStorage/账号 —— 实测 2.6 秒即落库。
 *   ③ 登录：账号+密码表单在电视上没法打字，改成「手机扫码 → 文字直接落进字段」。
 *   ④ 线路配置由原生侧 TvConfig 负责拉取，这里只提供 shell.getConfig 的读取入口。
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
  var hlsHint = '';
  var qrInfo = null;
  var toastTimer = null;

  /* 阶段 6 状态 */
  var epList = [];            // [{label, el}]
  var epExpandedTried = false;
  var armedField = '';        // '' | 'account' | 'password'
  var loginValues = { account: '', password: '' };
  var loginPolling = 0;
  var progressSyncing = false;
  var tickCount = 0;

  var ICONS = {
    search: '<svg viewBox="0 0 24 24"><circle cx="10.5" cy="10.5" r="6.5"></circle>' +
            '<path d="M15.5 15.5L21 21"></path></svg>',
    qr: '<svg viewBox="0 0 24 24">' +
        '<path d="M4 4h6v6H4zM14 4h6v6h-6zM4 14h6v6H4z"></path>' +
        '<path d="M14 14h3v3h-3zM18 18h2v2h-2zM14 18h2v2h-2zM18 14h2v2h-2z"></path>' +
        '</svg>',
    play: '<svg viewBox="0 0 24 24"><path d="M7 4.5L19.5 12 7 19.5z"></path></svg>',
    list: '<svg viewBox="0 0 24 24"><path d="M4 6h16M4 12h16M4 18h10"></path></svg>',
    user: '<svg viewBox="0 0 24 24"><circle cx="12" cy="8" r="3.6"></circle>' +
          '<path d="M4.5 20c0-4.1 3.4-6.4 7.5-6.4s7.5 2.3 7.5 6.4"></path></svg>'
  };

  /* ── 小工具 ─────────────────────────────────────────────────── */

  function q(sel) { try { return document.querySelector(sel); } catch (e) { return null; } }
  function qa(sel) {
    try { return Array.prototype.slice.call(document.querySelectorAll(sel)); }
    catch (e) { return []; }
  }

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

  function text(el) { return el ? (el.textContent || '').replace(/\s+/g, ' ').trim() : ''; }

  function log(tag, obj) {
    /* SOUJUTV 前缀是 TvChromeClient 的转发白名单；不带前缀的 console 在
       电视上取不到，现场排查只能靠截图。 */
    try { console.log('SOUJUTV ' + tag + ' ' + JSON.stringify(obj)); } catch (e) {}
  }

  /** React 受控输入：必须走原型 setter，否则站点 state 不更新。 */
  function setValue(el, v) {
    if (!el) { return false; }
    try {
      var proto = el.tagName === 'TEXTAREA' ? window.HTMLTextAreaElement.prototype
                : (window.HTMLInputElement ? HTMLInputElement.prototype : null);
      var d = proto && Object.getOwnPropertyDescriptor(proto, 'value');
      if (d && d.set) { d.set.call(el, v); } else { el.value = v; }
      el.dispatchEvent(new Event('input', { bubbles: true }));
      el.dispatchEvent(new Event('change', { bubbles: true }));
      return true;
    } catch (e) { return false; }
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

  /* .ts 是 HLS 的分片，不能交给播放器（播 2 秒就停）。之前把 .ts 也记进
     mediaUrls，结果每 2 秒一片就把真正的 m3u8 从 8 条环形缓冲里挤出去，
     点「原生播放」时拿到的是一个 .ts 分片。现在 .ts 只用来反推播放列表。 */
  function isMediaUrl(u) {
    return /m3u8/i.test(u) || /\.(mp4|m4v|mov)(\?|#|$)/i.test(u) ||
           (/bytetos\.com/i.test(u) && /\/tos-cn-v-/i.test(u));
  }

  function recordMedia(u) {
    if (typeof u !== 'string' || u.indexOf('http') !== 0) { return; }
    if (/\.ts(\?|#|$)/i.test(u)) {
      /* .../3000k/hls/<hash>.ts → .../3000k/hls/index.m3u8（常见切片布局） */
      hlsHint = u.replace(/[^\/]+\.ts(\?|#|$)/i, 'index.m3u8');
      return;
    }
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
    /* 优先播放列表，其次 mp4 直链；都没有才用 .ts 反推出的列表地址。 */
    for (var mi = 0; mi < mediaUrls.length; mi++) {
      if (/m3u8/i.test(mediaUrls[mi])) { return mediaUrls[mi]; }
    }
    if (mediaUrls.length) { return mediaUrls[0]; }
    if (hlsHint) { return hlsHint; }
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

    /* 选集：只在播放/详情页有剧集时出现 */
    var episodeBtn = make('button', 'tv-tool-btn tv-hidden');
    episodeBtn.type = 'button';
    episodeBtn.setAttribute('aria-label', '选集');
    episodeBtn.setAttribute('title', '选集');
    episodeBtn.innerHTML = ICONS.list;
    episodeBtn.addEventListener('click', function () { openEpisodes(episodeBtn); }, false);

    /* 登录：站点把登录入口放在侧栏抽屉里，而侧栏在电视上被隐藏了 */
    var loginBtn = make('button', 'tv-tool-btn');
    loginBtn.type = 'button';
    loginBtn.setAttribute('aria-label', '账号');
    loginBtn.setAttribute('title', '账号登录');
    loginBtn.innerHTML = ICONS.user;
    loginBtn.addEventListener('click', function () { openLogin(loginBtn); }, false);

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
    tools.appendChild(episodeBtn);
    tools.appendChild(loginBtn);
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

    /* 选集浮层（阶段 6） */
    var epPanel = make('div', 'tv-episode-panel');
    epPanel.setAttribute('data-tv-overlay-root', 'episodes');
    epPanel.setAttribute('role', 'dialog');
    epPanel.setAttribute('aria-modal', 'true');
    epPanel.setAttribute('aria-label', '选集');
    epPanel.appendChild(make('h2', '', '选集'));
    var epMeta = make('div', 'tv-overlay-hint', '正在读取剧集…');
    epPanel.appendChild(epMeta);
    var epGrid = make('div', 'tv-episode-grid');
    epPanel.appendChild(epGrid);
    var epActions = make('div', 'tv-search-actions');
    var epClose = make('button', 'tv-dialog-btn tv-episode-close', '返回');
    epClose.type = 'button';
    epClose.setAttribute('aria-label', '关闭选集');
    epClose.addEventListener('click', function () { close(); }, false);
    epActions.appendChild(epClose);
    epPanel.appendChild(epActions);
    document.body.appendChild(epPanel);

    /* 登录浮层（阶段 6） */
    var loginPanel = make('div', 'tv-login-panel');
    loginPanel.setAttribute('data-tv-overlay-root', 'login');
    loginPanel.setAttribute('role', 'dialog');
    loginPanel.setAttribute('aria-modal', 'true');
    loginPanel.setAttribute('aria-label', '登录账号');
    loginPanel.appendChild(make('h2', '', '登录账号'));
    var loginHint = make('div', 'tv-overlay-hint',
      '电视上不便于打字：用手机扫右侧二维码，输入的内容会直接落进选中的输入框');
    loginPanel.appendChild(loginHint);

    var accRow = make('div', 'tv-login-row');
    accRow.appendChild(make('span', 'tv-login-label', '账号'));
    var accValue = make('span', 'tv-login-value tv-login-empty', '未填写');
    accRow.appendChild(accValue);
    var accArm = make('button', 'tv-dialog-btn tv-login-arm', '手机输入账号');
    accArm.type = 'button';
    accArm.setAttribute('aria-label', '用手机输入账号');
    accArm.addEventListener('click', function () { armField('account'); }, false);
    accRow.appendChild(accArm);
    loginPanel.appendChild(accRow);

    var pwdRow = make('div', 'tv-login-row');
    pwdRow.appendChild(make('span', 'tv-login-label', '密码'));
    var pwdValue = make('span', 'tv-login-value tv-login-empty', '未填写');
    pwdRow.appendChild(pwdValue);
    var pwdArm = make('button', 'tv-dialog-btn tv-login-arm', '手机输入密码');
    pwdArm.type = 'button';
    pwdArm.setAttribute('aria-label', '用手机输入密码');
    pwdArm.addEventListener('click', function () { armField('password'); }, false);
    pwdRow.appendChild(pwdArm);
    loginPanel.appendChild(pwdRow);

    var loginQrWrap = make('div', 'tv-login-qr');
    var loginQrImg = make('img', 'tv-qr-img');
    loginQrImg.setAttribute('alt', '手机输入二维码');
    loginQrWrap.appendChild(loginQrImg);
    var loginQrCopy = make('div', 'tv-qr-copy');
    var loginQrUrl = make('div', 'tv-qr-url', '正在获取地址…');
    loginQrCopy.appendChild(loginQrUrl);
    var loginQrPin = make('div', '', '');
    loginQrCopy.appendChild(loginQrPin);
    loginQrWrap.appendChild(loginQrCopy);
    loginPanel.appendChild(loginQrWrap);

    var loginStatus = make('div', 'tv-login-status', '');
    loginPanel.appendChild(loginStatus);

    var loginActions = make('div', 'tv-search-actions');
    var loginSubmit = make('button', 'tv-dialog-btn tv-login-submit', '登录');
    loginSubmit.type = 'button';
    loginSubmit.setAttribute('aria-label', '提交登录');
    loginSubmit.addEventListener('click', function () { submitLogin(); }, false);
    var loginClose = make('button', 'tv-dialog-btn tv-login-close', '返回');
    loginClose.type = 'button';
    loginClose.setAttribute('aria-label', '关闭登录浮层');
    loginClose.addEventListener('click', function () { close(); }, false);
    loginActions.appendChild(loginSubmit);
    loginActions.appendChild(loginClose);
    loginPanel.appendChild(loginActions);
    document.body.appendChild(loginPanel);

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
      searchBtn: searchBtn, episodeBtn: episodeBtn, loginBtn: loginBtn,
      qrBtn: qrBtn, playerBtn: playerBtn,
      shade: shade, panel: panel, dialog: dlg, searchInput: input,
      epPanel: epPanel, epGrid: epGrid, epMeta: epMeta,
      loginPanel: loginPanel, loginAcc: accValue, loginPwd: pwdValue,
      loginQr: loginQrImg, loginQrUrl: loginQrUrl, loginQrPin: loginQrPin,
      loginStatus: loginStatus,
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
    } else if (m === 'episodes') {
      setTimeout(function () {
        if (mode !== 'episodes') { return; }
        window.__tvFocusElement('.tv-episode-cell.is-current') ||
          window.__tvFocusElement('.tv-episode-cell');
      }, 100);
    } else if (m === 'login') {
      loadQr();
      setTimeout(function () {
        if (mode !== 'login') { return; }
        window.__tvFocusElement('.tv-login-arm') || window.__tvFocusElement('.tv-login-submit');
      }, 120);
    }
    return true;
  }

  /** 站点 SPA 换页时，搜索框可能整块消失；换页就自动收起浮层，
      否则 html 上残留 data-tv-overlay 会把 focus.js 的候选域锁死。 */
  function close() {
    if (!mode) { return false; }
    var btn = returnBtn;
    setMode('');
    if (armedField) { armedField = ''; renderLogin(); }
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

  /* ── ① 选集 / 剧集列表（阶段 6） ───────────────────────────────
     站点把选集放在播放页右侧 352px 的抽屉里；电视上既点不准也看不全。
     这里读它的按钮，按 8 列重排成遥控器友好的网格。 */

  function epLabelOf(el) {
    var t = (el.getAttribute('title') || text(el) || '').trim();
    if (!t) {
      var inner = el.querySelector('span');
      t = text(inner);
    }
    return t.slice(0, 16);
  }

  function epOrder(label) {
    var m = /(\d{1,4})/.exec(label || '');
    return m ? parseInt(m[1], 10) : 9999;
  }

  /** 站点只有「已更新」的集会出现在列表里；展开层是完整目录。
      优先用带 data-directory-episode 的展开层按钮（有剧集 id，点击语义最稳）。 */
  function collectEpisodes() {
    var els = qa('.movie-episode-expanded-grid button[data-directory-episode]');
    if (!els.length) { els = qa('.movie-episode-quick-tab'); }
    if (!els.length) { els = qa('.movie-episode-item button'); }
    var out = [], seen = {};
    for (var i = 0; i < els.length; i++) {
      var label = epLabelOf(els[i]);
      if (!label || seen[label]) { continue; }
      seen[label] = 1;
      out.push({ label: label, el: els[i] });
    }
    out.sort(function (a, b) { return epOrder(a.label) - epOrder(b.label); });
    return out;
  }

  function isCurrentEp(el) {
    return !!(el && el.className && /movie-button-primary|is-active|current/i.test(String(el.className)));
  }

  function currentEpIndex(list) {
    for (var i = 0; i < list.length; i++) {
      if (isCurrentEp(list[i].el)) { return i; }
    }
    return -1;
  }

  function renderEpisodes() {
    var u = window.__tvUi;
    if (!u) { return; }
    if (!epList.length) {
      u.epMeta.textContent = '当前页面没有可切换的剧集';
      u.epGrid.innerHTML = '';
      return;
    }
    var cur = currentEpIndex(epList);
    var grid = u.epGrid;
    while (grid.firstChild) { grid.removeChild(grid.firstChild); }
    for (var i = 0; i < epList.length; i++) {
      var cell = make('button', 'tv-episode-cell' + (i === cur ? ' is-current' : ''), epList[i].label);
      cell.type = 'button';
      cell.setAttribute('title', epList[i].label);
      cell.setAttribute('data-tv-ep-index', String(i));
      cell.setAttribute('aria-label', epList[i].label);
      bindPick(cell, i);
      grid.appendChild(cell);
    }
    var meta = '共 ' + epList.length + ' 集';
    if (cur >= 0) { meta += ' · 当前 ' + epList[cur].label; }
    u.epMeta.textContent = meta;
  }

  function bindPick(cell, i) {
    cell.addEventListener('click', function () {
      pickEpisode(i, false);
    }, false);
  }

  function openEpisodes(btn) {
    if (!build()) { return false; }
    epList = collectEpisodes();
    /* 站点默认只挂 15 个「快速集」；完整目录要展开一次才进 DOM。
       展开按钮本身在电视上被我们的皮肤压到屏幕外，用户看不到闪烁。 */
    if (!epList.length && !epExpandedTried) {
      var exp = q('.movie-episode-expand-button');
      if (exp) {
        epExpandedTried = true;
        try { exp.click(); } catch (e) {}
        setTimeout(function () { if (mode !== 'episodes') { openEpisodes(btn); } }, 420);
      }
    }
    if (!epList.length) {
      toast('当前页面没有可切换的剧集');
      return false;
    }
    renderEpisodes();
    return open('episodes', btn);
  }

  /** 在站点里点某一集。autoPlay=true 时切完后重新拉起原生播放器（原生选集面板回调用）。 */
  function pickEpisode(i, autoPlay) {
    var e = epList[i];
    if (!e || !e.el) { toast('剧集已失效，请重新打开选集'); return; }
    var prev = playUrl || currentMedia();
    var before = mediaUrls.slice(0, 8);
    try { e.el.click(); } catch (err) {}
    log('TVEPISODE', { pick: i, label: e.label, autoPlay: !!autoPlay });
    if (mode === 'episodes') { close(); }
    toast('正在切换到 ' + e.label);
    if (autoPlay) {
      /* 站点要 10 秒上下才把新集的 m3u8 拉回来，这期间它会自己开播。
         先静音，避免网页声音和随后的原生播放器打架。 */
      var mv = q('video');
      if (mv) { try { mv.muted = true; } catch (e2) {} }
      waitForMediaAndPlay(prev, 20000, i, before);
    }
  }

  /** 切集后 video.src 会换、站点还在缓冲。只要拿到新地址就可以交给原生播放器——
      原生自己会去拉流，不必等 H5 的 readyState 到 HAVE_CURRENT_DATA。
      实测（2026-11-07）：上一版要求 readyState>=2，站点新集停在 HAVE_METADATA(1)
      就会一直轮不到，20 秒后误报「还没缓冲好」。改为 duration>0 即认定新源就绪。 */
  function waitForMediaAndPlay(prevUrl, timeoutMs, epIndex, beforeUrls) {
    var start = Date.now();
    var before = beforeUrls || [];
    function freshFromVideo() {
      var v = q('video');
      if (!v) { return ''; }
      var src = v.currentSrc || v.getAttribute('src') || '';
      if (src.indexOf('http') !== 0) { return ''; }
      if (src === prevUrl) { return ''; }
      var dur = typeof v.duration === 'number' ? v.duration : 0;
      if (dur > 0 || v.readyState >= 2) { return src; }
      return '';
    }
    function freshFromSniff() {
      for (var i = 0; i < mediaUrls.length && i < 8; i++) {
        var u = mediaUrls[i];
        if (before.indexOf(u) >= 0 || u === prevUrl) { continue; }
        if (isMediaUrl(u) && !isImageUrl(u)) { return u; }
      }
      return '';
    }
    function poll() {
      var url = freshFromVideo();
      /* 嗅探兜底放在 2.5 秒之后：先给站点机会把 <video src> 换过来，
         免得误抓预取的下集地址。 */
      if (!url && Date.now() - start > 2500) { url = freshFromSniff(); }
      if (url) {
        playUrl = url;
        log('TVEPISODE', { resolved: url.slice(-40), afterMs: Date.now() - start });
        startNativePlay(url, epIndex);
        return;
      }
      if (Date.now() - start > timeoutMs) {
        var tv = q('video');
        if (tv) { try { tv.muted = false; } catch (e3) {} }
        toast('这一集地址还没出来，稍后可再按播放');
        return;
      }
      setTimeout(poll, 500);
    }
    setTimeout(poll, 600);
  }

  window.__tvPickEpisode = function (i) { pickEpisode(i, true); };

  /** 原生面板换集时用：先把当前集的进度写回站点（否则「继续观看」记不住刚看的那一集），
      2.4 秒后再切，避免两个动作抢同一个 <video>。 */
  window.__tvSyncThenPick = function (sec, idx) {
    var s = Number(sec || 0);
    if (s > 2) {
      syncProgress(s);
      setTimeout(function () { pickEpisode(idx, true); }, 2400);
    } else {
      pickEpisode(idx, true);
    }
  };

  /** 原生播放器点「下一集」时用：把当前集 +1 并续播。 */
  function advanceEpisode() {
    var list = collectEpisodes();
    if (!list.length) { return false; }
    var cur = currentEpIndex(list);
    if (cur < 0 || cur + 1 >= list.length) {
      toast('已经是最后一集了');
      return false;
    }
    epList = list;
    pickEpisode(cur + 1, true);
    return true;
  }

  /** 供原生播放器显示选集列表。 */
  window.__tvEpisodeList = function () {
    var list = collectEpisodes();
    var labels = [];
    for (var i = 0; i < list.length; i++) { labels.push(list[i].label); }
    return JSON.stringify({
      title: (q('h1') && text(q('h1'))) || document.title || '',
      labels: labels,
      index: currentEpIndex(list)
    });
  };

  /* ── ② 进度回写「继续观看」（阶段 6） ─────────────────────────
     原生播放器播的是系统 MediaPlayer，站点的 <video> 一直停在原地，
     站点自己的 recorder 收不到 timeupdate，于是「继续观看」永远不会前进。
     退出时把 <video> 静音真播 2 秒（seek 到目标位置前 2 秒），
     站点就会按它自己的格式写回 localStorage / 账号 —— 实测 2.6 秒内落库。 */
  function syncProgress(seconds) {
    var v = q('video');
    if (!v || !(seconds > 0) || progressSyncing) { return false; }
    var wasMuted = v.muted;
    var wasTime = v.currentTime;
    var want = Math.max(0, seconds - 2);
    var apply = function () {
      try {
        v.muted = true;
        v.currentTime = want;
      } catch (e) { return false; }
      return true;
    };
    if (!apply()) {
      /* 元数据还没就绪时 seek 会被丢掉，等 loadedmetadata 再试一次 */
      v.addEventListener('loadedmetadata', apply, false);
      setTimeout(apply, 1200);
    }
    progressSyncing = true;
    var p = null;
    try { p = v.play(); } catch (e) {}
    done(p, function () {});
    setTimeout(function () {
      try {
        v.pause();
        v.muted = wasMuted;
      } catch (e) {}
      progressSyncing = false;
      log('TVPROGRESS', { synced: Math.round(want), from: Math.round(wasTime) });
    }, 2100);
    return true;
  }

  /** 原生播放器退出时由 Java 侧回调。
      reason: back | completed | next | episode */
  window.__tvPlaybackReturn = function (payload) {
    var p = payload || {};
    if (typeof p === 'string') { try { p = JSON.parse(p); } catch (e) { p = {}; } }
    var sec = Number(p.positionMs || 0) / 1000;
    var reason = p.reason || 'back';
    log('TVPLAYBACK_RETURN', { sec: Math.round(sec), reason: reason });
    if (sec > 0) {
      setTimeout(function () { syncProgress(sec); }, 260);
    }
    if (reason === 'next') {
      /* 让进度先落库，再切下一集 */
      setTimeout(advanceEpisode, 3400);
    } else if (reason === 'completed') {
      toast('这一集看完了');
    }
    return true;
  };

  /* ── ③ 账号登录（阶段 6） ─────────────────────────────────────
     站点的登录表单是「账号 + 密码」，没有扫码/短信通道。电视上打字不现实，
     所以：先点站点（隐藏的）登录按钮把表单挂进 DOM，再用手机输入填字段。 */

  function siteLoginForm() {
    return q('.account-access-form');
  }

  function isLoggedIn() {
    return !q('button[aria-label="登录"]') && !q('[data-testid="menu-bottom-login-button"]');
  }

  function ensureLoginForm() {
    if (siteLoginForm()) { return true; }
    var b = q('button[aria-label="登录"]') || q('[data-testid="menu-bottom-login-button"]');
    if (b) { try { b.click(); } catch (e) {} }
    return !!siteLoginForm();
  }

  function maskPwd(v) {
    if (!v) { return ''; }
    var out = '';
    for (var i = 0; i < v.length; i++) { out += '•'; }
    return out;
  }

  function renderLogin() {
    var u = window.__tvUi;
    if (!u) { return; }
    if (loginValues.account) {
      u.loginAcc.textContent = loginValues.account;
      u.loginAcc.classList.remove('tv-login-empty');
    } else {
      u.loginAcc.textContent = armedField === 'account' ? '等待手机输入…' : '未填写';
      u.loginAcc.classList.add('tv-login-empty');
    }
    if (loginValues.password) {
      u.loginPwd.textContent = maskPwd(loginValues.password) + '（' + loginValues.password.length + ' 位）';
      u.loginPwd.classList.remove('tv-login-empty');
    } else {
      u.loginPwd.textContent = armedField === 'password' ? '等待手机输入…' : '未填写';
      u.loginPwd.classList.add('tv-login-empty');
    }
    /* 只增删 is-armed，不要整体赋值 className —— 那会把 focus.js 画上去的
       tv-focused 一起抹掉，焦点环的计算类随之消失（实测踩过一次）。 */
    var arms = qa('.tv-login-arm');
    for (var i = 0; i < arms.length; i++) {
      var isAcc = arms[i].getAttribute('aria-label') === '用手机输入账号';
      var on = (isAcc && armedField === 'account') || (!isAcc && armedField === 'password');
      if (on) { arms[i].classList.add('is-armed'); }
      else { arms[i].classList.remove('is-armed'); }
    }
    var status = '';
    if (isLoggedIn()) {
      status = '已登录，进度与片单会保存到账号';
    } else if (siteLoginForm()) {
      status = '当前为游客账号 · 登录后进度与片单跟着账号走';
    } else {
      status = '登录表单还没就绪，按「登录」会重试';
    }
    u.loginStatus.textContent = status;
  }

  function armField(field) {
    armedField = field;
    renderLogin();
    toast('请在手机上扫码输入' + (field === 'account' ? '账号' : '密码'), 4200);
    log('TVLOGIN_ARM', { field: field });
  }

  function openLogin(btn) {
    if (!build()) { return false; }
    if (isLoggedIn()) {
      toast('当前已登录，无需重复登录');
      return false;
    }
    ensureLoginForm();
    if (!loginValues.account && !loginValues.password) {
      loginValues = { account: '', password: '' };
    }
    armedField = '';
    renderLogin();
    loadQr();
    var ok = open('login', btn);
    /* 表单可能是异步挂载的，1 秒后再刷一次状态 */
    setTimeout(function () { if (mode === 'login') { ensureLoginForm(); renderLogin(); } }, 900);
    return ok;
  }

  function submitLogin() {
    var form = siteLoginForm();
    if (!form) {
      ensureLoginForm();
      form = siteLoginForm();
    }
    if (!form) { toast('登录表单未就绪，请稍后重试'); return false; }
    var acc = form.querySelector('input[autocomplete="username"]') ||
              form.querySelector('input[type="text"]');
    var pwd = form.querySelector('input[type="password"]');
    if (!loginValues.account) { toast('请先用手机输入账号'); return false; }
    if (!loginValues.password) { toast('请先用手机输入密码'); return false; }
    setValue(acc, loginValues.account);
    setValue(pwd, loginValues.password);
    var submit = form.querySelector('button[type="submit"]');
    log('TVLOGIN_SUBMIT', { hasForm: true, hasSubmit: !!submit });
    close();
    toast('正在登录…', 6000);
    setTimeout(function () { if (submit) { try { submit.click(); } catch (e) {} } }, 80);
    if (loginPolling) { clearTimeout(loginPolling); }
    loginPolling = setTimeout(checkLoginResult, 3800);
    return true;
  }

  function checkLoginResult() {
    var logged = isLoggedIn();
    log('TVLOGIN_RESULT', { logged: logged });
    if (logged) {
      loginValues = { account: '', password: '' };
      toast('登录成功，进度与片单已绑定账号', 5200);
    } else {
      toast('登录未成功：请确认账号密码，或站点改版导致表单结构变化', 5200);
    }
  }

  /* ── 二维码 / 手机输入 ───────────────────────────────────────── */

  function renderQr(info) {
    if (!info || !window.__tvUi) { return; }
    qrInfo = info;
    var u = window.__tvUi;
    if (info.qr) {
      u.qrImg.setAttribute('src', info.qr);
      if (u.loginQr) { u.loginQr.setAttribute('src', info.qr); }
    }
    u.qrUrl.textContent = info.url || '（未获取到局域网地址）';
    u.qrPin.textContent = info.pin ? '配对码 ' + info.pin : '';
    if (u.loginQrUrl) { u.loginQrUrl.textContent = info.url || '（未获取到局域网地址）'; }
    if (u.loginQrPin) { u.loginQrPin.textContent = info.pin ? '配对码 ' + info.pin : ''; }
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
    return setValue(ta, text);
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

  function onRemoteText(raw, at) {
    var text = String(raw || '').replace(/\s+/g, ' ').trim().slice(0, 160);
    if (!text) { return; }
    var lag = at ? (Date.now() - at) : -1;

    /* 登录浮层里：手机文字直接落进被选中的字段，不当作搜索词 */
    if (mode === 'login' && armedField) {
      loginValues[armedField] = text;
      var isPwd = armedField === 'password';
      armedField = '';
      renderLogin();
      toast('已填入' + (isPwd ? '密码（' + text.length + ' 位）' : '账号：' + text));
      log('TVINPUT', { text: isPwd ? '(password)' : text, field: isPwd ? 'password' : 'account', lagMs: lag });
      if (loginValues.account && loginValues.password) {
        setTimeout(submitLogin, 420);
      }
      return;
    }

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
    log('TVINPUT', { text: text, lagMs: lag });
  }

  /* ── 原生播放（阶段 5） ──────────────────────────────────────── */

  function startNativePlay(overrideUrl, epIndex) {
    var url = overrideUrl || playUrl || currentMedia();
    if (!url) { toast('当前页没有可直接播放的地址'); return; }
    var v = q('video');
    var pos = v && typeof v.currentTime === 'number' ? Math.round(v.currentTime * 1000) : 0;
    if (overrideUrl) { pos = 0; }
    var h1 = q('h1');
    var title = text(h1) || document.title || '搜剧TV';
    title = title.slice(0, 60);
    if (v) { try { v.pause(); } catch (e) {} }   // 避免网页与原生同时出声

    /* 阶段 6：把剧集列表一起交给原生播放器，MENU 就能在播放中换集 */
    var list = epList.length ? epList : collectEpisodes();
    var labels = [];
    for (var i = 0; i < list.length; i++) { labels.push(list[i].label); }
    var idx = typeof epIndex === 'number' ? epIndex : currentEpIndex(list);
    epList = list;

    call('playback', 'playNative', {
      url: url, title: title, positionMs: pos,
      episodes: labels, episodeIndex: idx
    });
    toast('已交给原生播放器：' + title);
  }

  function scanVideo() {
    if (!window.__tvUi) { return; }
    playUrl = currentMedia();
    if (playUrl) { window.__tvUi.playerBtn.classList.remove('tv-hidden'); }
    else { window.__tvUi.playerBtn.classList.add('tv-hidden'); }

    /* 选集按钮：只在真的有剧集时出现，避免首页多一个死按钮 */
    var hasEpisodes = !!q('.movie-episode-quick-tab') ||
                      !!q('.movie-episode-expanded-grid button[data-directory-episode]') ||
                      !!q('.movie-episode-item');
    if (hasEpisodes) { window.__tvUi.episodeBtn.classList.remove('tv-hidden'); }
    else { window.__tvUi.episodeBtn.classList.add('tv-hidden'); }
  }

  window.__tvPlayerState = function () {
    return JSON.stringify({
      url: playUrl, mediaUrls: mediaUrls.slice(0, 3),
      video: !!q('video'), buttonVisible: !!window.__tvUi &&
        !window.__tvUi.playerBtn.classList.contains('tv-hidden'),
      episodes: collectEpisodes().length,
      episodeBtn: !!window.__tvUi && !window.__tvUi.episodeBtn.classList.contains('tv-hidden'),
      ticks: tickCount,
      overlay: mode || '',
      login: { armed: armedField, account: loginValues.account ? 1 : 0,
               password: loginValues.password ? 1 : 0, loggedIn: isLoggedIn() }
    });
  };

  /* ── 事件 / 自同步 ───────────────────────────────────────────── */

  window.addEventListener('h5shell:native-event', function (ev) {
    var d = ev && ev.detail ? ev.detail : {};
    var p = d.payload || {};
    if (d.name === 'tv.remoteInput') { onRemoteText(p.text, p.at); }
    else if (d.name === 'tv.qrReady') { renderQr(p); }
    else if (d.name === 'tv.inputServerState') { renderQr(p); }
    else if (d.name === 'tv.playbackReturn') { window.__tvPlaybackReturn(p); }
  }, false);

  window.addEventListener('popstate', function () { close(); }, false);
  window.addEventListener('hashchange', function () { close(); }, false);

  function tick() {
    tickCount++;
    build();
    if (location.pathname !== lastPath) {
      lastPath = location.pathname;
      if (mode) { setMode(''); }
      epList = [];
      epExpandedTried = false;
    }
    scanVideo();
    /* 只上报一次状态：原生侧启动时会主动 emit qrReady，这里做兜底 */
    if (!qrInfo && (mode === 'qr' || mode === 'login')) { loadQr(); }
  }

  document.addEventListener('DOMContentLoaded', build, false);
  /* WebView 被原生播放器盖住时定时器会被冻结，回来后立刻补一次 tick，
     否则工具栏图标要么晚 1.5 秒才恢复，要么停在旧状态。 */
  document.addEventListener('visibilitychange', function () {
    if (document.visibilityState === 'visible') { setTimeout(tick, 120); }
  }, false);
  build();
  setInterval(tick, 1500);
  setTimeout(tick, 600);
  log('TVOVERLAY_INSTALLED', { build: 6 });
})();
