import SwiftUI

/// SwiftUI ↔ UIKit 的桥。壳本体是 UIKit（WKWebView 那套东西 SwiftUI 包不干净），
/// 原生界面用 SwiftUI 写。这层只做一件事：把 ShellViewController 塞进视图树并保持身份不变。
struct WebContainer: UIViewControllerRepresentable {

    let model: ShellModel

    func makeUIViewController(context: Context) -> ShellViewController {
        ShellViewController(model: model)
    }

    func updateUIViewController(_ uiViewController: ShellViewController, context: Context) {
        // 壳的状态由 ShellModel 单向下发，这里不需要做任何事。
        // 特别注意：不要在这里重建 webView，否则每次界面刷新都会重载页面。
    }
}
