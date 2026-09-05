import Foundation

/// 旧翻译入口只需要选中文本；实际采集实现位于 Core，供翻译与分诊共同复用。
nonisolated enum SelectedTextReader {
    static func isTrusted(promptIfNeeded: Bool = false) -> Bool {
        SelectionContextReader.isTrusted(promptIfNeeded: promptIfNeeded)
    }

    static func read() -> String? {
        SelectionContextReader.read()?.selectedText
    }
}
