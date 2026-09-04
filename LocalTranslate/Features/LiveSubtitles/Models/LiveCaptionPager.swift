import Foundation

/// 主行一次显示哪一段话。
///
/// 主行原先显示的是 `windowPlanner.pendingSourceText + volatile`，于是 planner
/// 每切走一段（12 词一切），主行的源文本就骤然只剩 volatile，译文从 38 字缩成
/// 6 字——实测 178 秒里 23 次变短、平均掉 13.7 字、最大掉 35 字，每一次骤降
/// 前面都跟着一条 planner drain。
///
/// 可是 planner 的切分是「翻译单元」，和「一屏该显示到哪」本来无关。让这两件
/// 事共用一个边界，就等于把翻译的内部节奏直接摊到用户眼前。
///
/// 这里给主行自己攒一页：finalized 的词持续累积，只在两种时候翻页——
///
/// - 整句定稿并进了上一行：翻页和上一行更新同时发生，用户看到的是「这句说完了，
///   换下一句」，而不是内容凭空缩水；
/// - 攒得太长：给一个上界，否则一直没有定稿回来时主行会无限增长，
///   最终又要靠 `previewAnchor` 截断，锚点重新开始漂。
nonisolated struct LiveCaptionPager: Sendable {
    struct Word: Sendable, Equatable {
        let text: String
        let range: LiveAudioTimeRange
    }

    /// 一页最多攒多少词。超过就强制翻页到最近的边界。
    ///
    /// 取 16 而不是贴着 `boundedPreviewCandidate` 的 28 词上界：主行实际送去
    /// 翻译的是「这一页 + 还没定稿的 volatile」，volatile 常有十来个词。留不出
    /// 这段余量，取词就会退回按词数硬截，锚点重新开始漂——上一轮
    /// `anchor bounded=true` 频繁出现正是这个。
    static let maximumPageWords = 16

    private static let boundaryTerminators: Set<Character> = [
        ".", "?", "!", "。", "？", "！", ",", ";", ":", "，", "；", "："
    ]

    private var words: [Word] = []
    private var ingestedSpanIDs: Set<UUID> = []

    var isEmpty: Bool { words.isEmpty }

    var pageText: String {
        words.map(\.text).joined(separator: " ")
    }

    var pageRange: LiveAudioTimeRange? {
        guard let first = words.first, let last = words.last else { return nil }
        return LiveAudioTimeRange(
            start: first.range.start,
            duration: max(last.range.end - first.range.start, 0)
        )
    }

    var wordCount: Int { words.count }

    /// 返回这次因为超上界而被裁掉的词数。
    ///
    /// 裁掉的内容还没定稿、也没进上一行，用户看到它从主行消失却没有去处。
    /// 这是设计上的取舍（否则页面无限增长），但必须能被观测到。
    @discardableResult
    mutating func append(finalizedSpans: [LiveTranscriptSpan]) -> Int {
        for span in finalizedSpans.sorted(by: { $0.range.start < $1.range.start }) {
            guard span.isFinalized,
                  !ingestedSpanIDs.contains(span.id) else { continue }
            ingestedSpanIDs.insert(span.id)
            words.append(contentsOf: Self.timedWords(from: span))
        }
        words.sort { $0.range.start < $1.range.start }
        let before = words.count
        trimToLimit()
        return before - words.count
    }

    /// 这段话已经定稿并进了上一行，主行从它之后重新开始。
    mutating func turnPage(through audioEnd: TimeInterval) {
        words.removeAll { $0.range.end <= audioEnd + 0.01 }
    }

    /// 攒过头时切到最靠前、且剩余不超上界的那个边界，尽量多留上下文。
    mutating func trimToLimit() {
        guard words.count > Self.maximumPageWords else { return }

        var boundaries: [Int] = []
        for (index, word) in words.enumerated() where index + 1 < words.count {
            guard let last = word.text.last else { continue }
            if Self.boundaryTerminators.contains(last) {
                boundaries.append(index + 1)
            }
        }
        if let start = boundaries.first(
            where: { words.count - $0 <= Self.maximumPageWords }
        ) {
            words.removeFirst(start)
            return
        }
        words.removeFirst(words.count - Self.maximumPageWords)
    }

    mutating func reset() {
        words.removeAll(keepingCapacity: false)
        ingestedSpanIDs.removeAll(keepingCapacity: false)
    }

    private static func timedWords(from span: LiveTranscriptSpan) -> [Word] {
        let tokens = span.text
            .split(whereSeparator: \Character.isWhitespace)
            .map(String.init)
        guard !tokens.isEmpty else { return [] }
        let wordDuration = span.range.duration / Double(tokens.count)
        return tokens.enumerated().map { index, token in
            Word(
                text: token,
                range: LiveAudioTimeRange(
                    start: span.range.start + Double(index) * wordDuration,
                    duration: wordDuration
                )
            )
        }
    }
}
