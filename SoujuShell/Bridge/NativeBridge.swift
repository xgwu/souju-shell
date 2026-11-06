import Foundation
import WebKit
import SafariServices

/// 桥的 RPC 路由器。
///
/// 收到的 payload 结构（来自站点 bundle 里的 `.call(module, method, params)`）：
///     { operation_id, module, method, params }
/// 回包走 `window.__nativeReply(operation_id, jsonObj)`。
///
/// 能力清单必须如实上报：站点把 `capabilities.actions` 当作"这个壳支持什么"的唯一依据，
/// 谎报会导致它调用不存在的方法然后静默降级 —— 比不支持更难排查。
final class NativeBridge: NSObject, WKScriptMessageHandler {

    weak var controller: ShellViewController?

    private let model: ShellModel
    private let downloads: DownloadManager

    init(model: ShellModel, downloads: DownloadManager = .shared) {
        self.model = model
        self.downloads = downloads
        super.init()
    }

    // MARK: - 入口

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else {
            model.log("bridge", "收到非字典 payload：\(message.body)")
            return
        }

        let operationID = (body["operation_id"] as? String) ?? (body["operationId"] as? String) ?? ""
        let module = (body["module"] as? String) ?? ""
        let method = (body["method"] as? String) ?? (body["action"] as? String) ?? ""
        let params = (body["params"] as? [String: Any]) ?? (body["payload"] as? [String: Any]) ?? [:]

        // 原始 payload 全文入控制台 —— 下载入参形状没拿到，后面就靠这条日志对齐
        model.log("← \(module).\(method)", Self.prettyJSON(body), isRaw: true)

        switch (module, method) {

        case ("app", "getCapabilities"):
            let caps = capabilities()
            model.log("→ capabilities", Self.prettyJSON(caps))
            reply(operationID, caps)

        case ("app", "getSystemInsets"):
            reply(operationID, systemInsets())

        case ("app", "ready"), ("app", "ping"):
            reply(operationID, ["ok": true])

        case ("statusBar", "setStyle"):
            let style = (params["style"] as? String) ?? (params["value"] as? String) ?? ""
            model.applyStatusBarStyle(style)
            model.log("statusBar", "style = \(style)")
            reply(operationID, ["ok": true, "style": style])

        case ("browser", "openExternalURL"), ("app", "openExternalBrowser"):
            let url = (params["url"] as? String) ?? ""
            let title = params["title"] as? String
            controller?.presentExternal(url: url, title: title)
            reply(operationID, ["ok": true, "opened": true, "mode": "external", "url": url])

        // MARK: 下载

        case ("download", "enqueue"):
            let result = downloads.enqueue(params)
            reply(operationID, result)

        case ("download", "existsBatch"):
            reply(operationID, downloads.existsBatch(params))

        case ("download", "getState"):
            reply(operationID, downloads.stateSnapshot())

        case ("download", "play"):
            let result = downloads.play(params)
            if result["ok"] as? Bool == true,
               let taskID = result["taskId"] as? String,
               let task = downloads.task(with: taskID) {
                controller?.presentPlayer(for: task)
            }
            reply(operationID, result)

        case ("download", "showManager"):
            downloads.requestManager()
            reply(operationID, ["ok": true])

        case ("download", "storeCover"):
            reply(operationID, downloads.storeCover(params))

        // MARK: 投屏 / 原生播放器

        case ("cast", "openAirPlayRoutePicker"),
             ("playback", "openAirPlayRoutePicker"):
            controller?.presentAirPlayPicker()
            reply(operationID, ["ok": true, "accepted": true, "state": "done"])

        case ("cast", "getState"):
            reply(operationID, [
                "ok": true,
                "state": "idle",
                "connected": false,
                "devices": [],
                "route": ["name": "", "type": "none"]
            ])

        case ("playback", "getNativePlayerState"):
            // 未启用原生播放器，明确回空态而不是 undefined
            reply(operationID, ["ok": true, "state": "idle", "nativePlayer": NSNull()])

        default:
            model.log("bridge", "未实现：\(module).\(method)")
            reply(operationID, [
                "ok": false,
                "code": "NOT_IMPL",
                "message": "\(module).\(method) 未实现"
            ])
        }
    }

    // MARK: - 能力协商

    /// 形状对齐站点 `Iv()` / `Rx()` 的解析：
    ///   platform 必须是 "ios" 才进 iOS 分支
    ///   actions 是白名单，站点用 includes("download.enqueue") 这类判断
    ///   nativePlayer.supportsNativePlayer=false → 站点判为 legacy_app，回落到自带 H5 播放器
    func capabilities() -> [String: Any] {
        var actions: [String] = [
            "app.getSystemInsets",
            "statusBar.setStyle",
            "browser.openExternalURL",
            "app.openExternalBrowser"
        ]

        if ShellSettings.shared.downloadEnabled {
            actions += [
                "download.enqueue",
                "download.existsBatch",
                "download.getState",
                "download.play",
                "download.showManager",
                "download.storeCover"
            ]
        }

        return [
            "platform": "ios",
            "actions": actions,
            "aimovieNativeClientVersion": ShellConfig.aimovieNativeClientVersion,
            "nativePlayer": [
                "supportsNativePlayer": ShellConfig.supportsNativePlayer,
                "profile": ShellConfig.nativePlayerProfile
            ],
            "download": [
                "supportsOfflineDanmakuSnapshot": false,
                "supportsManager": ShellSettings.shared.downloadEnabled
            ],
            "app": [
                "version": ShellConfig.appVersion,
                "build": ShellConfig.buildNumber,
                "bridge": BridgeScript.version
            ]
        ]
    }

    private func systemInsets() -> [String: Any] {
        let insets = controller?.view.safeAreaInsets ?? .zero
        // 站点当前的解析器只认 platform == "android"，iOS 会走 CSS env(safe-area-inset-*)。
        // 仍然如实回传，方便后续站点补 iOS 分支。
        return [
            "platform": "ios",
            "top": Double(insets.top),
            "right": Double(insets.right),
            "bottom": Double(insets.bottom),
            "left": Double(insets.left),
            "edgeToEdge": true
        ]
    }

    // MARK: - 回包 / 事件

    func reply(_ operationID: String, _ payload: [String: Any]) {
        guard !operationID.isEmpty else { return }
        guard let json = Self.jsonString(payload) else { return }
        let js = "window.__nativeReply(\(Self.quote(operationID)), \(json));"
        evaluate(js)
    }

    /// 壳 → 网页事件，对齐站点监听的 CustomEvent("h5shell:native-event")
    func emit(_ name: String, payload: [String: Any]) {
        guard let json = Self.jsonString(payload) else { return }
        let js = "window.__nativeEvent && window.__nativeEvent(\(Self.quote(name)), \(json));"
        evaluate(js)
    }

    private func evaluate(_ js: String) {
        DispatchQueue.main.async { [weak self] in
            self?.controller?.webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    // MARK: - JSON 工具

    static func jsonString(_ object: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(object) else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: []) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func prettyJSON(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return String(describing: object)
        }
        return text
    }

    /// 安全地把 Swift String 变成 JS 双引号字面量
    static func quote(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}
