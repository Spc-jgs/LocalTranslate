import Foundation

/// 翻译 worker 的三条通道。
nonisolated enum LiveTranslationLane: Equatable, Sendable {
    case preview
    case stable
    case archive
}

/// 对新来的任务，正在跑的活怎么让位。
nonisolated enum LiveTranslationPreempt: Equatable, Sendable {
    /// 正在跑的跑完为止。
    case none
    /// 打断并放回归档队列。
    case requeue
}

/// 三条通道的出队与抢占规则。抽成纯函数，因为 worker 的 HTTP 路径进不了
/// 状态测试，而这些规则正是「整句定稿被 cancel 就永远翻不了页」的不变量。
nonisolated enum LiveTranslationLanePolicy {
    /// 下一步该跑哪条通道。归档只在没有当前讲话时出队。
    static func nextLane(
        liveActivity: Bool,
        hasPreview: Bool,
        hasStable: Bool,
        hasArchive: Bool
    ) -> LiveTranslationLane? {
        if hasPreview { return .preview }
        if hasStable { return .stable }
        if hasArchive, !liveActivity { return .archive }
        return nil
    }

    /// 正在跑的活要不要给新来的让位。
    ///
    /// 整句定稿和当前句预览 in-flight 都不取消：前者 completion 一丢主行
    /// 翻不了页，后者刚要完成就被下一帧识别取消会让字幕只剩原文。
    /// 归档可以被抢占并重排。
    static func preempt(
        active: LiveTranslationLane,
        incoming: LiveTranslationLane
    ) -> LiveTranslationPreempt {
        switch active {
        case .stable, .preview:
            return .none
        case .archive:
            return incoming == .archive ? .none : .requeue
        }
    }
}
