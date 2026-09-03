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
    /// 两次「改写」之间的最短间隔。
    ///
    /// 取值是可读性和滞后之间的直接取舍：调大更好读、字幕更滞后。700 ms 大约是
    /// 一行短字幕能读完的下限，同时不会让改写堆积到静音之后才出现。
    static let minimumHoldInterval: Duration = .milliseconds(700)

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
        minimumHold: Duration = minimumHoldInterval
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
