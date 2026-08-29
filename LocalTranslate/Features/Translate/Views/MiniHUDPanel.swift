import SwiftUI
import AppKit

final class MiniHUDPanel: NSPanel {

    var isPinned = false
    private var displayedAt: Date = .distantPast
    private var globalClickMonitor: Any?

    init<Content: View>(
        content: Content,
        initialSize: NSSize = NSSize(width: 420, height: 180)
    ) {
        let hostingView = NSHostingView(rootView: content)
        hostingView.frame = NSRect(origin: .zero, size: initialSize)

        super.init(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [
                .borderless,
                .nonactivatingPanel
            ],
            backing: .buffered,
            defer: false
        )

        contentView = hostingView
        level = .floating
        isFloatingPanel = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        becomesKeyOnlyIfNeeded = false
        isMovableByWindowBackground = true
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

    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }

    override func resignKey() {
        super.resignKey()

        guard !isPinned else { return }
        guard Date().timeIntervalSince(displayedAt) > 0.35 else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isPinned else { return }
            self.orderOut(nil)
        }
    }

    func positionNearMouse(customSize: NSSize? = nil) {
        let mouseLocation = NSEvent.mouseLocation
        let screens = NSScreen.screens
        let currentScreen = screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main ?? screens.first
        let visibleFrame = currentScreen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        let targetSize = customSize ?? frame.size
        let width = targetSize.width
        let height = targetSize.height

        // 默认放置在鼠标光标右下方 12pt
        var x = mouseLocation.x + 12
        var y = mouseLocation.y - height - 12

        // 右边缘检测：若超出屏幕右侧，则向左弹出
        if x + width > visibleFrame.maxX - 10 {
            x = mouseLocation.x - width - 12
        }

        // 左边缘防越界保护
        if x < visibleFrame.minX + 10 {
            x = visibleFrame.minX + 10
        }

        // 下边缘检测：若超出屏幕底部，则向上弹出
        if y < visibleFrame.minY + 10 {
            y = mouseLocation.y + 16
        }

        // 上边缘防越界保护
        if y + height > visibleFrame.maxY - 10 {
            y = visibleFrame.maxY - height - 10
        }

        setFrame(
            NSRect(x: round(x), y: round(y), width: width, height: height),
            display: true
        )
    }

    func updateHeight(_ newHeight: CGFloat, animated: Bool = false) {
        let oldHeight = frame.height
        guard abs(oldHeight - newHeight) > 1 else { return }

        var newFrame = frame
        newFrame.size.height = newHeight
        newFrame.origin.y += (oldHeight - newHeight)

        let screens = NSScreen.screens
        let currentScreen = screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main ?? screens.first
        if let visibleFrame = currentScreen?.visibleFrame {
            if newFrame.origin.y < visibleFrame.minY + 10 {
                newFrame.origin.y = visibleFrame.minY + 10
            }
            if newFrame.origin.y + newHeight > visibleFrame.maxY - 10 {
                newFrame.origin.y = visibleFrame.maxY - newHeight - 10
            }
        }

        setFrame(newFrame, display: true, animate: animated)
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
