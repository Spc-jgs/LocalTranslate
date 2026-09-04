import Foundation

/// 决定字幕行怎么跟着新译文变化。
///
/// 译文到达的节奏由 Ollama 决定，快语速下一秒可能来好几次，而且新一轮常常
/// 把已经显示出来的半句改写掉。照单全收地贴到屏幕上，读者就永远在追一段正在
/// 变形的文字——「读到一半被换掉」正是这么来的。
///
/// 这里只有两条规则：
///
/// - 新译文以已显示的内容开头，就只是往后长，已读的部分一个字不动。这种变化
///   不需要节流，它本来就跟着说话走。
/// - 否则是改写，必须和上一次可见变化隔开最短停留时间。宁可让字幕晚半秒，
///   也不要在一秒里抖两次。
///
/// 被压住的那次不会丢：调用方留着它，下一次识别回调（讲话时每 50-100 ms 一次）
/// 会重新评估，静音时由 flush 兜底。所以这里不持有定时器。
nonisolated struct LiveCaptionPresenter {
    /// 一条字幕至少要留多久才允许被改写。
    ///
    /// 原先是固定 700 ms，两处都不对：它比 Netflix 的 5/6 秒（833 ms）最短
    /// 显示时长还短，而且没有跟内容长度挂钩——一条 20 字的译文显示 700 ms，
    /// 按 Netflix 成人内容 20 字/秒的阅读速度上限只够读 14 字，读不完就被换掉。
    ///
    /// 改成按已经显示出去的字数算，并保留 833 ms 的地板。BBC 给直播字幕的
    /// 口径更保守（160-180 wpm，约每词 0.33 秒），这里取 Netflix 的速度上限，
    /// 免得把延迟推得太高——实测上屏间隔中位数本来就在 1.9-2.7 秒，这个门槛
    /// 只在密集改写时才真正生效，而那正是最难读的时候。
    static let minimumHoldFloor: Duration = .milliseconds(833)
    static let readingCharactersPerSecond: Double = 20

    static func minimumHold(forDisplayed characters: Int) -> Duration {
        let needed = Duration.milliseconds(
            Int((Double(max(characters, 0)) / readingCharactersPerSecond) * 1_000)
        )
        return max(minimumHoldFloor, needed)
    }

    enum Update: Equatable {
        /// 新译文以已显示内容为前缀，往后追加。已读部分不变。
        case append(String)
        /// 前面的内容被改写了，整行替换，需要淡入。
        case replace(String)
        /// 这次不动屏幕。
        case hold
    }

    static func update(
        displayed: String,
        incoming: String,
        sinceLastChange: Duration,
        minimumHold: Duration
    ) -> Update {
        let incoming = incoming.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !incoming.isEmpty else { return .hold }
        guard !displayed.isEmpty else { return .replace(incoming) }
        guard incoming != displayed else { return .hold }

        if incoming.hasPrefix(displayed) {
            return .append(incoming)
        }
        // 改写，也包括译文变短——不让已经读到的字缩回去，除非它已经停够了。
        guard sinceLastChange >= minimumHold else { return .hold }
        return .replace(incoming)
    }

    /// 把续写结果接回已经显示出去的前缀。
    ///
    /// 让模型接着已有译文往下写（请求末尾放一条 assistant），返回的正常是增量
    /// 部分——已显示的字因此物理上不可能被改写，这是「翻译到一半整段被覆盖」
    /// 唯一的根治办法。但不能假定每个模型都守规矩：有的会把前缀重复一遍，
    /// 有的只重复末尾几个字，所以这里按最长重叠去重再拼。
    static func stitch(prefix: String, continuation: String) -> String {
        let continuation = continuation.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !prefix.isEmpty else { return continuation }
        guard !continuation.isEmpty else { return prefix }

        // 整段重复：模型把前缀又写了一遍。
        if continuation.hasPrefix(prefix) { return continuation }

        // 部分重复：续写的开头和前缀的结尾撞上了。
        let prefixCharacters = Array(prefix)
        let overlapLimit = min(prefixCharacters.count, continuation.count)
        for length in stride(from: overlapLimit, through: 1, by: -1) {
            let tail = String(prefixCharacters.suffix(length))
            if continuation.hasPrefix(tail) {
                return prefix + continuation.dropFirst(length)
            }
        }
        return prefix + continuation
    }

    /// 一句话 commit 之后在字幕条上定格多久。
    ///
    /// 说完一句到下一句的 preview 出现之间通常只有几百毫秒，不定格的话完整
    /// 译文根本来不及被看见——现在它甚至压根不上字幕条，只进历史抽屉。
    ///
    /// 定格期内 preview 上不了屏，所以这个值直接加在延迟上。取 800 ms 是因为
    /// 下一句 preview 本来就要等三个安全词加一次 Ollama 往返，多数情况下自然
    /// 间隔已经够长，定格只在说话不停顿时才真正生效。
    static let commitHoldInterval: Duration = .milliseconds(800)

    /// commit 的句子是否还在定格期内，期内不让 preview 顶掉它。
    static func holdsCommittedCaption(
        sinceCommit: Duration,
        hold: Duration = commitHoldInterval
    ) -> Bool {
        sinceCommit < hold
    }
}
