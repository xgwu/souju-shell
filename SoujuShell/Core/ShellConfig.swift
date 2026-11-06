import Foundation

/// 全局配置。改这里就能调整线路、能力开关与调试行为，不用碰业务代码。
enum ShellConfig {

    // MARK: - 线路

    /// 主线路在前。壳会按顺序探活，失败自动往下走。
    /// 站点采用域名轮换架构（响应头 X-Ai-Movie-Route-Policy），线路挂了就把新域名加进来。
    static let builtinDomains: [String] = [
        "https://souju.ai",
        "https://hctd4.com"
    ]

    /// 单次导航超时（秒）
    static let requestTimeout: TimeInterval = 8

    // MARK: - 桥

    /// 必须与网页侧 `window.webkit.messageHandlers.<name>` 完全一致，否则识别不到原生容器。
    static let bridgeHandlerName = "nativeBridge"

    /// 网页侧事件通道名，与 bundle 里的 `h5shell:native-event` 对齐。
    static let bridgeEventName = "h5shell:native-event"

    // MARK: - 能力协商

    /// 原生播放器 profile。当前版本不实现原生播放器（工程量在数周级），
    /// 因此 `supportsNativePlayer` 固定为 false，站点会回落 `legacy_app` + 自带 H5 播放器。
    /// 这不是缺陷，是有意的取舍：H5 播放器本身可用，且规避了逆协议带来的不确定性。
    static let nativePlayerProfile = "aimovie_native_player_v1"
    static let supportsNativePlayer = false

    /// 客户端版本号。站点判定 `aimovie_native_v1` 时要求 >= 2；我们不进那条分支，填 0。
    static let aimovieNativeClientVersion = 0

    // MARK: - 图标

    static var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.0"
    }

    static var buildNumber: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "1"
    }
}

/// 用户偏好。壳的"设置"面板读写这里，持久化在 UserDefaults。
final class ShellSettings: ObservableObject {

    static let shared = ShellSettings()

    private let defaults = UserDefaults.standard

    private enum Key {
        static let customDomains = "shell.customDomains"
        static let preferredDomain = "shell.preferredDomain"
        static let downloadEnabled = "shell.downloadEnabled"
        static let followSiteTheme = "shell.followSiteTheme"
        static let customCSS = "shell.customCSS"
        static let customJS = "shell.customJS"
        static let customInjectionEnabled = "shell.customInjectionEnabled"
        static let skin = "shell.skin"
    }

    /// 自定义线路（为空则用内置列表）
    @Published var customDomains: [String] {
        didSet { defaults.set(customDomains, forKey: Key.customDomains) }
    }

    /// 上次成功打开过的线路，冷启动优先用它
    @Published var preferredDomain: String? {
        didSet { defaults.set(preferredDomain, forKey: Key.preferredDomain) }
    }

    /// 离线下载能力开关。关掉后 `getCapabilities` 不再上报 download.* ，
    /// 站点会自动隐藏下载入口 —— 不想开下载时用它一键降级。
    @Published var downloadEnabled: Bool {
        didSet { defaults.set(downloadEnabled, forKey: Key.downloadEnabled) }
    }

    /// 跟随站点主题切换状态栏明暗。关掉则固定深色。
    @Published var followSiteTheme: Bool {
        didSet { defaults.set(followSiteTheme, forKey: Key.followSiteTheme) }
    }

    // MARK: - 自定义注入
    //
    // 这两项让"改网页 UI"不用重新编译、不用重新签名：
    // 改完存进 UserDefaults，壳重建 user scripts 后刷新页面即生效。
    // 存本地而不是写死在源码里，是因为站点 DOM 会变，改一次编译一次太蠢。

    /// 注入到站点的 CSS。空串表示不注入。
    @Published var customCSS: String {
        didSet { defaults.set(customCSS, forKey: Key.customCSS) }
    }

    /// 注入到站点的 JS。空串表示不注入。
    /// 写入前必须过 `CustomInjection.syntaxError`，语法错会让整段脚本静默失效。
    @Published var customJS: String {
        didSet { defaults.set(customJS, forKey: Key.customJS) }
    }

    /// 自定义注入总开关。关掉后壳只注入桥，页面保持站点原样 ——
    /// 用来判断"某个问题是站点改版还是我的样式造成的"。
    @Published var customInjectionEnabled: Bool {
        didSet { defaults.set(customInjectionEnabled, forKey: Key.customInjectionEnabled) }
    }

    /// 内置皮肤。`none` = 站点原样，`souju-light` = 全站换成纸白 + 海报优先。
    /// 皮肤与自定义注入是叠加关系：皮肤先铺底，用户 CSS/JS 后盖上去。
    @Published var skin: String {
        didSet { defaults.set(skin, forKey: Key.skin) }
    }

    /// 解析成枚举，未知值一律回落 `none`（比如将来删掉某个皮肤）
    var activeSkin: SkinPreset {
        SkinPreset.named(skin)
    }

    private init() {
        customDomains = defaults.stringArray(forKey: Key.customDomains) ?? []
        preferredDomain = defaults.string(forKey: Key.preferredDomain)
        downloadEnabled = defaults.object(forKey: Key.downloadEnabled) as? Bool ?? true
        followSiteTheme = defaults.object(forKey: Key.followSiteTheme) as? Bool ?? true
        customCSS = defaults.string(forKey: Key.customCSS) ?? ""
        customJS = defaults.string(forKey: Key.customJS) ?? ""
        customInjectionEnabled = defaults.object(forKey: Key.customInjectionEnabled) as? Bool ?? true
        skin = defaults.string(forKey: Key.skin) ?? SkinPreset.none.rawValue
    }

    /// 是否真的注入内容（开关开着且有内容）
    var hasCustomInjection: Bool {
        guard customInjectionEnabled else { return false }
        return !customCSS.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !customJS.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 是否有任何一层覆盖（皮肤或自定义）
    var hasAnyInjection: Bool {
        hasCustomInjection || activeSkin != .none
    }

    /// 有效线路列表：自定义优先，其次内置
    var effectiveDomains: [String] {
        let list = customDomains.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return list.isEmpty ? ShellConfig.builtinDomains : list
    }

    func adopt(domain: String) {
        guard preferredDomain != domain else { return }
        preferredDomain = domain
    }
}
