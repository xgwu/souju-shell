/* tv-skin.js — TV 版式皮肤的同步器（阶段 3）
 *
 * 配套 tv-skin.css（由 TvFocusEngine 注入到 <style id="__tvSkinCss">）。
 * JS 只做四件 CSS 做不到的事：
 *   ① 给动态拼接的容器打 data-* 标记（Chrome 83 没有 :has()，只能 JS 打点）
 *   ② 把「本周追剧日历」用 flex order 挪到海报墙之后（首屏留给海报）
 *   ③ 用首张海报的数据造「今晚首选」宽幅卡（不额外发网络请求）
 *   ④ 锚点自检 → shell.reportHealth，站点改版导致选择器失效时主动报警
 *
 * 站点是 SPA：换页不触发 WebView 的 onPageFinished，所以必须自己
 * MutationObserver + popstate + 4s 兜底重同步。所有操作幂等。
 *
 * 约束：Chromium 83。不用 ?. / ??= / :has / Array.at / 复杂 :not()。
 */
(function () {
  if (window.__tvSkinInstalled) {
    if (window.__tvSkinSync) { window.__tvSkinSync(); }
    return;
  }
  window.__tvSkinInstalled = true;

  var SKIN = 'tv-dark-v1';
  var installedAt = Date.now();
  var lastReport = '';
  var lastReportAt = 0;
  var pendingSig = '';
  var pendingCount = 0;
  var state = { installed: true, skin: SKIN, ready: false };
  var timer = null;

  /* 站点改版最可能先动的就是这几个锚点。分通用壳 + 首页两组：
     详情页 / 播放器本来就没有 composer、feed rail，不能算 missing。
     刻意不放 .home-feed-card-title：feed 卡片会被站点缓存层逐张重建，
     标题会短暂消失，实测启动 8 秒时误报过一次「改版」告警。 */
  var ANCHORS_COMMON = [
    '.movie-app-bg', '.movie-page-shell', '.movie-page-body',
    '.app-primary-nav-desktop', '.movie-side-menu-panel'
  ];
  var ANCHORS_HOME = [
    '.movie-home-page-shell', '.movie-composer-root', '.movie-composer-text-input',
    '.movie-home-prompt-groups', '.movie-chip', '.home-feed-rail-track',
    '.home-feed-card', '.home-watch-calendar-list'
  ];

  function q(sel) {
    try { return document.querySelector(sel); } catch (e) { return null; }
  }
  function qa(sel) {
    try { return Array.prototype.slice.call(document.querySelectorAll(sel)); }
    catch (e) { return []; }
  }
  function setFlag(el, name) {
    if (el && !el.hasAttribute(name)) { el.setAttribute(name, ''); }
  }
  function text(el) { return el ? (el.textContent || '').trim() : ''; }

  /* 站点会懒加载分片 CSS 并往 head 末尾插 <style>。我们的覆盖规则
     必须始终排在最后，否则同特异性下会被站点规则反压回去。 */
  function ensureCssAtEnd() {
    var s = document.getElementById('__tvSkinCss');
    if (s && s.parentNode && s.parentNode.lastElementChild !== s) {
      s.parentNode.appendChild(s);
    }
    return !!s;
  }

  function mark() {
    var root = document.documentElement;
    if (root.getAttribute('data-tv-skin') !== 'on') {
      root.setAttribute('data-tv-skin', 'on');
    }
    /* 站点 .movie-main-shell 的 padding-left 用 `var(--movie-sidebar-width)!important`，
       且变量会在 [data-side-menu-collapsed] 等派生选择器上被重定义。
       html 上写 inline !important 是唯一不会被样式表顺序反压的位置。 */
    try {
      root.style.setProperty('--movie-sidebar-width', '40px', 'important');
    } catch (e) { /* 老内核不支持自定义属性时，CSS 里的 padding 覆盖仍然兜底 */ }

    var side = q('.movie-side-menu-panel');
    if (side && side.parentElement) { setFlag(side.parentElement, 'data-tv-nav-host'); }

    var h1 = q('.movie-home-page-shell h1');
    if (h1 && h1.parentElement) { setFlag(h1.parentElement, 'data-tv-hero'); }

    /* 第二组推荐词在 TV 首屏价值不高，隐藏以给海报让位 */
    var groups = qa('.movie-home-prompt-groups [data-home-suggestion-group]');
    for (var g = 1; g < groups.length; g++) { setFlag(groups[g], 'data-tv-secondary-chips'); }

    /* order 必须在同一个 flex 容器里：.movie-page-body 的第一个直接子 div */
    var wrap = q('.movie-page-body > div');
    if (wrap) {
      for (var i = 0; i < wrap.children.length; i++) {
        var c = wrap.children[i];
        if (c.hasAttribute('data-tv-tonight')) { continue; }
        var isFeed = !!c.querySelector('.home-feed-rail');
        var head = (c.innerText || '').slice(0, 60);
        var isLate = !!c.querySelector('.home-watch-calendar-list') ||
                     head.indexOf('本周追剧') >= 0;
        var isTail = head.indexOf('继续下滑') >= 0 || head.indexOf('加载更多') >= 0;
        if (isFeed) { setFlag(c, 'data-tv-feed'); }
        else if (isLate) { setFlag(c, 'data-tv-late'); }
        else if (isTail) { setFlag(c, 'data-tv-tail'); }
      }
    }
  }

  /* 今晚首选：复用首张 feed 卡的图 / 标题 / 简介 / 链接。
     不写 innerHTML（站点 CSP 无 unsafe-inline，且避免把标题当 HTML 解析）。 */
  function tonight() {
    var old = q('.tv-tonight-card');
    if (!q('.movie-home-page-shell')) { return; }

    var card = q('.home-feed-card');
    if (!card) { return; }
    var link = card.querySelector('.home-feed-card-link');
    var img = card.querySelector('.home-feed-card-image');
    var title = text(card.querySelector('.home-feed-card-title'));
    if (!link || !img || !title) { return; }

    /* 用 getAttribute 而不是 currentSrc 做签名：后者要等图片解码完成才有值，
       会让签名在启动期变一次。 */
    var src = img.getAttribute('src') || img.currentSrc || img.src || '';
    var href = link.getAttribute('href') || '#';
    var sig = href + '|' + title + '|' + src;

    /* 必须幂等。第一版每次 sync 都 removeChild + 重建，MutationObserver 又被
       自己的 DOM 改动触发，形成 220ms 一次的死循环；实机表现为候选数在
       75/76 之间跳、焦点每按两下就被打回「首页」重新初始化。 */
    if (old && old.getAttribute('data-tv-sig') === sig) { return; }
    if (old && old.parentNode) { old.parentNode.removeChild(old); }

    var a = document.createElement('a');
    a.className = 'tv-tonight-card';
    a.setAttribute('href', href);
    a.setAttribute('data-tv-tonight', '');
    a.setAttribute('data-tv-sig', sig);
    a.setAttribute('aria-label', '今晚首选：' + title);

    if (src) {
      var cover = document.createElement('img');
      cover.setAttribute('src', src);
      cover.setAttribute('alt', '');
      cover.setAttribute('loading', 'eager');
      cover.setAttribute('referrerpolicy', 'no-referrer');
      cover.addEventListener('error', function () {
        if (cover.parentNode) { cover.parentNode.removeChild(cover); }
      }, false);
      a.appendChild(cover);
    }

    var shade = document.createElement('div');
    shade.className = 'tv-tonight-shade';
    a.appendChild(shade);

    var copy = document.createElement('div');
    copy.className = 'tv-tonight-copy';
    var label = document.createElement('span');
    label.className = 'tv-tonight-label';
    label.textContent = '今晚首选';
    var h = document.createElement('span');
    h.className = 'tv-tonight-title';
    h.textContent = title;
    var meta = document.createElement('span');
    meta.className = 'tv-tonight-meta';
    meta.textContent = text(card.querySelector('.home-feed-card-meta')) || '今晚就看这一部';
    copy.appendChild(label);
    copy.appendChild(h);
    copy.appendChild(meta);
    a.appendChild(copy);

    var groups = q('.movie-home-prompt-groups');
    var wrap = groups ? groups.parentElement : q('.movie-page-body > div');
    if (!wrap) { return; }
    /* 插在热词组之后；日历 section 因 order:3 会自动排到末尾 */
    wrap.insertBefore(a, groups ? groups.nextSibling : null);
  }

  function health() {
    var isHome = !!q('.movie-home-page-shell');
    var list = ANCHORS_COMMON.concat(isHome ? ANCHORS_HOME : []);
    var missing = [];
    for (var i = 0; i < list.length; i++) {
      if (!q(list[i])) { missing.push(list[i]); }
    }
    var track = q('.home-feed-rail-track');
    var cols = 0;
    if (track) {
      var g = window.getComputedStyle(track).gridTemplateColumns;
      cols = g ? g.split(' ').length : 0;
    }
    var overflow = document.documentElement.scrollWidth > window.innerWidth + 2;
    var composer = q('.movie-composer-text-input');
    var font = composer ? window.getComputedStyle(composer).fontSize : '';
    var chip = q('.movie-chip');
    var chipFont = chip ? window.getComputedStyle(chip).fontSize : '';

    state = {
      installed: true, skin: SKIN, ready: true,
      path: location.pathname, home: isHome,
      css: !!document.getElementById('__tvSkinCss'),
      marker: document.documentElement.getAttribute('data-tv-skin'),
      columns: cols, overflowX: overflow,
      inputFont: font, chipFont: chipFont,
      tonight: !!q('.tv-tonight-card'),
      checked: list.length, missing: missing
    };

    /* 实机启动日志给出的教训：主文档 readyState=complete 之后，SPA 首页组件
       还要 2–3 秒才挂载。原来的 2.5s 门槛在启动 1.2–2.5 秒内连报 3 次
       「4 个锚点缺失」的假警，触发了原生侧的告警 Toast。
       改成双重门槛：4 秒宽限期 + 连续两次签名一致才上报。
       站点真改版时签名稳定，约 6 秒必报；启动期的抖动签名各不相同，会被吃掉。 */
    if (Date.now() - installedAt < 6000) { return; }
    if (document.readyState !== 'complete') { return; }

    var sig = location.pathname + '|' + missing.join(',') + '|' + overflow + '|' + cols;
    if (sig === pendingSig) { pendingCount++; }
    else { pendingSig = sig; pendingCount = 1; }
    if (pendingCount < 2) { return; }
    if (sig === lastReport && Date.now() - lastReportAt < 30000) { return; }
    lastReport = sig;
    lastReportAt = Date.now();

    try {
      if (window.H5ShellNativeBridge && window.H5ShellNativeBridge.call) {
        window.H5ShellNativeBridge.call('shell', 'reportHealth', {
          missing: missing.join(','), skin: SKIN, path: location.pathname,
          checked: list.length, columns: cols, overflowX: overflow
        })['catch'](function () { /* 桥未就绪时静默，下次同步再试 */ });
      }
    } catch (e) { /* 不让自检把页面搞崩 */ }
  }

  var mo = null;
  function observe() {
    if (!mo) { return; }
    if (document.body) { mo.observe(document.body, { childList: true, subtree: true }); }
    if (document.head) { mo.observe(document.head, { childList: true }); }
  }
  function schedule() {
    if (timer) { return; }
    timer = setTimeout(function () { timer = null; sync(); }, 220);
  }
  function sync() {
    if (mo) { mo.disconnect(); }
    try {
      ensureCssAtEnd();
      mark();
      tonight();
      health();
    } catch (e) {
      state = { installed: true, skin: SKIN, ready: true, error: String(e) };
    }
    observe();
  }

  window.__tvSkinSync = sync;
  window.__tvSkinState = function () { return JSON.stringify(state); };

  if (window.MutationObserver) {
    mo = new MutationObserver(function () { schedule(); });
  }
  window.addEventListener('popstate', schedule, false);
  window.addEventListener('hashchange', schedule, false);
  document.addEventListener('DOMContentLoaded', sync, false);
  window.addEventListener('load', function () { setTimeout(sync, 300); }, false);
  /* SPA 里偶发整块替换不被 observer 捕获，3 秒兜底；
     4.2 秒那次与下一次定时同步正好凑齐「连续两次一致」的上报门槛。 */
  setInterval(sync, 3000);

  sync();
  setTimeout(sync, 4200);
  console.log('TVSKIN_INSTALLED');
})();
