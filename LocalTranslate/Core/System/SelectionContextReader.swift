import AppKit
import Foundation
// kAXTrustedCheckOptionPrompt 在 SDK 里被声明为可变全局变量。
@preconcurrency import ApplicationServices

nonisolated struct SelectionContext: Equatable, Sendable {
    enum CaptureQuality: String, Sendable {
        case surroundingText
        case selectionOnly

        var localizedTitle: String {
            switch self {
            case .surroundingText: return "已读取周围上下文"
            case .selectionOnly: return "仅选中文本"
            }
        }
    }

    let selectedText: String
    let before: String
    let after: String
    let sourceApp: String?
    let captureQuality: CaptureQuality

    var surroundingText: String {
        [before, selectedText, after]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// 选中内容已经作为独立字段传给模型与交接负载；上下文只保留它两侧的文字，
    /// 用标记保住语法位置，避免长选区被重复发送。
    var adjacentText: String {
        guard !before.isEmpty || !after.isEmpty else { return "" }
        return [before, "【选中位置】", after]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

nonisolated enum SelectionContextReader {
    private static let surroundingCharacterLimit = 400

    static func isTrusted(promptIfNeeded: Bool = false) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: promptIfNeeded] as CFDictionary)
    }

    static func read() -> SelectionContext? {
        let sourceApp = NSWorkspace.shared.frontmostApplication?.localizedName
        if let context = readUsingAccessibility(sourceApp: sourceApp) {
            return context
        }
        guard let selected = readUsingClipboardFallback() else { return nil }
        return SelectionContext(
            selectedText: selected,
            before: "",
            after: "",
            sourceApp: sourceApp,
            captureQuality: .selectionOnly
        )
    }

    private static func readUsingAccessibility(sourceApp: String?) -> SelectionContext? {
        guard AXIsProcessTrusted(), let focused = focusedElement(),
              let selected = selectedText(from: focused) else { return nil }
        guard let range = selectedRange(from: focused),
              let totalLength = numberOfCharacters(in: focused),
              let expanded = expandedText(
                  from: focused,
                  selectedRange: range,
                  totalLength: totalLength
              ) else {
            return SelectionContext(
                selectedText: selected,
                before: "",
                after: "",
                sourceApp: sourceApp,
                captureQuality: .selectionOnly
            )
        }

        let parts = split(
            expanded.text,
            selectedLocation: range.location - expanded.range.location,
            selectedLength: range.length
        )
        return SelectionContext(
            selectedText: selected,
            before: parts?.before ?? "",
            after: parts?.after ?? "",
            sourceApp: sourceApp,
            captureQuality: parts == nil ? .selectionOnly : .surroundingText
        )
    }

    private static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system,
            kAXFocusedUIElementAttribute as CFString,
            &value
        ) == .success,
        let value,
        CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private static func selectedText(from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &value
        ) == .success,
        let value else { return nil }
        if let text = value as? String { return clean(text) }
        if let text = value as? NSAttributedString { return clean(text.string) }
        return nil
    }

    private static func selectedRange(from element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &value
        ) == .success,
        let value,
        CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(
            unsafeDowncast(value, to: AXValue.self),
            .cfRange,
            &range
        ) else { return nil }
        return range.location >= 0 && range.length > 0 ? range : nil
    }

    private static func numberOfCharacters(in element: AXUIElement) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXNumberOfCharactersAttribute as CFString,
            &value
        ) == .success else { return nil }
        return (value as? NSNumber)?.intValue
    }

    private static func expandedText(
        from element: AXUIElement,
        selectedRange: CFRange,
        totalLength: Int
    ) -> (text: String, range: CFRange)? {
        let start = max(selectedRange.location - surroundingCharacterLimit, 0)
        let end = min(
            selectedRange.location + selectedRange.length + surroundingCharacterLimit,
            totalLength
        )
        var range = CFRange(location: start, length: max(end - start, 0))
        guard let value = AXValueCreate(.cfRange, &range) else { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            value,
            &result
        ) == .success,
        let text = result as? String else { return nil }
        return (text, range)
    }

    static func split(
        _ expandedText: String,
        selectedLocation: Int,
        selectedLength: Int
    ) -> (before: String, after: String)? {
        let string = expandedText as NSString
        guard selectedLocation >= 0,
              selectedLength > 0,
              selectedLocation + selectedLength <= string.length else { return nil }
        let before = string.substring(
            with: NSRange(location: 0, length: selectedLocation)
        )
        let afterStart = selectedLocation + selectedLength
        let after = string.substring(
            with: NSRange(location: afterStart, length: string.length - afterStart)
        )
        return (clean(before) ?? "", clean(after) ?? "")
    }

    private static func readUsingClipboardFallback() -> String? {
        let pasteboard = NSPasteboard.general
        let previousItems = pasteboard.pasteboardItems?.map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
        }
        let oldChangeCount = pasteboard.changeCount
        sendCopyShortcut()
        let timeout = Date().addingTimeInterval(0.25)
        while pasteboard.changeCount == oldChangeCount && Date() < timeout {
            RunLoop.current.run(
                mode: .default,
                before: Date().addingTimeInterval(0.01)
            )
        }
        let selected = clean(pasteboard.string(forType: .string))
        restorePasteboard(previousItems, to: pasteboard)
        return selected
    }

    private static func sendCopyShortcut() {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let keyDown = CGEvent(
            keyboardEventSource: source,
            virtualKey: 8,
            keyDown: true
        ), let keyUp = CGEvent(
            keyboardEventSource: source,
            virtualKey: 8,
            keyDown: false
        ) else { return }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    private static func restorePasteboard(
        _ items: [[NSPasteboard.PasteboardType: Data]]?,
        to pasteboard: NSPasteboard
    ) {
        pasteboard.clearContents()
        guard let items else { return }
        pasteboard.writeObjects(items.map { values in
            let item = NSPasteboardItem()
            values.forEach { item.setData($0.value, forType: $0.key) }
            return item
        })
    }

    private static func clean(_ text: String?) -> String? {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
