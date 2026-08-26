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

        // 核心：
        // 完全不存在可见滚动条。
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false

        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay

        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        // 仍然支持触控板 / 鼠标滚轮滚动。
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

        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView

        applyText(
            text,
            to: textView
        )

        return scrollView
    }

    func updateNSView(
        _ scrollView: NSScrollView,
        context: Context
    ) {

        // 防止 AppKit 在某些刷新情况下
        // 又创建 scrollbar。
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false

        guard let textView =
            context.coordinator.textView
        else {
            return
        }

        if textView.string != text {

            applyText(
                text,
                to: textView
            )

            // Streaming 时跟随最新内容。
            DispatchQueue.main.async {

                textView.scrollToEndOfDocument(
                    nil
                )
            }
        }
    }

    private func applyText(
        _ text: String,
        to textView: NSTextView
    ) {

        let paragraphStyle =
            NSMutableParagraphStyle()

        paragraphStyle.lineSpacing = 5

        let attributes:
            [NSAttributedString.Key: Any] = [

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

        let attributedString =
            NSAttributedString(
                string: text,
                attributes: attributes
            )

        textView.textStorage?
            .setAttributedString(
                attributedString
            )
    }

    final class Coordinator {

        weak var textView:
            NSTextView?

        weak var scrollView:
            NSScrollView?
    }
}
