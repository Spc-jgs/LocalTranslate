import Foundation
import AppKit
// kAXTrustedCheckOptionPrompt 在 SDK 里被声明为可变全局变量。
@preconcurrency import ApplicationServices

enum SelectedTextReader {

    static func isTrusted(promptIfNeeded: Bool = false) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String

        let options = [
            key: promptIfNeeded
        ] as CFDictionary

        return AXIsProcessTrustedWithOptions(options)
    }

    static func read() -> String? {
        // 第一优先：Accessibility API
        if let text = readUsingAccessibility() {
            return text
        }

        // 第二优先：模拟 Command + C
        return readUsingClipboardFallback()
    }

    // MARK: - Accessibility

    private static func readUsingAccessibility() -> String? {
        guard AXIsProcessTrusted() else {
            return nil
        }

        let systemWideElement = AXUIElementCreateSystemWide()

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

        return clean(text)
    }

    // MARK: - Clipboard fallback

    private static func readUsingClipboardFallback() -> String? {
        let pasteboard = NSPasteboard.general

        // 保存用户原来的剪贴板内容
        let previousItems = pasteboard.pasteboardItems?.map { item -> [NSPasteboard.PasteboardType: Data] in
            var values: [NSPasteboard.PasteboardType: Data] = [:]

            for type in item.types {
                if let data = item.data(forType: type) {
                    values[type] = data
                }
            }

            return values
        }

        let oldChangeCount = pasteboard.changeCount

        // 模拟 ⌘C
        sendCopyShortcut()

        // 给当前 App 一点时间处理复制
        let timeout = Date().addingTimeInterval(0.25)

        while pasteboard.changeCount == oldChangeCount && Date() < timeout {
            RunLoop.current.run(
                mode: .default,
                before: Date().addingTimeInterval(0.01)
            )
        }

        let selectedText = clean(
            pasteboard.string(forType: .string)
        )

        // 恢复用户之前的剪贴板
        restorePasteboard(
            previousItems,
            to: pasteboard
        )

        return selectedText
    }

    private static func sendCopyShortcut() {
        let source = CGEventSource(
            stateID: .combinedSessionState
        )

        guard let keyDown = CGEvent(
            keyboardEventSource: source,
            virtualKey: 8, // C
            keyDown: true
        ),
        let keyUp = CGEvent(
            keyboardEventSource: source,
            virtualKey: 8,
            keyDown: false
        ) else {
            return
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    private static func restorePasteboard(
        _ items: [[NSPasteboard.PasteboardType: Data]]?,
        to pasteboard: NSPasteboard
    ) {
        guard let items else {
            return
        }

        pasteboard.clearContents()

        let restoredItems = items.map { values in
            let item = NSPasteboardItem()

            for (type, data) in values {
                item.setData(data, forType: type)
            }

            return item
        }

        pasteboard.writeObjects(restoredItems)
    }

    private static func clean(_ text: String?) -> String? {
        guard let text else {
            return nil
        }

        let trimmed = text.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        return trimmed.isEmpty ? nil : trimmed
    }
}
