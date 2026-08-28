import SwiftUI
import AppKit

final class FloatingPanel: NSPanel {

    var isPinned = false
    private var displayedAt: Date = .distantPast
    private var globalClickMonitor: Any?

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

        setupGlobalClickMonitor()
    }

    func markDisplayed() {
        displayedAt = Date()
    }

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }

    // Esc 始终可以隐藏
    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }

    // 点击其他 App 且未钉住时：通过时间阈值与全局点击监听器平滑隐藏
    override func resignKey() {
        super.resignKey()

        guard !isPinned else {
            return
        }

        // 忽略弹出瞬间 (350ms 内) 系统自动派发的焦点丢失事件
        guard Date().timeIntervalSince(displayedAt) > 0.35 else {
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isPinned else { return }
            self.orderOut(nil)
        }
    }

    private func setupGlobalClickMonitor() {
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            guard let self, self.isVisible, !self.isPinned else { return }
            guard Date().timeIntervalSince(self.displayedAt) > 0.35 else { return }

            let mouseLocation = NSEvent.mouseLocation
            if !self.frame.contains(mouseLocation) {
                DispatchQueue.main.async {
                    self.orderOut(nil)
                }
            }
        }
    }

    deinit {
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}
