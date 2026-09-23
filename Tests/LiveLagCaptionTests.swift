import Foundation

@main
struct LiveLagCaptionTests {
    static func main() {
        runningShowsTenthsOfASecond()
        catchingUpAddsTheSuffix()
        zeroLagStillShowsANumber()
        print("LiveLagCaptionTests: 3 passed")
    }

    /// 字幕条上要能看见落后多少秒，不能只剩「追赶中」。
    private static func runningShowsTenthsOfASecond() {
        let text = LiveLagCaption.text(lag: 1.56, catchingUp: false)
        expect(text == "1.6 秒", "落后秒数格式不对：\(text)")
    }

    private static func catchingUpAddsTheSuffix() {
        let text = LiveLagCaption.text(lag: 3.96, catchingUp: true)
        expect(
            text == "4.0 秒（追赶中）",
            "3.96 秒追赶中应显示成「4.0 秒（追赶中）」，实际 \(text)"
        )
    }

    private static func zeroLagStillShowsANumber() {
        let text = LiveLagCaption.text(lag: 0, catchingUp: false)
        expect(text == "0.0 秒", "零延迟也应是数字，实际 \(text)")
    }

    private static func expect(_ condition: Bool, _ message: String) {
        guard condition else {
            fatalError("LiveLagCaptionTests failed: \(message)")
        }
    }
}
