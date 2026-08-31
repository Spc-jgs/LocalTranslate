import SwiftUI
import AppKit

public final class LiveSubtitlesOverlayPanel: NSPanel {

    public static let shared = LiveSubtitlesOverlayPanel()

    private var screenObserver: (any NSObjectProtocol)?

    private init() {
        let size = NSSize(
            width: LiveSubtitlesOverlayLayout.width(for: nil),
            height: LiveSubtitlesOverlayLayout.compactHeight
        )

        let hostingView = NSHostingView(
            rootView: LiveSubtitlesView()
        )
        hostingView.frame = NSRect(origin: .zero, size: size)

        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [
                .borderless,
                .nonactivatingPanel,
                .resizable
            ],
            backing: .buffered,
            defer: false
        )

        self.contentView = hostingView
        self.level = .floating
        self.isFloatingPanel = true
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = false
        self.isMovableByWindowBackground = true
        self.isReleasedWhenClosed = false
        self.hidesOnDeactivate = false

        self.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary
        ]

        self.animationBehavior = .none

        positionAtScreenBottom()
        observeScreenChanges()
    }

    deinit {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
    }

    public override var canBecomeKey: Bool {
        true
    }

    public override var canBecomeMain: Bool {
        false
    }

    public func setClickThrough(_ enabled: Bool) {
        self.ignoresMouseEvents = enabled
    }

    public func setHistoryExpanded(_ expanded: Bool) {
        let previousFrame = frame
        setContentSize(
            NSSize(
                width: previousFrame.width,
                height: LiveSubtitlesOverlayLayout.height(
                    historyExpanded: expanded
                )
            )
        )
        setFrameOrigin(
            NSPoint(
                x: previousFrame.midX - frame.width / 2,
                y: previousFrame.minY
            )
        )
    }

    public func positionAtScreenBottom() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            self.center()
            return
        }

        let visibleFrame = screen.visibleFrame

        setContentSize(
            NSSize(
                width: LiveSubtitlesOverlayLayout.width(for: screen),
                height: frame.height
            )
        )

        self.setFrameOrigin(
            NSPoint(
                x: visibleFrame.midX - frame.width / 2,
                y: visibleFrame.minY + LiveSubtitlesOverlayLayout.bottomInset
            )
        )
    }

    /// 分辨率变化、插拔外接显示器都会改变可用宽度。宽度原先只在单例
    /// 初始化时按 `NSScreen.main` 算一次，之后整个进程都不再更新。
    private func observeScreenChanges() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.adjustToCurrentScreen()
            }
        }
    }

    private func adjustToCurrentScreen() {
        let screen = self.screen ?? NSScreen.main ?? NSScreen.screens.first
        let width = LiveSubtitlesOverlayLayout.width(for: screen)

        guard abs(frame.width - width) >= 1 else {
            keepInsideScreen(screen)
            return
        }

        let previousCenterX = frame.midX
        setContentSize(
            NSSize(width: width, height: frame.height)
        )
        setFrameOrigin(
            NSPoint(
                x: previousCenterX - width / 2,
                y: frame.minY
            )
        )
        keepInsideScreen(screen)
    }

    private func keepInsideScreen(_ screen: NSScreen?) {
        guard let screen else { return }

        let visibleFrame = screen.visibleFrame
        var origin = frame.origin

        origin.x = min(
            max(origin.x, visibleFrame.minX),
            max(visibleFrame.maxX - frame.width, visibleFrame.minX)
        )
        origin.y = min(
            max(origin.y, visibleFrame.minY),
            max(visibleFrame.maxY - frame.height, visibleFrame.minY)
        )

        guard origin != frame.origin else { return }
        setFrameOrigin(origin)
    }
}
