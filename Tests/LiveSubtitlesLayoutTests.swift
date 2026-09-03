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
            let previousHeight = measure(
                lines: 1,
                fontSize: max(
                    size * LiveSubtitlesOverlayLayout.previousScale,
                    LiveSubtitlesOverlayLayout.previousMinimumSize
                ),
                weight: .medium
            )
            let needed = previousHeight
                + LiveSubtitlesOverlayLayout.captionSourceSpacing
                + captionHeight
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

    /// 高度要贴合内容，不能白留一大片空。
    ///
    /// 这条原先写死「贴近 124pt」，于是字幕从两行结构改成三行（多了一行降权的
    /// 上一句）时它就红了——而那次变高是有意的。写死数值只能记住昨天长什么样，
    /// 改成断言「富余不超过 chrome 的预算」才是真正要守的东西。
    private static func defaultSizeStaysCloseToTheShippedHeight() {
        let size = AppSettings.defaultLiveFontSize
        let height = LiveSubtitlesOverlayLayout.compactHeight(fontSize: size)
        let needed = measure(
            lines: 1,
            fontSize: max(
                size * LiveSubtitlesOverlayLayout.previousScale,
                LiveSubtitlesOverlayLayout.previousMinimumSize
            ),
            weight: .medium
        )
            + LiveSubtitlesOverlayLayout.captionSourceSpacing
            + measure(lines: 2, fontSize: size, weight: .bold)
            + LiveSubtitlesOverlayLayout.captionSourceSpacing
            + measure(
                lines: 1,
                fontSize: max(
                    size * LiveSubtitlesOverlayLayout.sourceScale,
                    LiveSubtitlesOverlayLayout.sourceMinimumSize
                ),
                weight: .medium
            )
        let slack = height - needed
        expect(
            slack >= 0 && slack <= LiveSubtitlesOverlayLayout.verticalChrome + 8,
            "折叠高度 \(height) 相对内容 \(needed) 富余 \(slack)，超出留白预算"
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
