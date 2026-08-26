import SwiftUI
import AppKit

struct CleanTextScrollView: NSViewRepresentable {

    let text: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(
        context: Context
    ) -> NSScrollView {

        let scrollView = NSScrollView()

        // 保留滚动能力，但完全不显示滚动条。
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay

        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        scrollView.verticalScrollElasticity = .automatic
        scrollView.horizontalScrollElasticity = .none

        let textView = NSTextView(
            frame: .zero
        )

        textView.isEditable = false
        textView.isSelectable = true

        textView.isRichText = false
        textView.importsGraphics = false

        textView.drawsBackground = false

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

        if let textContainer =
            textView.textContainer {

            textContainer.widthTracksTextView = true
            textContainer.lineFragmentPadding = 0
        }

        scrollView.documentView = textView

        context.coordinator.textView =
            textView

        context.coordinator.scrollView =
            scrollView

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

        // 强制保持无滚动条。
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false

        guard
            let textView =
                context.coordinator.textView
        else {
            return
        }

        let oldText =
            textView.string

        guard oldText != text else {
            return
        }

        let shouldFollowBottom =
            context.coordinator
                .isNearBottom()

        // Streaming 正常情况下只追加新增文本，
        // 避免每个 token 都重绘全部内容。
        if text.hasPrefix(oldText) {

            let suffix =
                String(
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

            // 重新翻译、清空、切换内容时，
            // 才整体替换。
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

    // MARK: - Text

    private func setFullText(
        _ text: String,
        to textView: NSTextView
    ) {

        let attributed =
            NSAttributedString(
                string: text,
                attributes:
                    textAttributes()
            )

        guard
            let storage =
                textView.textStorage
        else {
            return
        }

        storage.beginEditing()

        storage.setAttributedString(
            attributed
        )

        storage.endEditing()
    }

    private func appendText(
        _ text: String,
        to textView: NSTextView
    ) {

        let attributed =
            NSAttributedString(
                string: text,
                attributes:
                    textAttributes()
            )

        guard
            let storage =
                textView.textStorage
        else {
            return
        }

        storage.beginEditing()

        storage.append(
            attributed
        )

        storage.endEditing()
    }

    private func textAttributes()
        -> [NSAttributedString.Key: Any] {

        let paragraphStyle =
            NSMutableParagraphStyle()

        paragraphStyle.lineSpacing = 5

        return [
            .font:
                NSFont.systemFont(
                    ofSize: 15,
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

        weak var textView:
            NSTextView?

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

            scrollWorkItem?
                .cancel()

            let workItem =
                DispatchWorkItem {
                    [weak self] in

                    self?
                        .textView?
                        .scrollToEndOfDocument(
                            nil
                        )
                }

            scrollWorkItem =
                workItem

            // 将连续的 Streaming 滚动请求合并，
            // 避免高频重绘。
            DispatchQueue.main
                .asyncAfter(
                    deadline:
                        .now() + 0.08,
                    execute:
                        workItem
                )
        }

        deinit {

            scrollWorkItem?
                .cancel()
        }
    }
}
