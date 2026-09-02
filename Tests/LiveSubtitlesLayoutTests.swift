import AppKit
import Foundation

@main
struct LiveSubtitlesLayoutTests {
    static func main() {
        heightGrowsWithFontSize()
        heightFitsTwoCaptionLinesPlusSourceAtEverySize()
        defaultSizeStaysCloseToTheShippedHeight()
        expandedHeightIgnoresFontSize()
        print("LiveSubtitlesLayoutTests: 4 passed")
    }

    private static let range = AppSettings.liveFontSizeRange

    private static func heightGrowsWithFontSize() {
        var previous: CGFloat = 0
        var size = range.lowerBound
        while size <= range.upperBound {
            let height = LiveSubtitlesOverlayLayout.compactHeight(fontSize: size)
            expect(
                height > previous,
                "height must increase with font size (at \(size)pt)"
            )
            previous = height
            size += AppSettings.liveFontSizeStep
        }
    }

    /// 核心不变量：推导出的高度必须真的放得下它要放的东西。
    ///
    /// 用 TextKit 实测两行译文与一行原文的排版高度，而不是复用布局自己的
    /// 行高系数——否则这条断言只是把公式抄了一遍。
    private static func heightFitsTwoCaptionLinesPlusSourceAtEverySize() {
        var size = range.lowerBound
        while size <= range.upperBound {
            let captionHeight = measure(
                lines: 2,
                fontSize: size,
                weight: .bold
            )
            let sourceHeight = measure(
                lines: 1,
                fontSize: max(
                    size * LiveSubtitlesOverlayLayout.sourceScale,
                    LiveSubtitlesOverlayLayout.sourceMinimumSize
                ),
                weight: .medium
            )
            let needed = captionHeight
                + LiveSubtitlesOverlayLayout.captionSourceSpacing
                + sourceHeight

            let available = LiveSubtitlesOverlayLayout
                .compactHeight(fontSize: size)

            expect(
                available >= needed,
                "\(size)pt: height \(available) cannot fit text \(needed)"
            )
            size += AppSettings.liveFontSizeStep
        }
    }

    /// 默认字号下不应偏离既有观感太多——此前写死的是 124pt。
    private static func defaultSizeStaysCloseToTheShippedHeight() {
        let height = LiveSubtitlesOverlayLayout.compactHeight(
            fontSize: AppSettings.defaultLiveFontSize
        )
        expect(
            abs(height - 124) <= 6,
            "default font size should stay near the previous 124pt, got \(height)"
        )
    }

    /// 抽屉展开时内容是固定字号的历史列表，不随字幕字号变化。
    private static func expandedHeightIgnoresFontSize() {
        let low = LiveSubtitlesOverlayLayout.height(
            historyExpanded: true,
            fontSize: range.lowerBound
        )
        let high = LiveSubtitlesOverlayLayout.height(
            historyExpanded: true,
            fontSize: range.upperBound
        )
        expect(low == high, "expanded height must not depend on font size")
    }

    private static func measure(
        lines: Int,
        fontSize: CGFloat,
        weight: NSFont.Weight
    ) -> CGFloat {
        let font = NSFont.systemFont(ofSize: fontSize, weight: weight)
        let layout = NSLayoutManager()
        return layout.defaultLineHeight(for: font) * CGFloat(lines)
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        guard condition() else {
            fatalError("LiveSubtitlesLayoutTests failed: \(message)")
        }
    }
}
