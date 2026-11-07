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

  /* 站点还在为某个媒体发请求的次数。recordMedia 每次被调用都 +1（同一地址
     重复请求也算），直通播放靠它判断「这一轮的解析真的开始了」——
     SPA 换页后 <video> 里往往还留着上一部片的地址且 duration 依然 > 0，
     只看 duration 会把上一部片当成这一部直接起播（实测踩过）。 */
  var mediaSeq = 0;

  function recordMedia(u) {
    if (typeof u !== 'string' || u.indexOf('http') !== 0) { return; }
    mediaSeq++;
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
        startNativePlay(url, epIndex, 'pick');
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
    /* 直通会话里换集：先把遮罩切回「正在切换剧集」，用户在播放器里选完集
       到新集起播这段时间，看到的是遮罩而不是详情页。 */
    if (window.__tvDpSwitch) { window.__tvDpSwitch(); }
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
    /* 直通播放：用户看到的「上级页面」应该是首页，不是被遮住的详情页。
       等 2.6 秒让 syncProgress 那 2.1 秒的静音回写跑完，再回退一步；
       遮罩在这 2.6 秒里继续盖着，只在回到首页（popstate）时才撤掉。 */
    if (dpActive && (reason === 'back' || reason === 'completed')) {
      dpPhase = 'exit';
      dpSession = false;
      if (!q('.tv-dp')) { dpOverlay(); }
      dpHint(reason === 'completed' ? '这一集看完了，正在返回首页…' : '正在返回首页…');
      log('TVDP_EXIT', { reason: reason });
      setTimeout(function () {
        try { window.history.back(); } catch (e) {}
      }, 2600);
    }
    if (reason === 'next') {
      /* 直通会话里：立刻把遮罩切回「正在切换剧集」，用户看不到详情页 */
      if (dpActive) { window.__tvDpSwitch(); }
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

  var lastNativeUrl = '';
  var lastNativeAt = 0;

  function startNativePlay(overrideUrl, epIndex, note) {
    var url = overrideUrl || playUrl || currentMedia();
    if (!url) { toast('当前页没有可直接播放的地址'); return; }
    /* 直通播放时 dpTick 与 pickEpisode 自己的轮询会同时发现同一个地址，
       不加这道闸门就会连开两个播放器 Activity（叠在一起，返回要按两次）。 */
    if (url === lastNativeUrl && Date.now() - lastNativeAt < 3000) { return; }
    lastNativeUrl = url;
    lastNativeAt = Date.now();
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

    /* 直通会话：不管是首次起播、播放器里换集还是「下一集」，只要交给原生播放器，
       遮罩就从「等地址」切到「已起播」（不撤 —— 播放器会整块盖住 WebView，
       留着它，用户退出播放器时看到的是遮罩而不是详情页）。 */
    dpToPlaying(note || (overrideUrl ? 'pick' : 'resolve'), url);

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

  window.addEventListener('popstate', function () {
    close();
    /* 回到首页 = 直通会话收尾，撤遮罩、清状态。两种情况都会走到这里：
       ① 用户在看遮罩时按了返回（电视上主线程被详情页解析卡住时返回键会被
          排队几秒才派发，实测和起播只差 93ms，不处理就会「人已回首页、播放器
          又自己弹出来」）；② 播放器退出后我们主动 history.back() 回首页。 */
    if (dpActive && location.pathname === '/') {
      var d = dpGet() || {};
      log('TVDP_CANCEL', { note: 'popstate', phase: dpPhase,
        waitedMs: d.t ? (Date.now() - d.t) : -1 });
      dpReset();
    }
  }, false);
  window.addEventListener('hashchange', function () { close(); }, false);

  /* ── 阶段 8：直通播放（点海报 → 全屏原生播放器） ──────────────
     用户反馈：点海报先落到详情页，信息一堆、还要自己找播放键；而站点详情页
     在这台机器上要 11 秒才建出 <video>、24 秒才可播（关皮肤实测 14/27 秒，
     不是我们拖慢的）。
     做法：点海报时记下「要直通」并盖一层全屏起播遮罩，站点照常 SPA 进详情页
     （跑在遮罩下面，用户看不见）；一旦拿到可播地址就立刻交给原生播放器全屏起播，
     退出播放器时 history.back() 回首页 —— 全程没有「详情页」这一刻。
     换集不打断：播放器选集面板返回 pick 时 Java 侧调 __tvSyncThenPick，
     在后台的详情页里点对应集，站点重新解析后播放器重开，链路与阶段 6 一致。 */
  var DP_KEY = '__tvDirectPlay';
  var dpTimer = null;
  /** 一次直通会话是否在进行：从点海报开始，到回到首页结束。
      遮罩在整个会话期间**一直挂着**（原生播放器是独立 Activity，会整块盖住
      WebView，用户看不到遮罩），换来的是换集回来时零闪烁 —— 不会再闪一下详情页。 */
  var dpActive = false;
  /** resolve（首次解析）| switch（换集重解析）| playing（播放器已起）| exit（正在回首页） */
  var dpPhase = '';
  var dpSession = false;
  /** 进入「等地址」那一刻的媒体水位：序号、<video> 元素、它当时挂的地址。 */
  var dpSeq = 0;
  var dpVideo = null;
  var dpOldSrc = '';
  /** 这一轮锁定的详情页路径。遮罩盖着的时候用户仍可能盲按 OK/方向键把站点
      导航到别的片，路径一变就该收手，不能等地址就绪再「隔空起播」。 */
  var dpPath = '';
  /** 「线路较慢」只记一次日志，别每 300ms 刷一条 */
  var dpSlowLogged = false;

  function dpGet() {
    try { return JSON.parse(sessionStorage.getItem(DP_KEY) || 'null'); } catch (e) { return null; }
  }
  function dpSet(v) {
    try {
      if (v) { sessionStorage.setItem(DP_KEY, JSON.stringify(v)); }
      else { sessionStorage.removeItem(DP_KEY); }
    } catch (e) {}
  }

  function dpHint(txt) {
    var h = q('.tv-dp-hint');
    if (h && txt && h.textContent !== txt) { h.textContent = txt; }
  }

  function dpOverlay() {
    var el = q('.tv-dp');
    if (el) { return el; }
    if (!document.body) { return null; }
    var dp = dpGet() || {};
    el = make('div', 'tv-dp');
    el.setAttribute('data-tv-dp', '');
    var bg = make('div', 'tv-dp-bg');
    if (dp.poster) { bg.style.backgroundImage = 'url("' + dp.poster + '")'; }
    var shade = make('div', 'tv-dp-shade');
    var copy = make('div', 'tv-dp-copy');
    var t = make('div', 'tv-dp-title');
    t.textContent = dp.title || '正在起播';
    var hint = make('div', 'tv-dp-hint');
    hint.textContent = dpPhase === 'switch' ? '正在切换剧集…' : '正在解析线路…';
    var bar = make('div', 'tv-dp-bar');
    bar.appendChild(make('i', ''));
    copy.appendChild(t);
    copy.appendChild(hint);
    copy.appendChild(bar);
    el.appendChild(bg);
    el.appendChild(shade);
    el.appendChild(copy);
    document.body.appendChild(el);
    return el;
  }

  function dpClose() {
    var el = q('.tv-dp');
    if (el && el.parentNode) { el.parentNode.removeChild(el); }
  }

  /** 把直通会话彻底复位。缺了它，一轮播完后状态永远停在「已起播」，
      这之后所有海报点击都会被 dpBegin 之前的守卫静默掉（实测第二次点海报
      直接落到了普通详情页）。 */
  function dpReset() {
    dpActive = false;
    dpPhase = '';
    dpSession = false;
    dpPath = '';
    dpSlowLogged = false;
    if (dpTimer) { clearInterval(dpTimer); dpTimer = null; }
    dpClose();
    dpSet(null);
  }

  /** 进入「等地址」阶段：首次解析（resolve）和换集重解析（switch）都走这里。
      t 同时用来算超时和提示里的秒数。 */
  function dpWait(phase) {
    var dp = dpGet() || {};
    dpActive = true;
    dpPhase = phase;
    dpPath = '';
    dpSlowLogged = false;
    dpSeq = mediaSeq;
    dpVideo = q('video');
    dpOldSrc = dpVideo ? (dpVideo.currentSrc || dpVideo.getAttribute('src') || '') : '';
    var rec = {
      t: Date.now(), phase: phase,
      title: dp.title || '', poster: dp.poster || ''
    };
    dpSet(rec);
    dpOverlay();
    dpHint(phase === 'switch' ? '正在切换剧集…' : '正在解析线路…');
    if (!dpTimer) { dpTimer = setInterval(dpTick, 300); }
    return rec;
  }

  /** 播放器一起播就切到 playing：遮罩留着（被播放器整块盖住），但不再轮询。
      首次起播、换集、下一集都收敛到这里。 */
  function dpToPlaying(note, src) {
    if (!dpActive) { return false; }
    var dp = dpGet() || {};
    dpSession = true;
    dpPhase = 'playing';
    if (dpTimer) { clearInterval(dpTimer); dpTimer = null; }
    dp.phase = 'playing';
    dpSet(dp);
    dpHint('正在起播…');
    log('TVDP_START', {
      src: src ? src.slice(0, 64) : '', note: note || '',
      waitedMs: dp.t ? (Date.now() - dp.t) : -1
    });
    return true;
  }

  function dpStart(src) {
    if (dpPhase === 'playing') { return; }   // pickEpisode 自己那条路可能已经起播
    startNativePlay(src, 0, dpPhase === 'switch' ? 'switch' : 'resolve');
  }

  /** 播放器里换集 / 下一集：把遮罩切回「等地址」，站点在后台重新解析。
      用户从播放器退出时看到的是遮罩而不是详情页 —— 这正是要的效果。 */
  window.__tvDpSwitch = function (label) {
    if (!dpActive) { return false; }
    dpWait('switch');
    if (label) { dpHint('正在切换剧集… ' + label); }
    log('TVDP_SWITCH', { label: label || '' });
    return true;
  };

  function dpTick() {
    if (!dpActive) {
      if (dpTimer) { clearInterval(dpTimer); dpTimer = null; }
      return;
    }
    /* playing / exit 两个阶段不需要轮询：playing 时播放器盖着，exit 时在等 history.back */
    if (dpPhase === 'playing' || dpPhase === 'exit') { return; }
    var dp = dpGet();
    if (!dp) {
      if (dpTimer) { clearInterval(dpTimer); dpTimer = null; }
      return;
    }
    var waited = Date.now() - dp.t;
    var path = location.pathname;
    /* 回到首页 = 这一轮结束（用户按返回放弃，或播完自动回来）。留 1.5 秒宽限，
       因为 dpBegin 那一刻路径还是「/」，SPA 要几十毫秒后才换到详情页。 */
    if (waited > 1500 && path === '/') {
      log('TVDP_CANCEL', { note: 'home', phase: dpPhase, waitedMs: Math.round(waited) });
      dpReset();
      return;
    }
    /* 遮罩是挂在 body 上的普通 div，SPA 换页不会清掉它；万一被清掉就补一块。 */
    if (!q('.tv-dp')) { dpOverlay(); }
    if (path.indexOf('/player/') !== 0) { return; }
    if (!dpPath) { dpPath = path; }
    else if (path !== dpPath) {
      log('TVDP_CANCEL', { note: 'path-changed', waitedMs: Math.round(waited) });
      dpReset();
      return;
    }
    /* 遮罩盖着时站点自己的 <video> 在后台解析，可能自己出声 —— 一律静音，
       声音只给原生播放器。 */
    var v = q('video');
    if (v) { try { if (!v.muted) { v.muted = true; } } catch (e) {} }
    /* 判据必须和工具栏「原生播放」完全一致（currentMedia）：站点把整部 mp4
       藏在 .image 路径下伪装（CDN 谎报 image/*，字节是 ftyp isom），
       按扩展名过滤会把真直链当成封面图跳过 —— 实测就是这样一直等到超时。
       但 currentMedia 会顺着沿用 SPA 换页后残留的 <video>，所以再加两道
       新鲜度闸门：① 这一轮得真有媒体请求；② 不能还是原地那个元素那个地址。 */
    var src = currentMedia();
    /* 换集阶段不抢起播：pickEpisode 自己会轮询并用「正确的第几集」调
       startNativePlay。这里再抢一次会和它撞车 —— 实测旧集换个 HLS 变体地址
       （index.m3u8 → 3000k/hls/mixed.m3u8）就能骗过新鲜度判断，结果先黑屏
       播回旧集，4 秒后新集的播放器才盖上来。 */
    if (dpPhase !== 'switch') {
      var stale = (v && v === dpVideo && src && src === dpOldSrc);
      if (src && mediaSeq > dpSeq && !stale) {
        dpStart(src);
        return;
      }
    }
    var sec = Math.round(waited / 1000);
    var base = dpPhase === 'switch' ? '正在切换剧集… ' : '正在解析线路… ';
    /* 用户明确要求「一直停在起播页」，所以不再定时把详情页甩出来。
       超过 1 分钟只换一句提示，告诉他还能按返回自己退出。 */
    if (waited > 60000) {
      if (!dpSlowLogged) {
        dpSlowLogged = true;
        log('TVDP_SLOW', { phase: dpPhase, waitedMs: Math.round(waited) });
      }
      dpHint('线路较慢，仍在解析… ' + sec + 's（按返回可退出）');
    } else {
      dpHint(base + sec + 's');
    }
    /* 3 分钟还拿不到地址，基本可以判定这条线路是死的 —— 这时才退回详情页。 */
    if (waited > 180000) {
      log('TVDP_TIMEOUT', { phase: dpPhase, waitedMs: Math.round(waited) });
      dpReset();
      toast('线路一直没解析出来，已回到详情页 —— 可按 MENU 换一条线路再试');
    }
  }

  function dpBegin(link) {
    var title = text(link.querySelector('.home-feed-card-title, h3')) || '';
    var img = link.querySelector('img');
    var poster = img ? (img.currentSrc || img.getAttribute('src') || '') : '';
    dpSession = false;
    dpActive = false;
    dpSet({ t: Date.now(), title: title, poster: poster });   // 先把标题海报放进记录
    dpWait('resolve');
    log('TVDP_BEGIN', { title: title.slice(0, 24) });
  }

  /* 只在首页的「海报 / 继续观看」卡片上触发；不 preventDefault ——
     站点自己的 SPA 路由必须照常跑，否则详情页不会去解析播放地址。 */
  document.addEventListener('click', function (ev) {
    /* 回到首页 = 上一轮已经收尾，先复位再判断，否则会话标记的残留会把
       这一轮的所有海报点击都吃掉。 */
    if (dpActive && location.pathname === '/') { dpReset(); }
    if (mode || dpActive) { return; }
    if (location.pathname !== '/') { return; }
    var t = ev.target;
    if (!t || !t.closest) { return; }
    var a = t.closest('.home-feed-card-link, .movie-resume-link');
    if (!a) { return; }
    dpBegin(a);
  }, true);

  window.__tvDirectPlayState = function () {
    var dp = dpGet();
    return JSON.stringify({
      active: dpActive, phase: dpPhase, session: dpSession,
      mask: !!q('.tv-dp'),
      title: dp ? dp.title : '', waitedMs: dp && dp.t ? (Date.now() - dp.t) : -1,
      mediaSeq: mediaSeq, dpSeq: dpSeq
    });
  };

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
