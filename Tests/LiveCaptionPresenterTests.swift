import Foundation

@main
struct LiveCaptionPresenterTests {
    static func main() {
        growthIsNeverThrottled()
        rewriteWaitsForTheMinimumHold()
        captionNeverShrinksBackWithinTheHold()
        identicalTextDoesNotTouchTheScreen()
        committedCaptionHoldsItsSlot()
        holdScalesWithHowMuchMustBeReread()
        stitchJoinsContinuationOntoWhatIsAlreadyOnScreen()
        print("LiveCaptionPresenterTests: 7 passed")
    }

    /// 往后长不算打断阅读：已读的字一个没动，节流反而让字幕白白落后。
    private static func growthIsNeverThrottled() {
        let update = LiveCaptionPresenter.update(
            displayed: "他说这件事",
            incoming: "他说这件事很重要",
            sinceContentShown: .zero
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
            sinceContentShown: .milliseconds(200)
        )
        expect(tooSoon == .hold, "改写没有等到最短停留时间就上屏了")

        let later = LiveCaptionPresenter.update(
            displayed: "他说这件事很重要",
            incoming: "她认为这件事很关键",
            sinceContentShown: .milliseconds(1_200)
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
            sinceContentShown: .milliseconds(100)
        )
        expect(update == .hold, "字幕在停留期内缩回了")
    }

    private static func identicalTextDoesNotTouchTheScreen() {
        let same = LiveCaptionPresenter.update(
            displayed: "他说这件事",
            incoming: "他说这件事",
            sinceContentShown: .seconds(5)
        )
        expect(same == .hold, "同样的文本又重绘了一次")

        let empty = LiveCaptionPresenter.update(
            displayed: "他说这件事",
            incoming: "   ",
            sinceContentShown: .seconds(5)
        )
        expect(empty == .hold, "空译文把已显示的字幕清掉了")

        let first = LiveCaptionPresenter.update(
            displayed: "",
            incoming: "他说这件事",
            sinceContentShown: .zero
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

    /// 门槛量的是「这次改写要重读多少字」，不是整条字幕的长度。
    ///
    /// Netflix 的 20 字/秒是给预制字幕定的——每条独立读完。主行持续增长、
    /// 读者跟着读，改写时只需要重读公共前缀之后那一段。按整条长度算会把
    /// 延迟顶上去：实测页面上界一放宽，displayLag 的 p90 就从 2.99 秒涨到 5.89 秒。
    private static func holdScalesWithHowMuchMustBeReread() {
        let displayed = String(repeating: "字", count: 40)

        // 只有结尾几个字变了：要重读的少，等一会儿就能换。
        let smallEdit = LiveCaptionPresenter.update(
            displayed: displayed,
            incoming: String(repeating: "字", count: 38) + "改了",
            sinceContentShown: .milliseconds(900)
        )
        expect(
            smallEdit == .replace(String(repeating: "字", count: 38) + "改了"),
            "只改结尾两个字却按整条 40 字的阅读时间在等"
        )

        // 整段换掉：40 字要重读，按 20 字/秒需要两秒。
        let full = "完全换了一种说法"
        expect(
            LiveCaptionPresenter.update(
                displayed: displayed,
                incoming: full,
                sinceContentShown: .milliseconds(900)
            ) == .hold,
            "整段改写只显示 0.9 秒就换掉了"
        )
        expect(
            LiveCaptionPresenter.update(
                displayed: displayed,
                incoming: full,
                sinceContentShown: .milliseconds(2_100)
            ) == .replace(full),
            "整段改写等够两秒仍然被压着"
        )

        // 定稿不受门槛约束。
        expect(
            LiveCaptionPresenter.update(
                displayed: displayed,
                incoming: full,
                sinceContentShown: .zero,
                bypassHold: true
            ) == .replace(full),
            "整句定稿被阅读门槛挡住了"
        )
    }
}
