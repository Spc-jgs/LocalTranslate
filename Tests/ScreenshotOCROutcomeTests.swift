import Foundation

@main
struct ScreenshotOCROutcomeTests {
    static func main() {
        cancelAndPermissionStaySilent()
        missingImageAndMissingTextExplainTheNextStep()
        recognizedTextHasNoMessage()
        emptyRecognizedTextIsTreatedAsNoText()
        print("ScreenshotOCROutcomeTests: 4 passed")
    }

    /// 取消和权限框已经有系统交互，再弹一句会叠两层。
    private static func cancelAndPermissionStaySilent() {
        expect(
            ScreenshotOCROutcome.cancelled.userMessage == nil,
            "取消截图不该再出一句错误"
        )
        expect(
            ScreenshotOCROutcome.permissionDenied.userMessage == nil,
            "权限拒绝已有系统 Alert"
        )
        expect(
            ScreenshotOCROutcome.alreadyCapturing.userMessage == nil,
            "连按热键正在截图时保持静默"
        )
    }

    /// 空图和无字以前和 Esc 取消混成 nil，用户分不清下一步。
    private static func missingImageAndMissingTextExplainTheNextStep() {
        let noImage = ScreenshotOCROutcome.noImage.userMessage
        expect(noImage != nil, "没截到画面必须有说明")
        expect(
            noImage?.contains("框选") == true,
            "没截到画面要告诉用户再框选：\(noImage ?? "nil")"
        )

        let noText = ScreenshotOCROutcome.noText.userMessage
        expect(noText != nil, "没识别到文字必须有说明")
        expect(
            noText?.contains("文字") == true,
            "没识别到文字要说清是识别问题：\(noText ?? "nil")"
        )
    }

    private static func recognizedTextHasNoMessage() {
        expect(
            ScreenshotOCROutcome.recognized("hello").userMessage == nil,
            "成功识别不该带错误文案"
        )
    }

    /// 识别结果去掉空白后为空，按「没有文字」处理，不能当成成功。
    private static func emptyRecognizedTextIsTreatedAsNoText() {
        expect(
            ScreenshotOCROutcome.normalized("   \n") == .noText,
            "只有空白的识别结果应变成 noText"
        )
        expect(
            ScreenshotOCROutcome.normalized("cache") == .recognized("cache"),
            "有字的结果应原样保留"
        )
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        guard condition() else {
            fatalError("ScreenshotOCROutcomeTests failed: \(message)")
        }
    }
}
