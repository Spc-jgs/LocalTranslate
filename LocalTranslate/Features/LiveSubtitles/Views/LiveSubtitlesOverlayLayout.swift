import AppKit
import Foundation

/// 字幕条的几何常量。
///
/// 这些数值原先在 `LiveSubtitlesView` 与 `LiveSubtitlesOverlayPanel` 里各写
/// 一份（宽度公式一份、124/250 两个高度各一份），改一处另一处不会跟随。
/// 宽度现在由 Panel 单独持有并在屏幕参数变化时重算，View 只负责填满。
nonisolated enum LiveSubtitlesOverlayLayout {

    static let compactHeight: CGFloat = 124
    static let expandedHeight: CGFloat = 250

    /// 距屏幕底部的初始留白。
    static let bottomInset: CGFloat = 50

    static let cornerRadius: CGFloat = 16

    /// 原文行的最大排版宽度，与字幕条宽度解耦。
    static let sourceLineMaximumWidth: CGFloat = 840
    static let captionMaximumWidth: CGFloat = 600

    static func height(historyExpanded: Bool) -> CGFloat {
        historyExpanded ? expandedHeight : compactHeight
    }

    @MainActor
    static func width(for screen: NSScreen?) -> CGFloat {
        let screenWidth = (screen ?? NSScreen.main ?? NSScreen.screens.first)?
            .visibleFrame.width ?? 1_440

        return min(max(screenWidth * 0.72, 720), 980)
    }
}
