import Foundation

/// 内置皮肤：同一套结构的两种介质。
///
///   - `souju-dark`（默认，依据资料库 souju-dark.html）：墨玉 #0E0E10 + 暖白 #F2F1ED + 亮橙 #FF6B42
///   - `souju-light`（依据 souju-light.html）：纸白 #FAFAF8 + 墨黑 #12100F + 强调橙 #FF5C35
///
/// 为什么皮肤放在源码里而不是资源文件：本工程只有一个 PBXResourcesBuildPhase 都没有的
/// 纯代码 target，加资源要动 pbxproj 的构建阶段；字符串常量零构建风险，改样式改这个文件即可。
///
/// 两套皮肤共用一份结构（light 的 CSS 已经把整站按 BEM 类名重排过），
/// dark 由它派生：换作用域 → 过一张色值映射表 → 追加手写的「介质层」。
///
/// JS 也只有一份模板（`skinJSTemplate`），三处占位：切哪个 data-theme、挂不挂 html.dark、
/// 状态栏用深图标还是浅图标。结构逻辑（今晚首选 / 只看未看过 / 路由跟随）不重复实现。
///
/// 站点 DOM 用的是语义类名（home-feed-card / watch-calendar-page-day / app-primary-bottom-nav），
/// 不是纯原子类，所以覆盖是「按组件」而不是「按位置」的，改版后失效范围可控。
enum SkinPreset: String, CaseIterable, Identifiable {
    case none
    case soujuDark = "souju-dark"
    case soujuLight = "souju-light"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "站点原样"
        case .soujuDark: return "搜剧 Dark"
        case .soujuLight: return "搜剧 Light"
        }
    }

    var subtitle: String {
        switch self {
        case .none: return "跟随站点自己的深色主题"
        case .soujuDark: return "墨玉画布 · 暖白 · 单一亮橙"
        case .soujuLight: return "纸白画布 · 海报优先 · 单一强调橙"
        }
    }

    /// 是否是「深色介质」的皮肤。工具箱的主题开关、状态栏取向都看这个。
    var isDark: Bool { self == .soujuDark }

    var css: String {
        switch self {
        case .none: return ""
        case .soujuDark: return SkinPreset.soujuDarkCSS
        case .soujuLight: return SkinPreset.soujuLightCSS
        }
    }

    var js: String {
        switch self {
        case .none: return ""
        case .soujuDark:
            return SkinPreset.skinJS(skin: "souju-dark", theme: "movie-dark", dark: true)
        case .soujuLight:
            return SkinPreset.skinJS(skin: "souju-light", theme: "movie-light", dark: false)
        }
    }

    /// 两套皮肤共用同一段结构性 JS（今晚首选 / 只看未看过 / 主题纠偏 / 状态栏），
    /// 只有「切哪个 data-theme、挂不挂 html.dark、状态栏用深图标还是浅图标」不同，
    /// 所以做成模板 + 三个占位符，避免两份 12KB 脚本各自漂移。
    private static func skinJS(skin: String, theme: String, dark: Bool) -> String {
        skinJSTemplate
            .replacingOccurrences(of: "__SKIN__", with: skin)
            .replacingOccurrences(of: "__THEME__", with: theme)
            .replacingOccurrences(of: "__DARK__", with: dark ? "true" : "false")
    }

    static func named(_ raw: String?) -> SkinPreset {
        guard let raw = raw, let value = SkinPreset(rawValue: raw) else { return .none }
        return value
    }

    // MARK: - souju-light

    private static let soujuLightCSS = #"""
/* =========================================================
   搜剧 Light · 全站皮肤  v1
   设计依据：souju-light.html（海报优先 / 纸白 + 墨黑 + 一个橙）
   用法：data-theme 切到 movie-light 后注入本文件
   ========================================================= */

[data-theme="movie-light"],
html[data-skin="souju-light"] {
  --paper: #FAFAF8;
  --card: #FFFFFF;
  --ink: #12100F;
  --ink-mid: #6B6863;
  --ink-faint: #A3A09A;
  --line: #E8E6E1;
  --hair: #F0EEE9;
  --accent: #FF5C35;

  /* 站点设计令牌重映射 */
  --movie-bg: var(--paper);
  --movie-bg-elevated: var(--card);
  --movie-surface: #FFFFFF;
  --movie-surface-strong: #F5F4F0;
  --movie-border: var(--line);
  --movie-border-soft: var(--hair);
  --movie-text: var(--ink);
  --movie-text-muted: var(--ink-mid);
  --movie-text-subtle: var(--ink-faint);
  --movie-primary: var(--ink);
  --movie-primary-strong: var(--accent);
  --movie-primary-foreground: #FFFFFF;
  --movie-primary-muted: rgba(18, 16, 15, 0.05);
  --movie-accent: var(--accent);
  --movie-accent-muted: rgba(255, 92, 53, 0.08);
  --movie-share-button-background: var(--ink);
  --movie-player-danmaku-accent: var(--accent);
  --movie-player-danmaku-accent-hover: #FF7A57;
  --movie-player-danmaku-on-accent: #FFFFFF;

  --movie-legacy-bg-rgb: 250, 250, 248;
  --movie-legacy-bg-elevated-rgb: 255, 255, 255;
  --movie-legacy-surface-rgb: 255, 255, 255;
  --movie-legacy-border-soft-rgb: 232, 230, 225;
  --movie-legacy-primary-rgb: 18, 16, 15;
  --movie-legacy-primary-strong-rgb: 255, 92, 53;
  --movie-legacy-text-rgb: 18, 16, 15;
  --movie-legacy-text-subtle-rgb: 107, 104, 99;
  --movie-legacy-accent-rgb: 255, 92, 53;

  color-scheme: light;
}

/* ---------- 画布 ---------- */
html[data-skin="souju-light"] body,
html[data-skin="souju-light"] .min-h-dvh {
  background: var(--paper) !important;
  color: var(--ink) !important;
}
html[data-skin="souju-light"] .movie-app-bg {
  background: var(--paper) !important;
}
html[data-skin="souju-light"] .movie-atmosphere,
html[data-skin="souju-light"] .movie-app-bg::before,
html[data-skin="souju-light"] .movie-app-bg::after {
  display: none !important;
}
html[data-skin="souju-light"] .movie-page-loading-progress-rail {
  background: rgba(18, 16, 15, 0.08) !important;
}
html[data-skin="souju-light"] .movie-page-loading-progress-value {
  background: var(--ink) !important;
}

/* ---------- 顶栏 ---------- */
html[data-skin="souju-light"] .app-page-header-row {
  background: rgba(250, 250, 248, 0.9) !important;
  -webkit-backdrop-filter: saturate(180%) blur(16px);
  backdrop-filter: saturate(180%) blur(16px);
  border-bottom: 0 !important;
}
html[data-skin="souju-light"] .movie-button-secondary,
html[data-skin="souju-light"] .app-header-control {
  background: #FFFFFF !important;
  border: 1px solid var(--line) !important;
  color: var(--ink) !important;
  box-shadow: 0 1px 1px rgba(18, 16, 15, 0.03) !important;
  -webkit-backdrop-filter: none !important;
  backdrop-filter: none !important;
}
html[data-skin="souju-light"] .app-header-control-icon,
html[data-skin="souju-light"] .movie-button-secondary svg {
  color: var(--ink) !important;
}
html[data-skin="souju-light"] .movie-button-primary {
  background: var(--ink) !important;
  color: #FFFFFF !important;
  border: 0 !important;
}

/* ---------- 首页 hero ---------- */
html[data-skin="souju-light"] .movie-home-page-shell .text-center h1 {
  color: var(--ink) !important;
  font-size: 1.5rem !important;
  font-weight: 700 !important;
  letter-spacing: -0.02em !important;
  line-height: 1.25 !important;
}
html[data-skin="souju-light"] .home-permanent-domain,
html[data-skin="souju-light"] .movie-home-page-shell .text-center > div.mt-2 {
  display: none !important;
}
html[data-skin="souju-light"] img.movie-brand-lockup {
  filter: grayscale(1) contrast(1.15) brightness(0.5);
}
html[data-skin="souju-light"] .movie-home-page-shell .mx-auto.max-w-3xl {
  gap: 0.75rem !important;
  padding-top: 0.25rem !important;
}

/* ---------- 搜索框 ---------- */
html[data-skin="souju-light"] .movie-composer-root {
  background: #FFFFFF !important;
  border: 1px solid var(--line) !important;
  border-radius: 18px !important;
  box-shadow: 0 1px 2px rgba(18, 16, 15, 0.04) !important;
}
html[data-skin="souju-light"] .movie-composer-text-input {
  color: var(--ink) !important;
  caret-color: var(--accent) !important;
  font-size: 14px !important;
}
html[data-skin="souju-light"] .movie-composer-text-input::placeholder,
html[data-skin="souju-light"] .movie-composer-root ::placeholder {
  color: var(--ink-faint) !important;
}
html[data-skin="souju-light"] .movie-composer-mode-switch {
  background: #F4F3EF !important;
  border: 0 !important;
}
html[data-skin="souju-light"] .movie-composer-mode-thumb {
  background: #FFFFFF !important;
  box-shadow: 0 1px 3px rgba(18, 16, 15, 0.14) !important;
}
html[data-skin="souju-light"] .movie-composer-search-mode-option {
  color: var(--ink-mid) !important;
}
html[data-skin="souju-light"] .movie-composer-search-mode-option svg {
  color: currentColor !important;
}
html[data-skin="souju-light"] .movie-composer-leading-icon {
  background: #F4F3EF !important;
  color: var(--ink) !important;
  border: 0 !important;
}
html[data-skin="souju-light"] .movie-composer-voice-toggle {
  color: var(--ink-mid) !important;
  background: transparent !important;
}

/* ---------- 提示 chip ---------- */
html[data-skin="souju-light"] .movie-chip {
  background: #FFFFFF !important;
  border: 1px solid var(--line) !important;
  color: var(--ink-mid) !important;
  box-shadow: 0 1px 1px rgba(18, 16, 15, 0.03) !important;
  font-weight: 500 !important;
}
html[data-skin="souju-light"] .movie-home-prompt-groups .movie-chip svg {
  color: var(--ink-faint) !important;
}

/* ---------- 提示 chip：热门影片 + 推荐输入合并为一行横滑 ---------- */
/* 站点把提示做成「分组标题 + chips」两段折行：热门影片 7 个 chip 折 3 行，推荐输入只有
   1 个 chip 却独占 1 行，加搜索框控制行一共吃掉 4 行、336px（iPhone 14）。
   这里把两个分组盒子摘掉（display:contents），让标签与 chip 一起成为同一个横向滚动
   容器的子项：164px → 36px，首屏多露出 128px，8 个 chip 全部保留、滑动可达。 */
html[data-skin="souju-light"] .movie-home-prompt-groups {
  display: flex !important;
  flex-wrap: nowrap !important;
  align-items: center !important;
  justify-content: flex-start !important;
  gap: 8px !important;
  padding: 0 0 6px !important;
  overflow-x: auto !important;
  overflow-y: hidden !important;
  scrollbar-width: none;
  -webkit-overflow-scrolling: touch;
  overscroll-behavior-x: contain;
  touch-action: pan-x;
}
html[data-skin="souju-light"] .movie-home-prompt-groups::-webkit-scrollbar {
  display: none;
}
html[data-skin="souju-light"] .movie-home-prompt-groups [data-home-suggestion-group] {
  display: contents !important;
}
/* 分组标题（热门影片 / 推荐输入）在单行里会打断 chip 的节奏，收起 */
html[data-skin="souju-light"] .movie-home-prompt-groups [data-home-suggestion-group] > span {
  display: none !important;
}
html[data-skin="souju-light"] .movie-home-prompt-groups .movie-chip {
  flex: 0 0 auto !important;
}
html[data-skin="souju-light"] .movie-home-prompt-groups .movie-chip > span {
  white-space: nowrap !important;
}

/* ---------- 日历：数字条降级为下划线指示 ---------- */
html[data-skin="souju-light"] .home-watch-calendar {
  border-top: 1px solid var(--line);
  padding-top: 14px;
}
html[data-skin="souju-light"] .home-watch-calendar-heading h2 {
  color: var(--ink) !important;
  font-size: 16px !important;
  font-weight: 650 !important;
  letter-spacing: -0.01em !important;
}
html[data-skin="souju-light"] .home-watch-calendar-icon {
  color: var(--accent) !important;
}
html[data-skin="souju-light"] .home-watch-calendar-more {
  color: var(--ink-faint) !important;
  font-size: 11px !important;
  font-weight: 500 !important;
}
html[data-skin="souju-light"] .home-watch-calendar-days {
  display: grid !important;
  grid-template-columns: repeat(7, minmax(0, 1fr)) !important;
  gap: 0 !important;
  overflow: visible !important;
  border-bottom: 1px solid var(--hair);
  padding-bottom: 0 !important;
  scroll-snap-type: none !important;
}
html[data-skin="souju-light"] .home-watch-calendar-day {
  flex: 1 1 0 !important;
  width: auto !important;
  min-width: 0 !important;
  background: transparent !important;
  border: 0 !important;
  border-radius: 0 !important;
  padding: 6px 0 8px !important;
  display: flex !important;
  flex-direction: column !important;
  align-items: center !important;
  gap: 1px !important;
  box-shadow: inset 0 -2px 0 transparent !important;
}
html[data-skin="souju-light"] .home-watch-calendar-day[data-selected="true"] {
  background: transparent !important;
  box-shadow: inset 0 -2px 0 var(--accent) !important;
}
html[data-skin="souju-light"] .home-watch-calendar-day span {
  color: var(--ink-faint) !important;
  font-size: 10px !important;
  font-weight: 500 !important;
  letter-spacing: 0.06em !important;
  line-height: 13px !important;
}
html[data-skin="souju-light"] .home-watch-calendar-day strong {
  color: var(--ink) !important;
  font-size: 15px !important;
  font-weight: 650 !important;
  line-height: 19px !important;
  font-variant-numeric: tabular-nums;
}
html[data-skin="souju-light"] .home-watch-calendar-day em {
  color: var(--ink-faint) !important;
  font-size: 9px !important;
  font-style: normal !important;
  line-height: 12px !important;
  font-variant-numeric: tabular-nums;
}
html[data-skin="souju-light"] .home-watch-calendar-day[data-selected="true"] span,
html[data-skin="souju-light"] .home-watch-calendar-day[data-selected="true"] em {
  color: var(--ink-mid) !important;
}

/* 日历里的剧集行：去掉卡片容器 */
html[data-skin="souju-light"] .home-watch-calendar-group-header h3 {
  color: var(--ink) !important;
  font-size: 12px !important;
  font-weight: 600 !important;
  letter-spacing: 0.02em !important;
}
html[data-skin="souju-light"] .home-watch-calendar-group-header span {
  color: var(--ink-faint) !important;
  font-size: 10px !important;
}
html[data-skin="souju-light"] .home-watch-calendar-list {
  display: grid !important;
  grid-template-columns: repeat(2, minmax(0, 1fr)) !important;
  grid-auto-flow: row !important;
  grid-auto-columns: auto !important;
  gap: 10px 16px !important;
  overflow: visible !important;
  scroll-snap-type: none !important;
}
html[data-skin="souju-light"] .home-watch-calendar-list > * {
  width: 100% !important;
  min-width: 0 !important;
}
html[data-skin="souju-light"] .home-watch-calendar-item-link {
  display: block !important;
  width: 100% !important;
}
html[data-skin="souju-light"] .home-watch-calendar-item {
  width: 100% !important;
}
html[data-skin="souju-light"] .home-watch-calendar-group + .home-watch-calendar-group {
  margin-top: 14px;
}
html[data-skin="souju-light"] .home-watch-calendar-item {
  background: transparent !important;
  border: 0 !important;
  border-radius: 0 !important;
  box-shadow: none !important;
}
html[data-skin="souju-light"] .home-watch-calendar-item-copy h4 {
  white-space: nowrap !important;
  overflow: hidden !important;
  text-overflow: ellipsis !important;
}
html[data-skin="souju-light"] .home-watch-calendar-item-copy p {
  white-space: nowrap !important;
  overflow: hidden !important;
  text-overflow: ellipsis !important;
}
html[data-skin="souju-light"] .home-watch-calendar-poster {
  flex: 0 0 44px !important;
  width: 44px !important;
  height: 66px !important;
  border-radius: 4px !important;
  background: #EFEDE7 !important;
  overflow: hidden !important;
}
html[data-skin="souju-light"] .home-watch-calendar-poster-image {
  width: 100% !important;
  height: 100% !important;
  object-fit: cover !important;
}
html[data-skin="souju-light"] .home-watch-calendar-item {
  display: flex !important;
  align-items: flex-start !important;
  gap: 10px !important;
}
html[data-skin="souju-light"] .home-watch-calendar-item-copy {
  flex: 1 1 auto !important;
  min-width: 0 !important;
  padding-top: 2px !important;
}
html[data-skin="souju-light"] .home-watch-calendar-item-copy h4 {
  color: var(--ink) !important;
  font-size: 12px !important;
  font-weight: 600 !important;
}
html[data-skin="souju-light"] .home-watch-calendar-item-copy p {
  color: var(--ink-faint) !important;
  font-size: 10px !important;
}

/* ---------- 板块标题 ---------- */
html[data-skin="souju-light"] .home-feed-section-list {
  gap: 26px !important;
}
html[data-skin="souju-light"] .home-section-title {
  color: var(--ink) !important;
  font-size: 17px !important;
  font-weight: 650 !important;
  letter-spacing: -0.015em !important;
  line-height: 24px !important;
}
html[data-skin="souju-light"] .home-section-subtitle {
  color: var(--ink-faint) !important;
  font-size: 11px !important;
  line-height: 16px !important;
}
html[data-skin="souju-light"] .home-browse-button {
  background: transparent !important;
  border: 0 !important;
  color: var(--ink-faint) !important;
  font-size: 11px !important;
  padding: 0 !important;
  box-shadow: none !important;
}
html[data-skin="souju-light"] .home-rail-header-control {
  background: transparent !important;
  border: 1px solid var(--line) !important;
  color: var(--ink-mid) !important;
}

/* ---------- 海报流：横滑卡片 → 三列海报 ---------- */
html[data-skin="souju-light"] .home-feed-rail {
  overflow: visible !important;
}
html[data-skin="souju-light"] .home-feed-rail-track {
  grid-auto-flow: row !important;
  grid-template-columns: repeat(3, minmax(0, 1fr)) !important;
  grid-auto-columns: auto !important;
  overflow: visible !important;
  gap: 16px 10px !important;
  padding: 0 !important;
  scroll-snap-type: none !important;
}
html[data-skin="souju-light"] .home-feed-card {
  aspect-ratio: auto !important;
  height: auto !important;
  border: 0 !important;
  border-radius: 0 !important;
  background: transparent !important;
  box-shadow: none !important;
  contain: none !important;
  scroll-snap-align: none !important;
}
html[data-skin="souju-light"] .home-feed-card-link {
  position: relative !important;
  display: block !important;
  inset: auto !important;
}
html[data-skin="souju-light"] .home-feed-card-image {
  position: relative !important;
  inset: auto !important;
  display: block !important;
  width: 100% !important;
  height: auto !important;
  aspect-ratio: 2 / 3 !important;
  object-fit: cover !important;
  border-radius: 6px !important;
  background: #EFEDE7 !important;
}
html[data-skin="souju-light"] .home-feed-card-shade {
  display: none !important;
}
html[data-skin="souju-light"] .home-feed-card-badges {
  position: absolute !important;
  top: 5px !important;
  left: 5px !important;
  right: 5px !important;
  bottom: auto !important;
  display: flex !important;
  gap: 4px !important;
}
html[data-skin="souju-light"] .home-feed-card-status {
  max-width: 100% !important;
  background: rgba(250, 250, 248, 0.94) !important;
  color: var(--ink) !important;
  border: 0 !important;
  border-radius: 3px !important;
  font-size: 9px !important;
  font-weight: 600 !important;
  line-height: 12px !important;
  padding: 1px 4px !important;
  -webkit-backdrop-filter: blur(6px);
  backdrop-filter: blur(6px);
}
html[data-skin="souju-light"] .home-feed-card-status.is-fresh {
  color: var(--accent) !important;
}
html[data-skin="souju-light"] .home-feed-card-heat {
  display: none !important;
}
html[data-skin="souju-light"] .home-feed-card-copy {
  position: static !important;
  inset: auto !important;
  margin: 0 !important;
  padding-top: 7px !important;
}
html[data-skin="souju-light"] .home-feed-card-title {
  color: var(--ink) !important;
  font-size: 12px !important;
  font-weight: 600 !important;
  line-height: 16px !important;
  letter-spacing: -0.01em !important;
}
html[data-skin="souju-light"] .home-feed-card-meta {
  color: var(--ink-faint) !important;
  font-size: 10px !important;
  line-height: 13px !important;
  margin-top: 2px !important;
}

/* ---------- 底部导航 ---------- */
html[data-skin="souju-light"] .app-primary-bottom-nav {
  background: rgba(250, 250, 248, 0.9) !important;
  border: 1px solid var(--line) !important;
  border-radius: 22px !important;
  box-shadow: 0 10px 30px rgba(18, 16, 15, 0.12) !important;
  -webkit-backdrop-filter: saturate(180%) blur(22px) !important;
  backdrop-filter: saturate(180%) blur(22px) !important;
}
html[data-skin="souju-light"] .app-primary-bottom-link {
  color: var(--ink-faint) !important;
  border-radius: 14px !important;
  background: transparent !important;
  border-color: transparent !important;
  box-shadow: none !important;
}
html[data-skin="souju-light"] .app-primary-bottom-link.is-active {
  color: var(--ink) !important;
  background: transparent !important;
  border-color: transparent !important;
  box-shadow: inset 0 -2px 0 var(--accent) !important;
}
html[data-skin="souju-light"] .app-primary-bottom-link.is-active .app-primary-bottom-icon {
  color: var(--ink) !important;
  stroke-width: 2.1 !important;
}
html[data-skin="souju-light"] .app-primary-bottom-share-icon {
  background: var(--ink) !important;
  color: #FFFFFF !important;
  box-shadow: 0 6px 16px rgba(18, 16, 15, 0.24) !important;
}

/* ---------- 侧边菜单 / 弹层 ---------- */
html[data-skin="souju-light"] .movie-side-menu-panel {
  background: #FFFFFF !important;
  border-right: 1px solid var(--line) !important;
}
html[data-skin="souju-light"] .movie-menu-scrim {
  background: rgba(18, 16, 15, 0.32) !important;
}
html[data-skin="souju-light"] .movie-mobile-bottom-drawer-dialog {
  background: #FFFFFF !important;
}

/* ---------- 短剧竖屏流（/short-drama）：纸白化 ---------- */
html[data-skin="souju-light"] .short-drama-shell,
html[data-skin="souju-light"] .short-drama-feed-viewport,
html[data-skin="souju-light"] .short-drama-video-slide,
html[data-skin="souju-light"] .short-drama-slide-body,
html[data-skin="souju-light"] .short-drama-video-stage,
html[data-skin="souju-light"] .short-drama-video-backdrop,
html[data-skin="souju-light"] .short-drama-detail-snap-pager {
  background: var(--paper) !important;
}
html[data-skin="souju-light"] video.short-drama-video,
html[data-skin="souju-light"] .short-drama-video-scrim {
  background: transparent !important;
}
/* 上下模糊底图：不是压黑，而是压成很淡的纸色，和纸白画布接得上 */
html[data-skin="souju-light"] .short-drama-video-cover-layer {
  background: rgba(250, 250, 248, 0.58) !important;
}

/* 信息层：纸白渐隐，保证叠在画面上的文字可读 */
html[data-skin="souju-light"] .short-drama-overlay {
  background: linear-gradient(to top, #FAFAF8 0%, rgba(250, 250, 248, 0.97) 38%, rgba(250, 250, 248, 0.78) 66%, rgba(250, 250, 248, 0) 100%) !important;
  color: var(--ink) !important;
}
html[data-skin="souju-light"] .short-drama-copy h2 {
  color: var(--ink) !important;
  letter-spacing: -0.015em !important;
  text-shadow: none !important;
}
html[data-skin="souju-light"] .short-drama-copy p {
  color: var(--ink-mid) !important;
  text-shadow: none !important;
}
html[data-skin="souju-light"] .short-drama-copy > span {
  background: rgba(18, 16, 15, 0.06) !important;
  border: 0 !important;
  color: var(--ink-mid) !important;
  text-shadow: none !important;
}
html[data-skin="souju-light"] .short-drama-actions .movie-button-secondary,
html[data-skin="souju-light"] .short-drama-favorite-button {
  background: rgba(255, 255, 255, 0.94) !important;
  border: 1px solid var(--line) !important;
  color: var(--ink) !important;
  -webkit-backdrop-filter: blur(14px) saturate(160%);
  backdrop-filter: blur(14px) saturate(160%);
}
html[data-skin="souju-light"] .short-drama-more-link {
  background: var(--ink) !important;
  border: 0 !important;
  color: #FFFFFF !important;
  box-shadow: 0 6px 16px rgba(18, 16, 15, 0.22) !important;
}
/* 短剧页按钮会落在任意亮度的视频画面上，边界只能靠阴影兜住 */
html[data-skin="souju-light"] .short-drama-header .app-header-control,
html[data-skin="souju-light"] .short-drama-detail-header .app-header-control {
  box-shadow: 0 2px 14px rgba(18, 16, 15, 0.20), 0 0 0 1px rgba(18, 16, 15, 0.05) !important;
}

/* 播放进度：白轨在纸白上会消失 */
html[data-skin="souju-light"] .short-drama-progress-track {
  background: rgba(18, 16, 15, 0.10) !important;
}
html[data-skin="souju-light"] .short-drama-progress-fill {
  background: var(--ink) !important;
  box-shadow: none !important;
}

/* 详情页 / 竖屏播放：右侧操作列（除「片单」外均为无类名按钮） */
html[data-skin="souju-light"] .short-drama-control-dock > button {
  background: rgba(255, 255, 255, 0.94) !important;
  border: 1px solid var(--line) !important;
  color: var(--ink) !important;
  box-shadow: 0 3px 16px rgba(18, 16, 15, 0.22), 0 0 0 1px rgba(18, 16, 15, 0.05) !important;
  -webkit-backdrop-filter: blur(16px) saturate(160%);
  backdrop-filter: blur(16px) saturate(160%);
}
html[data-skin="souju-light"] .short-drama-control-dock svg,
html[data-skin="souju-light"] .short-drama-control-dock span {
  color: var(--ink) !important;
}
html[data-skin="souju-light"] .short-drama-video-status {
  background: rgba(255, 255, 255, 0.94) !important;
  border: 1px solid var(--line) !important;
  color: var(--ink-mid) !important;
  -webkit-backdrop-filter: blur(16px);
  backdrop-filter: blur(16px);
}
html[data-skin="souju-light"] .short-drama-video-status svg,
html[data-skin="souju-light"] .short-drama-status-icon {
  color: var(--ink-mid) !important;
}
html[data-skin="souju-light"] .short-drama-video-cover,
html[data-skin="souju-light"] .short-drama-detail-preview-page,
html[data-skin="souju-light"] .short-drama-detail-preview-cover {
  background: var(--paper) !important;
}
html[data-skin="souju-light"] .short-drama-state-card {
  background: #FFFFFF !important;
  border: 1px solid var(--line) !important;
  color: var(--ink) !important;
  box-shadow: 0 10px 30px rgba(18, 16, 15, 0.08) !important;
}

/* 短剧控制层（选集/评论/换源/倍速）：站点把它钉死在 movie-dark，需要在层内重映射令牌 */
html[data-skin="souju-light"] .short-drama-control-drawer-layer {
  --movie-bg: var(--paper);
  --movie-bg-elevated: #FFFFFF;
  --movie-surface: #FFFFFF;
  --movie-surface-strong: #F5F4F0;
  --movie-border: var(--line);
  --movie-border-soft: var(--hair);
  --movie-text: var(--ink);
  --movie-text-muted: var(--ink-mid);
  --movie-text-subtle: var(--ink-faint);
  --movie-primary: var(--ink);
  --movie-primary-foreground: #FFFFFF;
  --movie-primary-muted: rgba(18, 16, 15, 0.05);
  --movie-accent: var(--accent);
  --movie-accent-muted: rgba(255, 92, 53, 0.08);
  color-scheme: light;
}
html[data-skin="souju-light"] .short-drama-control-drawer-layer .movie-player-expanded-panel {
  background: #FFFFFF !important;
  color: var(--ink) !important;
  border-top: 1px solid var(--line) !important;
  box-shadow: 0 -12px 44px rgba(18, 16, 15, 0.16) !important;
}
html[data-skin="souju-light"] .short-drama-control-drawer-layer .react-player-episode-option {
  background: #F7F6F2 !important;
  border-color: var(--hair) !important;
  color: var(--ink-mid) !important;
  /* WebKit 下 .text-xs + font-black 会把「第16集」挤成两行，锁成一行 */
  white-space: nowrap !important;
  font-size: 12px !important;
}
html[data-skin="souju-light"] .short-drama-control-drawer-layer .react-player-episode-option.is-active {
  background: var(--ink) !important;
  border-color: var(--ink) !important;
  color: #FFFFFF !important;
}
html[data-skin="souju-light"] .short-drama-control-drawer-layer .movie-player-expanded-panel-close {
  background: #F5F4F0 !important;
  border-color: var(--line) !important;
  color: var(--ink) !important;
}

/* ---------- 通用：去掉彩色光晕与渐变描边 ---------- */
html[data-skin="souju-light"] .movie-card-glow-hover::after {
  display: none !important;
}

/* =========================================================
   剧集 / 播放页
   ========================================================= */

/* 选集标题与操作 */
html[data-skin="souju-light"] .movie-episode-section-title {
  color: var(--ink) !important;
  font-weight: 650 !important;
  font-size: 15px !important;
  letter-spacing: -0.01em !important;
}
html[data-skin="souju-light"] .movie-episode-expand-button {
  background: transparent !important;
  border: 1px solid var(--line) !important;
  color: var(--ink) !important;
  box-shadow: none !important;
  border-radius: 10px !important;
  font-weight: 600 !important;
}
html[data-skin="souju-light"] .movie-episode-expand-button svg {
  color: var(--ink) !important;
}

/* 最近更新条：去青底 */
html[data-skin="souju-light"] .movie-episode-latest {
  background: #F4F3EF !important;
  border: 0 !important;
  color: var(--ink) !important;
  border-radius: 10px !important;
}
html[data-skin="souju-light"] .movie-episode-latest span,
html[data-skin="souju-light"] .movie-episode-latest svg {
  color: var(--ink) !important;
}

/* 集数格子 */
html[data-skin="souju-light"] .movie-episode-item {
  background: #FFFFFF !important;
  border: 1px solid var(--line) !important;
  color: var(--ink-mid) !important;
  border-radius: 9px !important;
  box-shadow: none !important;
  font-weight: 500 !important;
}
html[data-skin="souju-light"] .movie-episode-item[aria-current="true"],
html[data-skin="souju-light"] .movie-episode-item[data-active="true"],
html[data-skin="souju-light"] .movie-episode-item.is-active {
  background: var(--ink) !important;
  border-color: var(--ink) !important;
  color: #FFFFFF !important;
  font-weight: 600 !important;
}

/* 顶部 tab */
html[data-skin="souju-light"] .movie-player-content-tabs,
html[data-skin="souju-light"] .movie-player-sticky-tabs {
  background: var(--paper) !important;
  border-bottom: 1px solid var(--hair) !important;
}
html[data-skin="souju-light"] .movie-surface-tab {
  color: var(--ink-faint) !important;
  background: transparent !important;
  font-weight: 600 !important;
}
html[data-skin="souju-light"] .movie-surface-tab.movie-player-tab-active,
html[data-skin="souju-light"] .movie-surface-tab[data-active="true"] {
  color: var(--ink) !important;
}
html[data-skin="souju-light"] .movie-surface-tab.movie-player-tab-active::after,
html[data-skin="souju-light"] .movie-surface-tab[data-active="true"]::after {
  background: var(--accent) !important;
}

/* 快捷操作 / 悬浮按钮：橙 → 墨 */
html[data-skin="souju-light"] .movie-player-support-trigger {
  background: var(--ink) !important;
  color: #FFFFFF !important;
  border: 0 !important;
  box-shadow: 0 8px 20px rgba(18, 16, 15, 0.22) !important;
}
html[data-skin="souju-light"] .movie-player-support-trigger svg,
html[data-skin="souju-light"] .movie-player-support-trigger-icon {
  color: #FFFFFF !important;
}

/* AI 发现图标：彩色 → 中性 */
html[data-skin="souju-light"] .movie-player-ai-discovery-icon {
  background: #F4F3EF !important;
  color: var(--ink) !important;
  border-radius: 10px !important;
}

/* 推荐 / 等级卡 */
html[data-skin="souju-light"] .movie-similar-recommendations {
  border-top: 1px solid var(--hair) !important;
  padding-top: 16px !important;
}
html[data-skin="souju-light"] .movie-level-card {
  background: #FFFFFF !important;
  border: 1px solid var(--line) !important;
  border-radius: 12px !important;
  box-shadow: none !important;
}

/* 广告位：自用壳里不展示 */
html[data-skin="souju-light"] .movie-player-info-ad-slot,
html[data-skin="souju-light"] .movie-player-info-ad-grid,
html[data-skin="souju-light"] .movie-player-info-ad-header,
html[data-skin="souju-light"] .movie-player-info-flip-back .movie-player-info-ad-slot {
  display: none !important;
}

/* =========================================================
   追剧周表 /updates
   ========================================================= */
html[data-skin="souju-light"] .watch-calendar-page-day {
  background: transparent !important;
  border: 0 !important;
  border-radius: 0 !important;
  box-shadow: inset 0 -2px 0 transparent !important;
  padding: 4px 0 8px !important;
}
html[data-skin="souju-light"] .watch-calendar-page-day[data-selected="true"] {
  background: transparent !important;
  box-shadow: inset 0 -2px 0 var(--accent) !important;
}
html[data-skin="souju-light"] .watch-calendar-page-day span {
  color: var(--ink-faint) !important;
  font-size: 10px !important;
  letter-spacing: 0.06em !important;
}
html[data-skin="souju-light"] .watch-calendar-page-day strong {
  color: var(--ink) !important;
  font-weight: 650 !important;
}
html[data-skin="souju-light"] .watch-calendar-page-day em {
  color: var(--ink-faint) !important;
  font-style: normal !important;
}
html[data-skin="souju-light"] .watch-calendar-page-day[data-selected="true"] strong,
html[data-skin="souju-light"] .watch-calendar-page-day[data-selected="true"] span,
html[data-skin="souju-light"] .watch-calendar-page-day[data-selected="true"] em {
  color: var(--ink) !important;
}

html[data-skin="souju-light"] .watch-calendar-kind-tabs {
  background: transparent !important;
  border-bottom: 1px solid var(--hair) !important;
  gap: 4px !important;
}
html[data-skin="souju-light"] .watch-calendar-kind-tabs > button {
  background: transparent !important;
  border: 0 !important;
  border-radius: 0 !important;
  color: var(--ink-faint) !important;
  font-weight: 600 !important;
  box-shadow: inset 0 -2px 0 transparent !important;
}
html[data-skin="souju-light"] .watch-calendar-kind-tabs > button[data-selected="true"] {
  color: var(--ink) !important;
  box-shadow: inset 0 -2px 0 var(--accent) !important;
}

html[data-skin="souju-light"] .watch-calendar-page-item-link {
  border-radius: 12px !important;
}
html[data-skin="souju-light"] .watch-calendar-page-item {
  background: #FFFFFF !important;
  border: 1px solid var(--line) !important;
  border-radius: 12px !important;
  box-shadow: none !important;
}
html[data-skin="souju-light"] .watch-calendar-page-item-copy h3,
html[data-skin="souju-light"] .watch-calendar-page-item-copy h4 {
  color: var(--ink) !important;
  font-weight: 600 !important;
}
html[data-skin="souju-light"] .watch-calendar-page-item-copy a {
  color: var(--ink) !important;
}
html[data-skin="souju-light"] .watch-calendar-page-item-copy p {
  color: var(--ink-mid) !important;
}

/* 内容区广告条：自用壳不展示 */
html[data-skin="souju-light"] .movie-content-grid-ad {
  display: none !important;
}

/* 周表卡片内的细节 */
html[data-skin="souju-light"] .watch-calendar-page-poster {
  border-radius: 8px !important;
  background: #EFEDE7 !important;
}
html[data-skin="souju-light"] .calendar-card-update {
  background: transparent !important;
  border: 0 !important;
  padding: 0 !important;
  color: var(--accent) !important;
  font-size: 11px !important;
  font-weight: 600 !important;
  border-radius: 0 !important;
}
html[data-skin="souju-light"] .calendar-card-meta span,
html[data-skin="souju-light"] .calendar-card-schedule {
  color: var(--ink-faint) !important;
}
html[data-skin="souju-light"] .calendar-card-action {
  color: var(--ink) !important;
  font-weight: 600 !important;
}

/* ---------- 通用：抹掉站点遗留的立体/渐变按钮观感 ---------- */
html[data-skin="souju-light"] button,
html[data-skin="souju-light"] .movie-button-secondary,
html[data-skin="souju-light"] .movie-button-primary {
  background-image: none !important;
  text-shadow: none !important;
}
html[data-skin="souju-light"] .movie-button-secondary {
  background-color: #FFFFFF !important;
  border: 1px solid var(--line) !important;
  color: var(--ink) !important;
  box-shadow: 0 1px 1px rgba(18, 16, 15, 0.03) !important;
}

/* =========================================================
   ① 今晚首选（首页置顶）
   ——数据只读站点自己的 playback-resume，不自己记"已看"
   ========================================================= */
html[data-skin="souju-light"] .souju-tonight {
  margin: 4px 12px 14px;
}
html[data-skin="souju-light"] .souju-tonight-head {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  gap: 12px;
  padding: 2px 2px 9px;
}
html[data-skin="souju-light"] .souju-tonight-kicker {
  position: relative;
  padding-left: 14px;
  font-size: 11px;
  font-weight: 650;
  letter-spacing: 0.1em;
  color: var(--ink);
}
html[data-skin="souju-light"] .souju-tonight-kicker::before {
  content: "";
  position: absolute;
  left: 0;
  top: 50%;
  width: 6px;
  height: 6px;
  margin-top: -3px;
  border-radius: 1.5px;
  background: var(--accent);
}
html[data-skin="souju-light"] .souju-tonight-meta {
  font-size: 11px;
  color: var(--ink-faint);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}
html[data-skin="souju-light"] .souju-tonight-card {
  display: flex;
  align-items: center;
  gap: 12px;
  padding: 10px;
  border: 1px solid var(--line);
  border-radius: 14px;
  background: var(--card);
  box-shadow: 0 1px 2px rgba(18, 16, 15, 0.04);
  text-decoration: none !important;
  color: var(--ink) !important;
}
html[data-skin="souju-light"] .souju-unseen-chip,
html[data-skin="souju-light"] .souju-tonight-card {
  -webkit-tap-highlight-color: transparent;
}
html[data-skin="souju-light"] .souju-tonight-card:active {
  background: #FBFAF7;
}
html[data-skin="souju-light"] .souju-tonight-poster {
  flex: 0 0 76px;
  width: 76px;
  height: 106px;
  border-radius: 8px;
  overflow: hidden;
  background: #EFEDE7;
}
html[data-skin="souju-light"] .souju-tonight-poster img {
  display: block;
  width: 100%;
  height: 100%;
  object-fit: cover;
}
html[data-skin="souju-light"] .souju-tonight-copy {
  flex: 1 1 auto;
  min-width: 0;
  display: flex;
  flex-direction: column;
  justify-content: center;
  gap: 7px;
}
html[data-skin="souju-light"] .souju-tonight-title {
  font-size: 17px;
  font-weight: 650;
  letter-spacing: -0.01em;
  color: var(--ink);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}
html[data-skin="souju-light"] .souju-tonight-sub {
  font-size: 12px;
  color: var(--ink-mid);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}
html[data-skin="souju-light"] .souju-tonight-cta {
  flex: 0 0 auto;
  align-self: center;
  padding: 7px 13px;
  border-radius: 999px;
  background: var(--ink);
  color: #FFFFFF;
  font-size: 12.5px;
  font-weight: 600;
}

/* =========================================================
   ② 周表筛选：只看未看过
   ========================================================= */
html[data-skin="souju-light"] .souju-unseen-bar {
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 10px 0 2px;
}
html[data-skin="souju-light"] .souju-unseen-chip {
  flex: 0 0 auto;
  padding: 6px 13px;
  border: 1px solid var(--line);
  border-radius: 999px;
  background: #FFFFFF;
  color: var(--ink-mid);
  font-size: 12px;
  font-weight: 600;
  line-height: 1.2;
  box-shadow: none;
}
html[data-skin="souju-light"] .souju-unseen-chip:focus,
html[data-skin="souju-light"] .souju-unseen-chip:focus-visible {
  outline: none !important;
}
html[data-skin="souju-light"] .souju-unseen-chip[aria-pressed="true"] {
  background: var(--ink);
  border-color: var(--ink);
  color: #FFFFFF;
}
html[data-skin="souju-light"] .souju-unseen-hint {
  min-width: 0;
  font-size: 11px;
  color: var(--ink-faint);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}
html[data-souju-unseen="on"] .watch-calendar-page-item-link[data-souju-seen="1"] {
  display: none !important;
}
html[data-skin="souju-light"] .souju-unseen-empty {
  padding: 26px 0 30px;
  text-align: center;
  font-size: 12px;
  color: var(--ink-faint);
}

"""#

    // MARK: - souju-dark
    //
    // 设计依据：资料库 souju-dark.html（v2）。那篇稿子一句话概括是
    // **「把灯关掉，但不改结构」**：light 版的六条约束（一屏一焦点 / 海报优先 /
    // 单一强调色 / 留白建层级 / 海报承担全部色彩 / 3.2× 比例）一条不动，换的只是介质：
    //
    //   · 画布用墨玉 #0E0E10，不用纯黑 —— #000 会让海报黑边和背景融成一片，层级消失
    //   · 层级靠「比画布更亮的卡片 #191A1D + 1px 亮描边」—— 黑投影打在近黑底上等于没画
    //   · 文字用暖白 #F2F1ED —— 纯白在暗底会 halation，小字尤其糊
    //   · 橙色提亮到 #FF6B42，但预算收紧 —— 同一块橙在暗底的视觉重量约是浅底 1.6 倍
    //   · 海报默认 brightness(.88)，按下复原 —— 暗底会把海报衬得过曝，六张一起喊就没焦点
    //
    // 实现上不复制 34KB 结构：结构只有一份（light 的 CSS，因为它已经把整站重排过），
    // dark = 换作用域 + 一张色值映射表 + 一份手写的「介质层」。
    // 以后改布局只改 light，dark 自动跟上；dark 独有的只有颜色、层级与橙色预算。

    private static let soujuDarkCSS: String = {
        let scoped = soujuLightCSS.replacingOccurrences(
            of: #"data-skin="souju-light""#,
            with: #"data-skin="souju-dark""#
        )
        return darken(scoped) + soujuDarkLayerCSS
    }()

    /// light → dark 的色值映射。只换「表面」与「文字」，不碰任何结构属性。
    /// 顺序有讲究：`background-color: #FFFFFF` 必须先于 `color: #FFFFFF`，
    /// 否则前者会被后者的子串规则截胡。
    private static func darken(_ css: String) -> String {
        let map: [(String, String)] = [
            ("background-color: #FFFFFF", "background-color: #191A1D"),
            ("background: #FFFFFF", "background: #191A1D"),
            ("color: #FFFFFF", "color: #0A0A0B"),
            ("rgba(250, 250, 248,", "rgba(14, 14, 16,"),
            ("rgba(18, 16, 15,", "rgba(0, 0, 0,"),
            ("#F4F3EF", "#212226"),
            ("#EFEDE7", "#1C1D21"),
            ("#F5F4F0", "#212226"),
            ("#F7F6F2", "#1A1B1F"),
            ("#FBFAF7", "#141417"),
            ("#FAFAF8", "#0E0E10"),
            ("#FF7A57", "#FF8A63"),
        ]
        var out = css
        for (from, to) in map {
            out = out.replacingOccurrences(of: from, with: to)
        }
        return out
    }

    /// 介质层：令牌重映射 + 暗底特有的补偿（描边代替阴影、橙色预算、海报压亮度）。
    private static let soujuDarkLayerCSS = #"""

/* =========================================================
   搜剧 Dark · 介质层  v1
   接在 light 结构之后，负责三件 light 不需要的事：
   ① 把纸白令牌换成墨玉/暖白；② 用描边重建层级；③ 收紧橙色预算
   ========================================================= */

html[data-skin="souju-dark"] {
  --bg: #0E0E10;
  --bg2: #141417;
  --surf: #191A1D;
  --surf2: #212226;
  --txt: #F2F1ED;
  --txt2: #9C9993;
  --txt3: #7A7873;
  --edge: rgba(255, 255, 255, 0.07);
  --edge2: rgba(255, 255, 255, 0.15);
  --on-light: #0A0A0B;

  /* 沿用 light 层的变量名，值换介质 */
  --paper: var(--bg);
  --card: var(--surf);
  --ink: var(--txt);
  --ink-mid: var(--txt2);
  --ink-faint: var(--txt3);
  --line: var(--edge);
  --hair: rgba(255, 255, 255, 0.05);
  --accent: #FF6B42;

  --movie-bg: var(--bg);
  --movie-bg-elevated: var(--surf);
  --movie-surface: var(--surf);
  --movie-surface-strong: var(--surf2);
  --movie-border: var(--edge);
  --movie-border-soft: rgba(255, 255, 255, 0.05);
  --movie-text: var(--txt);
  --movie-text-muted: var(--txt2);
  --movie-text-subtle: var(--txt3);
  --movie-primary: var(--txt);
  --movie-primary-strong: var(--accent);
  --movie-primary-foreground: var(--on-light);
  --movie-primary-muted: rgba(255, 255, 255, 0.08);
  --movie-accent: var(--accent);
  --movie-accent-muted: rgba(255, 107, 66, 0.14);
  --movie-share-button-background: var(--txt);
  --movie-player-danmaku-accent: var(--accent);
  --movie-player-danmaku-accent-hover: #FF8A63;
  --movie-player-danmaku-on-accent: var(--on-light);

  --movie-legacy-bg-rgb: 14, 14, 16;
  --movie-legacy-bg-elevated-rgb: 25, 26, 29;
  --movie-legacy-surface-rgb: 25, 26, 29;
  --movie-legacy-border-soft-rgb: 255, 255, 255;
  --movie-legacy-primary-rgb: 242, 241, 237;
  --movie-legacy-primary-strong-rgb: 255, 107, 66;
  --movie-legacy-text-rgb: 242, 241, 237;
  --movie-legacy-text-subtle-rgb: 156, 153, 147;
  --movie-legacy-accent-rgb: 255, 107, 66;

  color-scheme: dark;
}

/* ---------- 画布 ---------- */
html[data-skin="souju-dark"] body,
html[data-skin="souju-dark"] .min-h-dvh,
html[data-skin="souju-dark"] .movie-app-bg {
  background: var(--bg) !important;
  color: var(--txt) !important;
}
/* 站点的氛围光带一点青，会把「墨玉 + 暖白 + 一个橙」稀释掉 */
html[data-skin="souju-dark"] .movie-atmosphere,
html[data-skin="souju-dark"] .movie-app-bg::before,
html[data-skin="souju-dark"] .movie-app-bg::after {
  display: none !important;
}
html[data-skin="souju-dark"] .movie-page-loading-progress-rail {
  background: rgba(255, 255, 255, 0.08) !important;
}
html[data-skin="souju-dark"] .movie-page-loading-progress-value {
  background: var(--txt) !important;
}

/* ---------- 顶栏 ---------- */
html[data-skin="souju-dark"] .app-page-header-row {
  background: rgba(14, 14, 16, 0.86) !important;
  -webkit-backdrop-filter: saturate(160%) blur(18px);
  backdrop-filter: saturate(160%) blur(18px);
  border-bottom: 1px solid var(--edge) !important;
}
html[data-skin="souju-dark"] .app-header-control,
html[data-skin="souju-dark"] .movie-button-secondary {
  background: rgba(255, 255, 255, 0.06) !important;
  border: 1px solid var(--edge) !important;
  color: var(--txt) !important;
  box-shadow: none !important;
}
html[data-skin="souju-dark"] .app-header-control-icon,
html[data-skin="souju-dark"] .movie-button-secondary svg {
  color: var(--txt) !important;
}
/* 主行动：暖白实心 + 墨色字（light 是墨黑实心 + 白字，暗底要反过来） */
html[data-skin="souju-dark"] .movie-button-primary {
  background: var(--txt) !important;
  color: var(--on-light) !important;
  border: 0 !important;
  box-shadow: none !important;
}
html[data-skin="souju-dark"] .movie-button-primary svg {
  color: var(--on-light) !important;
}

/* ---------- 首页 hero ---------- */
html[data-skin="souju-dark"] .movie-home-page-shell .text-center h1 {
  color: var(--txt) !important;
}
/* 品牌标自带一块青蓝，会把「墨玉 + 暖白 + 一个橙」稀释掉：去色后提亮，落在暖白段 */
html[data-skin="souju-dark"] img.movie-brand-lockup {
  filter: grayscale(1) brightness(1.32) !important;
}

/* ---------- 搜索框 ---------- */
html[data-skin="souju-dark"] .movie-composer-root {
  background: var(--surf) !important;
  border: 1px solid rgba(255, 255, 255, 0.08) !important;
  border-radius: 18px !important;
  box-shadow: inset 0 1px 0 rgba(255, 255, 255, 0.04) !important;
}
html[data-skin="souju-dark"] .movie-composer-text-input {
  color: var(--txt) !important;
  caret-color: var(--accent) !important;
}
html[data-skin="souju-dark"] .movie-composer-text-input::placeholder,
html[data-skin="souju-dark"] .movie-composer-root ::placeholder {
  color: var(--txt3) !important;
}
html[data-skin="souju-dark"] .movie-composer-mode-switch {
  background: var(--surf2) !important;
  border: 0 !important;
}
html[data-skin="souju-dark"] .movie-composer-mode-thumb {
  background: rgba(255, 255, 255, 0.12) !important;
  box-shadow: none !important;
}
html[data-skin="souju-dark"] .movie-composer-search-mode-option {
  color: var(--txt2) !important;
}
html[data-skin="souju-dark"] .movie-composer-search-mode-option[aria-pressed="true"] {
  color: var(--txt) !important;
}
html[data-skin="souju-dark"] .movie-composer-leading-icon {
  background: rgba(255, 255, 255, 0.06) !important;
  color: var(--txt) !important;
  border: 0 !important;
}
html[data-skin="souju-dark"] .movie-composer-voice-toggle {
  color: var(--txt2) !important;
  background: transparent !important;
}

/* ---------- 提示 chip ---------- */
html[data-skin="souju-dark"] .movie-chip {
  background: var(--surf) !important;
  border: 1px solid var(--edge) !important;
  color: var(--txt2) !important;
  box-shadow: none !important;
}
html[data-skin="souju-dark"] .movie-home-prompt-groups .movie-chip svg {
  color: var(--txt3) !important;
}

/* ---------- 日期条：指示线用暖白，只有「今天」的数字留橙 ---------- */
/* 那篇稿子把 light 版的「橙色指示线」列为砍掉的两处之一：同一块橙在暗底重 1.6 倍，
   日期条这种每天常驻的元素必须让位给真正的主行动。 */
html[data-skin="souju-dark"] .home-watch-calendar {
  border-top: 1px solid var(--edge);
}
html[data-skin="souju-dark"] .home-watch-calendar-days {
  border-bottom: 1px solid var(--edge) !important;
}
html[data-skin="souju-dark"] .home-watch-calendar-day[data-selected="true"] {
  box-shadow: inset 0 -2px 0 var(--txt) !important;
  color: var(--txt) !important;
}
html[data-skin="souju-dark"] .home-watch-calendar-day[data-selected="true"] strong {
  color: var(--accent) !important;
}
html[data-skin="souju-dark"] .watch-calendar-page-day[data-selected="true"] {
  box-shadow: inset 0 -2px 0 var(--txt) !important;
}
html[data-skin="souju-dark"] .watch-calendar-page-day[data-selected="true"] strong {
  color: var(--accent) !important;
}

/* ---------- 海报与卡片：描边代替阴影，海报压 12% 亮度 ---------- */
html[data-skin="souju-dark"] .home-feed-card,
html[data-skin="souju-dark"] .home-feed-card-link,
html[data-skin="souju-dark"] .souju-tonight-card {
  background: transparent !important;
  box-shadow: none !important;
}
html[data-skin="souju-dark"] .home-feed-card-image,
html[data-skin="souju-dark"] .home-watch-calendar-poster,
html[data-skin="souju-dark"] .home-watch-calendar-poster-image,
html[data-skin="souju-dark"] .watch-calendar-page-poster,
html[data-skin="souju-dark"] .souju-tonight-poster img {
  filter: brightness(0.88) contrast(1.05);
  transition: filter 0.18s ease-out;
}
html[data-skin="souju-dark"] .home-feed-card:active .home-feed-card-image,
html[data-skin="souju-dark"] .souju-tonight-card:active .souju-tonight-poster img {
  filter: brightness(1) contrast(1.02);
}
html[data-skin="souju-dark"] .home-feed-card-image,
html[data-skin="souju-dark"] .souju-tonight-poster {
  border: 1px solid rgba(255, 255, 255, 0.08);
  border-radius: 11px;
}
/* 海报底部的压暗渐变要落在墨玉上，不能留纸白 */
html[data-skin="souju-dark"] .home-feed-card-shade {
  background: linear-gradient(to top, rgba(14, 14, 16, 0.92), rgba(14, 14, 16, 0.1) 42%, transparent 66%) !important;
}
/* 更新角标：全场允许的实心橙之一 */
html[data-skin="souju-dark"] .home-feed-card-status.is-fresh {
  background: var(--accent) !important;
  color: var(--on-light) !important;
}
html[data-skin="souju-dark"] .home-feed-card-heat {
  color: var(--txt3) !important;
}
html[data-skin="souju-dark"] .home-section-title,
html[data-skin="souju-dark"] .home-feed-card-title {
  color: var(--txt) !important;
}
html[data-skin="souju-dark"] .home-section-subtitle,
html[data-skin="souju-dark"] .home-feed-card-meta {
  color: var(--txt3) !important;
}

/* ---------- 底部导航 ---------- */
html[data-skin="souju-dark"] .app-primary-bottom-nav {
  background: rgba(14, 14, 16, 0.9) !important;
  -webkit-backdrop-filter: saturate(160%) blur(18px);
  backdrop-filter: saturate(160%) blur(18px);
  border-top: 1px solid var(--edge) !important;
  box-shadow: none !important;
}
html[data-skin="souju-dark"] .app-primary-bottom-link {
  color: var(--txt3) !important;
}
html[data-skin="souju-dark"] .app-primary-bottom-link.is-active {
  color: var(--txt) !important;
}
html[data-skin="souju-dark"] .app-primary-bottom-share-icon {
  background: var(--txt) !important;
  color: var(--on-light) !important;
  box-shadow: none !important;
}

/* ---------- 侧边菜单 / 抽屉 ---------- */
html[data-skin="souju-dark"] .movie-side-menu-panel {
  background: var(--bg2) !important;
  border-right: 1px solid var(--edge) !important;
}
html[data-skin="souju-dark"] .movie-menu-scrim {
  background: rgba(0, 0, 0, 0.55) !important;
}
html[data-skin="souju-dark"] .movie-mobile-bottom-drawer-dialog {
  background: var(--surf) !important;
  border: 1px solid var(--edge) !important;
}

/* ---------- 今晚首选（壳插入的卡） ---------- */
html[data-skin="souju-dark"] .souju-tonight-card {
  border: 1px solid var(--edge) !important;
  background: var(--surf) !important;
}
html[data-skin="souju-dark"] .souju-tonight-kicker {
  color: var(--txt2) !important;
}
html[data-skin="souju-dark"] .souju-tonight-kicker::before {
  background: var(--accent) !important;
}
html[data-skin="souju-dark"] .souju-tonight-title {
  color: var(--txt) !important;
}
html[data-skin="souju-dark"] .souju-tonight-sub,
html[data-skin="souju-dark"] .souju-tonight-meta {
  color: var(--txt3) !important;
}
html[data-skin="souju-dark"] .souju-tonight-cta {
  background: var(--txt) !important;
  color: var(--on-light) !important;
}

/* ---------- 周表筛选（壳插入的 chip） ---------- */
html[data-skin="souju-dark"] .souju-unseen-chip {
  background: transparent;
  border: 1px solid var(--edge);
  color: var(--txt2);
}
html[data-skin="souju-dark"] .souju-unseen-chip[aria-pressed="true"] {
  background: var(--txt);
  border-color: var(--txt);
  color: var(--on-light);
}
html[data-skin="souju-dark"] .souju-unseen-hint,
html[data-skin="souju-dark"] .souju-unseen-empty {
  color: var(--txt3);
}

/* ---------- 周表页 /updates ---------- */
html[data-skin="souju-dark"] .watch-calendar-page-item {
  background: var(--surf) !important;
  border: 1px solid var(--edge) !important;
  box-shadow: none !important;
}
html[data-skin="souju-dark"] .watch-calendar-kind-tabs > button[data-selected="true"] {
  color: var(--txt) !important;
  box-shadow: inset 0 -2px 0 var(--txt) !important;
}

/* ---------- 播放页 / 详情页 ---------- */
html[data-skin="souju-dark"] .movie-episode-item {
  background: var(--surf2) !important;
  border: 1px solid var(--edge) !important;
  color: var(--txt2) !important;
}
html[data-skin="souju-dark"] .movie-episode-item[aria-current="true"],
html[data-skin="souju-dark"] .movie-episode-item[data-active="true"],
html[data-skin="souju-dark"] .movie-episode-item.is-active {
  background: rgba(255, 255, 255, 0.14) !important;
  border-color: rgba(255, 255, 255, 0.22) !important;
  color: var(--txt) !important;
}
html[data-skin="souju-dark"] .movie-level-card {
  background: var(--surf) !important;
  border: 1px solid var(--edge) !important;
  box-shadow: none !important;
}
html[data-skin="souju-dark"] .movie-player-support-trigger,
html[data-skin="souju-dark"] .movie-player-support-trigger-icon {
  color: var(--on-light) !important;
}

/* ---------- 短剧竖屏流：暗底上是「压墨」而不是「压纸」 ---------- */
html[data-skin="souju-dark"] .short-drama-video-cover-layer {
  background: rgba(14, 14, 16, 0.62) !important;
}
html[data-skin="souju-dark"] .short-drama-overlay {
  background: linear-gradient(to top, #0E0E10 0%, rgba(14, 14, 16, 0.97) 38%, rgba(14, 14, 16, 0.78) 66%, rgba(14, 14, 16, 0) 100%) !important;
  color: var(--txt) !important;
}
html[data-skin="souju-dark"] .short-drama-copy h2 {
  color: var(--txt) !important;
}
html[data-skin="souju-dark"] .short-drama-copy p {
  color: var(--txt2) !important;
}
html[data-skin="souju-dark"] .short-drama-copy > span {
  background: rgba(255, 255, 255, 0.08) !important;
  color: var(--txt2) !important;
}
html[data-skin="souju-dark"] .short-drama-control-dock > button {
  background: rgba(14, 14, 16, 0.5) !important;
  border: 1px solid rgba(255, 255, 255, 0.12) !important;
  -webkit-backdrop-filter: blur(12px);
  backdrop-filter: blur(12px);
  box-shadow: none !important;
}
/* light 版这三处是「白磨砂」，暗底上原样保留会变成「浅底 + 暖白字」= 文字消失，
   必须一起翻成「墨磨砂 + 暖白字」。 */
html[data-skin="souju-dark"] .short-drama-actions .movie-button-secondary,
html[data-skin="souju-dark"] .short-drama-favorite-button {
  background: rgba(14, 14, 16, 0.62) !important;
  border: 1px solid rgba(255, 255, 255, 0.16) !important;
  color: var(--txt) !important;
  -webkit-backdrop-filter: blur(14px) saturate(140%);
  backdrop-filter: blur(14px) saturate(140%);
}
html[data-skin="souju-dark"] .short-drama-more-link {
  background: var(--txt) !important;
  color: var(--on-light) !important;
  border: 0 !important;
  box-shadow: none !important;
}
html[data-skin="souju-dark"] .short-drama-video-status {
  background: rgba(14, 14, 16, 0.62) !important;
  border: 1px solid rgba(255, 255, 255, 0.12) !important;
  color: var(--txt2) !important;
}
html[data-skin="souju-dark"] .short-drama-header .app-header-control,
html[data-skin="souju-dark"] .short-drama-detail-header .app-header-control {
  background: rgba(14, 14, 16, 0.55) !important;
  border: 1px solid rgba(255, 255, 255, 0.14) !important;
  box-shadow: none !important;
}
html[data-skin="souju-dark"] .short-drama-state-card {
  background: var(--surf) !important;
  border: 1px solid var(--edge) !important;
}
html[data-skin="souju-dark"] .short-drama-control-drawer-layer {
  --movie-bg: var(--bg2);
  --movie-bg-elevated: var(--surf);
  --movie-surface: var(--surf);
  --movie-surface-strong: var(--surf2);
  --movie-border: var(--edge);
  --movie-border-soft: rgba(255, 255, 255, 0.05);
  --movie-text: var(--txt);
  --movie-text-muted: var(--txt2);
  --movie-text-subtle: var(--txt3);
  --movie-primary: var(--txt);
  --movie-primary-foreground: var(--on-light);
  color-scheme: dark;
}
html[data-skin="souju-dark"] .short-drama-control-drawer-layer .movie-player-expanded-panel {
  background: var(--surf) !important;
  border: 1px solid var(--edge) !important;
}
html[data-skin="souju-dark"] .short-drama-control-drawer-layer .react-player-episode-option {
  background: var(--surf2) !important;
  border: 1px solid var(--edge) !important;
  color: var(--txt2) !important;
}
html[data-skin="souju-dark"] .short-drama-control-drawer-layer .react-player-episode-option.is-active {
  background: rgba(255, 255, 255, 0.14) !important;
  border-color: rgba(255, 255, 255, 0.22) !important;
  color: var(--txt) !important;
}
"""#

    private static let skinJSTemplate = #"""
(function () {
  // 皮肤名 / 主题名 / 明暗标记由 Swift 侧填进来（见 skinJS(skin:theme:dark:)）。
  // 两套皮肤共用这一段，结构逻辑（今晚首选、只看未看过、路由跟随）不重复实现。
  var SKIN = "__SKIN__";
  var THEME = "__THEME__";
  var DARK = __DARK__;

  // 换皮肤时页面会整体 reload，脚本重新执行；同一个皮肤内重复执行直接退出
  if (window.__soujuSkinLoaded === SKIN) { return; }
  window.__soujuSkinLoaded = SKIN;

  // 短剧页已并入皮肤，不再单独分支（保留正则以便按路由做例外）
  var RE_SHORT = /^\/short-drama(\/|$)/;
  var RE_UPDATES = /^\/updates(\/|$)/;
  var RE_HOME = /^\/$/;

  var PREF_UNSEEN = "souju:unseen-only";

  var state = {
    unseenOnly: readFlag(PREF_UNSEEN, false),
    watching: {},      // variantId -> true
    resume: [],        // 按 updatedAt 倒序
    timer: 0
  };

  // ---------- 小工具 ----------

  function readFlag(key, fallback) {
    try {
      var v = localStorage.getItem(key);
      if (v === "1") { return true; }
      if (v === "0") { return false; }
    } catch (e) {}
    return fallback;
  }

  function writeFlag(key, on) {
    try { localStorage.setItem(key, on ? "1" : "0"); } catch (e) {}
  }

  function el(tag, cls, text) {
    var node = document.createElement(tag);
    if (cls) { node.className = cls; }
    if (text != null) { node.textContent = text; }
    return node;
  }

  function path() {
    return location.pathname || "";
  }

  // 站点把播放地址写成 /player/<variantId>?from=...，id 是唯一能跟续播记录对上号的东西
  function variantIdOf(href) {
    var m = /\/player\/(av_[A-Za-z0-9_-]+)/.exec(href || "");
    return m ? m[1] : "";
  }

  // 悬浮条上要显示的是剧名，不是站点名。
  // document.title 是站点 SEO 标题（"搜剧AI - souju.ai - ..."），不能用；
  // 播放页真正的剧名在 h1 里，再退回页头居中的「剧名 年份 · 地区」。
  function pageTitle() {
    var name = "";
    var h1 = document.querySelector("h1");
    if (h1 && (h1.textContent || "").trim()) {
      name = (h1.textContent || "").trim();
    }
    if (!name) {
      var center = document.querySelector(".movie-app-header .text-center");
      if (center && (center.textContent || "").trim()) {
        name = (center.textContent || "").trim().split(/\s+/)[0];
      }
    }
    if (!name) {
      name = (document.title || "").replace(/\s*[-|\u00b7]\s*搜剧AI[\s\S]*$/, "").trim();
    }

    var id = variantIdOf(path());
    for (var i = 0; i < state.resume.length; i++) {
      if (state.resume[i].variantId === id) {
        var ep = state.resume[i].episodeLabel || state.resume[i].episode || "";
        if (ep) { name = name + " \u00b7 " + ep; }
        break;
      }
    }
    return name;
  }

  function setStatusBar(style) {
    try {
      var b = window.H5ShellNativeBridge;
      if (b && typeof b.call === "function") { b.call("statusBar", "setStyle", { style: style }); }
    } catch (e) {}
  }

  // ---------- 观看数据 ----------

  // 只读站点自己的续播记录，不写、不缓存 —— 我们没有任何自己的"已看"概念，
  // 站点记什么就是什么，换设备/换账号都跟得上。
  //
  // 解析 localStorage 比查 DOM 贵，而 MutationObserver 会在播放器每帧更新时触发，
  // 所以这份数据自带 1.5s 的最小刷新间隔：切页面时会先失效再读。
  var watchLoadedAt = 0;

  function loadWatchData(maxAge) {
    var now = Date.now();
    if (watchLoadedAt && now - watchLoadedAt < (maxAge || 1500)) { return; }
    watchLoadedAt = now;
    var all = [];
    try {
      for (var i = 0; i < localStorage.length; i++) {
        var key = localStorage.key(i);
        if (!key || key.indexOf("playback-resume") < 0 || key.indexOf(":owner:") < 0) { continue; }
        var arr = JSON.parse(localStorage.getItem(key) || "[]");
        if (Object.prototype.toString.call(arr) === "[object Array]") {
          for (var j = 0; j < arr.length; j++) {
            if (arr[j] && arr[j].variantId) { all.push(arr[j]); }
          }
        }
      }
    } catch (e) {}

    var seen = {};
    var dedup = [];
    for (var k = 0; k < all.length; k++) {
      var id = all[k].variantId;
      if (seen[id]) { continue; }
      seen[id] = true;
      dedup.push(all[k]);
    }
    dedup.sort(function (a, b) {
      return (Date.parse(b.updatedAt) || 0) - (Date.parse(a.updatedAt) || 0);
    });

    var watching = {};
    for (var n = 0; n < dedup.length; n++) { watching[dedup[n].variantId] = true; }

    state.resume = dedup;
    state.watching = watching;
  }

  // ---------- ① 今晚首选 ----------

  // 「今晚首选」不是"接着看"：站点首页本来就有「继续观看」，
  // 我们再放一张续播卡只会重复推荐同一部。这里做的是**发现**——
  // 从今天更新的日历里挑一部还没在追的，补上"今晚看什么"这个决策。
  // 海报取址：站点的日历项是懒加载图，冷启动那一刻 src 可能还是空的，
  // 依次退到 data-src / srcset —— 否则卡片会永久留一块空海报。
  function posterOf(img) {
    if (!img) { return ""; }
    var src = img.currentSrc || img.getAttribute("src") || "";
    if (!src) { src = img.getAttribute("data-src") || ""; }
    if (!src) {
      var set = img.getAttribute("srcset") || img.getAttribute("data-srcset") || "";
      if (set) { src = set.split(",")[0].trim().split(" ")[0]; }
    }
    return src;
  }

  function tonightData() {
    var groups = document.querySelectorAll(".home-watch-calendar-group");
    var firstAny = null;

    for (var g = 0; g < groups.length; g++) {
      var head = groups[g].querySelector(".home-watch-calendar-group-header h3");
      var kind = head ? (head.textContent || "").trim() : "";

      var items = groups[g].querySelectorAll(".home-watch-calendar-item");
      for (var i = 0; i < items.length; i++) {
        var link = items[i].closest("a");
        var title = items[i].querySelector("h4");
        if (!link || !title) { continue; }
        var img = items[i].querySelector("img");
        var note = items[i].querySelector("p");
        var data = {
          key: "cal:" + (link.getAttribute("href") || ""),
          href: link.getAttribute("href") || "",
          title: (title.textContent || "").trim(),
          kicker: "今晚首选",
          meta: kind ? kind + " · 今天更新" : "今天更新",
          sub: note && note.textContent ? note.textContent.trim() : "今日更新",
          poster: posterOf(img)
        };
        if (!firstAny) { firstAny = data; }
        if (!state.watching[variantIdOf(data.href)]) { return data; }
      }
    }
    return firstAny;
  }

  // 渲染时若还取不到海报，安排几次自重试：冷启动那一刻源图往往还没 src，
  // 等它到了再重建这张卡，用户看到的就是"晚半秒出现"，而不是永久空白。
  var posterRetry = 0;

  function schedulePosterRetry() {
    if (posterRetry >= 4) { return; }
    posterRetry += 1;
    setTimeout(function () { syncTonight(); }, posterRetry === 1 ? 500 : 1200);
  }

  function renderTonight(data) {
    var wrap = el("section", "souju-tonight");
    wrap.setAttribute("data-souju-tonight", "1");
    wrap.setAttribute("data-souju-key", data.key);

    var head = el("div", "souju-tonight-head");
    head.appendChild(el("span", "souju-tonight-kicker", data.kicker));
    if (data.meta) { head.appendChild(el("span", "souju-tonight-meta", data.meta)); }
    wrap.appendChild(head);

    var card = el("a", "souju-tonight-card");
    card.setAttribute("href", data.href);
    card.setAttribute("data-discover", "true");

    var poster = el("span", "souju-tonight-poster");
    if (data.poster) {
      var img = document.createElement("img");
      img.src = data.poster;
      img.alt = "";
      // 不要 lazy：这张卡在首屏第一屏，而 WebKit 会按「插入那一刻的位置」判定是否延迟，
      // 结果经常一直不加载 —— 表现就是卡片左边永远一块空海报。
      img.loading = "eager";
      img.decoding = "async";
      // 站点的海报走第三方图床，Referer 带了反而可能被拒；原图用的是 no-referrer
      img.referrerPolicy = "no-referrer";
      poster.appendChild(img);
    } else {
      schedulePosterRetry();
    }
    card.appendChild(poster);

    var copy = el("span", "souju-tonight-copy");
    copy.appendChild(el("span", "souju-tonight-title", data.title));
    copy.appendChild(el("span", "souju-tonight-sub", data.sub));

    card.appendChild(copy);

    var cta = el("span", "souju-tonight-cta", "去看看");
    card.appendChild(cta);

    wrap.appendChild(card);
    return wrap;
  }

  function syncTonight() {
    if (!RE_HOME.test(path())) { return; }
    var anchor = document.querySelector(".home-watch-calendar");
    if (!anchor || !anchor.parentElement) { return; }

    var data = tonightData();
    var existing = document.querySelector("[data-souju-tonight]");

    if (!data) {
      if (existing) { existing.remove(); }
      return;
    }

    if (existing && existing.getAttribute("data-souju-key") === data.key) {
      // 海报迟到了：内容没变但卡里还是空海报，重建一次把图补上
      var posterBox = existing.querySelector(".souju-tonight-poster");
      if (data.poster && posterBox && !posterBox.firstChild) {
        existing.remove();
        posterRetry = 0;
        anchor.parentElement.insertBefore(renderTonight(data), anchor);
        return;
      }
      // 内容没变，只要保证它还排在日历前面（React 重排过就挪回来）
      if (existing.nextElementSibling !== anchor) {
        anchor.parentElement.insertBefore(existing, anchor);
      }
      return;
    }
    if (existing) { existing.remove(); }
    anchor.parentElement.insertBefore(renderTonight(data), anchor);
  }

  // ---------- ② 周表「只看未看过」 ----------

  function buildUnseenBar() {
    var bar = el("div", "souju-unseen-bar");
    bar.setAttribute("data-souju-unseen-bar", "1");

    var chip = el("button", "souju-unseen-chip");
    chip.setAttribute("type", "button");
    chip.setAttribute("data-souju-unseen-chip", "1");
    chip.addEventListener("click", function (event) {
      event.preventDefault();
      event.stopPropagation();
      state.unseenOnly = !state.unseenOnly;
      writeFlag(PREF_UNSEEN, state.unseenOnly);
      syncUnseen();
    });
    bar.appendChild(chip);

    var hint = el("span", "souju-unseen-hint");
    hint.setAttribute("data-souju-unseen-hint", "1");
    bar.appendChild(hint);

    return bar;
  }

  function syncUnseen() {
    if (!RE_UPDATES.test(path())) { return; }

    var links = document.querySelectorAll(".watch-calendar-page-item-link");
    if (!links.length) { return; }

    var total = links.length;
    var seen = 0;
    for (var i = 0; i < total; i++) {
      var isSeen = !!state.watching[variantIdOf(links[i].getAttribute("href"))];
      links[i].setAttribute("data-souju-seen", isSeen ? "1" : "0");
      if (isSeen) { seen++; }
    }

    var tabs = document.querySelector(".watch-calendar-kind-tabs");
    if (tabs && tabs.parentElement) {
      var bar = document.querySelector("[data-souju-unseen-bar]");
      if (!bar) {
        bar = buildUnseenBar();
        tabs.parentElement.insertBefore(bar, tabs.nextElementSibling);
      } else if (bar.previousElementSibling !== tabs) {
        tabs.parentElement.insertBefore(bar, tabs.nextElementSibling);
      }

      var chip = bar.querySelector("[data-souju-unseen-chip]");
      var hint = bar.querySelector("[data-souju-unseen-hint]");
      var unseen = total - seen;
      if (chip) {
        chip.textContent = state.unseenOnly ? "只看未看过 · " + unseen : "只看未看过";
        chip.setAttribute("aria-pressed", state.unseenOnly ? "true" : "false");
      }
      if (hint) {
        hint.textContent = unseen === 0 && total > 0 && state.unseenOnly
          ? ""
          : (state.unseenOnly ? "已看过的 " + seen + " 部已隐藏" : "共 " + total + " 部，已看 " + seen + " 部");
      }
    }

    document.documentElement.setAttribute("data-souju-unseen", state.unseenOnly ? "on" : "off");

    var empty = document.querySelector("[data-souju-unseen-empty]");
    var allSeen = state.unseenOnly && total > 0 && seen === total;
    if (allSeen && !empty) {
      var note = el("p", "souju-unseen-empty", "这几部都看过了，点上面的按钮看全部");
      note.setAttribute("data-souju-unseen-empty", "1");
      var list = links[0].parentElement;
      if (list && list.parentElement) { list.parentElement.insertBefore(note, list.nextSibling); }
    } else if (!allSeen && empty) {
      empty.remove();
    }

  }

  window.__soujuState = function () {
    return {
      path: path(),
      unseenOnly: state.unseenOnly,
      title: pageTitle(),
      resumeCount: state.resume.length,
      watchedCount: Object.keys(state.watching).length
    };
  };

  // ---------- 路由与主题 ----------

  function markFresh() {
    var nodes = document.querySelectorAll(".home-feed-card-status");
    for (var i = 0; i < nodes.length; i++) {
      if (/\u66f4\u65b0|\u65b0/.test(nodes[i].textContent || "")) {
        nodes[i].classList.add("is-fresh");
      }
    }
  }

  function applyTheme() {
    var h = document.documentElement;
    if (h.getAttribute("data-theme") !== THEME) { h.setAttribute("data-theme", THEME); }
    if (h.getAttribute("data-skin") !== SKIN) { h.setAttribute("data-skin", SKIN); }
    // 深色皮肤要跟着站点的暗色约定挂 html.dark（它的 Tailwind dark: 变体看这个类）
    if (DARK) {
      if (!h.classList.contains("dark")) { h.classList.add("dark"); }
    } else if (h.classList.contains("dark")) {
      h.classList.remove("dark");
    }
  }

  // 一次 sync 把所有区块对齐到当前路由与最新数据
  function sync(force) {
    loadWatchData(force ? 0 : 1500);
    applyTheme();
    syncTonight();
    syncUnseen();
    markFresh();

    // 短剧页顶部就是视频画面，明暗不可控：状态栏交给站点（固定浅色图标，融进画面）；
    // 其余页面深色皮肤用浅色图标，浅色皮肤用深色图标。
    if (!RE_SHORT.test(path())) {
      setStatusBar(DARK ? "lightContent" : "darkContent");
    }
  }

  // 站点每次路由切换都会大面积重建 DOM，我们的节点会被 React 顺手带走；
  // 用一个节流的 MutationObserver 兜底，而不是轮询整个树。
  function scheduleSync() {
    if (state.timer) { return; }
    state.timer = setTimeout(function () {
      state.timer = 0;
      sync();
    }, 200);
  }

  sync();


  // 站点渲染后会自己调 statusBar.setStyle("lightContent")，拖一拍纠正
  setTimeout(function () { sync(true); }, 1200);
  setTimeout(function () { sync(true); }, 2600);

  var last = location.href;
  setInterval(function () {
    if (location.href === last) { return; }
    last = location.href;
    sync(true);
  }, 400);

  window.addEventListener("popstate", function () { sync(true); });
  window.addEventListener("hashchange", function () { sync(true); });

  try {
    var observer = new MutationObserver(function () {
      var h = document.documentElement;
      if (h.getAttribute("data-skin") !== SKIN || h.getAttribute("data-theme") !== THEME) {
        applyTheme();
      }
      scheduleSync();
    });
    observer.observe(document.documentElement, {
      childList: true, subtree: true, attributes: true,
      attributeFilter: ["data-theme", "data-skin", "class", "href"]
    });
  } catch (e) {}
})();
"""#
}
