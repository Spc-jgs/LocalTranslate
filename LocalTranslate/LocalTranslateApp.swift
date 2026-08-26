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
                    "character.book.closed"
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

        hotKeyManager.register {
            [weak self] in

            self?
                .handleTranslateHotKey()
        }

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

    // MARK: - Menu

    @objc
    private func
    handleShowTranslatePanelNotification(
        _ notification: Notification
    ) {

        viewModel
            .prepareManualInput(
                clearExisting: false
            )

        showPanel(
            reposition: true,
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
                    !viewModel
                        .isPinned,
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
                !viewModel
                    .isPinned,
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

    // MARK: - Panel

    private func showPanel(
        reposition: Bool,
        activateApp: Bool
    ) {

        guard let panel else {
            return
        }

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

        if
            x
            + panelSize.width
            >
            visibleFrame.maxX
            - margin {

            x =
                mouseLocation.x
                - panelSize.width
                - gap
        }

        if
            x
            <
            visibleFrame.minX
            + margin {

            x =
                visibleFrame.minX
                + margin
        }

        if
            y
            <
            visibleFrame.minY
            + margin {

            y =
                mouseLocation.y
                + gap
        }

        if
            y
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

            // Streaming 时使用固定高度。
            //
            // translatedText 每次 token 更新
            // 都会进入这里，
            // 但算出来的目标高度始终完全一致。
            //
            // 因此不会再 resize Panel。
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

        // MARK: Height

        let baseHeight:
            CGFloat = 390

        let desiredHeight =
            baseHeight
            + originalExtraHeight
            + translationExtraHeight

        let finalHeight =
            min(
                max(
                    desiredHeight,
                    390
                ),
                560
            )

        // Streaming 每个 token 虽然都会触发 Publisher，
        // 但目标高度不变，因此这里直接退出。
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

    private func resizePanel(
        _ panel: NSPanel,
        toHeight height: CGFloat
    ) {

        guard
            abs(
                panel.frame.height
                - height
            ) >= 8
        else {
            return
        }

        var frame =
            panel.frame

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

            if
                frame.minY
                <
                visible.minY
                + 12 {

                frame.origin.y =
                    visible.minY
                    + 12
            }

            if
                frame.maxY
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
}
