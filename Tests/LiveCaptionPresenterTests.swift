import Foundation

@main
struct LiveCaptionPresenterTests {
    static func main() {
        growthIsNeverThrottled()
        rewriteWaitsForTheMinimumHold()
        captionNeverShrinksBackWithinTheHold()
        identicalTextDoesNotTouchTheScreen()
        committedCaptionHoldsItsSlot()
        print("LiveCaptionPresenterTests: 5 passed")
    }

    /// 往后长不算打断阅读：已读的字一个没动，节流反而让字幕白白落后。
    private static func growthIsNeverThrottled() {
        let update = LiveCaptionPresenter.update(
            displayed: "他说这件事",
            incoming: "他说这件事很重要",
            sinceLastChange: .zero
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
            sinceLastChange: .milliseconds(200)
        )
        expect(tooSoon == .hold, "改写没有等到最短停留时间就上屏了")

        let later = LiveCaptionPresenter.update(
            displayed: "他说这件事很重要",
            incoming: "她认为这件事很关键",
            sinceLastChange: .milliseconds(800)
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
            sinceLastChange: .milliseconds(100)
        )
        expect(update == .hold, "字幕在停留期内缩回了")
    }

    private static func identicalTextDoesNotTouchTheScreen() {
        let same = LiveCaptionPresenter.update(
            displayed: "他说这件事",
            incoming: "他说这件事",
            sinceLastChange: .seconds(5)
        )
        expect(same == .hold, "同样的文本又重绘了一次")

        let empty = LiveCaptionPresenter.update(
            displayed: "他说这件事",
            incoming: "   ",
            sinceLastChange: .seconds(5)
        )
        expect(empty == .hold, "空译文把已显示的字幕清掉了")

        let first = LiveCaptionPresenter.update(
            displayed: "",
            incoming: "他说这件事",
            sinceLastChange: .zero
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
}
