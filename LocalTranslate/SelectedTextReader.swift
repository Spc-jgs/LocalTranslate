import Foundation
import ApplicationServices

enum SelectedTextReader {

    /// 检查辅助功能权限。
    /// promptIfNeeded = true 时，首次会让 macOS 提示用户授权。
    static func isTrusted(promptIfNeeded: Bool = false) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String

        let options = [
            key: promptIfNeeded
        ] as CFDictionary

        return AXIsProcessTrustedWithOptions(options)
    }

    /// 读取当前系统中获得焦点元素的选中文本
    static func read() -> String? {

        guard AXIsProcessTrusted() else {
            return nil
        }

        let systemWideElement = AXUIElementCreateSystemWide()

        // 1. 找当前获得焦点的 UI 元素
        var focusedValue: CFTypeRef?

        let focusedResult = AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        )

        guard focusedResult == .success,
              let focusedValue,
              CFGetTypeID(focusedValue) == AXUIElementGetTypeID()
        else {
            return nil
        }

        let focusedElement = unsafeDowncast(
            focusedValue,
            to: AXUIElement.self
        )

        // 2. 从这个元素读取选中的文字
        var selectedValue: CFTypeRef?

        let selectedResult = AXUIElementCopyAttributeValue(
            focusedElement,
            kAXSelectedTextAttribute as CFString,
            &selectedValue
        )

        guard selectedResult == .success,
              let selectedValue
        else {
            return nil
        }

        let text: String?

        if let string = selectedValue as? String {
            text = string
        } else if let attributedString = selectedValue as? NSAttributedString {
            text = attributedString.string
        } else {
            text = nil
        }

        guard let text else {
            return nil
        }

        let trimmed = text.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        return trimmed.isEmpty ? nil : trimmed
    }
}
