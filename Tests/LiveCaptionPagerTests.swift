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
        print("LiveCaptionPagerTests: 6 passed")
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
        let text = (0..<14).map { "w\($0)" }.joined(separator: " ")
            + " end, " + (0..<8).map { "t\($0)" }.joined(separator: " ")
        pager.append(finalizedSpans: [span(text, start: 0, duration: 23)])
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
        let text = (0..<60).map { "w\($0)" }.joined(separator: " ")
        pager.append(finalizedSpans: [span(text, start: 0, duration: 60)])
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
}
