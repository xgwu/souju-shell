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
  /* .app-primary-nav-desktop 只存在于首页壳：/session/new、/player/:id 都没有，
     放在 COMMON 里会在每次搜索后误报「站点改版」并弹 Toast。 */
  /* 播放页 / 会话页只保留全局壳：实测这两个页面没有 .movie-page-shell /
     .movie-page-body / .app-primary-nav-desktop，列进 COMMON 会持续误报。 */
  var ANCHORS_COMMON = [
    '.movie-app-bg', '.movie-side-menu-panel'
  ];
  var ANCHORS_HOME = [
    '.movie-page-shell', '.movie-page-body',
    '.movie-home-page-shell', '.app-primary-nav-desktop',
    '.movie-composer-root', '.movie-composer-text-input',
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

  /** 从 el 向上走到 wrap 的直接子节点，给它打标记（flex order 只认同一层兄弟）。 */
  function flagBlock(wrap, sel, attr) {
    var el = q(sel);
    if (!el) { return; }
    var n = el;
    while (n && n.parentElement && n.parentElement !== wrap) { n = n.parentElement; }
    if (n && n.parentElement === wrap) { setFlag(n, attr); }
  }

  /* 站点用 keepalive 缓存路由：进入 /player 或 /session 后首页 DOM 仍留在文档里
     （只是隐藏）。按 DOM 判首页会把 HOME 锚点套到播放页上连报「站点改版」。
     一律按 pathname 判定。 */
  function isHomePath() {
    var p = location.pathname;
    return p === '/' || p === '' || p === '/index.html';
  }

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

    /* order 必须在同一个 flex 容器里：.movie-page-body 的第一个直接子 div。
       旧版靠 innerText 猜哪一块是「继续观看/本周追剧」，站点把标题渲染晚
       0.5 秒就漏标 —— 实测 data-tv-feed 到 8 秒还没打上，于是海报墙先按默认
       order 排到日历前面，再被顶下去。改成从真实节点向上走到 wrap 的直接
       子节点，结构再变也对得上。 */
    var wrap = q('.movie-page-body > div');
    if (wrap) {
      flagBlock(wrap, '.home-feed-rail-track', 'data-tv-feed');
      flagBlock(wrap, '.home-feed-section-list', 'data-tv-feed');
      flagBlock(wrap, '.movie-resume-section', 'data-tv-resume');
      flagBlock(wrap, '.home-watch-calendar', 'data-tv-late');
      /* 「继续下滑，或点击加载更多」没有稳定类名，只能按文案认，但它是纯文本块 */
      for (var i = 0; i < wrap.children.length; i++) {
        var c = wrap.children[i];
        var head = (c.innerText || '').slice(0, 60);
        if (head.indexOf('继续下滑') >= 0 || head.indexOf('加载更多') >= 0) {
          setFlag(c, 'data-tv-tail');
        }
      }
    }

    /* 今晚首选卡的宿主 div（站点那个 max-w-3xl 容器）：要压掉它的 pt-4/pt-6，
       否则首屏顶部白掉 24px。标记而不是按类名命中，站点换 class 也不影响。
       阶段 7 补：**卡还没建出来就要先标记**。宿主没标记时高度只有 24px，
       等真卡在 9.7 秒建好、`min-height:126px` 才生效，整页在揭幕之后
       又整体下移 102px（实测 继续观看 ph 从 y=106 跳到 208）——
       这正好是用户说的「先闪一版再刷新」。热词组是宿主的稳定子节点，
       从它拿父节点比等卡更早。 */
    var pg = q('.movie-home-prompt-groups');
    var host = pg ? pg.parentElement : null;
    if (!host) {
      var tn = q('.tv-tonight-card');
      if (tn) { host = tn.parentElement; }
    }
    if (host) { setFlag(host, 'data-tv-tonight-host'); }
  }

  /* ── 首屏占位（阶段 7） ─────────────────────────────────────
     站点首页的「继续观看」「本周追剧」是后挂载的：实测海报墙 4.3 秒就有了，
     这两块要 7.6 秒。等它们 = 开机空等 3 秒多；不等就会被它们当场把海报墙
     顶下去 300px —— 这就是「初始首页闪一下再刷新」的观感来源。
     折中：先放等高占位撑住位置，真块挂上来原位替换，海报墙从第一帧起
     就待在最终位置，全程零位移。 */
  var PH_KEYS = ['resume', 'late'];

  function ensurePh(wrap, key) {
    if (q('[data-tv-ph="' + key + '"]')) { return; }
    var d = document.createElement('div');
    d.className = 'tv-ph tv-ph-' + key;
    d.setAttribute('data-tv-ph', key);
    d.setAttribute('aria-hidden', 'true');
    d.__tvPhAt = Date.now();
    wrap.appendChild(d);
  }

  function placeholders() {
    var i, key, real, ph;
    if (!isHomePath()) {
      for (i = 0; i < PH_KEYS.length; i++) { dropPh(PH_KEYS[i]); }
      return;
    }
    var wrap = q('.movie-page-body > div');
    if (!wrap) { return; }
    var now = Date.now();
    for (i = 0; i < PH_KEYS.length; i++) {
      key = PH_KEYS[i];
      real = q('[data-tv-' + key + ']');
      ph = q('[data-tv-ph="' + key + '"]');
      if (real) {
        /* 真块到位：同位撤掉占位。 */
        if (ph && ph.parentNode) { ph.parentNode.removeChild(ph); }
        continue;
      }
      /* 12 秒还没挂上来（例如没登录 / 没有观看记录）就撤掉，别留空档 */
      if (ph && ph.__tvPhAt && now - ph.__tvPhAt > 12000) {
        if (ph.parentNode) { ph.parentNode.removeChild(ph); }
        continue;
      }
      if (!ph) { ensurePh(wrap, key); }
    }
  }

  function dropPh(key) {
    var el = q('[data-tv-ph="' + key + '"]');
    if (el && el.parentNode) { el.parentNode.removeChild(el); }
  }

  /* 今晚首选：复用首张 feed 卡的图 / 标题 / 简介 / 链接。
     不写 innerHTML（站点 CSP 无 unsafe-inline，且避免把标题当 HTML 解析）。 */
  function tonight() {
    var old = q('.tv-tonight-card');
    if (!isHomePath()) { return; }

    /* 不能直接取第一张 .home-feed-card：站点的骨架卡也带这个类、但没有
       <img> 和标题，实测会一直卡住，直到骨架被替换（比 feed 晚 5 秒）。
       这里扫描第一张「图和标题都在」的真卡。 */
    var cards = qa('.home-feed-card');
    var card = null, link = null, img = null, title = '';
    for (var ci = 0; ci < cards.length; ci++) {
      var l = cards[ci].querySelector('.home-feed-card-link');
      var im = cards[ci].querySelector('.home-feed-card-image');
      var t = text(cards[ci].querySelector('.home-feed-card-title'));
      if (l && im && t) { card = cards[ci]; link = l; img = im; title = t; break; }
    }
    if (!card) { return; }

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

    /* 版式（阶段 7）：原来把 420×600 的竖版封面 cover 到 1200×148 ——
       先横向放大 2.86 倍、再按 148 高裁掉 82% 画面，等于「又糊又空」。
       现在拆成两层：背景用同一张图 blur(26px) 抹掉放大痕迹，
       前景放 64×96 的竖版缩略图（原图 420×600 恰好是 2:3，缩小后锐利）。 */
    if (src) {
      var bg = document.createElement('div');
      bg.className = 'tv-tonight-bg';
      var blur = document.createElement('img');
      blur.className = 'tv-tonight-bg-img';
      blur.setAttribute('src', src);
      blur.setAttribute('alt', '');
      blur.setAttribute('referrerpolicy', 'no-referrer');
      bg.appendChild(blur);
      a.appendChild(bg);
    }

    var shade = document.createElement('div');
    shade.className = 'tv-tonight-shade';
    a.appendChild(shade);

    /* 缩略图排在遮罩之后：遮罩是左深右浅的渐变，压在缩略图上会把它压暗。 */
    if (src) {
      var thumb = document.createElement('img');
      thumb.className = 'tv-tonight-thumb';
      thumb.setAttribute('src', src);
      thumb.setAttribute('alt', '');
      thumb.setAttribute('loading', 'eager');
      thumb.setAttribute('referrerpolicy', 'no-referrer');
      thumb.addEventListener('error', function () {
        if (thumb.parentNode) { thumb.parentNode.removeChild(thumb); }
      }, false);
      a.appendChild(thumb);
    }

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
    var isHome = isHomePath();
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
      overlay: document.documentElement.getAttribute('data-tv-overlay') || '',
      toolbar: !!q('.tv-toolbar'),
      chipsHidden: (function () {
        var g = q('.movie-home-prompt-groups');
        return g ? window.getComputedStyle(g).display === 'none' : false;
      })(),
      composerHidden: (function () {
        var c = q('.movie-composer-root');
        return c ? window.getComputedStyle(c).display === 'none' : false;
      })(),
      checked: list.length, missing: missing
    };

    markPart('feedTrack:' + !!q('.home-feed-rail-track'));
    markPart('feedCard:' + !!q('.home-feed-card'));
    markPart('tonight:' + !!q('.tv-tonight-card'));
    markPart('resume:' + !!q('.movie-resume-section'));
    markPart('late:' + !!q('.home-watch-calendar-days'));

    markPart('feedTrack:' + !!q('.home-feed-rail-track'));
    markPart('feedCard:' + !!q('.home-feed-card'));
    markPart('tonight:' + !!q('.tv-tonight-card'));
    markPart('resume:' + !!q('.movie-resume-section'));
    markPart('late:' + !!q('.home-watch-calendar-days'));

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
      placeholders();
      tonight();
      health();
    } catch (e) {
      state = { installed: true, skin: SKIN, ready: true, error: String(e) };
    }
    observe();
  }

  /* ── 就绪上报（阶段 7 关键） ────────────────────────────────
     为什么不用原生轮询 evaluateJavascript：实测这个 WebView 在页面忙碌时
     evaluateJavascript 的 ValueCallback 延迟能到 1.6 秒（一次请求 8 秒只回了
     5 次），轮询永远踩不到「刚好就绪」的那一刻，只能等超时。
     改成 JS 自己 push：就绪后 console.log('SOUJUTV SKIN_READY')，
     原生 TvChromeClient 已经在转发 SOUJUTV 前缀的 console，直接接住即可，
     零延迟、零新桥面。 */
  var readyAnnounced = false;
  var readyTimer = null;

  function announceReady() {
    if (readyAnnounced) { return; }
    var r = window.__tvSkinReady ? window.__tvSkinReady() : 0;
    if (!r) { return; }
    readyAnnounced = true;
    if (readyTimer) { clearInterval(readyTimer); readyTimer = null; }
    try { console.log('SOUJUTV SKIN_READY'); } catch (e) {}
  }

  /* 揭幕门超时自述：把每个门槛的真实值打出来，下次「一直不揭幕」
     不用再猜是哪一项。只在原生判定超时时调用一次。 */
  window.__tvSkinReadyWhy = function () {
    var t = q('.home-feed-rail-track');
    return [
      'marker=' + document.documentElement.getAttribute('data-tv-skin'),
      'css=' + !!document.getElementById('__tvSkinCss'),
      'rs=' + document.readyState,
      'home=' + isHomePath(),
      'stateReady=' + (state && state.ready),
      'feed=' + !!q('[data-tv-feed]'),
      'trackKids=' + (t ? t.children.length : 'none'),
      'age=' + (Date.now() - installedAt),
      'ready=' + (window.__tvSkinReady ? window.__tvSkinReady() : 'nofn')
    ].join(' ');
  };

  /* 揭幕门超时自述：把每个门槛的真实值打出来，下次「一直不揭幕」
     不用再猜是哪一项。只在原生判定超时时调用一次。 */
  window.__tvSkinReadyWhy = function () {
    var t = q('.home-feed-rail-track');
    return [
      'marker=' + document.documentElement.getAttribute('data-tv-skin'),
      'css=' + !!document.getElementById('__tvSkinCss'),
      'rs=' + document.readyState,
      'home=' + isHomePath(),
      'stateReady=' + (state && state.ready),
      'feed=' + !!q('[data-tv-feed]'),
      'trackKids=' + (t ? t.children.length : 'none'),
      'age=' + (Date.now() - installedAt),
      'ready=' + (window.__tvSkinReady ? window.__tvSkinReady() : 'nofn')
    ].join(' ');
  };

  window.__tvSkinSync = sync;
  window.__tvSkinState = function () { return JSON.stringify(state); };

  /* 阶段 7 取证：各关键块「第一次出现」的时刻，用来定揭幕门槛。
     每个 part 只打一次，正常启动在 logcat 里就是一条 5~6 行的时间线。 */
  var seenParts = {};
  function markPart(name) {
    if (seenParts[name]) { return; }
    seenParts[name] = 1;
    try {
      var t = Math.round((window.performance && performance.now)
        ? performance.now() : Date.now());
      console.log('SOUJUTV SKIN_PART ' + name + ' t=' + t);
    } catch (e) {}
  }

  /* 阶段 7 取证：各关键块「第一次出现」的时刻，用来定揭幕门槛。
     每个 part 只打一次，正常启动在 logcat 里就是一条 5~6 行的时间线。 */
  var seenParts = {};
  function markPart(name) {
    if (seenParts[name]) { return; }
    seenParts[name] = 1;
    try {
      var t = Math.round((window.performance && performance.now)
        ? performance.now() : Date.now());
      console.log('SOUJUTV SKIN_PART ' + name + ' t=' + t);
    } catch (e) {}
  }

  /* 阶段 7 揭幕门探针（原生 RevealGate 每 120ms 问一次）。
     只回 0/1，不返回对象 —— evaluateJavascript 拿到的字符串越小越好。
     首页必须等「今晚首选卡已插好 + feed 已打标 + 首图存在」才算成型，
     否则揭幕时拍到的正是「站点原生版式」那一版，问题等于没修。
     详情页 / 播放页没有 feed，只要求 marker + 样式表就位。 */
  window.__tvSkinReady = function () {
    var root = document.documentElement;
    if (root.getAttribute('data-tv-skin') !== 'on') { return 0; }
    if (!document.getElementById('__tvSkinCss')) { return 0; }
    if (document.readyState === 'loading') { return 0; }
    if (!isHomePath()) { return state && state.ready ? 1 : 0; }
    /* 首页门槛只看「海报墙已经挂上骨架卡」这一步（实测 4.3s）。
       继续观看 / 本周追剧要 7.6s 才有，等它们等于白等 3 秒；
       这两块的位置已经由 .tv-ph 占位撑住，晚到也不会顶动版式。 */
    /* 站点先渲染骨架卡（4.1s）再换成真卡（7~10s，取决于接口）。骨架卡不带
       .home-feed-card 类，所以要按「rail 里已经有子节点」判断，
       否则等于一直等到真数据回来。 */
    var track = q('.home-feed-rail-track');
    if (track && track.children && track.children.length > 0) { return 1; }
    /* 兜底：站点接口慢的时候（实测 4~10 秒不定）不能把加载页一直拖着。
       注入后 3.5 秒还没等到骨架就放行，此时外壳、导航、字号已经全部是
       TV 版式，缺的只是卡片内容 —— 这比「黑屏等数据」观感好得多。 */
    if (Date.now() - installedAt > 3500) { return 1; }
    return 0;
  };

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
  /* 200ms 一次，成本只有几次 querySelector；就绪后自己停。 */
  readyTimer = setInterval(announceReady, 200);
  setTimeout(announceReady, 300);
  console.log('TVSKIN_INSTALLED');
})();
