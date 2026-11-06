import SwiftUI
import UIKit

/// 工具箱。壳是自用的，所以把"能救命的开关"全放在这里：
/// 换线路、清缓存、看桥日志、关掉下载能力。
/// 入口：摇一摇，或双指下滑。不占用网页的任何一个像素。
struct ToolboxView: View {

    @ObservedObject var model: ShellModel
    @ObservedObject private var settings = ShellSettings.shared
    @Environment(\.dismiss) private var dismiss

    @State private var newDomain: String = ""
    @State private var showClearConfirm = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 14) {
                    themeSection
                    domainSection
                    pageSection
                    customSection
                    downloadSection
                    diagnosticsSection
                    dangerSection
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
            .background(Palette.canvas.ignoresSafeArea())
            .navigationTitle("工具箱")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                        .foregroundColor(Palette.accent)
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .sheet(isPresented: $model.showConsole) {
            ConsoleView(model: model)
        }
        .alert(isPresented: $showClearConfirm) {
            Alert(
                title: Text("清理站点数据？"),
                message: Text("会清掉登录态、本地缓存与站点 storage，下次打开需要重新登录。"),
                primaryButton: .destructive(Text("清理")) {
                    model.clearCache()
                    dismiss()
                },
                secondaryButton: .cancel(Text("取消"))
            )
        }
    }

    // MARK: - 主题

    /// 两套皮肤是同一套结构的两种介质，切换只换介质不换结构，所以做成一个开关而不是一组设置：
    /// 深色（墨玉 + 暖白 + 亮橙）是默认，浅色（纸白 + 墨黑 + 橙）给白天的户外用。
    /// 写 `settings.skin` 后重建注入并 reload，登录态与播放进度都在站点侧，不受影响。
    private var themeSection: some View {
        Card(title: "主题", footnote: "即时切换，不重载页面；与站点右上角的日/夜按钮是同一个开关") {
            HStack(spacing: 8) {
                themeOption(.soujuDark, icon: "moon.stars.fill", label: "深色")
                themeOption(.soujuLight, icon: "sun.max.fill", label: "浅色")
            }
            .padding(.vertical, 10)
        }
    }

    private func themeOption(_ skin: SkinPreset, icon: String, label: String) -> some View {
        let selected = settings.activeSkin == skin
        return Button {
            guard settings.skin != skin.rawValue else { return }
            model.switchSkin(to: skin)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                Text(label)
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundColor(selected ? Palette.canvas : Palette.ink)
            .frame(maxWidth: .infinity)
            .frame(height: 42)
            .background(selected ? Palette.ink : Palette.canvas)
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(selected ? Color.clear : Palette.hairline, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(PlainButtonStyle())
    }

    // MARK: - 线路

    private var domainSection: some View {
        Card(title: "线路", footnote: "站点采用域名轮换，某天打不开就换一条") {
            VStack(spacing: 0) {
                ForEach(settings.effectiveDomains, id: \.self) { domain in
                    Button(action: {
                        model.switchTo(domain: domain)
                        dismiss()
                    }) {
                        HStack(spacing: 10) {
                            Circle()
                                .fill(domain == model.currentDomain ? Palette.accent : Palette.hairline)
                                .frame(width: 7, height: 7)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(URL(string: domain)?.host ?? domain)
                                    .font(Typography.body)
                                    .foregroundColor(Palette.ink)
                                Text(domain)
                                    .font(Typography.mono)
                                    .foregroundColor(Palette.inkFaint)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if domain == model.currentDomain {
                                Text("当前")
                                    .font(Typography.caption)
                                    .foregroundColor(Palette.accent)
                            }
                        }
                        .padding(.vertical, 11)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PlainButtonStyle())

                    Divider().overlay(Palette.hairline)
                }

                HStack(spacing: 8) {
                    TextField("https://新域名", text: $newDomain)
                        .font(Typography.mono)
                        .foregroundColor(Palette.ink)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .keyboardType(.URL)
                        .padding(.horizontal, 10)
                        .frame(height: 38)
                        .background(Palette.canvas)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

                    Button(action: openCustomDomain) {
                        Text("打开")
                            .font(Typography.label)
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .frame(height: 38)
                            .background(newDomain.isEmpty ? Palette.hairline : Palette.accent)
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                    .buttonStyle(PlainButtonStyle())
                    .disabled(newDomain.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.vertical, 12)
            }
        }
    }

    private func openCustomDomain() {
        let trimmed = newDomain.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var list = settings.customDomains
        if !list.contains(trimmed) {
            list.insert(trimmed, at: 0)
            settings.customDomains = list
        }
        model.switchTo(domain: trimmed)
        newDomain = ""
        dismiss()
    }

    // MARK: - 页面

    private var pageSection: some View {
        Card(title: "页面") {
            VStack(spacing: 0) {
                ActionRow(title: "重新加载") {
                    model.reload()
                    dismiss()
                }
                Divider().overlay(Palette.hairline)

                ActionRow(
                    title: "返回上一页",
                    subtitle: model.canGoBack ? nil : "已经是最前面",
                    enabled: model.canGoBack
                ) {
                    model.goBack()
                    dismiss()
                }
                Divider().overlay(Palette.hairline)

                ActionRow(title: "复制当前地址", subtitle: model.currentDomain) {
                    UIPasteboard.general.string = model.currentDomain
                    dismiss()
                }
            }
        }
    }

    // MARK: - 外观

    /// 站点是远端 SPA，源码改不了，但它渲染出来的 DOM 可以改。
    /// 规则存在 UserDefaults，改一次即生效 —— 不用重编译、不用重签名。
    private var customSection: some View {
        Card(title: "外观", footnote: "皮肤铺底，自定义样式叠加在上；站点改版后可能需要补选择器") {
            VStack(spacing: 0) {
                ForEach(SkinPreset.allCases) { skin in
                    Button(action: {
                        guard settings.skin != skin.rawValue else { return }
                        settings.chooseSkin(skin)
                        model.applyCustomInjection()
                    }) {
                        HStack(spacing: 10) {
                            Circle()
                                .fill(settings.activeSkin == skin ? Palette.accent : Palette.hairline)
                                .frame(width: 7, height: 7)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(skin.title)
                                    .font(Typography.body)
                                    .foregroundColor(Palette.ink)
                                Text(skin.subtitle)
                                    .font(Typography.caption)
                                    .foregroundColor(Palette.inkFaint)
                            }
                            Spacer()
                            if settings.activeSkin == skin {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(Palette.accent)
                            }
                        }
                        .contentShape(Rectangle())
                        .padding(.vertical, 9)
                    }
                    .buttonStyle(PlainButtonStyle())

                    if skin != SkinPreset.allCases.last {
                        Divider().overlay(Palette.hairline)
                    }
                }

                Divider().overlay(Palette.hairline)

                Toggle(isOn: Binding(
                    get: { settings.customInjectionEnabled },
                    set: { newValue in
                        settings.customInjectionEnabled = newValue
                        model.applyCustomInjection()
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("启用自定义注入")
                            .font(Typography.body)
                            .foregroundColor(Palette.ink)
                        Text(injectionSummary)
                            .font(Typography.caption)
                            .foregroundColor(Palette.inkFaint)
                    }
                }
                .tint(Palette.accent)
                .padding(.vertical, 10)

                Divider().overlay(Palette.hairline)

                ActionRow(
                    title: "编辑样式与脚本",
                    subtitle: settings.hasCustomInjection ? "保存后自动刷新" : "尚未设置"
                ) {
                    let open = { model.showCustomStyle = true }
                    dismiss()
                    // 同一个视图上只能同时存在一个 sheet，先关再开
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: open)
                }
            }
        }
    }

    private var injectionSummary: String {
        let skin = settings.activeSkin
        var parts: [String] = []
        if skin != .none { parts.append("皮肤 \(skin.title)") }
        guard settings.customInjectionEnabled else {
            parts.append("自定义已关闭")
            return parts.joined(separator: " · ")
        }
        let css = settings.customCSS.trimmingCharacters(in: .whitespacesAndNewlines).count
        let js = settings.customJS.trimmingCharacters(in: .whitespacesAndNewlines).count
        if css > 0 { parts.append("CSS \(css) 字") }
        if js > 0 { parts.append("JS \(js) 字") }
        if parts.isEmpty { parts.append("暂无内容") }
        return parts.joined(separator: " · ")
    }

    // MARK: - 离线

    private var downloadSection: some View {
        Card(title: "离线下载", footnote: "关掉后站点会自动隐藏下载入口，需重新加载生效") {
            VStack(spacing: 0) {
                Toggle(isOn: Binding(
                    get: { settings.downloadEnabled },
                    set: { settings.downloadEnabled = $0 }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("启用离线下载")
                            .font(Typography.body)
                            .foregroundColor(Palette.ink)
                        Text("壳向上报 download.* 能力")
                            .font(Typography.caption)
                            .foregroundColor(Palette.inkFaint)
                    }
                }
                .tint(Palette.accent)
                .padding(.vertical, 10)

                Divider().overlay(Palette.hairline)

                ActionRow(
                    title: "打开下载列表",
                    subtitle: "\(DownloadManager.shared.tasks.count) 个任务"
                ) {
                    let open = { model.showDownloads = true }
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: open)
                }
            }
        }
    }

    // MARK: - 诊断

    private var diagnosticsSection: some View {
        Card(title: "诊断", footnote: "桥日志是排查「功能消失」的第一现场") {
            VStack(spacing: 0) {
                Toggle(isOn: Binding(
                    get: { settings.followSiteTheme },
                    set: { settings.followSiteTheme = $0 }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("跟随站点主题")
                            .font(Typography.body)
                            .foregroundColor(Palette.ink)
                        Text("关闭后状态栏固定深色")
                            .font(Typography.caption)
                            .foregroundColor(Palette.inkFaint)
                    }
                }
                .tint(Palette.accent)
                .padding(.vertical, 10)

                Divider().overlay(Palette.hairline)

                ActionRow(
                    title: "桥日志",
                    subtitle: "\(model.consoleEntries.count) 条 · 含原始 payload"
                ) {
                    model.showConsole = true
                }

                Divider().overlay(Palette.hairline)

                HStack {
                    Text("版本")
                        .font(Typography.body)
                        .foregroundColor(Palette.ink)
                    Spacer()
                    Text("壳 \(ShellConfig.appVersion) · 桥 \(BridgeScript.version)")
                        .font(Typography.mono)
                        .foregroundColor(Palette.inkFaint)
                }
                .padding(.vertical, 12)
            }
        }
    }

    // MARK: - 危险操作

    private var dangerSection: some View {
        Card(title: nil) {
            ActionRow(
                title: "清理站点数据",
                subtitle: "白屏、登录态异常时用",
                tint: Palette.danger
            ) {
                showClearConfirm = true
            }
        }
    }
}

// MARK: - 控制台

struct ConsoleView: View {

    @ObservedObject var model: ShellModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if model.consoleEntries.isEmpty {
                        Text("还没有日志。打开一次页面再看。")
                            .font(Typography.body)
                            .foregroundColor(Palette.inkFaint)
                            .padding(.top, 40)
                    }

                    ForEach(model.consoleEntries.reversed()) { entry in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(entry.module)
                                    .font(Typography.mono)
                                    .foregroundColor(entry.isRaw ? Palette.inkFaint : Palette.accent)
                                Text(ConsoleView.timeFormatter.string(from: entry.time))
                                    .font(Typography.mono)
                                    .foregroundColor(Palette.inkFaint)
                            }
                            Text(entry.text)
                                .font(Typography.mono)
                                .foregroundColor(entry.isRaw ? Palette.inkMuted : Palette.ink)
                                .textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Palette.card)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
                .padding(16)
            }
            .background(Palette.canvas.ignoresSafeArea())
            .navigationTitle("桥日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("清空") { model.clearConsole() }
                        .foregroundColor(Palette.inkMuted)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") { dismiss() }
                        .foregroundColor(Palette.accent)
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}

// MARK: - 组件

struct Card<Content: View>: View {

    let title: String?
    let footnote: String?
    let content: Content

    init(title: String?, footnote: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footnote = footnote
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title = title {
                Text(title)
                    .font(Typography.caption)
                    .tracking(1.2)
                    .foregroundColor(Palette.inkFaint)
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
            }

            content
                .padding(.horizontal, 14)

            if let footnote = footnote {
                Text(footnote)
                    .font(Typography.caption)
                    .foregroundColor(Palette.inkFaint)
                    .padding(.horizontal, 14)
                    .padding(.top, 2)
                    .padding(.bottom, 12)
            } else {
                Color.clear.frame(height: 6)
            }
        }
        .background(Palette.card)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct ActionRow: View {

    let title: String
    var subtitle: String?
    var tint: Color = Palette.ink
    var enabled: Bool = true
    var showsChevron: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Typography.body)
                        .foregroundColor(enabled ? tint : Palette.inkFaint)
                    if let subtitle = subtitle {
                        Text(subtitle)
                            .font(Typography.caption)
                            .foregroundColor(Palette.inkFaint)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Palette.inkFaint)
                }
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(!enabled)
    }
}
