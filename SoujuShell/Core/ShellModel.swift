import Foundation
import SwiftUI
import os

/// 壳的单一状态源。UIKit 层（ShellViewController）写，SwiftUI 层（RootView）读。
///
/// 刻意不加 `@MainActor`：这类标注在 Swift 5.5–5.7 上会让
/// `@StateObject var model = ShellModel()` 的属性初始化报隔离错误。
/// 改为约定——所有写入都发生在主线程（WKScriptMessageHandler 与导航回调本身就在主线程），
/// 唯一可能越界的下载进度用 `onMain` 兜底。
final class ShellModel: ObservableObject {

    enum LoadState: Equatable {
        case booting          // 冷启动，还没发起导航
        case loading          // 正在拉页面
        case ready            // 页面已就绪
        case failed(String)   // 全部线路都挂了
    }

    struct ConsoleEntry: Identifiable, Equatable {
        let id = UUID()
        let time: Date
        let module: String
        let text: String
        /// 桥收到的原始 payload，用于对齐协议形状
        let isRaw: Bool
    }

    // MARK: - 对外状态

    @Published var state: LoadState = .booting
    @Published var progress: Double = 0
    @Published var pageTitle: String = ""
    @Published var currentDomain: String = ""
    @Published var canGoBack: Bool = false
    @Published var colorScheme: ColorScheme = .dark

    /// 是否处于"跟着站点主题走"的状态。关闭后固定深色。
    @Published var followsSiteTheme: Bool = true

    // MARK: - 面板

    @Published var showToolbox = false
    @Published var showDownloads = false
    @Published var showConsole = false
    @Published var showCustomStyle = false
    @Published var consoleEntries: [ConsoleEntry] = []

    /// 正在播放的离线剧集（非 nil 就 present 原生播放器）
    @Published var playingTask: DownloadTask?

    // MARK: - 内部

    weak var controller: ShellViewController?

    func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
    }

    // MARK: - 日志

    /// 三路输出，各有用处：
    ///   1. 内存 —— 工具箱里的「桥日志」列表，现场看
    ///   2. 系统日志 —— `log stream --predicate 'subsystem == "com.wuxiaogang.soujushell"'`
    ///   3. 文件 —— Documents/bridge.log，能用「文件」App 或 Finder 拷出来
    /// 第 3 路是为了排查 `download.enqueue` 入参这类没有文档的协议：
    /// 真机点一次下载，把 bridge.log 拉出来，字段名就钉死了。
    private static let osLogger = Logger(
        subsystem: "com.wuxiaogang.soujushell",
        category: "bridge"
    )

    private static let logQueue = DispatchQueue(label: "com.wuxiaogang.soujushell.bridge-log")

    private static let logFileURL: URL = {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return dir.appendingPathComponent("bridge.log")
    }()

    private static let logTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    func log(_ module: String, _ text: String, isRaw: Bool = false) {
        Self.osLogger.debug("[\(module, privacy: .public)] \(text, privacy: .public)")
        let stamp = Self.logTimeFormatter.string(from: Date())
        let line = "\(stamp) [\(module)] \(text)\n"
        Self.logQueue.async { Self.appendToFile(line) }
        onMain {
            self.consoleEntries.append(ConsoleEntry(time: Date(), module: module, text: text, isRaw: isRaw))
            if self.consoleEntries.count > 300 {
                self.consoleEntries.removeFirst(self.consoleEntries.count - 300)
            }
        }
    }

    private static func appendToFile(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        let url = logFileURL
        let fm = FileManager.default

        // 超过 1MB 就截断重来，避免长期使用把沙盒写满
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 1_048_576 {
            try? fm.removeItem(at: url)
        }

        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    func clearConsole() {
        consoleEntries.removeAll()
        Self.logQueue.async {
            try? FileManager.default.removeItem(at: Self.logFileURL)
        }
    }

    // MARK: - 状态栏

    /// 站点通过 `statusBar.setStyle` 传 `{"style": "lightContent" | "darkContent"}`。
    /// lightContent = 白色图标 = 深色界面，反之亦然。
    func applyStatusBarStyle(_ style: String) {
        guard ShellSettings.shared.followSiteTheme else { return }
        let normalized = style.lowercased()
        onMain {
            if normalized.contains("light") {
                if self.colorScheme != .dark { self.colorScheme = .dark }
            } else if normalized.contains("dark") {
                if self.colorScheme != .light { self.colorScheme = .light }
            }
        }
    }

    // MARK: - 指令转发

    func reload() {
        controller?.reloadCurrent()
    }

    func retry() {
        controller?.restartFailover()
    }

    func goBack() {
        controller?.goBack()
    }

    func clearCache() {
        controller?.clearSiteData()
    }

    func load(urlString: String) {
        controller?.load(urlString: urlString)
    }

    func switchTo(domain: String) {
        controller?.forceLoad(domain: domain)
    }

    /// 重新应用自定义 CSS / JS 并刷新页面
    func applyCustomInjection() {
        controller?.applyCustomInjection()
    }

    /// 切主题。两套介质都已在页面里，正常情况只改属性、不刷新；
    /// 只有从「站点原样」切过来（页面里还没有皮肤样式）才需要重建注入。
    func switchSkin(to preset: SkinPreset) {
        controller?.switchSkin(to: preset)
    }

    #if DEBUG
    /// 调试：对站点自带的日/夜按钮发一次真实点击，用来验证「接管 → 桥 → 热切换」整条链路。
    /// 模拟器没法脚本化点按（`simctl` 没有 tap 命令），只能从页面里派发事件。
    func debugTapThemeButton() {
        controller?.debugTapThemeButton()
    }
    #endif
}
