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

            Button(
                "显示翻译窗口"
            ) {

                NotificationCenter
                    .default
                    .post(
                        name:
                            .showTranslatePanel,
                        object: nil
                    )
            }

            Divider()

            SettingsLink {

                Label(
                    "设置…",
                    systemImage: "gear"
                )
            }

            Divider()

            Button(
                "退出 Local Translate"
            ) {

                NSApp.terminate(nil)
            }

        } label: {

            Image(
                systemName:
                    "character.book.closed"
            )
        }

        Settings {
            SettingsView()
        }
    }
}

// MARK: - AppDelegate

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

    // MARK: Launch

    func applicationDidFinishLaunching(
        _ notification: Notification
    ) {

        // 菜单栏后台工具，
        // 不显示 Dock 图标
        NSApp.setActivationPolicy(
            .accessory
        )

        // 创建悬浮窗口
        let panel =
            FloatingPanel(
                content:
                    ContentView(
                        viewModel:
                            viewModel
                    )
            )

        self.panel = panel

        // 动态高度
        observeContentSize()

        // Pin 状态
        observePinState()

        // 全局快捷键
        let hotKeyManager =
            HotKeyManager()

        hotKeyManager.register {
            [weak self] in

            self?
                .handleTranslateHotKey()
        }

        self.hotKeyManager =
            hotKeyManager

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(
                handleShowTranslatePanelNotification
            ),
            name: .showTranslatePanel,
            object: nil
        )
    }

    func applicationWillTerminate(
        _ notification: Notification
    ) {
        NotificationCenter.default.removeObserver(
            self
        )
    }
    
    @objc
    private func handleShowTranslatePanelNotification(
        _ notification: Notification
    ) {
        viewModel.prepareManualInput(
            clearExisting: false
        )

        showPanel(
            reposition: true,
            activateApp: true
        )

        DispatchQueue.main.async { [weak self] in
            self?.viewModel.requestInputFocus()
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

        // --------------------------------
        // 模式 1：
        // 当前 App 有选中文字
        // → 自动抓取 + 自动翻译
        // --------------------------------

        if let selectedText =
            SelectedTextReader.read() {

            viewModel
                .loadSelectedText(
                    selectedText
                )

            // Pin 状态下如果窗口已经显示，
            // 保留用户手动摆放的位置。
            showPanel(
                reposition:
                    !viewModel.isPinned,
                activateApp: false
            )

            viewModel.translate()

            return
        }

        // --------------------------------
        // 模式 2：
        // 没有选中文字
        // → 打开手动输入模式
        // --------------------------------

        viewModel
            .prepareManualInput(
                clearExisting: false
            )

        showPanel(
            reposition:
                !viewModel.isPinned,
            activateApp: true
        )

        // 等窗口变成 key window 后，
        // 再把焦点交给 TextEditor。
        DispatchQueue
            .main
            .async {
                [weak self] in

                self?
                    .viewModel
                    .requestInputFocus()
            }
    }

    // MARK: - Panel

    private func showPanel(
        reposition: Bool,
        activateApp: Bool
    ) {

        guard let panel else {
            return
        }

        // 如果窗口当前是隐藏的，
        // 即使处于 Pin 状态，
        // 也重新定位一次。
        if reposition ||
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
    }

    private func
    positionPanelNearMouse(
        _ panel: NSPanel
    ) {

        let mouseLocation =
            NSEvent.mouseLocation

        let screen =
            NSScreen.screens.first {

                NSMouseInRect(
                    mouseLocation,
                    $0.frame,
                    false
                )

            } ?? NSScreen.main

        guard let screen else {

            panel.center()

            return
        }

        let visibleFrame =
            screen.visibleFrame

        let panelSize =
            panel.frame.size

        let gap: CGFloat = 18
        let margin: CGFloat = 16

        // 默认鼠标右下方
        var x =
            mouseLocation.x
            + gap

        var y =
            mouseLocation.y
            - panelSize.height
            - gap

        // 右边不够
        // → 左边
        if x + panelSize.width
            >
            visibleFrame.maxX
            - margin {

            x =
                mouseLocation.x
                - panelSize.width
                - gap
        }

        // 左侧越界保护
        if x <
            visibleFrame.minX
            + margin {

            x =
                visibleFrame.minX
                + margin
        }

        // 下方不够
        // → 上方
        if y <
            visibleFrame.minY
            + margin {

            y =
                mouseLocation.y
                + gap
        }

        // 顶部越界保护
        if y
            + panelSize.height
            >
            visibleFrame.maxY
            - margin {

            y =
                visibleFrame.maxY
                - panelSize.height
                - margin
        }

        panel.setFrameOrigin(
            NSPoint(
                x: x,
                y: y
            )
        )
    }

    // MARK: - Pin

    private func observePinState() {

        viewModel
            .$isPinned
            .removeDuplicates()
            .receive(
                on: RunLoop.main
            )
            .sink {
                [weak self] isPinned in

                guard
                    let panel =
                        self?.panel
                else {
                    return
                }

                panel.isPinned =
                    isPinned

                if isPinned &&
                    panel.isVisible {

                    panel
                        .orderFrontRegardless()
                }
            }
            .store(
                in: &cancellables
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
                on: RunLoop.main
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
                in: &cancellables
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

        let originalLines =
            estimatedLines(
                for: original,
                charactersPerLine:
                    58
            )

        let translationLines =
            loading
            ? 2
            : estimatedLines(
                for:
                    translated,
                charactersPerLine:
                    30
            )

        // 输入框最少 3 行，
        // 最多按 7 行算高度，
        // 再长就让 TextEditor 自己滚动。
        let visibleOriginalLines =
            min(
                max(
                    originalLines,
                    3
                ),
                7
            )

        let visibleTranslationLines =
            min(
                max(
                    translationLines,
                    2
                ),
                11
            )

        let originalHeight =
            CGFloat(
                visibleOriginalLines
            ) * 20

        let translationHeight =
            CGFloat(
                visibleTranslationLines
            ) * 24

        let desiredHeight =
            155
            + originalHeight
            + translationHeight

        let finalHeight =
            min(
                max(
                    desiredHeight,
                    300
                ),
                540
            )

        resizePanel(
            panel,
            toHeight:
                finalHeight
        )
    }

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
                            Double(
                                length
                            )
                            /
                            Double(
                                charactersPerLine
                            )
                        )
                    )

                return result
                    + max(
                        lines,
                        1
                    )
            }
    }

    private func resizePanel(
        _ panel: NSPanel,
        toHeight height: CGFloat
    ) {

        guard abs(
            panel.frame.height
            - height
        ) > 2
        else {
            return
        }

        var frame =
            panel.frame

        // 保持顶部位置不动，
        // 向下伸缩。
        let top =
            frame.maxY

        frame.size.height =
            height

        frame.origin.y =
            top - height

        if let screen =
            panel.screen {

            let visible =
                screen.visibleFrame

            if frame.minY
                <
                visible.minY
                + 12 {

                frame.origin.y =
                    visible.minY
                    + 12
            }

            if frame.maxY
                >
                visible.maxY
                - 12 {

                frame.origin.y =
                    visible.maxY
                    - frame.height
                    - 12
            }
        }

        panel.setFrame(
            frame,
            display: true,
            animate: true
        )
    }
}

// MARK: - Notification

extension Notification.Name {

    static let showTranslatePanel =
        Notification.Name(
            "showTranslatePanel"
        )
}
