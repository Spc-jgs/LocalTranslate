import SwiftUI
import AppKit

struct CleanTextScrollView: NSViewRepresentable {

    let text: String
    var onCopy: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(
        context: Context
    ) -> NSScrollView {

        let scrollView = NSScrollView()

        // 保留滚动能力，完全不显示滚动条
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay

        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        scrollView.verticalScrollElasticity = .automatic
        scrollView.horizontalScrollElasticity = .none

        let textView = CopyFriendlyTextView(
            frame: .zero
        )

        textView.isEditable = false
        textView.isSelectable = true

        textView.isRichText = false
        textView.importsGraphics = false

        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textColor = .textColor
        textView.insertionPointColor = .controlAccentColor

        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true

        textView.autoresizingMask = [
            .width
        ]

        textView.minSize = .zero

        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )

        textView.textContainerInset = NSSize(
            width: 0,
            height: 0
        )

        if let textContainer = textView.textContainer {
            textContainer.widthTracksTextView = true
            textContainer.lineFragmentPadding = 0
        }

        textView.onCopy = {
            onCopy?()
        }

        scrollView.documentView = textView

        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView

        setFullText(
            text,
            to: textView
        )

        return scrollView
    }

    func updateNSView(
        _ scrollView: NSScrollView,
        context: Context
    ) {

        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false

        guard
            let textView = context.coordinator.textView
        else {
            return
        }

        textView.onCopy = {
            onCopy?()
        }

        let oldText = textView.string

        guard oldText != text else {
            return
        }

        let shouldFollowBottom =
            context.coordinator.isNearBottom()

        // Streaming 时只追加新增内容，避免每个 token 全文重绘
        if text.hasPrefix(oldText) {

            let suffix = String(
                text.dropFirst(
                    oldText.count
                )
            )

            if !suffix.isEmpty {
                appendText(
                    suffix,
                    to: textView
                )
            }

        } else {

            // 清空、重新翻译、切换内容时才整体替换
            setFullText(
                text,
                to: textView
            )
        }

        if shouldFollowBottom {
            context.coordinator
                .scheduleScrollToBottom()
        }
    }

    // MARK: - Full Text

    private func setFullText(
        _ text: String,
        to textView: NSTextView
    ) {

        let attributed = NSAttributedString(
            string: text,
            attributes: textAttributes()
        )

        guard
            let storage = textView.textStorage
        else {
            return
        }

        storage.beginEditing()
        storage.setAttributedString(attributed)
        storage.endEditing()
    }

    // MARK: - Append Text

    private func appendText(
        _ text: String,
        to textView: NSTextView
    ) {

        let attributed = NSAttributedString(
            string: text,
            attributes: textAttributes()
        )

        guard
            let storage = textView.textStorage
        else {
            return
        }

        storage.beginEditing()
        storage.append(attributed)
        storage.endEditing()
    }

    private func textAttributes()
        -> [NSAttributedString.Key: Any] {

        let paragraphStyle =
            NSMutableParagraphStyle()

        paragraphStyle.lineSpacing = 4

        return [
            .font:
                NSFont.systemFont(
                    ofSize: 14,
                    weight: .medium
                ),

            .foregroundColor:
                NSColor.labelColor,

            .paragraphStyle:
                paragraphStyle
        ]
    }

    // MARK: - Coordinator

    final class Coordinator {

        fileprivate weak var textView:
            CopyFriendlyTextView?

        weak var scrollView:
            NSScrollView?

        private var scrollWorkItem:
            DispatchWorkItem?

        func isNearBottom() -> Bool {

            guard
                let scrollView,
                let textView
            else {
                return true
            }

            let visibleBottom =
                scrollView
                    .contentView
                    .bounds
                    .maxY

            let documentBottom =
                textView
                    .bounds
                    .maxY

            return
                documentBottom
                - visibleBottom
                < 50
        }

        func scheduleScrollToBottom() {

            scrollWorkItem?.cancel()

            let workItem =
                DispatchWorkItem {
                    [weak self] in

                    self?
                        .textView?
                        .scrollToEndOfDocument(
                            nil
                        )
                }

            scrollWorkItem = workItem

            DispatchQueue.main
                .asyncAfter(
                    deadline: .now() + 0.08,
                    execute: workItem
                )
        }

        deinit {
            scrollWorkItem?.cancel()
        }
    }
}

// MARK: - Copy Friendly NSTextView

fileprivate final class CopyFriendlyTextView:
    NSTextView {

    var onCopy: (() -> Void)?

    override func copy(
        _ sender: Any?
    ) {

        let selection =
            selectedRange()

        // 有选区：按 NSTextView 默认行为只复制选中内容
        if selection.length > 0 {

            super.copy(sender)
            onCopy?()
            return
        }

        // 没有选区但触发了 Copy：复制完整译文
        guard !string.isEmpty else {
            return
        }

        let pasteboard =
            NSPasteboard.general

        pasteboard.clearContents()

        pasteboard.setString(
            string,
            forType: .string
        )

        onCopy?()
    }
}
