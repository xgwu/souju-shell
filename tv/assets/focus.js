/* focus.js — 遥控器焦点引擎（注入到每个主文档）
 *
 * 不依赖 WebView 自带的空间导航：在「横向列表套纵向列表」的海报墙结构里，
 * 原生焦点遍历会斜跳、越界、抖动，而且方向键常被原生层直接消费、根本不到 JS。
 * 因此 Activity.dispatchKeyEvent 拦截按键，转成 __tvKey('up'|'down'|'left'|'right'|'ok')。
 *
 * 约束：Chromium 83。不用 ?. / ??= / :has / :focus-visible / gap / aspect-ratio / inset。
 */
(function () {
  if (window.__tvFocusInstalled) { return; }
  window.__tvFocusInstalled = true;

  var SELECTOR = [
    '[data-tv-focusable]', 'a[href]', 'button', 'input:not([type="hidden"])',
    'select', 'textarea', '[role="button"]', '[role="link"]',
    '[tabindex]:not([tabindex="-1"])'
  ].join(',');

  var FOCUS_CLASS = 'tv-focused';
  var RING_ATTR = 'data-tv-ring';
  var current = null;
  var rafPending = false;
  var pendingScroll = null;
  /* 站点的 feed 卡片会被缓存层逐张重建。重建后 document.activeElement 回到 body，
     旧 current 也 isConnected=false，用户会看到焦点突然弹回顶部「首页」。
     记住上一次焦点的「身份 + 坐标」，重渲染后按身份找回等价元素。 */
  var lastFocusKey = '';
  var lastFocusPoint = null;

  /* 焦点环必须写成 inline + !important。
   * 站点按钮带 `.movie-button-secondary:focus` 这类高特异性规则，会盖掉样式表里的
   * `.tv-focused { outline: ... !important }` —— 实测三个按钮里两个分别显示成
   * rgba(255,255,255,.9) 和 rgb(3,17,20)，只有第三个是橙色。
   *
   * v0.4 修复「橙环残留」：旧版只用一个 savedEl/savedStyle 槽位存原值，
   * 站点重建卡片后 refind() 会对一个「还带着我们自己写进去的 inline 环」的元素
   * 再调一次 applyStyle，把橙色当成「原值」存下来；之后 restoreStyle 又把它写回去，
   * 于是每走过一个元素就永久留一圈橙色光晕（实机 60+ 个元素带残留 box-shadow）。
   * 现在改成：原值存在元素自己身上 + data-tv-ring 标记 + 每次按键全量清扫。
   * 刻意不写 -webkit-box-shadow：它在 Chrome 83 里与 box-shadow 互为别名，
   * removeProperty 一个另一个还在，是最容易漏清理的一条。 */
  var RING_KEYS = ['outline', 'outline-offset', 'box-shadow'];
  var RING = {
    'outline': '3px solid #FF8A3D',
    'outline-offset': '3px',
    'box-shadow': '0 0 0 7px rgba(255,138,61,0.25)'
  };
  var styled = [];

  function isOurRing(v) {
    if (!v) { return false; }
    return v.indexOf('255,138,61') >= 0 || v.indexOf('255, 138, 61') >= 0 ||
           v.toUpperCase().indexOf('FF8A3D') >= 0;
  }

  /** 当前文档里所有「带过焦点环」的元素（含旧版本遗留的 inline 值）全部还原。 */
  function clearRings() {
    var seen = [], i, j, el;
    var found = document.querySelectorAll(
      '[' + RING_ATTR + '],.tv-focused,[style*="255, 138, 61"],' +
      '[style*="255,138,61"],[style*="FF8A3D"],[style*="ff8a3d"]');
    for (i = 0; i < found.length; i++) { seen.push(found[i]); }
    for (i = 0; i < styled.length; i++) { seen.push(styled[i]); }

    var parents = document.querySelectorAll('[data-tv-focus-parent]');
    for (i = 0; i < parents.length; i++) { parents[i].removeAttribute('data-tv-focus-parent'); }

    for (i = 0; i < seen.length; i++) {
      el = seen[i];
      if (!el || !el.style) { continue; }
      var dupe = false;
      for (j = 0; j < i; j++) { if (seen[j] === el) { dupe = true; break; } }
      if (dupe) { continue; }
      var saved = el.__tvRingSaved;
      for (var k = 0; k < RING_KEYS.length; k++) {
        var key = RING_KEYS[k];
        var v = saved ? saved[key] : null;
        if (v && v[0] && !isOurRing(v[0])) {
          el.style.setProperty(key, v[0], v[1] || '');
        } else {
          el.style.removeProperty(key);
        }
      }
      /* 旧版写过的 webkit 别名，顺手清掉 */
      el.style.removeProperty('-webkit-box-shadow');
      if (el.classList) { el.classList.remove(FOCUS_CLASS); }
      el.removeAttribute(RING_ATTR);
      try { delete el.__tvRingSaved; } catch (e) { el.__tvRingSaved = null; }
    }
    styled = [];
  }

  /** 海报卡 overflow:hidden 会裁掉环：给最外层卡片打标记，CSS 里改成 visible。 */
  function markParent(el) {
    var n = el, depth = 0;
    while (n && depth < 5) {
      if (n.classList && (n.classList.contains('home-feed-card') ||
                          n.classList.contains('tv-tonight-card') ||
                          n.classList.contains('home-watch-calendar-item'))) {
        n.setAttribute('data-tv-focus-parent', '');
        return;
      }
      n = n.parentElement;
      depth++;
    }
  }

  function applyStyle(el) {
    clearRings();
    var saved = {};
    for (var k = 0; k < RING_KEYS.length; k++) {
      var key = RING_KEYS[k];
      var raw = el.style.getPropertyValue(key);
      saved[key] = (raw && !isOurRing(raw))
        ? [raw, el.style.getPropertyPriority(key)] : null;
      el.style.setProperty(key, RING[key], 'important');
    }
    el.__tvRingSaved = saved;
    el.setAttribute(RING_ATTR, '');
    /* clearRings() 会把全文档（含 el 自己）的 .tv-focused 摘掉，
       所以类必须在它之后再补回来，否则 CSS 里的卡片放大规则永远不生效。 */
    if (el.classList) { el.classList.add(FOCUS_CLASS); }
    styled.push(el);
    markParent(el);
  }

  /** 用「标签 + 可读文本」给焦点元素做身份签名。
   *  刻意不带 className：站点会给卡片动态挂 opacity-100 / is-active 等类，
   *  带类名会让同一个元素在重建前后对不上号。同名元素靠坐标最近来消歧。 */
  function identity(el) {
    if (!el) { return ''; }
    var t = (el.getAttribute('aria-label') || el.innerText || el.value || el.title || '').trim();
    t = t.replace(/\s+/g, ' ').slice(0, 64);
    return el.tagName + '|' + t;
  }

  function remember(el) {
    if (!el) { return; }
    lastFocusKey = identity(el);
    if (el.getBoundingClientRect) {
      var c = center(el);
      lastFocusPoint = { x: c.x, y: c.y };
    }
  }

  /** 站点自己 focus 过的元素也要亮起来，否则 document.activeElement 有焦点、
   *  用户却看不到任何高亮（第一次按键常出现这种情况）。 */
  function ensureMarked(el) {
    if (!el) { return; }
    remember(el);
    if (current === el && el.hasAttribute(RING_ATTR) &&
        el.classList && el.classList.contains(FOCUS_CLASS)) { return; }
    current = el;
    if (el.classList) { el.classList.add(FOCUS_CLASS); }
    applyStyle(el);
  }

  function isVisible(el) {
    if (!el || !el.getBoundingClientRect) { return false; }
    var r = el.getBoundingClientRect();
    if (r.width < 6 || r.height < 6) { return false; }
    var st;
    try { st = window.getComputedStyle(el); } catch (e) { return false; }
    if (!st || st.display === 'none' || st.visibility === 'hidden') { return false; }
    if (parseFloat(st.opacity || '1') < 0.06) { return false; }
    if (el.disabled || el.getAttribute('aria-hidden') === 'true') { return false; }
    return true;
  }

  /** 元素中心点真正命中的是不是自己（或自己的后代）。
   *  站点弹窗没有 role="dialog" 时，遮罩是兄弟节点，被压在下面的按钮仍然
   *  getBoundingClientRect 可见、visibility 也是 visible —— 只靠 isVisible 会把焦点
   *  送进遮罩底下。视口外的候选不做这个检查，否则向下滚动时永远找不到下一行。 */
  function isTopmost(el) {
    var r = el.getBoundingClientRect();
    var x = r.left + r.width / 2, y = r.top + r.height / 2;
    if (x < 0 || y < 0 || x >= window.innerWidth || y >= window.innerHeight) { return true; }
    try {
      var top = document.elementFromPoint(x, y);
      return !!top && (el === top || el.contains(top));
    } catch (e) { return true; }
  }

  /** 有模态层时把候选集限定在模态内。
   *  v0.4：搜索/扫码浮层打开时，只保留浮层内 + 搜索表单内的候选，
   *  否则方向键会跑到遮罩底下的海报墙上（看起来像「焦点丢了」）。 */
  function scopeRoots() {
    var mode = document.documentElement.getAttribute('data-tv-overlay');
    if (mode === 'search') {
      return document.querySelectorAll(
        '.movie-composer-root,[data-tv-overlay-root="search"]');
    }
    if (mode === 'qr') {
      return document.querySelectorAll('[data-tv-overlay-root="qr"]');
    }
    var dialogs = document.querySelectorAll('[role="dialog"],[aria-modal="true"]');
    for (var i = dialogs.length - 1; i >= 0; i--) {
      if (isVisible(dialogs[i])) { return [dialogs[i]]; }
    }
    return [document];
  }

  function candidates() {
    var roots = scopeRoots();
    var all = [], seen = [], r, i, j;
    for (r = 0; r < roots.length; r++) {
      if (!roots[r]) { continue; }
      var nodes = Array.prototype.slice.call(roots[r].querySelectorAll(SELECTOR));
      if (roots[r].matches && roots[r].matches(SELECTOR)) { nodes.unshift(roots[r]); }
      for (i = 0; i < nodes.length; i++) {
        var dup = false;
        for (j = 0; j < seen.length; j++) { if (seen[j] === nodes[i]) { dup = true; break; } }
        if (!dup) { seen.push(nodes[i]); all.push(nodes[i]); }
      }
    }
    // 先做可见性 + 最上层过滤，再做嵌套去重；否则被遮罩压住的元素会误伤有效候选
    var list = [];
    for (var k = 0; k < all.length; k++) {
      if (isVisible(all[k]) && isTopmost(all[k])) { list.push(all[k]); }
    }
    var out = [];
    var el;
    for (i = 0; i < list.length; i++) {
      el = list[i];
      // 嵌套候选保留最内层（a 里套 button 时只留 button），否则一次按键会跳两级
      var nested = false;
      for (j = 0; j < list.length; j++) {
        if (i === j) { continue; }
        if (el !== list[j] && el.contains(list[j]) &&
            list[j].getBoundingClientRect().width > 4) { nested = true; break; }
      }
      if (!nested) { out.push(el); }
    }
    return out;
  }

  function center(el) {
    var r = el.getBoundingClientRect();
    return { x: r.left + r.width / 2, y: r.top + r.height / 2, r: r };
  }

  /** 按身份找回被重建的焦点元素；多个同名时取离上次坐标最近的。
   *  候选集之外也找一遍：元素被暂时隐藏 / 滚出视口时它不会出现在 candidates() 里，
   *  但它仍在 DOM，下一个 tick 就会恢复可见。 */
  function refind(list, strict) {
    if (!lastFocusKey || !lastFocusPoint) { return null; }
    var pool = (list || []).slice();
    /* 浮层打开时严格限定在当前候选域内：否则会按身份找回遮罩底下的搜索图标，
       把焦点环画到一个用户看不见、也按不到的地方。 */
    var more = strict ? [] : document.querySelectorAll(SELECTOR);
    for (var m = 0; m < more.length; m++) { pool.push(more[m]); }
    var best = null, bestD = Infinity, seen = [];
    for (var i = 0; i < pool.length; i++) {
      var el = pool[i];
      if (!el || seen.indexOf(el) >= 0) { continue; }
      seen.push(el);
      if (identity(el) !== lastFocusKey) { continue; }
      var c = center(el);
      var d = Math.abs(c.x - lastFocusPoint.x) + Math.abs(c.y - lastFocusPoint.y);
      if (d < bestD) { bestD = d; best = el; }
    }
    return best;
  }

  /** 焦点身份彻底对不上时，落回「上次位置附近」而不是列表第一个。 */
  function closestTo(list, p) {
    var best = null, bestD = Infinity;
    for (var i = 0; i < list.length; i++) {
      var c = center(list[i]);
      var d = Math.abs(c.x - p.x) + Math.abs(c.y - p.y);
      if (d < bestD) { bestD = d; best = list[i]; }
    }
    return best;
  }

  function active(list) {
    var a = document.activeElement;
    if (a && a !== document.body && a !== document.documentElement &&
        isVisible(a) && isTopmost(a)) { return a; }
    if (current && current.isConnected && isVisible(current) &&
        isTopmost(current)) { return current; }
    var overlayMode = document.documentElement.getAttribute('data-tv-overlay');
    var found = refind(list || candidates(), !!overlayMode);
    if (found && overlayMode && list && list.indexOf(found) < 0) { found = null; }
    if (found) {
      /* 不真正调 el.focus()：DOM 刚重建完，避免和站点的自动聚焦抢。
         只要把焦点环画回去，方向键与 OK 键都能继续作用在这个元素上。 */
      ensureMarked(found);
      return found;
    }
    return null;
  }

  /**
   * 轴向最近邻。主方向距离权重 1、侧向偏移权重 2.6 —— 只按欧氏距离会斜跳。
   * 另外要求主方向确有位移（> 6px），否则同一行的元素会在左右键时互相误判。
   */
  function nearest(from, dir, list) {
    var c = center(from), best = null, bestScore = Infinity;
    for (var i = 0; i < list.length; i++) {
      var el = list[i];
      if (el === from) { continue; }
      var t = center(el);
      var dx = t.x - c.x, dy = t.y - c.y;
      var primary, cross;
      if (dir === 'left')       { primary = -dx; cross = Math.abs(dy); }
      else if (dir === 'right') { primary =  dx; cross = Math.abs(dy); }
      else if (dir === 'up')    { primary = -dy; cross = Math.abs(dx); }
      else                      { primary =  dy; cross = Math.abs(dx); }

      /* 宽幅元素用中心点算侧向偏移是错的：阶段 3 的「今晚首选」横卡宽 1200px，
         从左侧热词按 DOWN 时中心点差 400+px，会被误判成「斜跳」而跳过整张卡。 */
      if ((dir === 'up' || dir === 'down') &&
          t.r.width > window.innerWidth * 0.5 &&
          c.x >= t.r.left && c.x <= t.r.right) { cross = 0; }
      if ((dir === 'left' || dir === 'right') &&
          t.r.height > window.innerHeight * 0.5 &&
          c.y >= t.r.top && c.y <= t.r.bottom) { cross = 0; }

      if (primary <= 6) { continue; }
      var span = (dir === 'left' || dir === 'right') ? c.r.height + t.r.height
                                                     : c.r.width + t.r.width;
      var offBand = cross > span ? 600 : 0;
      var score = primary + cross * 2.6 + offBand;
      if (score < bestScore) { bestScore = score; best = el; }
    }
    return best;
  }

  /** 直接改 scrollTop，不用 scrollIntoView({behavior:'smooth'})：低端 SoC 上会抖。 */
  function reveal(el) {
    pendingScroll = el;
    if (rafPending) { return; }
    rafPending = true;
    window.requestAnimationFrame(function () {
      rafPending = false;
      var target = pendingScroll;
      pendingScroll = null;
      if (!target || !target.isConnected) { return; }
      var node = target.parentNode, scroller = null;
      while (node && node !== document.body && node !== document.documentElement) {
        var st = window.getComputedStyle(node);
        if (/(auto|scroll)/.test(st.overflowY || '') &&
            node.scrollHeight > node.clientHeight + 4) { scroller = node; break; }
        node = node.parentNode;
      }
      if (!scroller) { scroller = document.scrollingElement || document.documentElement; }
      var r = target.getBoundingClientRect();
      var p = scroller.getBoundingClientRect();
      var margin = 72;
      var delta = 0;
      if (r.top < p.top + margin) { delta = r.top - p.top - margin; }
      else if (r.bottom > p.bottom - margin) { delta = r.bottom - p.bottom + margin; }
      if (delta) { scroller.scrollTop += delta; }
    });
  }

  function setFocus(el) {
    if (!el) { return; }
    try { el.focus({ preventScroll: true }); } catch (e) { el.focus(); }
    current = el;
    if (el.classList) { el.classList.add(FOCUS_CLASS); }
    applyStyle(el);
    remember(el);
    reveal(el);
  }

  /** 给浮层 / 桥事件用：把焦点明确交到某个元素，并画上环。 */
  window.__tvFocusElement = function (x) {
    var el = typeof x === 'string' ? document.querySelector(x) : x;
    if (!el || !isVisible(el)) { return false; }
    setFocus(el);
    return true;
  };

  /** 取证用：手动清一遍残留（诊断「橙环擦不掉」时很有用）。 */
  window.__tvClearRings = function () { clearRings(); current = null; return 'cleared'; };

  function label(el) {
    if (!el) { return '(none)'; }
    var t = (el.getAttribute('aria-label') || el.innerText || el.value || el.title || '').trim();
    t = t.replace(/\s+/g, ' ').slice(0, 42);
    return (t || el.tagName.toLowerCase()) + '@' +
      Math.round(el.getBoundingClientRect().left) + ',' +
      Math.round(el.getBoundingClientRect().top);
  }

  /** 原生按键唯一入口。返回 JSON 供 evaluateJavascript 回传取证。 */
  window.__tvKey = function (action) {
    var list = candidates();
    var from = active(list);
    if (from) { ensureMarked(from); }
    var to = null;
    var note = '';

    if (action === 'ok') {
      if (from && from.hasAttribute && from.hasAttribute('data-tv-overlay-input')) {
        /* 我们自建的搜索浮层输入框：OK 直接提交，不走站点 form。 */
        if (window.__tvSubmitSearch) { window.__tvSubmitSearch(); note = 'submitted-overlay'; }
        else { note = 'overlay-submit-missing'; }
      } else if (from && /^(INPUT|TEXTAREA|SELECT)$/.test(from.tagName)) {
        /* TV 没有软键盘：其它输入框按 OK 就等于提交所在 form。 */
        var form = from.closest ? from.closest('form') : null;
        var submit = form ? form.querySelector('button[type="submit"],[aria-label="发送搜索"]') : null;
        if (submit) { submit.click(); note = 'submitted'; }
        else { note = 'input-focused-no-submit'; }
      } else if (from) {
        from.click();
        note = 'clicked';
      } else {
        note = 'no-focus';
      }
    } else if (from && (action === 'up' || action === 'down' ||
                        action === 'left' || action === 'right')) {
      to = nearest(from, action, list);
      if (to) { setFocus(to); note = 'moved'; }
      else { note = 'edge'; }
    } else if (!from && list.length) {
      // 第一次按方向键：懒聚焦到第一个候选，不抢站点初始化时的默认焦点。
      // 若已经有过焦点，则按上次坐标就近恢复，不让焦点弹回顶部。
      to = lastFocusPoint ? closestTo(list, lastFocusPoint) : list[0];
      setFocus(to);
      note = lastFocusPoint ? 'recovered' : 'initial';
    } else if (!list.length) {
      note = 'no-candidates';
    }

    var out = {
      action: action,
      note: note,
      candidates: list.length,
      ringElements: document.querySelectorAll('[' + RING_ATTR + ']').length,
      from: label(from),
      to: label(to || active()),
      scrollY: (document.scrollingElement || document.documentElement).scrollTop || 0
    };
    try { console.log('TVFOCUS ' + JSON.stringify(out)); } catch (e) {}
    return JSON.stringify(out);
  };

  /** 取证用：读当前焦点状态，不改任何东西。 */
  window.__tvState = function () {
    var a = active();
    return JSON.stringify({
      installed: true,
      focused: label(a),
      candidates: candidates().length,
      ringElements: document.querySelectorAll('[' + RING_ATTR + ']').length,
      overlay: document.documentElement.getAttribute('data-tv-overlay') || '',
      bridge: !!(window.H5ShellNativeBridge && window.H5ShellNativeBridge.call),
      viewport: [window.innerWidth, window.innerHeight, window.devicePixelRatio],
      url: location.href
    });
  };

  console.log('TVFOCUS_INSTALLED');
})();
