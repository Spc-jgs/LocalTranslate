import SwiftUI
import AppKit

final class FloatingPanel: NSPanel {

    var isPinned = false

    init<Content: View>(
        content: Content,
        size: NSSize = NSSize(
            width: 520,
            height: 320
        )
    ) {

        let hostingView = NSHostingView(
            rootView: content
        )

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

        // 始终位于普通窗口之上
        level = .floating

        isFloatingPanel = true

        // SwiftUI 自己负责背景
        backgroundColor = .clear
        isOpaque = false

        hasShadow = true

        // 允许 SwiftUI 控件获取焦点
        becomesKeyOnlyIfNeeded = false

        // Header 等空白区域可拖动
        isMovableByWindowBackground = true

        // 隐藏之后对象仍然保留
        isReleasedWhenClosed = false

        hidesOnDeactivate = false

        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary
        ]

        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }

    // Esc 始终可以隐藏
    override func cancelOperation(
        _ sender: Any?
    ) {
        orderOut(nil)
    }

    // 点击其他 App：
    //
    // 未钉住 → 自动隐藏
    // 已钉住   → 保持显示
    override func resignKey() {

        super.resignKey()

        guard !isPinned else {
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.orderOut(nil)
        }
    }
}
