import SwiftUI

/// 设计令牌。
///
/// 来源是资料库那篇 souju-light：**海报优先 / 编辑感 / 单一强调色**。
/// 但站点自身默认是深色（theme-color #071013，localStorage 预设 movie-dark），
/// 所以壳的原生界面以深色为默认底，避免冷启动时闪一下白底 —— 那看起来像坏了。
/// 两个调色板都在这里，亮色那套留给"跟随站点主题"切换时用。
enum Palette {

    // MARK: - 深色（默认，对齐站点 movie-dark）

    /// 画布 #08080A
    static let canvas = Color(hex: 0x08080A)
    /// 卡片 #151518
    static let card = Color(hex: 0x151518)
    /// 分隔线，极轻
    static let hairline = Color(hex: 0x2A2A2E)
    /// 暖白正文 #F4F2EE
    static let ink = Color(hex: 0xF4F2EE)
    /// 次级文字
    static let inkMuted = Color(hex: 0x8A8A8F)
    /// 更弱，仅用于说明
    static let inkFaint = Color(hex: 0x5C5C62)

    // MARK: - 亮色（souju-light 原文）

    static let lightCanvas = Color(hex: 0xFAFAF8)
    static let lightCard = Color(hex: 0xFFFFFF)
    static let lightInk = Color(hex: 0x12100F)

    // MARK: - 强调色

    /// #FF5C35。全应用唯一强调色，只允许出现在三处：
    /// ① 主行动按钮 ② 进度指示线 ③ 选中态标记。
    /// 像素占比控制在 3% 以内 —— 这是那篇设计文档里最重要的约束。
    static let accent = Color(hex: 0xFF5C35)

    /// 危险操作（清理缓存等）用低饱和红，不与主橙抢注意力
    static let danger = Color(hex: 0xE5484D)
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

enum Typography {
    /// 标题：32pt 上限，对应设计文档里"标题最大 32px / 正文最小 10px，比例 3.2×"
    static let display = Font.system(size: 30, weight: .semibold, design: .default)
    static let title = Font.system(size: 20, weight: .semibold)
    static let body = Font.system(size: 15, weight: .regular)
    static let label = Font.system(size: 13, weight: .medium)
    static let caption = Font.system(size: 11, weight: .regular)
    /// 等宽小标签，用于版本号、域名这类"证据性"文本
    static let mono = Font.system(size: 11, weight: .regular, design: .monospaced)
}
