import SwiftUI
import AppKit
import Combine

@main
struct LocalTranslateApp: App {

    @NSApplicationDelegateAdaptor(
        AppDelegate.self
    )
    private var appDelegate

    var body: some Scene {

        MenuBarExtra {

            MenuBarContent()

        } label: {

            Image(
                systemName:
                    "translate"
            )
        }

        Settings {
            SettingsView()
        }
    }
}

// MARK: - Menu Bar

private struct MenuBarContent: View {

    @Environment(\.openSettings)
    private var openSettings

    var body: some View {

        Button("划词翻译 (⌥⇧T)") {
            NotificationCenter.default.post(
                name: .triggerTranslateSelection,
                object: nil
            )
        }

        Button("截图翻译 (⌥⇧S)") {
            NotificationCenter.default.post(
                name: .triggerScreenshotOCR,
                object: nil
            )
        }

        Button("输入翻译窗口") {
            NotificationCenter.default.post(
                name: .showTranslatePanel,
                object: nil
            )
        }

        Divider()

        Button {

            openSettings()

            NSApp.activate(
                ignoringOtherApps: true
            )

            DispatchQueue.main
                .asyncAfter(
                    deadline:
                        .now() + 0.08
                ) {

                    NSApp.activate(
                        ignoringOtherApps: true
                    )

                    let settingsWindow =
                        NSApp.windows.first {
                            window in

                            window.isVisible
                            &&
                            !(window is NSPanel)
                        }

                    settingsWindow?
                        .makeKeyAndOrderFront(
                            nil
                        )

                    settingsWindow?
                        .orderFrontRegardless()
                }

        } label: {

            Label(
                "设置…",
                systemImage: "gear"
            )
        }
        .keyboardShortcut(",")

        Divider()

        Button(
            "退出 Local Translate"
        ) {

            NSApp.terminate(nil)
        }
    }
}

// MARK: - App Delegate

@MainActor
final class AppDelegate:
    NSObject,
    NSApplicationDelegate {

    private var panel:
        FloatingPanel?

    private var hotKeyManager:
        HotKeyManager?

    private var cancellables =
        Set<AnyCancellable>()

    private let viewModel =
        TranslationViewModel()

    private var lastPanelHeight:
        CGFloat = 390

    // MARK: - Launch

    func applicationDidFinishLaunching(
        _ notification: Notification
    ) {

        NSApp.setActivationPolicy(
            .accessory
        )

        let panel =
            FloatingPanel(
                content:
                    ContentView(
                        viewModel:
                            viewModel
                    ),
                size:
                    NSSize(
                        width: 520,
                        height: 390
                    )
            )

        self.panel =
            panel

        lastPanelHeight =
            390

        observeContentSize()
        observePinState()

        let hotKeyManager =
            HotKeyManager()

        hotKeyManager.register(
            onTranslate: { [weak self] in
                self?.handleTranslateHotKey()
            },
            onScreenshot: { [weak self] in
                self?.handleScreenshotHotKey()
            }
        )

        self.hotKeyManager =
            hotKeyManager

        NotificationCenter.default
            .addObserver(
                self,
                selector:
                    #selector(
                        handleShowTranslatePanelNotification
                    ),
                name:
                    .showTranslatePanel,
                object: nil
            )

        NotificationCenter.default
            .addObserver(
                self,
                selector:
                    #selector(
                        handleTranslateSelectionNotification
                    ),
                name:
                    .triggerTranslateSelection,
                object: nil
            )

        NotificationCenter.default
            .addObserver(
                self,
                selector:
                    #selector(
                        handleScreenshotOCRNotification
                    ),
                name:
                    .triggerScreenshotOCR,
                object: nil
            )
    }

    func applicationWillTerminate(
        _ notification: Notification
    ) {

        NotificationCenter
            .default
            .removeObserver(
                self
            )
    }

    // MARK: - Menu Bar Show

    @objc
    private func
    handleShowTranslatePanelNotification(
        _ notification: Notification
    ) {

        viewModel
            .prepareManualInput(
                clearExisting: false
            )

        showPanelCentered(
            activateApp: true
        )

        DispatchQueue.main.async {
            [weak self] in

            self?
                .viewModel
                .requestInputFocus()
        }
    }

    // MARK: - HotKey

    private func
    handleTranslateHotKey() {

        guard
            SelectedTextReader
                .isTrusted(
                    promptIfNeeded: true
                )
        else {
            return
        }

        if let selectedText =
            SelectedTextReader.read() {

            viewModel
                .loadSelectedText(
                    selectedText
                )

            showPanel(
                reposition:
                    !viewModel.isPinned,
                activateApp:
                    false
            )

            viewModel.translate()

            return
        }

        viewModel
            .prepareManualInput(
                clearExisting: false
            )

        showPanel(
            reposition:
                !viewModel.isPinned,
            activateApp:
                true
        )

        DispatchQueue.main.async {
            [weak self] in

            self?
                .viewModel
                .requestInputFocus()
        }
    }

    // MARK: - Screenshot OCR HotKey

    private func handleScreenshotHotKey() {
        if let panel, panel.isVisible, !viewModel.isPinned {
            panel.orderOut(nil)
        }

        Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                guard let recognizedText = try await ScreenshotOCRService.shared.captureAndRecognizeText(),
                      !recognizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return
                }

                self.viewModel.loadSelectedText(recognizedText)
                self.showPanel(
                    reposition: !self.viewModel.isPinned,
                    activateApp: true
                )
                self.viewModel.translate()
            } catch {
                // 静默忽略用户取消
            }
        }
    }

    @objc
    private func handleTranslateSelectionNotification(_ notification: Notification) {
        handleTranslateHotKey()
    }

    @objc
    private func handleScreenshotOCRNotification(_ notification: Notification) {
        handleScreenshotHotKey()
    }

    // MARK: - Normal Panel Show

    private func showPanel(
        reposition: Bool,
        activateApp: Bool
    ) {

        guard let panel else {
            return
        }

        // 每次显示前先保证窗口尺寸
        // 没有超过当前屏幕。
        constrainPanelToVisibleScreen(
            panel
        )

        if
            reposition
            ||
            !panel.isVisible {

            positionPanelNearMouse(
                panel
            )
        }

        if activateApp {

            NSApp.activate(
                ignoringOtherApps: true
            )
        }

        panel.makeKeyAndOrderFront(
            nil
        )
        panel.orderFrontRegardless()
    }

    // MARK: - Centered Show

    private func showPanelCentered(
        activateApp: Bool
    ) {

        guard let panel else {
            return
        }

        constrainPanelToVisibleScreen(
            panel
        )

        centerPanelOnCurrentScreen(
            panel
        )

        if activateApp {

            NSApp.activate(
                ignoringOtherApps: true
            )
        }

        panel.makeKeyAndOrderFront(
            nil
        )
    }

    private func centerPanelOnCurrentScreen(
        _ panel: NSPanel
    ) {

        guard let screen =
            currentScreen()
        else {

            panel.center()

            return
        }

        let visibleFrame =
            screen.visibleFrame

        let panelSize =
            panel.frame.size

        let x =
            visibleFrame.midX
            - panelSize.width / 2

        let y =
            visibleFrame.midY
            - panelSize.height / 2

        panel.setFrameOrigin(
            NSPoint(
                x: x,
                y: y
            )
        )
    }

    // MARK: - Near Mouse

    private func
    positionPanelNearMouse(
        _ panel: NSPanel
    ) {

        let mouseLocation =
            NSEvent.mouseLocation

        guard let screen =
            currentScreen()
        else {

            panel.center()

            return
        }

        let visibleFrame =
            screen.visibleFrame

        let panelSize =
            panel.frame.size

        let gap:
            CGFloat = 18

        let margin:
            CGFloat = 16

        var x =
            mouseLocation.x
            + gap

        var y =
            mouseLocation.y
            - panelSize.height
            - gap

        // 右侧不够
        // → 放鼠标左边。
        if
            x + panelSize.width
            >
            visibleFrame.maxX
            - margin {

            x =
                mouseLocation.x
                - panelSize.width
                - gap
        }

        // 左侧保护。
        if
            x
            <
            visibleFrame.minX
            + margin {

            x =
                visibleFrame.minX
                + margin
        }

        // 下方不够
        // → 放鼠标上方。
        if
            y
            <
            visibleFrame.minY
            + margin {

            y =
                mouseLocation.y
                + gap
        }

        // 最终 Y 坐标强制限制在屏幕内部。
        y =
            min(
                max(
                    y,
                    visibleFrame.minY
                    + margin
                ),
                visibleFrame.maxY
                - panelSize.height
                - margin
            )

        panel.setFrameOrigin(
            NSPoint(
                x: x,
                y: y
            )
        )
    }

    // MARK: - Current Screen

    private func currentScreen()
        -> NSScreen? {

        let mouseLocation =
            NSEvent.mouseLocation

        return
            NSScreen.screens.first {

                NSMouseInRect(
                    mouseLocation,
                    $0.frame,
                    false
                )

            }
            ??
            panel?.screen
            ??
            NSScreen.main
    }

    // MARK: - Screen-Aware Max Height

    private func maximumPanelHeight(
        on screen: NSScreen?
    ) -> CGFloat {

        guard let screen else {

            return 500
        }

        let visibleHeight =
            screen.visibleFrame.height

        // 浮窗不应该像普通 App 一样
        // 把整个屏幕纵向占满。
        //
        // 小屏：
        // 最多占可用区域约 78%。
        //
        // 大屏：
        // 仍然限制在 520pt。
        let proportionalMaximum =
            visibleHeight * 0.78

        return min(
            520,
            proportionalMaximum
        )
    }

    // MARK: - Hard Screen Constraint

    private func
    constrainPanelToVisibleScreen(
        _ panel: NSPanel
    ) {

        let screen =
            panel.screen
            ??
            currentScreen()

        guard let screen else {
            return
        }

        let maxHeight =
            maximumPanelHeight(
                on: screen
            )

        guard
            panel.frame.height
            >
            maxHeight
        else {
            return
        }

        resizePanel(
            panel,
            toHeight:
                maxHeight
        )
    }

    // MARK: - Pin

    private func observePinState() {

        viewModel
            .$isPinned
            .removeDuplicates()
            .receive(
                on:
                    RunLoop.main
            )
            .sink {
                [weak self]
                isPinned in

                guard
                    let panel =
                        self?.panel
                else {
                    return
                }

                panel.isPinned =
                    isPinned

                if
                    isPinned
                    &&
                    panel.isVisible {

                    panel
                        .orderFrontRegardless()
                }
            }
            .store(
                in:
                    &cancellables
            )
    }

    // MARK: - Dynamic Size

    private func
    observeContentSize() {

        Publishers
            .CombineLatest3(
                viewModel
                    .$originalText,
                viewModel
                    .$translatedText,
                viewModel
                    .$isTranslating
            )
            .receive(
                on:
                    RunLoop.main
            )
            .sink {
                [weak self]
                original,
                translated,
                loading in

                self?
                    .updatePanelSize(
                        original:
                            original,
                        translated:
                            translated,
                        loading:
                            loading
                    )
            }
            .store(
                in:
                    &cancellables
            )
    }

    private func updatePanelSize(
        original: String,
        translated: String,
        loading: Bool
    ) {

        guard let panel else {
            return
        }

        // MARK: Original

        let originalLines =
            estimatedLines(
                for: original,
                charactersPerLine: 55
            )

        let visibleOriginalLines =
            min(
                max(
                    originalLines,
                    3
                ),
                7
            )

        let originalExtraLines =
            max(
                visibleOriginalLines
                - 3,
                0
            )

        let originalExtraHeight =
            CGFloat(
                originalExtraLines
            ) * 19

        // MARK: Translation

        let translationExtraHeight:
            CGFloat

        if loading {

            // Streaming 阶段保持固定，
            // 避免 token 更新造成窗口闪动。
            translationExtraHeight =
                88

        } else if translated.isEmpty {

            translationExtraHeight =
                0

        } else {

            let translationLines =
                estimatedLines(
                    for: translated,
                    charactersPerLine: 29
                )

            let visibleTranslationLines =
                min(
                    max(
                        translationLines,
                        3
                    ),
                    9
                )

            let translationExtraLines =
                max(
                    visibleTranslationLines
                    - 3,
                    0
                )

            translationExtraHeight =
                CGFloat(
                    translationExtraLines
                ) * 24
        }

        // MARK: Desired Height

        let baseHeight:
            CGFloat = 390

        let desiredHeight =
            baseHeight
            + originalExtraHeight
            + translationExtraHeight

        // MARK: Screen-Aware Maximum

        let screen =
            panel.screen
            ??
            currentScreen()

        let screenMaximum =
            maximumPanelHeight(
                on: screen
            )

        let finalHeight =
            min(
                max(
                    desiredHeight,
                    390
                ),
                screenMaximum
            )

        guard
            abs(
                finalHeight
                - lastPanelHeight
            ) >= 8
        else {
            return
        }

        lastPanelHeight =
            finalHeight

        resizePanel(
            panel,
            toHeight:
                finalHeight
        )
    }

    // MARK: - Line Estimate

    private func estimatedLines(
        for text: String,
        charactersPerLine: Int
    ) -> Int {

        guard !text.isEmpty else {
            return 1
        }

        return text
            .components(
                separatedBy:
                    .newlines
            )
            .reduce(0) {
                result,
                line in

                let length =
                    max(
                        line.count,
                        1
                    )

                let lines =
                    Int(
                        ceil(
                            Double(length)
                            /
                            Double(
                                charactersPerLine
                            )
                        )
                    )

                return
                    result
                    + max(
                        lines,
                        1
                    )
            }
    }

    // MARK: - Resize

    private func resizePanel(
        _ panel: NSPanel,
        toHeight requestedHeight: CGFloat
    ) {

        let screen =
            panel.screen
            ??
            currentScreen()

        let maximumHeight =
            maximumPanelHeight(
                on: screen
            )

        // 双保险：
        // 无论调用者传多少，
        // resizePanel 自己都不会允许超出安全高度。
        let height =
            min(
                requestedHeight,
                maximumHeight
            )

        guard
            abs(
                panel.frame.height
                - height
            ) >= 8
        else {
            keepPanelInsideScreen(
                panel
            )

            return
        }

        var frame =
            panel.frame

        // 默认保持窗口顶部位置，
        // 向下伸缩。
        let oldTop =
            frame.maxY

        frame.size.height =
            height

        frame.origin.y =
            oldTop - height

        panel.setFrame(
            frame,
            display: true,
            animate: false
        )

        // resize 完以后无条件再做一次
        // 屏幕边界校正。
        keepPanelInsideScreen(
            panel
        )
    }

    // MARK: - Keep Inside Screen

    private func keepPanelInsideScreen(
        _ panel: NSPanel
    ) {

        let screen =
            panel.screen
            ??
            currentScreen()

        guard let screen else {
            return
        }

        let visible =
            screen.visibleFrame

        let margin:
            CGFloat = 16

        var frame =
            panel.frame

        // 左边。
        if
            frame.minX
            <
            visible.minX
            + margin {

            frame.origin.x =
                visible.minX
                + margin
        }

        // 右边。
        if
            frame.maxX
            >
            visible.maxX
            - margin {

            frame.origin.x =
                visible.maxX
                - frame.width
                - margin
        }

        // 下边。
        if
            frame.minY
            <
            visible.minY
            + margin {

            frame.origin.y =
                visible.minY
                + margin
        }

        // 上边。
        if
            frame.maxY
            >
            visible.maxY
            - margin {

            frame.origin.y =
                visible.maxY
                - frame.height
                - margin
        }

        panel.setFrame(
            frame,
            display: true,
            animate: false
        )
    }
}

// MARK: - Notification

extension Notification.Name {

    static let showTranslatePanel =
        Notification.Name(
            "showTranslatePanel"
        )

    static let triggerTranslateSelection =
        Notification.Name(
            "triggerTranslateSelection"
        )

    static let triggerScreenshotOCR =
        Notification.Name(
            "triggerScreenshotOCR"
        )
}
