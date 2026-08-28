import SwiftUI
import AppKit

public final class LiveSubtitlesOverlayPanel: NSPanel {

    public static let shared = LiveSubtitlesOverlayPanel()

    private init() {
        let size = NSSize(width: 720, height: 160)

        let hostingView = NSHostingView(
            rootView: LiveSubtitlesView()
        )
        hostingView.frame = NSRect(origin: .zero, size: size)

        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [
                .borderless,
                .nonactivatingPanel
            ],
            backing: .buffered,
            defer: false
        )

        self.contentView = hostingView
        self.level = .floating
        self.isFloatingPanel = true
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = true
        self.isMovableByWindowBackground = true
        self.isReleasedWhenClosed = false
        self.hidesOnDeactivate = false

        self.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary
        ]

        self.animationBehavior = .utilityWindow

        positionAtScreenBottom()
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

    public func positionAtScreenBottom() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            self.center()
            return
        }

        let visibleFrame = screen.visibleFrame
        let panelSize = self.frame.size

        let x = visibleFrame.midX - panelSize.width / 2
        let y = visibleFrame.minY + 60 // 距离屏幕底部 60pt

        self.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
