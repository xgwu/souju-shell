import SwiftUI
import UIKit

/// 自定义外观编辑器。
///
/// 存在的理由：站点是远端 SPA，改不了它的源码，但可以改它**渲染出来的样子**。
/// 而站点会改版、选择器会变，所以这段配置不能写死在 Swift 里 ——
/// 写死意味着每改一条规则就要重新编译 + 重新签名（免费证书 7 天一次），太重。
/// 放这里：改完即生效，不碰 Xcode。
struct CustomStyleView: View {

    @ObservedObject var model: ShellModel
    @ObservedObject private var settings = ShellSettings.shared
    @Environment(\.dismiss) private var dismiss

    @State private var tab: Int = 0
    @State private var cssDraft: String = ""
    @State private var jsDraft: String = ""
    @State private var enabledDraft: Bool = true
    @State private var rawError: String = ""

    init(model: ShellModel) {
        self.model = model
        // iOS 15 的 TextEditor 背景是 systemBackground，和工具箱的卡片色对不上。
        // 这里统一清掉，让下面的 ZStack 底色透出来。
        UITextView.appearance().backgroundColor = .clear
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    Text("样式 CSS").tag(0)
                    Text("脚本 JS").tag(1)
                }
                .pickerStyle(SegmentedPickerStyle())
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 10)

                editor
                    .padding(.horizontal, 16)

                footer
            }
            .background(Palette.canvas.ignoresSafeArea())
            .navigationTitle("自定义外观")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarLeading) {
                    Button("清空") {
                        if tab == 0 { cssDraft = "" } else { jsDraft = "" }
                    }
                    .foregroundColor(Palette.inkMuted)

                    Button("取消") { dismiss() }
                        .foregroundColor(Palette.inkMuted)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("保存") { save() }
                        .foregroundColor(Palette.accent)
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .onAppear {
            cssDraft = settings.customCSS
            jsDraft = settings.customJS
            enabledDraft = settings.customInjectionEnabled
        }
        .alert(isPresented: Binding(
            get: { !rawError.isEmpty },
            set: { if !$0 { rawError = "" } }
        )) {
            Alert(
                title: Text("脚本有语法错误"),
                message: Text(rawError),
                dismissButton: .default(Text("好"))
            )
        }
    }

    // MARK: - 编辑器

    private var currentBinding: Binding<String> {
        tab == 0 ? $cssDraft : $jsDraft
    }

    private var placeholder: String {
        tab == 0
            ? "/* 例如：\n   body { -webkit-tap-highlight-color: transparent; }\n   #root { font-size: 15px; }\n*/"
            : "// 例如：\n// document.documentElement.style.setProperty('--x', '1')"
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Palette.card)

            if currentBinding.wrappedValue.isEmpty {
                Text(placeholder)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Palette.inkFaint)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 16)
                    .allowsHitTesting(false)
            }

            TextEditor(text: currentBinding)
                .id(tab)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(Palette.ink)
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Palette.hairline, lineWidth: 1)
        )
    }

    // MARK: - 底部说明

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $enabledDraft) {
                Text("启用自定义注入")
                    .font(Typography.body)
                    .foregroundColor(Palette.ink)
            }
            .tint(Palette.accent)

            Text(hint)
                .font(Typography.caption)
                .foregroundColor(Palette.inkFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 16)
    }

    private var hint: String {
        if tab == 0 {
            return "站点的 CSP 放行内联样式，这里的规则会直接生效。选择器要对着真实 DOM 写：手机连 Mac 后，Safari → 开发 → 你的 iPhone → 搜剧，用元素检查器取。保存后会刷新一次页面。"
        }
        return "脚本在页面加载完执行一次，前进/后退时重跑。受站点 CSP 限制：不能用 eval / new Function / import，也不能引外部脚本。运行时报错会打到网页 console，用 Safari 开发菜单看。"
    }

    // MARK: - 保存

    private func save() {
        // 语法错必须先拦：解析阶段的错误 try/catch 兜不住，
        // 放过去的话页面上只会"什么都没发生"，用户根本不知道哪一行写错了。
        if let error = CustomInjection.syntaxError(in: jsDraft) {
            tab = 1
            rawError = error
            return
        }

        settings.customCSS = cssDraft
        settings.customJS = jsDraft
        settings.customInjectionEnabled = enabledDraft

        model.applyCustomInjection()
        dismiss()
    }
}
