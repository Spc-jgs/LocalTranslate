import SwiftUI
import AppKit

final class FloatingPanel: NSPanel {

    init<Content: View>(
        content: Content,
        size: NSSize = NSSize(width: 500, height: 355)
    ) {
        let hostingView = NSHostingView(rootView: content)

        hostingView.frame = NSRect(
            origin: .zero,
            size: size
        )

        super.init(
            contentRect: NSRect(
                origin: .zero,
                size: size
            ),
            styleMask: [
                .borderless,
                .nonactivatingPanel
            ],
            backing: .buffered,
            defer: false
        )

        contentView = hostingView

        // 悬浮在普通窗口之上
        level = .floating

        // 真正的浮动面板
        isFloatingPanel = true

        // 背景由 SwiftUI 自己画
        backgroundColor = .clear
        isOpaque = false

        // macOS 阴影
        hasShadow = true

        // 可以点击 SwiftUI 内部控件
        becomesKeyOnlyIfNeeded = false

        // 可以拖动整个窗口
        isMovableByWindowBackground = true

        // 关闭后对象不释放，后面快捷键还能重新唤起
        isReleasedWhenClosed = false

        // 可以出现在所有桌面
        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary
        ]

        // 小工具式动画
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }

    // 按 Esc
    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }

    // 点击其他 App / 窗口
    override func resignKey() {
        super.resignKey()

        DispatchQueue.main.async { [weak self] in
            self?.orderOut(nil)
        }
    }
}
