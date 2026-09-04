import Foundation

@main
struct LiveCaptionPagerTests {
    static func main() {
        pageGrowsInsteadOfCollapsingWhenPlannerCuts()
        turningPageDropsOnlyWhatWasCommitted()
        overlongPageFallsBackToASemanticBoundary()
        overlongPageWithoutPunctuationStillHasACeiling()
        ingestingTheSameSpanTwiceDoesNotDuplicate()
        plannerWindowsAlignWithPagerWordBoundaries()
        pageHoldsAWindowPlusWhatIsSaidWhileItTranslates()
        plannerKeepsWindowsWithinTheTranslationUnitSize()
        print("LiveCaptionPagerTests: 8 passed")
    }

    /// 这是这套东西存在的理由：planner 切走一段不该让主行缩水。
    /// 主行的内容只由分页决定，跟翻译单元的切分无关。
    private static func pageGrowsInsteadOfCollapsingWhenPlannerCuts() {
        var pager = LiveCaptionPager()
        pager.append(finalizedSpans: [span("It knows that you", start: 0, duration: 2)])
        expect(pager.pageText == "It knows that you", "第一段没有原样进入页面")

        pager.append(finalizedSpans: [span("can't make it tonight", start: 2, duration: 2)])
        expect(
            pager.pageText == "It knows that you can't make it tonight",
            "第二段没有接在后面，实得：\(pager.pageText)"
        )
        expect(pager.pageRange?.start == 0, "页面起点不该跟着新段落往后跑")
    }

    /// 翻页只丢掉已经定稿、已经进上一行的那部分，后面说的必须留着。
    private static func turningPageDropsOnlyWhatWasCommitted() {
        var pager = LiveCaptionPager()
        pager.append(finalizedSpans: [span("one two three four", start: 0, duration: 4)])
        pager.turnPage(through: 2)
        expect(
            pager.pageText == "three four",
            "翻页没有从定稿之后接着显示，实得：\(pager.pageText)"
        )
        expect(pager.pageRange?.start ?? 0 >= 2, "翻页后页面起点没有前移")
    }

    /// 定稿迟迟不回来时，页面不能无限长——否则又要靠取词上界硬截，锚点重新漂。
    private static func overlongPageFallsBackToASemanticBoundary() {
        var pager = LiveCaptionPager()
        let text = (0..<22).map { "w\($0)" }.joined(separator: " ")
            + " end, " + (0..<8).map { "t\($0)" }.joined(separator: " ")
        pager.append(finalizedSpans: [span(text, start: 0, duration: 31)])
        expect(
            pager.wordCount <= LiveCaptionPager.maximumPageWords,
            "超长页面没有被裁到上界内，实得 \(pager.wordCount) 词"
        )
        expect(
            pager.pageText.hasPrefix("t0"),
            "没有切在逗号边界之后，实得：\(pager.pageText)"
        )
    }

    private static func overlongPageWithoutPunctuationStillHasACeiling() {
        var pager = LiveCaptionPager()
        let text = (0..<80).map { "w\($0)" }.joined(separator: " ")
        pager.append(finalizedSpans: [span(text, start: 0, duration: 80)])
        expect(
            pager.wordCount == LiveCaptionPager.maximumPageWords,
            "没有标点时上界失效了，实得 \(pager.wordCount) 词"
        )
    }

    private static func ingestingTheSameSpanTwiceDoesNotDuplicate() {
        var pager = LiveCaptionPager()
        let one = span("hello world", start: 0, duration: 2)
        pager.append(finalizedSpans: [one])
        pager.append(finalizedSpans: [one])
        expect(pager.pageText == "hello world", "同一个 span 被重复计入了")
    }

    private static func span(
        _ text: String,
        start: TimeInterval,
        duration: TimeInterval
    ) -> LiveTranscriptSpan {
        LiveTranscriptSpan(
            range: LiveAudioTimeRange(start: start, duration: duration),
            text: text,
            state: .finalized
        )
    }

    private static func expect(_ condition: Bool, _ message: String) {
        if !condition {
            FileHandle.standardError.write(Data("✗ \(message)\n".utf8))
            exit(1)
        }
    }

    /// planner 切窗口和 pager 攒页，各自算了一份词的时间轴。眼下算法一样，
    /// 但那是两份代码——一旦漂移，`turnPage(through:)` 就会多删或少删词：
    /// 主行要么凭空丢内容，要么把已经定过稿的话再显示一遍，而且不会有任何
    /// 报错。这里锁住真正的不变量：**window 消费掉的 + 页面剩下的 = 全部**。
    private static func plannerWindowsAlignWithPagerWordBoundaries() {
        let sentence = "we should ship it today, and then we can look at the "
            + "numbers tomorrow morning before the review meeting starts"
        let source = span(sentence, start: 0, duration: 20)

        var planner = LiveTranslationWindowPlanner()
        var pager = LiveCaptionPager()
        planner.append(finalizedSpans: [source])
        pager.append(finalizedSpans: [source])

        var consumed: [String] = []
        for window in planner.drain(force: true) {
            consumed.append(window.sourceText)
            pager.turnPage(through: window.range.end)
        }

        expect(!consumed.isEmpty, "planner 一个窗口都没切出来，这个用例就没意义了")
        expect(
            pager.isEmpty,
            "所有窗口都定稿之后页面还剩下 \(pager.wordCount) 个词：\(pager.pageText)"
        )

        let normalized = LiveSubtitleSemanticSegmenter.normalize(sentence)
        let rebuilt = LiveSubtitleSemanticSegmenter.normalize(
            consumed.joined(separator: " ")
        )
        expect(
            rebuilt == normalized,
            "窗口拼回来和原文对不上：\(rebuilt)"
        )
    }

    /// 页面上界要容得下「一个 planner 窗口 + 等它定稿回来这段时间新说的话」。
    ///
    /// 余量不够就会频繁裁剪，而裁剪和翻页不一样——它没有上一行更新配套，
    /// 用户只看到主行内容凭空变短。实测余量只有 4 词时，229 秒里裁了 22 次、
    /// 共 255 个词。
    private static func pageHoldsAWindowPlusWhatIsSaidWhileItTranslates() {
        var pager = LiveCaptionPager()
        // planner 的窗口上界是 12 词，先攒满一个窗口的量。
        let window = (0..<12).map { "w\($0)" }.joined(separator: " ")
        pager.append(finalizedSpans: [span(window, start: 0, duration: 4)])

        // 等这个窗口翻译回来的这几秒里又说了十个词。
        let while_translating = (0..<10).map { "t\($0)" }.joined(separator: " ")
        let trimmed = pager.append(
            finalizedSpans: [span(while_translating, start: 4, duration: 3)]
        )
        expect(
            trimmed == 0,
            "一个窗口加十个词就触发了裁剪，说明留给定稿往返的余量不够：裁了 \(trimmed) 词"
        )
    }

    /// 一次静音 flush 会切出好几个窗口。它们可以合并（把 1-2 词的碎窗口并掉），
    /// 但合出来的东西不能没有上界——实测无上界合并产生过 53 词的请求，
    /// 而 15 词以上的句子平均要在屏幕上变 3.24 次，5-9 词的只变 0.78 次。
    ///
    /// 这里守的是 planner 那一侧的不变量：单个窗口本身不会超过翻译单元的大小。
    private static func plannerKeepsWindowsWithinTheTranslationUnitSize() {
        var planner = LiveTranslationWindowPlanner()
        let long = (0..<60).map { "w\($0)" }.joined(separator: " ")
        planner.append(finalizedSpans: [span(long, start: 0, duration: 20)])

        let windows = planner.drain(force: true)
        expect(!windows.isEmpty, "六十个词一个窗口都没切出来")
        for window in windows {
            let count = window.sourceText
                .split(whereSeparator: \Character.isWhitespace).count
            expect(
                count <= 12,
                "单个窗口 \(count) 词，超过了翻译单元的上界"
            )
        }
    }
}
