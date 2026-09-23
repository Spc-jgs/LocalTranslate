import Foundation

@main
struct LiveTranslationLanePolicyTests {
    static func main() {
        previewBeatsStableBeatsArchive()
        archiveDoesNotRunWhileSpeechIsLive()
        inFlightStableIsNeverPreempted()
        inFlightPreviewIsNeverPreempted()
        liveActivityPreemptsArchiveAndRequeues()
        print("LiveTranslationLanePolicyTests: 5 passed")
    }

    /// 三条通道的优先级：当前句预览、整句定稿、补历史。
    private static func previewBeatsStableBeatsArchive() {
        expect(
            LiveTranslationLanePolicy.nextLane(
                liveActivity: false,
                hasPreview: true,
                hasStable: true,
                hasArchive: true
            ) == .preview,
            "有预览时不该去跑定稿或归档"
        )
        expect(
            LiveTranslationLanePolicy.nextLane(
                liveActivity: false,
                hasPreview: false,
                hasStable: true,
                hasArchive: true
            ) == .stable,
            "没有预览时应跑整句定稿，不能先归档"
        )
        expect(
            LiveTranslationLanePolicy.nextLane(
                liveActivity: false,
                hasPreview: false,
                hasStable: false,
                hasArchive: true
            ) == .archive,
            "空闲且只有归档时应跑归档"
        )
        expect(
            LiveTranslationLanePolicy.nextLane(
                liveActivity: false,
                hasPreview: false,
                hasStable: false,
                hasArchive: false
            ) == nil,
            "三队都空还应选出任务"
        )
    }

    /// 补历史只在静音或停止后跑，说话时不能占模型。
    private static func archiveDoesNotRunWhileSpeechIsLive() {
        expect(
            LiveTranslationLanePolicy.nextLane(
                liveActivity: true,
                hasPreview: false,
                hasStable: false,
                hasArchive: true
            ) == nil,
            "说话时归档队列不该出队"
        )
    }

    /// 整句定稿被 cancel 后没有 completion，主行会永远翻不了页。
    private static func inFlightStableIsNeverPreempted() {
        expect(
            LiveTranslationLanePolicy.preempt(
                active: .stable,
                incoming: .preview
            ) == .none,
            "预览不该打断正在跑的整句定稿"
        )
        expect(
            LiveTranslationLanePolicy.preempt(
                active: .stable,
                incoming: .archive
            ) == .none,
            "归档不该打断正在跑的整句定稿"
        )
    }

    /// 正在跑的预览也不取消：刚要完成就被下一帧识别取消，字幕会卡在只有原文。
    private static func inFlightPreviewIsNeverPreempted() {
        expect(
            LiveTranslationLanePolicy.preempt(
                active: .preview,
                incoming: .preview
            ) == .none,
            "新预览不该取消正在跑的预览"
        )
        expect(
            LiveTranslationLanePolicy.preempt(
                active: .preview,
                incoming: .stable
            ) == .none,
            "整句定稿不该取消正在跑的预览"
        )
    }

    /// 正在跑的归档可以被抢占并重排，说话一恢复就让位。
    private static func liveActivityPreemptsArchiveAndRequeues() {
        expect(
            LiveTranslationLanePolicy.preempt(
                active: .archive,
                incoming: .preview
            ) == .requeue,
            "预览应打断归档并把它放回队列"
        )
        expect(
            LiveTranslationLanePolicy.preempt(
                active: .archive,
                incoming: .stable
            ) == .requeue,
            "整句定稿应打断归档并把它放回队列"
        )
    }

    private static func expect(_ condition: Bool, _ message: String) {
        guard condition else {
            fatalError("LiveTranslationLanePolicyTests failed: \(message)")
        }
    }
}
