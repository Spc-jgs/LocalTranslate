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

    /// 上下文是从哪条链路拿到的。四条链路的覆盖面完全不同，而「读不到上下文」
    /// 过去只表现为一句笼统的提示，看不出是哪一段断了。把它摆到气泡上，
    /// 换个 App 试一次就知道该修哪条链路——这比事后猜要快得多。
    enum CaptureSource: String, Sendable {
        case nativeTextRange
        case webTextMarker
        case selectionOnly
        case clipboard

        var localizedTitle: String {
            switch self {
            case .nativeTextRange: return "原生文本"
            case .webTextMarker: return "网页文本"
            case .selectionOnly: return "无上下文接口"
            case .clipboard: return "复制兜底"
            }
        }
    }

    let selectedText: String
    let before: String
    let after: String
    let sourceApp: String?
    let captureQuality: CaptureQuality
    let captureSource: CaptureSource

    init(
        selectedText: String,
        before: String,
        after: String,
        sourceApp: String?,
        captureQuality: CaptureQuality,
        captureSource: CaptureSource? = nil
    ) {
        self.selectedText = selectedText
        self.before = before
        self.after = after
        self.sourceApp = sourceApp
        self.captureQuality = captureQuality
        self.captureSource = captureSource
            ?? (captureQuality == .surroundingText
                ? .nativeTextRange
                : .selectionOnly)
    }

    var captureSummary: String {
        "\(captureQuality.localizedTitle) · \(captureSource.localizedTitle)"
    }

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
            captureQuality: .selectionOnly,
            captureSource: .clipboard
        )
    }

    /// 两条上下文链路，覆盖面互不重叠：
    ///
    /// - `AXSelectedTextRange` + `AXStringForRange` 是 AppKit 文本控件的接口，
    ///   备忘录、Xcode、TextEdit 走这条；
    /// - WebKit 与 Chromium 的网页正文**不实现**上面那组属性，它们把位置表达成
    ///   text marker，取文字要走 `AXStringForTextMarkerRange`。
    ///
    /// 只实现前者，等于在浏览器和 PDF 里——也就是实际读东西的地方——永远拿不到
    /// 上下文。两条都失败时才退回只有选区的降级态。
    private static func readUsingAccessibility(sourceApp: String?) -> SelectionContext? {
        guard AXIsProcessTrusted(), let focused = focusedElement(),
              let selected = selectedText(from: focused) else { return nil }

        if let parts = nativeSurroundingText(from: focused) {
            return SelectionContext(
                selectedText: selected,
                before: parts.before,
                after: parts.after,
                sourceApp: sourceApp,
                captureQuality: .surroundingText,
                captureSource: .nativeTextRange
            )
        }

        if let parts = webSurroundingText(from: focused, selected: selected) {
            return SelectionContext(
                selectedText: selected,
                before: parts.before,
                after: parts.after,
                sourceApp: sourceApp,
                captureQuality: .surroundingText,
                captureSource: .webTextMarker
            )
        }

        return SelectionContext(
            selectedText: selected,
            before: "",
            after: "",
            sourceApp: sourceApp,
            captureQuality: .selectionOnly,
            captureSource: .selectionOnly
        )
    }

    private static func nativeSurroundingText(
        from element: AXUIElement
    ) -> (before: String, after: String)? {
        guard let range = selectedRange(from: element),
              let totalLength = numberOfCharacters(in: element),
              let expanded = expandedText(
                  from: element,
                  selectedRange: range,
                  totalLength: totalLength
              ) else { return nil }
        return split(
            expanded.text,
            selectedLocation: range.location - expanded.range.location,
            selectedLength: range.length
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

    // MARK: - WebKit / Chromium text markers

    // 这组属性不在公开 SDK 里，只能按名字取；WebKit 与 Chromium 都实现它们。
    // 每一步都判定返回码，缺任何一环就整条链路让位给降级态——不猜、不硬转。
    private static let selectedTextMarkerRangeAttribute = "AXSelectedTextMarkerRange"
    private static let startMarkerForRangeAttribute =
        "AXStartTextMarkerForTextMarkerRange"
    private static let paragraphRangeForMarkerAttribute =
        "AXParagraphTextMarkerRangeForTextMarker"
    private static let stringForMarkerRangeAttribute = "AXStringForTextMarkerRange"

    /// 用选区所在的**自然段**作为上下文单位。段落既是词义消歧真正需要的范围，
    /// 也省掉了逐个 marker 前后挪 400 次的往返——那样每次分诊都要几百次跨进程
    /// AX 调用，在阅读场景里会明显卡顿。
    private static func webSurroundingText(
        from element: AXUIElement,
        selected: String
    ) -> (before: String, after: String)? {
        guard let host = markerCapableElement(startingAt: element),
              let selectedRange = copyAttribute(
                  host,
                  selectedTextMarkerRangeAttribute
              ),
              let startMarker = copyParameterizedAttribute(
                  host,
                  startMarkerForRangeAttribute,
                  selectedRange
              ),
              let paragraphRange = copyParameterizedAttribute(
                  host,
                  paragraphRangeForMarkerAttribute,
                  startMarker
              ),
              let paragraph = copyParameterizedAttribute(
                  host,
                  stringForMarkerRangeAttribute,
                  paragraphRange
              ) as? String else { return nil }

        return locate(selected, in: paragraph)
    }

    /// 焦点常常落在网页里的具体节点上，而 marker 属性挂在它上层的 web area。
    /// 往上找有限几层，找不到就放弃——不遍历整棵树。
    private static func markerCapableElement(
        startingAt element: AXUIElement
    ) -> AXUIElement? {
        var current: AXUIElement? = element
        var depth = 0
        while let candidate = current, depth < 4 {
            if copyAttribute(candidate, selectedTextMarkerRangeAttribute) != nil {
                return candidate
            }
            current = parent(of: candidate)
            depth += 1
        }
        return nil
    }

    private static func parent(of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXParentAttribute as CFString,
            &value
        ) == .success,
        let value,
        CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private static func copyAttribute(
        _ element: AXUIElement,
        _ name: String
    ) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            name as CFString,
            &value
        ) == .success else { return nil }
        return value
    }

    private static func copyParameterizedAttribute(
        _ element: AXUIElement,
        _ name: String,
        _ parameter: CFTypeRef
    ) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            name as CFString,
            parameter,
            &value
        ) == .success else { return nil }
        return value
    }

    /// 段落文字里定位选区。同一段出现多次时取第一次——before/after 只作上下文，
    /// 取错一次的代价远小于整条链路退化成没有上下文。选区本身另有字段承载，
    /// 所以这里只需要它两侧的文字。
    static func locate(
        _ selected: String,
        in paragraph: String
    ) -> (before: String, after: String)? {
        let normalizedSelection = selected.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalizedSelection.isEmpty else { return nil }
        let text = paragraph as NSString
        let found = text.range(of: normalizedSelection)
        guard found.location != NSNotFound else { return nil }
        return split(
            paragraph,
            selectedLocation: found.location,
            selectedLength: found.length
        )
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
