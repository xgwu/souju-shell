import UIKit

/// 横屏 → 竖屏偶发"不旋转"的补正。
///
/// 壳里没有任何方向控制代码（`Info.plist` 允许竖屏 + 左右横屏，`ShellViewController` 也不做
/// 方向拦截），旋转本该由系统全权处理。实际使用中却偶发：从横屏转回竖屏，界面卡在横屏不动。
/// 诱因都在 UIKit / WebKit 一侧：
///
///  1. 站点「原生全屏」走 `video.webkitEnterFullscreen()`，WebKit 呈现的播放器全屏窗口控制器
///     在收起时可能把 `UIWindowScene` 的几何偏好留在横屏，之后系统不再按设备方向重算；
///  2. `SFSafariViewController`（外链）与 SwiftUI sheet 在横屏下进出，承载控制器的方向状态
///     也可能与设备脱节。
///
/// 这里只补**一种确定不合理**的状态：设备已经竖持（`portrait` / `portraitUpsideDown`），
/// 但场景界面仍是横屏。反方向（界面竖屏、设备横持）刻意不处理 —— 那通常是用户开了竖屏锁定，
/// 替用户"纠正"反而是 bug。
///
/// 所有方法都只在主线程被调用（通知队列为 `.main`，定时任务也在 `DispatchQueue.main`）。
final class RotationGuard {

    static let shared = RotationGuard()

    private weak var controller: UIViewController?
    private var observers: [NSObjectProtocol] = []
    private var pending: DispatchWorkItem?
    private var log: ((String) -> Void)?

    /// 补正之后短暂冷却，避免横竖交界处的连续通知反复触发。
    private var cooldownUntil = Date.distantPast
    /// 当前这次"卡住"已经补过几枪。状态恢复正常时清零；上限 2，防止和系统无限对拉。
    private var mismatchAttempts = 0
    /// 场景掩码此刻是否被收窄成了 `.portrait`。恢复失败（比如这 0.7s 内退到后台）
    /// 会让整个会话退化成"只能竖屏"，所以这个状态必须能被后续任意一次事件兜住。
    private var maskRestricted = false

    private init() {}

    // MARK: - 装配

    func attach(controller: UIViewController, log: ((String) -> Void)? = nil) {
        // 重复装配无意义，且会重复注册通知
        guard observers.isEmpty else { return }

        self.controller = controller
        self.log = log

        // 不开始生成通知，`UIDevice.orientationDidChangeNotification` 根本不会发
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()

        let center = NotificationCenter.default
        for name in [
            UIDevice.orientationDidChangeNotification,
            UIApplication.didBecomeActiveNotification,
            UIWindow.didBecomeVisibleNotification,
            // 退出 WebKit 的播放器全屏时 app 不会回前台（全屏窗口是应用内的另一个 window），
            // 但原窗口会重新成为 key —— 这是"退全屏后残留横屏"唯一的抓手。
            UIWindow.didBecomeKeyNotification
        ] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.scheduleCheck(reason: name.rawValue)
            }
            observers.append(token)
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    // MARK: - 判定

    /// 通知到达时先等一拍：正常旋转有 0.3s 左右的转场，抢在转场中间判定会误伤。
    private func scheduleCheck(reason: String) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.reconcile(reason: reason)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    private func reconcile(reason: String) {
        guard let controller,
              let scene = controller.view.window?.windowScene else { return }

        let device = UIDevice.current.orientation
        let interface = scene.interfaceOrientation

        // 只认明确的方向；faceUp / faceDown / unknown（手机平放）不判定
        let devicePortrait = (device == .portrait || device == .portraitUpsideDown)
        let interfaceLandscape = (interface == .landscapeLeft || interface == .landscapeRight)
        let stuck = devicePortrait && interfaceLandscape

        // 连续两枪都补不回来就收手：再打下去是跟系统抢方向盘
        let canRetry = mismatchAttempts < 2 && Date() >= cooldownUntil

        guard stuck, canRetry else {
            // 不补的时候有两件事要做：状态正常就把计数清零；掩码没收尾就还回去
            if !stuck { mismatchAttempts = 0 }
            if maskRestricted, #available(iOS 16.0, *) { restoreMask(on: scene) }
            return
        }

        mismatchAttempts += 1
        cooldownUntil = Date().addingTimeInterval(1.2)

        if #available(iOS 16.0, *) {
            log?("设备竖持、界面仍为横屏，补一次几何更新（\(reason)，第 \(mismatchAttempts) 次）")
            forcePortrait(on: scene)
        } else {
            log?("设备竖持、界面仍为横屏，请求系统重新判定（\(reason)，第 \(mismatchAttempts) 次）")
            // iOS 15 没有 requestGeometryUpdate，只能请系统按当前设备方向重新算一次；
            // 该 API 会尊重竖屏锁定，不会硬掰。
            UIViewController.attemptRotationToDeviceOrientation()
        }

        // 补完再看一眼：转场中被系统忽略的情况是有的，第二轮通常就过了
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { [weak self] in
            self?.reconcile(reason: "retry")
        }
    }

    // MARK: - 补正

    @available(iOS 16.0, *)
    private func forcePortrait(on scene: UIWindowScene) {
        maskRestricted = true

        // 关键：必须把场景的临时掩码收窄到 `.portrait` 才能真正转过去。
        // 直接请求 `.allButUpsideDown` 等于把选择权再交回系统，而系统此刻正是卡住不动的那一方。
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { [weak self] _ in
            DispatchQueue.main.async { self?.restoreMask(on: scene) }
        }

        // 兜底：无论回调来不来，都要把完整掩码还回去。
        // 少这一步，本次运行就会退化成"只能竖屏"——那比不旋转更糟。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            self?.restoreMask(on: scene)
        }
    }

    @available(iOS 16.0, *)
    private func restoreMask(on scene: UIWindowScene) {
        guard maskRestricted else { return }
        maskRestricted = false
        // 此刻设备已是竖持，恢复完整掩码不会引起二次旋转，只是把选择权还给系统
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .allButUpsideDown)) { _ in }
    }
}
