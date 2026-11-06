import UIKit
import WebKit
import SafariServices
import AVKit

/// 承载 WKWebView 的容器。壳的所有"原生增强"都挂在这里。
///
/// 三条设计原则：
///  1. **全屏铺满**：`contentInsetAdjustmentBehavior = .never` + `viewport-fit=cover`，
///     让站点自己的 CSS `env(safe-area-inset-*)` 决定留白，壳不插手布局，避免双重安全区。
///  2. **线路可换**：站点是域名轮换架构，写死一个域名等于把白屏权限交给别人。
///  3. **不打扰页面**：除投屏/下载/播放这些原生能力外，不注入任何 UI 到网页。
final class ShellViewController: UIViewController {

    let model: ShellModel
    private let downloads: DownloadManager
    private let bridge: NativeBridge

    private(set) lazy var webView: WKWebView = makeWebView()

    private var domainQueue: [String] = []
    private var currentDomainIndex = 0
    private var observations: [NSKeyValueObservation] = []
    private var isFailingOver = false

    init(model: ShellModel, downloads: DownloadManager = .shared) {
        self.model = model
        self.downloads = downloads
        self.bridge = NativeBridge(model: model, downloads: downloads)
        super.init(nibName: nil, bundle: nil)
        bridge.controller = self
        model.controller = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - 生命周期

    override func loadView() {
        let root = UIView()
        root.backgroundColor = UIColor(hex: 0x08080A)
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.addSubview(webView)
        webView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        setupRefreshControl()
        setupGestures()
        observeWebView()

        // 横屏转回竖屏偶发不旋转的补正，判定条件与原因见 RotationGuard
        RotationGuard.shared.attach(controller: self) { [weak self] message in
            self?.model.log("rotate", message)
        }

        downloads.onEvent = { [weak self] name, payload in
            self?.bridge.emit(name, payload: payload)
        }

        start()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    // MARK: - 方向

    /// 与 `Support/Info.plist` 的 `UISupportedInterfaceOrientations` 保持一致。
    /// 写在这里是为了让 SwiftUI 的承载控制器向上查询时拿到明确答案，而不是依赖默认值。
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .allButUpsideDown }

    override var shouldAutorotate: Bool { true }

    // MARK: - WKWebView 构建

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.allowsPictureInPictureMediaPlayback = true
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        configuration.userContentController.addUserScript(bridgeUserScript())
        configuration.userContentController.add(bridge, name: ShellConfig.bridgeHandlerName)
        installCustomScripts(into: configuration.userContentController)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = true
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.keyboardDismissMode = .onDrag

        if #available(iOS 16.4, *) {
            // 用 KVC 而不是直接调 isInspectable：后者要求 iOS 16.4 SDK，
            // 而 Xcode 14.x 系列的 SDK 版本参差不齐，直接调会让低版本 SDK 编译失败。
            if webView.responds(to: Selector(("setInspectable:"))) {
                webView.setValue(true, forKey: "inspectable")
            }
        }
        return webView
    }

    /// 桥必须在 documentStart 注入：站点在 [0,120,320,700]ms 内做四轮探测，晚了就当没有壳。
    /// 抽成方法是因为 `applyCustomInjection()` 重建 user scripts 时要把它补回去。
    private func bridgeUserScript() -> WKUserScript {
        WKUserScript(
            source: BridgeScript.source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
    }

    /// 挂皮肤 + 用户自定义的 CSS / JS。没有内容时什么都不加，不产生运行时开销。
    ///
    /// 顺序很重要：**皮肤先、自定义后**。后注入的样式天然覆盖先注入的，
    /// 所以用户在编辑器里写的那两条规则永远压在皮肤之上，不用加 `!important` 去打架。
    private func installCustomScripts(into controller: WKUserContentController) {
        let settings = ShellSettings.shared
        let skin = settings.activeSkin

        var cssParts: [String] = []
        var jsParts: [String] = []

        if !skin.css.isEmpty {
            // 内置皮肤把两套介质一起下发：页内热切换（站点右上角的日/夜按钮、
            // 工具箱的主题开关）只改 data-skin 属性，不用重建样式、不用 reload。
            let css = skin.bundlesBothMedia ? SkinPreset.dualCSS : skin.css
            cssParts.append("/* ===== skin: \(skin.rawValue) ===== */\n" + css)
            jsParts.append(skin.js)
        }

        if settings.customInjectionEnabled {
            let customCSS = settings.customCSS.trimmingCharacters(in: .whitespacesAndNewlines)
            let customJS = settings.customJS.trimmingCharacters(in: .whitespacesAndNewlines)
            if !customCSS.isEmpty { cssParts.append("/* ===== custom ===== */\n" + customCSS) }
            if !customJS.isEmpty { jsParts.append(customJS) }
        }

        guard !cssParts.isEmpty || !jsParts.isEmpty else { return }

        let scripts = CustomInjection.makeUserScripts(
            css: cssParts.joined(separator: "\n\n"),
            js: jsParts.joined(separator: "\n\n")
        )
        for script in scripts {
            controller.addUserScript(script)
        }
    }

    /// 用户在工具箱里改完自定义样式/脚本后调用。
    ///
    /// `WKUserContentController` 的脚本集合建好后就固定了，改内容只能整个重建。
    /// 注意必须顺手把桥补回去 —— 只 `removeAllUserScripts()` 不补，
    /// 页面会退化成纯网页，表现是"下载和投屏按钮突然都不见了"，很难联想到是这里。
    func applyCustomInjection() {
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        controller.addUserScript(bridgeUserScript())
        installCustomScripts(into: controller)

        let settings = ShellSettings.shared
        model.log(
            "custom",
            "注入已重建：皮肤 \(settings.activeSkin.rawValue) / CSS \(settings.customCSS.count) 字 / JS \(settings.customJS.count) 字 / 开关 \(settings.customInjectionEnabled ? "开" : "关")"
        )
        webView.reload()
    }

    /// 切主题：优先**页内热切换**，不刷新页面。
    ///
    /// 两套介质的样式在注入时就已经一起下发了（`SkinPreset.dualCSS`），
    /// 换介质只是把 `data-skin` / `data-theme` / `html.dark` 改一遍，
    /// 由页面里的 `window.__soujuSetTheme` 负责（它还会顺手重跑一次 sync）。
    ///
    /// 什么情况才回落 reload：
    ///   - 切之前是「站点原样」，页面里根本没有皮肤样式；
    ///   - 注入被关掉 / 页面还没跑到 documentEnd，拿不到那个函数。
    /// 这两条都会让热切换静默失败，所以用返回值判断，而不是假设它一定成功。
    func switchSkin(to preset: SkinPreset) {
        let previous = ShellSettings.shared.activeSkin
        ShellSettings.shared.chooseSkin(preset)

        guard previous.bundlesBothMedia, preset.bundlesBothMedia else {
            model.log("skin", "\(previous.rawValue) → \(preset.rawValue)：需要重建注入")
            applyCustomInjection()
            return
        }

        let mode = preset.isDark ? "dark" : "light"
        let js = "window.__soujuSetTheme ? window.__soujuSetTheme(\"\(mode)\") : false"
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self = self else { return }
            if (result as? Bool) == true {
                self.model.log("skin", "热切换 → \(preset.rawValue)（未重载页面）")
            } else {
                self.model.log("skin", "热切换不可用，重建注入 → \(preset.rawValue)")
                self.applyCustomInjection()
            }
        }
    }

    #if DEBUG
    /// 调试：在页面里对站点自带的日/夜按钮派发一次真实点击。
    /// 模拟器没法脚本化点按（`simctl` 没有 tap 命令），只能从页面内部派发事件；
    /// 这样走的是和手指点击完全相同的捕获链路，能覆盖「接管 → 桥 → 热切换」全流程。
    func debugTapThemeButton() {
        let js = """
        (function () {
          var b = document.querySelector('button[aria-label*="主题"]')
               || document.querySelector('button[title="亮色"]')
               || document.querySelector('button[title="暗色"]');
          if (!b) {
            var svgs = document.querySelectorAll('svg');
            for (var i = 0; i < svgs.length; i++) {
              var c = svgs[i].getAttribute('class') || '';
              if (/lucide-(sun|moon)/.test(c)) { b = svgs[i].closest('button'); break; }
            }
          }
          if (!b) { return 'no-button'; }
          b.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }));
          return 'clicked:' + (b.getAttribute('aria-label') || b.getAttribute('title') || '');
        })();
        """
        webView.evaluateJavaScript(js) { [weak self] result, error in
            let text = (result as? String) ?? error.map { "\($0)" } ?? "nil"
            self?.model.log("debug", "模拟点击主题按钮 → \(text)")
        }
    }
    #endif

    // MARK: - 线路与导航
    private func start() {
        domainQueue = orderedDomains()
        currentDomainIndex = 0
        loadCurrentDomain()
    }

    private func orderedDomains() -> [String] {
        var list = ShellSettings.shared.effectiveDomains
        if let preferred = ShellSettings.shared.preferredDomain,
           let index = list.firstIndex(of: preferred),
           index != 0 {
            list.remove(at: index)
            list.insert(preferred, at: 0)
        }
        return list
    }

    private func loadCurrentDomain() {
        guard currentDomainIndex < domainQueue.count else {
            model.state = .failed("所有线路都无法访问")
            return
        }

        let domain = domainQueue[currentDomainIndex]
        model.currentDomain = domain
        model.state = .loading
        model.progress = 0
        isFailingOver = false

        guard let url = URL(string: domain) else {
            currentDomainIndex += 1
            loadCurrentDomain()
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = ShellConfig.requestTimeout
        // 站点没有 UA 白名单，保留 WKWebView 默认 iOS UA 最稳：
        // 伪装成官方壳的 UA 需要知道它长什么样，猜错会触发站点另一条分支。
        webView.load(request)
        model.log("nav", "载入 \(domain)")
    }

    private func handleFailure(_ error: Error, isProvisional: Bool) {
        let nsError = error as NSError
        if nsError.code == NSURLErrorCancelled { return }

        model.log("nav", "失败(\(isProvisional ? "provisional" : "committed"))：\(error.localizedDescription)")

        // 已经渲染出内容后的子导航失败，不该整站重来
        if !isProvisional, model.state == .ready { return }
        if isFailingOver { return }
        isFailingOver = true

        currentDomainIndex += 1
        if currentDomainIndex < domainQueue.count {
            loadCurrentDomain()
        } else {
            model.state = .failed(error.localizedDescription)
        }
    }

    // MARK: - 对外指令

    func reloadCurrent() {
        if webView.url == nil {
            start()
        } else {
            webView.reload()
        }
    }

    func restartFailover() {
        currentDomainIndex = 0
        start()
    }

    func forceLoad(domain: String) {
        let normalized = domain.hasPrefix("http") ? domain : "https://" + domain
        domainQueue = [normalized]
        currentDomainIndex = 0
        loadCurrentDomain()
    }

    func load(urlString: String) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let normalized = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: normalized) else { return }

        var request = URLRequest(url: url)
        request.timeoutInterval = ShellConfig.requestTimeout
        model.state = .loading
        model.progress = 0
        webView.load(request)
    }

    func goBack() {
        if webView.canGoBack { webView.goBack() }
    }

    func clearSiteData() {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        WKWebsiteDataStore.default().removeData(
            ofTypes: types,
            modifiedSince: Date(timeIntervalSince1970: 0)
        ) { [weak self] in
            URLCache.shared.removeAllCachedResponses()
            guard let self = self else { return }
            self.model.log("cache", "站点数据与 URL 缓存已清理")
            self.webView.reload()
        }
    }

    // MARK: - 原生能力

    func presentExternal(url: String, title: String?) {
        guard let target = URL(string: url), let scheme = target.scheme?.lowercased() else { return }

        if scheme != "http" && scheme != "https" {
            UIApplication.shared.open(target, options: [:], completionHandler: nil)
            return
        }

        let configuration = SFSafariViewController.Configuration()
        configuration.entersReaderIfAvailable = false
        let safari = SFSafariViewController(url: target, configuration: configuration)
        safari.preferredControlTintColor = UIColor(hex: 0xFF5C35)
        safari.dismissButtonStyle = .close
        present(safari, animated: true)
    }

    /// AirPlay 设备选择。
    ///
    /// `AVRoutePickerView` 没有公开的"以代码打开"接口，内部按钮是私有实现。
    /// 这里不用私有 API 取巧，而是把它放进一个原生面板里让用户点 —— 行为可预期，也不会随系统版本失效。
    func presentAirPlayPicker() {
        let host = UIViewController()
        host.view.backgroundColor = UIColor(hex: 0x151518)
        host.modalPresentationStyle = .pageSheet

        let titleLabel = UILabel()
        titleLabel.text = "投屏到"
        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        titleLabel.textColor = UIColor(hex: 0xF4F2EE)
        titleLabel.textAlignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let hintLabel = UILabel()
        hintLabel.text = "点击下方按钮选择 AirPlay 设备"
        hintLabel.font = .systemFont(ofSize: 13)
        hintLabel.textColor = UIColor(hex: 0x8A8A8F)
        hintLabel.textAlignment = .center
        hintLabel.translatesAutoresizingMaskIntoConstraints = false

        let picker = AVRoutePickerView()
        picker.tintColor = UIColor(hex: 0xF4F2EE)
        picker.activeTintColor = UIColor(hex: 0xFF5C35)
        picker.prioritizesVideoDevices = true
        picker.translatesAutoresizingMaskIntoConstraints = false

        let container = UIView()
        container.backgroundColor = UIColor(hex: 0x08080A)
        container.layer.cornerRadius = 40
        container.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(picker)
        host.view.addSubview(titleLabel)
        host.view.addSubview(hintLabel)
        host.view.addSubview(container)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: host.view.topAnchor, constant: 40),
            titleLabel.leadingAnchor.constraint(equalTo: host.view.leadingAnchor, constant: 24),
            titleLabel.trailingAnchor.constraint(equalTo: host.view.trailingAnchor, constant: -24),

            container.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 28),
            container.centerXAnchor.constraint(equalTo: host.view.centerXAnchor),
            container.widthAnchor.constraint(equalToConstant: 80),
            container.heightAnchor.constraint(equalToConstant: 80),

            picker.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            picker.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            picker.widthAnchor.constraint(equalToConstant: 48),
            picker.heightAnchor.constraint(equalToConstant: 48),

            hintLabel.topAnchor.constraint(equalTo: container.bottomAnchor, constant: 20),
            hintLabel.leadingAnchor.constraint(equalTo: host.view.leadingAnchor, constant: 24),
            hintLabel.trailingAnchor.constraint(equalTo: host.view.trailingAnchor, constant: -24)
        ])

        if let sheet = host.sheetPresentationController {
            sheet.detents = [.medium()]
            sheet.prefersGrabberVisible = true
        }

        present(host, animated: true)
    }

    func presentPlayer(for task: DownloadTask) {
        guard let url = task.entryURL else {
            model.log("player", "离线文件不存在：\(task.title)")
            return
        }
        let player = OfflinePlayerController(localURL: url, title: task.title)
        player.modalPresentationStyle = .fullScreen
        present(player, animated: true)
    }

    // MARK: - 刷新

    private func setupRefreshControl() {
        let control = UIRefreshControl()
        control.tintColor = UIColor(hex: 0x8A8A8F)
        control.addTarget(self, action: #selector(handleRefresh), for: .valueChanged)
        webView.scrollView.refreshControl = control
    }

    @objc private func handleRefresh() {
        webView.reload()
    }

    // MARK: - 手势：摇一摇 / 双指下滑 打开工具箱

    private func setupGestures() {
        let swipe = UISwipeGestureRecognizer(target: self, action: #selector(handleToolboxSwipe))
        swipe.numberOfTouchesRequired = 2
        swipe.direction = .down
        swipe.delegate = self
        view.addGestureRecognizer(swipe)
    }

    @objc private func handleToolboxSwipe() {
        model.onMain { self.model.showToolbox = true }
    }

    override var canBecomeFirstResponder: Bool { true }

    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake {
            model.onMain { self.model.showToolbox = true }
        }
        super.motionEnded(motion, with: event)
    }

    // MARK: - KVO

    private func observeWebView() {
        observations.append(webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
            guard let self = self else { return }
            self.model.onMain { self.model.progress = webView.estimatedProgress }
        })

        observations.append(webView.observe(\.title, options: [.new]) { [weak self] webView, _ in
            guard let self = self else { return }
            let title = webView.title ?? ""
            self.model.onMain { self.model.pageTitle = title }
        })

        observations.append(webView.observe(\.canGoBack, options: [.new]) { [weak self] webView, _ in
            guard let self = self else { return }
            let canGoBack = webView.canGoBack
            self.model.onMain { self.model.canGoBack = canGoBack }
        })
    }
}

// MARK: - WKNavigationDelegate

extension ShellViewController: WKNavigationDelegate {

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        if model.state == .ready { return }
        model.onMain { self.model.state = .loading }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        model.onMain {
            self.model.state = .ready
            self.model.progress = 1
        }
        webView.scrollView.refreshControl?.endRefreshing()

        if let host = webView.url?.host,
           let matched = domainQueue.first(where: { URL(string: $0)?.host == host }) {
            ShellSettings.shared.adopt(domain: matched)
        }

        // 注入自检：桥没注进去，站点会静默降级成纯网页，表现就是"下载/投屏按钮都不见了"
        webView.evaluateJavaScript(
            "window.H5ShellNativeBridge && window.H5ShellNativeBridge.isAvailable ? 'bridge-ok' : 'bridge-missing'"
        ) { [weak self] value, _ in
            guard let self = self else { return }
            self.model.log("bridge", "注入自检：\(value as? String ?? "nil")")
        }
    }

    func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        handleFailure(error, isProvisional: true)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleFailure(error, isProvisional: false)
    }
}

// MARK: - WKUIDelegate

extension ShellViewController: WKUIDelegate {

    /// target=_blank / window.open：站内跳转留在壳里，站外走 Safari
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            presentExternal(url: url.absoluteString, title: nil)
        }
        return nil
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default) { _ in completionHandler() })
        present(alert, animated: true)
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in completionHandler(true) })
        present(alert, animated: true)
    }
}

// MARK: - UIGestureRecognizerDelegate

extension ShellViewController: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }
}
