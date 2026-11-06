import SwiftUI
import Combine

struct RootView: View {

    @StateObject private var model = ShellModel()
    @StateObject private var downloads = DownloadManager.shared

    var body: some View {
        ZStack(alignment: .top) {
            Palette.canvas.ignoresSafeArea()

            WebContainer(model: model)
                .ignoresSafeArea()

            loadingHairline

            overlay
        }
        .preferredColorScheme(model.colorScheme)
        .onAppear(perform: handleLaunchArguments)
        .sheet(isPresented: $model.showToolbox) {
            ToolboxView(model: model)
        }
        .sheet(isPresented: $model.showDownloads) {
            DownloadListView()
        }
        .sheet(isPresented: $model.showCustomStyle) {
            CustomStyleView(model: model)
        }
        .onReceive(downloads.$managerRequested) { requested in
            guard requested else { return }
            model.showDownloads = true
            downloads.managerRequested = false
        }
    }

    // MARK: - 调试入口

    /// 模拟器里没法摇一摇、也没法双指下滑，外观改动只能靠截图核对。
    /// `xcrun simctl launch <dev> com.wuxiaogang.soujushell -souju-toolbox 1` 启动即开工具箱。
    /// 只存在于 DEBUG 构建，App Store 包里没有这段。
    private func handleLaunchArguments() {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "souju-toolbox") {
            model.showToolbox = true
        }
        #endif
    }

    // MARK: - 顶部进度线

    /// 2px 橙线。设计文档里强调色只有三个用途，这是其中之一（"当前进度"）。
    @ViewBuilder
    private var loadingHairline: some View {
        if model.state == .loading && model.progress < 0.99 {
            GeometryReader { proxy in
                VStack(spacing: 0) {
                    ZStack(alignment: .leading) {
                        Color.clear
                        Rectangle()
                            .fill(Palette.accent)
                            .frame(width: max(0.06, model.progress) * proxy.size.width, height: 2)
                            .animation(.easeOut(duration: 0.25), value: model.progress)
                    }
                    .frame(height: 2)
                    Spacer(minLength: 0)
                }
            }
            .allowsHitTesting(false)
        }
    }

    // MARK: - 覆盖层

    @ViewBuilder
    private var overlay: some View {
        switch model.state {
        case .booting, .loading:
            BootOverlay(domain: model.currentDomain)
                .transition(.opacity)
        case .ready:
            EmptyView()
        case .failed(let message):
            FailOverlay(message: message, model: model)
                .transition(.opacity)
        }
    }
}

// MARK: - 启动页

private struct BootOverlay: View {
    let domain: String

    var body: some View {
        ZStack {
            Palette.canvas.ignoresSafeArea()

            VStack(spacing: 18) {
                Text("搜剧")
                    .font(.system(size: 32, weight: .semibold))
                    .tracking(6)
                    .foregroundColor(Palette.ink)

                Rectangle()
                    .fill(Palette.accent)
                    .frame(width: 28, height: 2)

                Text(domain.isEmpty ? "正在准备线路" : "正在打开 \(hostText)")
                    .font(Typography.mono)
                    .foregroundColor(Palette.inkFaint)
            }
        }
    }

    private var hostText: String {
        URL(string: domain)?.host ?? domain
    }
}

// MARK: - 全线路失败

private struct FailOverlay: View {
    let message: String
    @ObservedObject var model: ShellModel

    var body: some View {
        ZStack {
            Palette.canvas.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                Spacer(minLength: 0)

                Text("线路打不开")
                    .font(Typography.display)
                    .foregroundColor(Palette.ink)

                Text("所有线路都没有响应。站点是域名轮换架构，旧域名随时可能被换掉 —— 在工具箱里填一个新域名通常就好了。")
                    .font(Typography.body)
                    .foregroundColor(Palette.inkMuted)
                    .lineSpacing(4)
                    .padding(.top, 12)

                Text(message)
                    .font(Typography.mono)
                    .foregroundColor(Palette.inkFaint)
                    .lineLimit(2)
                    .padding(.top, 10)

                Button(action: { model.retry() }) {
                    Text("重试")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(Palette.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .padding(.top, 28)

                Button(action: { model.showToolbox = true }) {
                    Text("打开工具箱换线路")
                        .font(Typography.label)
                        .foregroundColor(Palette.inkMuted)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                }
                .padding(.top, 6)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 28)
        }
    }
}
