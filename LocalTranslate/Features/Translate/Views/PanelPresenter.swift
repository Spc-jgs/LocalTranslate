import AppKit
import Foundation

/// 翻译浮窗的呈现策略：在哪显示、不许超出哪、高度怎么应用。
///
/// 这些几何原先散在 `AppDelegate` 里，和 App 生命周期、快捷键装配、通知路由
/// 挤在同一个类型中。职责边界其实是清楚的：
/// `TranslatePanelLayout` 回答「多高」，这里回答「在哪、不许超出哪」。
@MainActor
final class PanelPresenter {

    private let panel: FloatingPanel
    private let baseHeight: CGFloat

    /// 最近一次应用过的高度，用于抑制不足一档的抖动。
    private var lastAppliedHeight: CGFloat

    /// 窗口边缘与屏幕可用区域之间保留的距离。
    private static let screenMargin: CGFloat = 16
    /// 跟随鼠标时窗口与光标的间隔。
    private static let mouseGap: CGFloat = 18
    /// 高度变化小于这个值就不重排，避免流式输出时窗口抖动。
    private static let heightChangeThreshold: CGFloat = 8
    /// 取不到屏幕时的兜底高度上限。
    private static let fallbackMaximumHeight: CGFloat = 500

    init(panel: FloatingPanel, baseHeight: CGFloat) {
        self.panel = panel
        self.baseHeight = baseHeight
        self.lastAppliedHeight = baseHeight
    }

    // MARK: - 显示

    /// 在鼠标附近显示。`reposition` 为假且窗口已可见时保持原位。
    func show(reposition: Bool, activateApp: Bool) {
        // 每次显示前先保证窗口尺寸没有超过当前屏幕。
        constrainToVisibleScreen()

        if reposition || !panel.isVisible {
            positionNearMouse()
        }

        bringToFront(activateApp: activateApp)
    }

    /// 在当前屏幕居中显示。
    func showCentered(activateApp: Bool) {
        constrainToVisibleScreen()
        centerOnCurrentScreen()
        bringToFront(activateApp: activateApp)
    }

    private func bringToFront(activateApp: Bool) {
        if activateApp {
            NSApp.activate(ignoringOtherApps: true)
        }

        panel.markDisplayed()
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }

    // MARK: - 高度

    /// 应用内容高度。
    ///
    /// `keepGrowingOnly` 用于流式翻译：每个 token 都重新排版会让窗口来回抖，
    /// 生成过程中只增不减。
    func apply(height requested: CGFloat, keepGrowingOnly: Bool) {
        var desired = requested

        if keepGrowingOnly {
            desired = max(desired, lastAppliedHeight)
        }

        let finalHeight = min(
            max(desired, baseHeight),
            maximumHeight(on: panel.screen ?? currentScreen())
        )

        guard abs(finalHeight - lastAppliedHeight)
            >= Self.heightChangeThreshold else { return }

        lastAppliedHeight = finalHeight
        resize(to: finalHeight)
    }

    // MARK: - 屏幕

    /// 鼠标所在的屏幕优先——用户是在那块屏幕上触发的翻译。
    private func currentScreen() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation

        return NSScreen.screens.first {
            NSMouseInRect(mouseLocation, $0.frame, false)
        }
            ?? panel.screen
            ?? NSScreen.main
    }

    /// 浮窗不该像普通 App 那样把屏幕纵向占满。
    private func maximumHeight(on screen: NSScreen?) -> CGFloat {
        guard let screen else {
            return Self.fallbackMaximumHeight
        }

        // 小屏最多占可用区域约 78%，大屏仍限制在 520pt。
        return min(520, screen.visibleFrame.height * 0.78)
    }

    private func constrainToVisibleScreen() {
        let screen = panel.screen ?? currentScreen()
        guard let screen else { return }

        let maxHeight = maximumHeight(on: screen)
        guard panel.frame.height > maxHeight else { return }

        resize(to: maxHeight)
    }

    // MARK: - 定位

    private func centerOnCurrentScreen() {
        guard let screen = currentScreen() else {
            panel.center()
            return
        }

        let visibleFrame = screen.visibleFrame
        let panelSize = panel.frame.size

        panel.setFrameOrigin(
            NSPoint(
                x: visibleFrame.midX - panelSize.width / 2,
                y: visibleFrame.midY - panelSize.height / 2
            )
        )
    }

    private func positionNearMouse() {
        let mouseLocation = NSEvent.mouseLocation

        guard let screen = currentScreen() else {
            panel.center()
            return
        }

        let visibleFrame = screen.visibleFrame
        let panelSize = panel.frame.size
        let gap = Self.mouseGap
        let margin = Self.screenMargin

        var x = mouseLocation.x + gap
        var y = mouseLocation.y - panelSize.height - gap

        // 右侧放不下就改放鼠标左边。
        if x + panelSize.width > visibleFrame.maxX - margin {
            x = mouseLocation.x - panelSize.width - gap
        }

        // 左侧保护。
        if x < visibleFrame.minX + margin {
            x = visibleFrame.minX + margin
        }

        // 下方放不下就改放鼠标上方。
        if y < visibleFrame.minY + margin {
            y = mouseLocation.y + gap
        }

        // 无论怎么翻转，最终都夹回屏幕内部。
        y = min(
            max(y, visibleFrame.minY + margin),
            visibleFrame.maxY - panelSize.height - margin
        )

        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: - 尺寸应用

    private func resize(to requestedHeight: CGFloat) {
        let maximumHeight = maximumHeight(
            on: panel.screen ?? currentScreen()
        )

        // 双保险：无论调用者传什么，这里都不越过安全高度。
        let height = min(requestedHeight, maximumHeight)

        guard abs(panel.frame.height - height)
            >= Self.heightChangeThreshold else {
            keepInsideScreen()
            return
        }

        var frame = panel.frame
        // 保持窗口顶部位置，向下伸缩。
        let oldTop = frame.maxY
        frame.size.height = height
        frame.origin.y = oldTop - height

        panel.setFrame(frame, display: true, animate: false)

        keepInsideScreen()
    }

    private func keepInsideScreen() {
        let screen = panel.screen ?? currentScreen()
        guard let screen else { return }

        let visible = screen.visibleFrame
        let margin = Self.screenMargin
        var frame = panel.frame

        if frame.minX < visible.minX + margin {
            frame.origin.x = visible.minX + margin
        }
        if frame.maxX > visible.maxX - margin {
            frame.origin.x = visible.maxX - frame.width - margin
        }
        if frame.minY < visible.minY + margin {
            frame.origin.y = visible.minY + margin
        }
        if frame.maxY > visible.maxY - margin {
            frame.origin.y = visible.maxY - frame.height - margin
        }

        panel.setFrame(frame, display: true, animate: false)
    }
}
