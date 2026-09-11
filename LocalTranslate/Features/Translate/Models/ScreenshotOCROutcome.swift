import Foundation

/// 截图 OCR 的结束原因。以前成功、取消、空图、无字都缩成 `nil`，
/// 热键只能静默返回，用户分不清「Esc 了」还是「框了但没字」。
nonisolated enum ScreenshotOCROutcome: Equatable, Sendable {
    case cancelled
    case permissionDenied
    case alreadyCapturing
    case noImage
    case noText
    case recognized(String)

    /// 需要写到翻译面板上的那一句。已经有系统交互的路径保持静默。
    var userMessage: String? {
        switch self {
        case .cancelled, .permissionDenied, .alreadyCapturing, .recognized:
            return nil
        case .noImage:
            return "没有截到画面，请再框选一次。"
        case .noText:
            return "没有识别到文字。换一块对比更清楚的区域再试。"
        }
    }

    /// 识别结果去掉空白后为空，按「没有文字」收口，不当成成功。
    static func normalized(_ text: String) -> ScreenshotOCROutcome {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? .noText : .recognized(trimmed)
    }
}
