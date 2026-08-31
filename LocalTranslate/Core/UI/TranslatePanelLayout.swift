import AppKit
import Foundation

/// 翻译浮窗的尺寸策略，是窗口高度与内容高度的**唯一**出处。
///
/// 之前 `ContentView` 与 `AppDelegate` 各自实现了一遍行数估算：字符数常量
/// 相同，每行像素却一个 23、一个 24，9 行时已经差出 6pt，且任何一边改常量
/// 另一边都不会跟随。现在两边都调用这里，窗口高度按定义等于
/// 「基础高度 + 内容相对空态的增量」，因此不可能再漂移。
@MainActor
enum TranslatePanelLayout {

    // MARK: - Panel

    static let panelWidth: CGFloat = 520
    static let baseHeight: CGFloat = 390

    // MARK: - Input

    /// 520 - 18*2（mainContent 左右边距）- 10*2（输入框内边距）
    static let inputTextWidth: CGFloat = 464
    static let inputFontSize: CGFloat = 13
    static let inputLineSpacing: CGFloat = 3
    static let inputVerticalPadding: CGFloat = 20
    static let inputMinimumLines = 3
    static let inputMaximumLines = 7

    static func inputHeight(for text: String) -> CGFloat {
        let measured = TextHeightMeasurer.height(
            for: text,
            width: inputTextWidth,
            fontSize: inputFontSize,
            lineSpacing: inputLineSpacing
        )

        return clamp(
            measured,
            lines: inputMinimumLines...inputMaximumLines,
            fontSize: inputFontSize,
            lineSpacing: inputLineSpacing
        ) + inputVerticalPadding
    }

    // MARK: - Translation

    /// 520 - 18*2（mainContent 左右边距）- 12*2（译文区内边距）
    static let translationTextWidth: CGFloat = 460
    static let translationFontSize: CGFloat = 14
    static let translationFontWeight: NSFont.Weight = .medium
    static let translationLineSpacing: CGFloat = 4
    static let translationMinimumHeight: CGFloat = 75
    static let translationMaximumHeight: CGFloat = 230
    /// 尚未产出任何 token 时的占位高度，避免首帧从 0 跳到正文高度。
    static let translationPendingHeight: CGFloat = 90

    static func translationHeight(
        for text: String,
        isTranslating: Bool
    ) -> CGFloat {

        if text.isEmpty {
            return isTranslating
                ? translationPendingHeight
                : translationMinimumHeight
        }

        let measured = TextHeightMeasurer.height(
            for: text,
            width: translationTextWidth,
            fontSize: translationFontSize,
            fontWeight: translationFontWeight,
            lineSpacing: translationLineSpacing
        )

        // 正文下方在流式期间还要放一行「正在生成…」。
        let footnote: CGFloat = isTranslating ? 22 : 0

        return min(
            max(
                measured + 20 + footnote,
                translationMinimumHeight
            ),
            translationMaximumHeight
        )
    }

    // MARK: - Window

    /// 窗口高度 = 基础高度 + 内容相对空态的增量。
    static func panelHeight(
        original: String,
        translated: String,
        isTranslating: Bool
    ) -> CGFloat {

        let inputDelta = inputHeight(for: original)
            - inputHeight(for: "")

        let translationDelta = translationHeight(
            for: translated,
            isTranslating: isTranslating
        ) - translationHeight(
            for: "",
            isTranslating: false
        )

        return baseHeight + inputDelta + translationDelta
    }

    // MARK: - Helpers

    private static func clamp(
        _ height: CGFloat,
        lines range: ClosedRange<Int>,
        fontSize: CGFloat,
        lineSpacing: CGFloat
    ) -> CGFloat {

        let minimum = heightForLines(
            range.lowerBound,
            fontSize: fontSize,
            lineSpacing: lineSpacing
        )

        let maximum = heightForLines(
            range.upperBound,
            fontSize: fontSize,
            lineSpacing: lineSpacing
        )

        return min(max(height, minimum), maximum)
    }

    /// 用同一个测量器换算行数，避免再出现一套独立的「每行多少 pt」常量。
    private static func heightForLines(
        _ lines: Int,
        fontSize: CGFloat,
        lineSpacing: CGFloat
    ) -> CGFloat {

        let placeholder = String(
            repeating: "\n",
            count: max(lines - 1, 0)
        )

        return TextHeightMeasurer.height(
            for: placeholder,
            width: .greatestFiniteMagnitude,
            fontSize: fontSize,
            lineSpacing: lineSpacing
        )
    }
}

/// 划词气泡的尺寸策略。同样是窗口与内容共用的唯一出处。
@MainActor
enum MiniHUDLayout {

    static let panelWidth: CGFloat = 420

    /// header 36 + footer 32 + content 上下边距 24
    static let chromeHeight: CGFloat = 92
    static let minimumPanelHeight: CGFloat = 140
    static let maximumPanelHeight: CGFloat = 450

    /// 420 - 12*2（content 内边距）- 8*2（原文块内边距）
    static let originalTextWidth: CGFloat = 380
    static let originalFontSize: CGFloat = 11
    static let originalMaximumLines = 2
    static let originalVerticalPadding: CGFloat = 18

    /// 420 - 12*2（content 内边距）
    static let translationTextWidth: CGFloat = 396
    static let translationFontSize: CGFloat = 14
    static let translationFontWeight: NSFont.Weight = .medium
    static let translationLineSpacing: CGFloat = 4
    static let translationMinimumHeight: CGFloat = 36
    static let translationMaximumHeight: CGFloat = 340

    static func originalHeight(for text: String) -> CGFloat {
        guard !text.isEmpty else { return 0 }

        let singleLine = TextHeightMeasurer.height(
            for: " ",
            width: originalTextWidth,
            fontSize: originalFontSize
        )

        let measured = TextHeightMeasurer.height(
            for: text,
            width: originalTextWidth,
            fontSize: originalFontSize
        )

        return min(
            measured,
            singleLine * CGFloat(originalMaximumLines)
        ) + originalVerticalPadding
    }

    static func translationHeight(
        for text: String,
        isTranslating: Bool
    ) -> CGFloat {

        guard !text.isEmpty else {
            return translationMinimumHeight
        }

        let measured = TextHeightMeasurer.height(
            for: text,
            width: translationTextWidth,
            fontSize: translationFontSize,
            fontWeight: translationFontWeight,
            lineSpacing: translationLineSpacing
        )

        let footnote: CGFloat = isTranslating ? 18 : 0

        return min(
            max(
                measured + 12 + footnote,
                translationMinimumHeight
            ),
            translationMaximumHeight
        )
    }

    static func panelHeight(
        original: String,
        translated: String,
        isTranslating: Bool
    ) -> CGFloat {

        // 还没有译文时正文区是「正在翻译…」或「等待输入…」占位。
        let bodyHeight = translated.isEmpty
            ? 46
            : translationHeight(
                for: translated,
                isTranslating: isTranslating
            )

        let total = chromeHeight
            + originalHeight(for: original)
            + bodyHeight

        return min(
            max(total, minimumPanelHeight),
            maximumPanelHeight
        )
    }
}
