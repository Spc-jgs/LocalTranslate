import Foundation

@main
struct LiveCaptionPresenterTests {
    static func main() {
        growthIsNeverThrottled()
        rewriteWaitsForTheMinimumHold()
        captionNeverShrinksBackWithinTheHold()
        identicalTextDoesNotTouchTheScreen()
        committedCaptionHoldsItsSlot()
        holdScalesWithHowMuchIsOnScreen()
        stitchJoinsContinuationOntoWhatIsAlreadyOnScreen()
        print("LiveCaptionPresenterTests: 7 passed")
    }

    /// 往后长不算打断阅读：已读的字一个没动，节流反而让字幕白白落后。
    private static func growthIsNeverThrottled() {
        let update = LiveCaptionPresenter.update(
            displayed: "他说这件事",
            incoming: "他说这件事很重要",
            sinceLastChange: .zero,
            minimumHold: LiveCaptionPresenter.minimumHold(forDisplayed: 5)
        )
        expect(
            update == .append("他说这件事很重要"),
            "纯追加被当成改写节流掉了"
        )
    }

    /// 改写要隔开最短停留时间，否则一秒里能抖好几次。
    private static func rewriteWaitsForTheMinimumHold() {
        let tooSoon = LiveCaptionPresenter.update(
            displayed: "他说这件事很重要",
            incoming: "她认为这件事很关键",
            sinceLastChange: .milliseconds(200),
            minimumHold: LiveCaptionPresenter.minimumHold(forDisplayed: 8)
        )
        expect(tooSoon == .hold, "改写没有等到最短停留时间就上屏了")

        let later = LiveCaptionPresenter.update(
            displayed: "他说这件事很重要",
            incoming: "她认为这件事很关键",
            sinceLastChange: .milliseconds(1_200),
            minimumHold: LiveCaptionPresenter.minimumHold(forDisplayed: 8)
        )
        expect(
            later == .replace("她认为这件事很关键"),
            "停留时间已过，改写却仍然被压着"
        )
    }

    /// 模型给出更短的译文时不能让字幕缩回去——读者会以为自己看错了。
    private static func captionNeverShrinksBackWithinTheHold() {
        let update = LiveCaptionPresenter.update(
            displayed: "他说这件事很重要",
            incoming: "他说这件事",
            sinceLastChange: .milliseconds(100),
            minimumHold: LiveCaptionPresenter.minimumHold(forDisplayed: 8)
        )
        expect(update == .hold, "字幕在停留期内缩回了")
    }

    private static func identicalTextDoesNotTouchTheScreen() {
        let same = LiveCaptionPresenter.update(
            displayed: "他说这件事",
            incoming: "他说这件事",
            sinceLastChange: .seconds(5),
            minimumHold: LiveCaptionPresenter.minimumHold(forDisplayed: 5)
        )
        expect(same == .hold, "同样的文本又重绘了一次")

        let empty = LiveCaptionPresenter.update(
            displayed: "他说这件事",
            incoming: "   ",
            sinceLastChange: .seconds(5),
            minimumHold: LiveCaptionPresenter.minimumHold(forDisplayed: 5)
        )
        expect(empty == .hold, "空译文把已显示的字幕清掉了")

        let first = LiveCaptionPresenter.update(
            displayed: "",
            incoming: "他说这件事",
            sinceLastChange: .zero,
            minimumHold: LiveCaptionPresenter.minimumHold(forDisplayed: 0)
        )
        expect(
            first == .replace("他说这件事"),
            "第一句字幕被最短停留时间挡住了"
        )
    }

    /// 说完一句到下一句 preview 之间只有几百毫秒，不定格就根本看不见。
    private static func committedCaptionHoldsItsSlot() {
        expect(
            LiveCaptionPresenter.holdsCommittedCaption(
                sinceCommit: .milliseconds(300)
            ),
            "commit 的整句刚上屏就被 preview 顶掉了"
        )
        expect(
            !LiveCaptionPresenter.holdsCommittedCaption(
                sinceCommit: .seconds(3)
            ),
            "commit 的句子定格之后没有让位"
        )
    }

    private static func expect(_ condition: Bool, _ message: String) {
        if !condition {
            FileHandle.standardError.write(Data("✗ \(message)\n".utf8))
            exit(1)
        }
    }

    /// 让模型接着已有译文写，返回的正常是增量；但不能假定每个模型都守规矩。
    private static func stitchJoinsContinuationOntoWhatIsAlreadyOnScreen() {
        expect(
            LiveCaptionPresenter.stitch(
                prefix: "它知道你",
                continuation: "今晚赶不上会议了。"
            ) == "它知道你今晚赶不上会议了。",
            "正常增量没有接对"
        )

        // 模型把前缀整段重复了一遍。
        expect(
            LiveCaptionPresenter.stitch(
                prefix: "它知道你",
                continuation: "它知道你今晚赶不上会议了。"
            ) == "它知道你今晚赶不上会议了。",
            "整段重复的前缀没有去掉"
        )

        // 只重复了前缀的末尾几个字。
        expect(
            LiveCaptionPresenter.stitch(
                prefix: "它知道你",
                continuation: "道你今晚赶不上会议了。"
            ) == "它知道你今晚赶不上会议了。",
            "部分重叠没有去掉"
        )

        expect(
            LiveCaptionPresenter.stitch(prefix: "", continuation: "它知道你")
                == "它知道你",
            "没有前缀时应当原样返回续写"
        )
        expect(
            LiveCaptionPresenter.stitch(prefix: "它知道你", continuation: "   ")
                == "它知道你",
            "空续写把已显示的字幕清掉了"
        )
    }

    /// 一条字幕能留多久，取决于屏幕上有多少字要读。
    ///
    /// 原先是固定 700 ms，比 Netflix 的 5/6 秒最短显示时长还短，而且不看内容：
    /// 20 字的译文显示 700 ms，按 20 字/秒的阅读上限只够读 14 字。
    private static func holdScalesWithHowMuchIsOnScreen() {
        expect(
            LiveCaptionPresenter.minimumHold(forDisplayed: 0)
                == LiveCaptionPresenter.minimumHoldFloor,
            "空字幕没有落到地板值"
        )
        expect(
            LiveCaptionPresenter.minimumHold(forDisplayed: 10)
                == LiveCaptionPresenter.minimumHoldFloor,
            "短字幕不该低于地板值"
        )

        let long = LiveCaptionPresenter.minimumHold(forDisplayed: 40)
        expect(
            long > LiveCaptionPresenter.minimumHoldFloor,
            "长字幕的停留时间没有跟着内容涨"
        )
        // 40 字按 20 字/秒要读两秒。
        expect(long == .milliseconds(2_000), "停留时间和阅读速度对不上：\(long)")

        // 同样的间隔，短字幕可以换掉，长字幕还得再等。
        let elapsed = Duration.milliseconds(1_200)
        expect(
            LiveCaptionPresenter.update(
                displayed: String(repeating: "字", count: 10),
                incoming: "换成别的说法",
                sinceLastChange: elapsed,
                minimumHold: LiveCaptionPresenter.minimumHold(forDisplayed: 10)
            ) != .hold,
            "短字幕等够了却没让改写通过"
        )
        expect(
            LiveCaptionPresenter.update(
                displayed: String(repeating: "字", count: 40),
                incoming: "换成别的说法",
                sinceLastChange: elapsed,
                minimumHold: LiveCaptionPresenter.minimumHold(forDisplayed: 40)
            ) == .hold,
            "40 字的字幕只显示 1.2 秒就被换掉了"
        )
    }
}
