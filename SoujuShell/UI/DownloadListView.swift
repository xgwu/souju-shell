import SwiftUI
import UIKit

/// 离线列表。数据来自 DownloadManager 的沙盒清单，跟网页无关 —— 断网也能打开。
struct DownloadListView: View {

    @ObservedObject private var downloads = DownloadManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 12) {
                    if downloads.tasks.isEmpty {
                        emptyState
                    } else {
                        ForEach(downloads.tasks) { task in
                            taskCard(task)
                        }
                    }
                }
                .padding(16)
            }
            .background(Palette.canvas.ignoresSafeArea())
            .navigationTitle("离线")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") { dismiss() }
                        .foregroundColor(Palette.accent)
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text("还没有离线内容")
                .font(Typography.title)
                .foregroundColor(Palette.ink)
            Text("在剧集页点「下载」，壳会把整集 HLS 分片抓到本地，之后不联网也能看。")
                .font(Typography.body)
                .foregroundColor(Palette.inkMuted)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
        }
        .padding(.horizontal, 20)
        .padding(.top, 60)
    }

    private func taskCard(_ task: DownloadTask) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(task.title)
                        .font(Typography.body)
                        .foregroundColor(Palette.ink)
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        Text(task.state.label)
                            .font(Typography.caption)
                            .foregroundColor(task.state == .failed ? Palette.danger : Palette.inkFaint)
                        if !task.progressText.isEmpty {
                            Text("·")
                                .font(Typography.caption)
                                .foregroundColor(Palette.inkFaint)
                            Text(task.progressText)
                                .font(Typography.caption)
                                .foregroundColor(Palette.inkFaint)
                        }
                    }
                }
                Spacer()
            }

            // 进度：只有进行中才用强调橙，完成态退回灰 —— 强调色不超过三个用途
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.hairline)
                    Capsule()
                        .fill(task.state == .failed ? Palette.danger : Palette.accent)
                        .frame(width: max(0.02, CGFloat(task.progress)) * proxy.size.width)
                }
            }
            .frame(height: 2)
            .opacity(task.state == .completed ? 0.35 : 1)

            HStack(spacing: 10) {
                if task.isPlayable {
                    Button(action: { PlayerPresenter.present(task: task) }) {
                        Text("播放")
                            .font(Typography.label)
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .frame(height: 34)
                            .background(Palette.accent)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(PlainButtonStyle())
                }

                if task.state == .failed || task.state == .queued {
                    Button(action: { downloads.retry(id: task.id) }) {
                        Text(task.state == .failed ? "重试" : "开始")
                            .font(Typography.label)
                            .foregroundColor(Palette.ink)
                            .padding(.horizontal, 14)
                            .frame(height: 34)
                            .overlay(
                                Capsule().stroke(Palette.hairline, lineWidth: 1)
                            )
                    }
                    .buttonStyle(PlainButtonStyle())
                }

                Spacer()

                Button(action: { downloads.remove(id: task.id) }) {
                    Text("删除")
                        .font(Typography.label)
                        .foregroundColor(Palette.inkFaint)
                        .padding(.horizontal, 12)
                        .frame(height: 34)
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(14)
        .background(Palette.card)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - 播放器呈现

/// 从 SwiftUI 里弹 UIKit 播放器。找当前 key window 的最顶层 VC，
/// 这样无论在根视图还是 sheet 里点"播放"都能正常弹出。
enum PlayerPresenter {

    static func present(task: DownloadTask) {
        guard let url = task.entryURL else { return }
        let player = OfflinePlayerController(localURL: url, title: task.title)
        player.modalPresentationStyle = .fullScreen
        topViewController()?.present(player, animated: true)
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap { $0.windows }.first { $0.isKeyWindow }
            ?? scenes.first?.windows.first

        var top = window?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}
