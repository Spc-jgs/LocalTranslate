import AppKit
import Foundation

/// 字幕条的几何常量。
///
/// 这些数值原先在 `LiveSubtitlesView` 与 `LiveSubtitlesOverlayPanel` 里各写
/// 一份（宽度公式一份、124/250 两个高度各一份），改一处另一处不会跟随。
/// 宽度现在由 Panel 单独持有并在屏幕参数变化时重算，View 只负责填满。
nonisolated enum LiveSubtitlesOverlayLayout {

    static let expandedHeight: CGFloat = 250

    // MARK: - 折叠高度随字号推导

    /// 译文最多两行，与影视字幕的惯例一致。
    static let captionMaximumLines: CGFloat = 2
    /// 原文行相对译文的字号比例，与 `LiveSubtitlesView` 保持一致。
    static let sourceScale: CGFloat = 0.56
    static let sourceMinimumSize: CGFloat = 14
    /// SF Pro 的行高约为字号的 1.2 倍，留一点余量。
    static let lineHeightFactor: CGFloat = 1.25
    /// 译文与原文之间的间距。
    static let captionSourceSpacing: CGFloat = 3
    /// 工具条留白、译文块的上下内边距与字幕条自身的呼吸空间。
    static let verticalChrome: CGFloat = 38

    /// 折叠态高度。
    ///
    /// 此前是写死的 124pt，而字号可以调到 34：两行译文加一行原文在最大字号下
    /// 需要约 150pt，于是长句被裁掉。高度必须跟着字号走。
    static func compactHeight(
        fontSize: CGFloat
    ) -> CGFloat {

        let captionBlock =
            captionMaximumLines
            * fontSize
            * lineHeightFactor

        let sourceBlock =
            max(fontSize * sourceScale, sourceMinimumSize)
            * lineHeightFactor

        return ceil(
            captionBlock
            + captionSourceSpacing
            + sourceBlock
            + verticalChrome
        )
    }

    /// 距屏幕底部的初始留白。
    static let bottomInset: CGFloat = 50

    static let cornerRadius: CGFloat = 16

    /// 原文行的最大排版宽度，与字幕条宽度解耦。
    static let sourceLineMaximumWidth: CGFloat = 840
    static let captionMaximumWidth: CGFloat = 600

    static func height(
        historyExpanded: Bool,
        fontSize: CGFloat
    ) -> CGFloat {
        historyExpanded
            ? expandedHeight
            : compactHeight(fontSize: fontSize)
    }

    @MainActor
    static func width(for screen: NSScreen?) -> CGFloat {
        let screenWidth = (screen ?? NSScreen.main ?? NSScreen.screens.first)?
            .visibleFrame.width ?? 1_440

        return min(max(screenWidth * 0.72, 720), 980)
    }
}
