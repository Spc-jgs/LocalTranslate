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

        Button("划词气泡 (⌥⇧D)") {
            NotificationCenter.default.post(
                name: .triggerMiniHUD,
                object: nil
            )
        }

        Button("截图翻译 (⌥⇧S)") {
            NotificationCenter.default.post(
                name: .triggerScreenshotOCR,
                object: nil
            )
        }

        Button("实时音视频字幕 (⌥⇧C)") {
            NotificationCenter.default.post(
                name: .triggerLiveSubtitles,
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

    private var panelPresenter:
        PanelPresenter?

    private var miniHUDPanel:
        MiniHUDPanel?

    private var hotKeyManager:
        HotKeyManager?

    private var cancellables =
        Set<AnyCancellable>()

    private let viewModel =
        TranslationViewModel()

    private let miniHUDViewModel =
        MiniHUDViewModel()

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
                        width:
                            TranslatePanelLayout.panelWidth,
                        height:
                            TranslatePanelLayout.baseHeight
                    )
            )

        self.panel =
            panel

        self.panelPresenter =
            PanelPresenter(
                panel: panel,
                baseHeight:
                    TranslatePanelLayout.baseHeight
            )

        let miniHUD =
            MiniHUDPanel(
                content:
                    MiniHUDView(
                        viewModel:
                            miniHUDViewModel,
                        onExpand: { [weak self] in
                            self?.expandMiniHUDToMainPanel()
                        },
                        onClose: { [weak self] in
                            self?.miniHUDPanel?.orderOut(nil)
                        }
                    )
            )

        self.miniHUDPanel =
            miniHUD

        observeContentSize()
        observeMiniHUDContentSize()
        observePinState()

        let hotKeyManager =
            HotKeyManager()

        let unavailable =
            hotKeyManager.register(
                handlers: [
                    .translateSelection: { [weak self] in
                        self?.handleTranslateHotKey()
                    },
                    .screenshotOCR: { [weak self] in
                        self?.handleScreenshotHotKey()
                    },
                    .liveSubtitles: { [weak self] in
                        self?.handleLiveSubtitlesHotKey()
                    },
                    .miniHUD: { [weak self] in
                        self?.handleMiniHUDHotKey()
                    }
                ]
            )

        HotKeyRegistry.shared.update(
            unavailable: unavailable
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

        NotificationCenter.default
            .addObserver(
                self,
                selector:
                    #selector(
                        handleLiveSubtitlesNotification
                    ),
                name:
                    .triggerLiveSubtitles,
                object: nil
            )

        NotificationCenter.default
            .addObserver(
                self,
                selector:
                    #selector(
                        handleMiniHUDNotification
                    ),
                name:
                    .triggerMiniHUD,
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

        panelPresenter?.showCentered(
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

            panelPresenter?.show(
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

        panelPresenter?.show(
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

        NSApp.activate(ignoringOtherApps: true)

        Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                guard let recognizedText = try await ScreenshotOCRService.shared.captureAndRecognizeText(),
                      !recognizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return
                }

                self.viewModel.loadSelectedText(recognizedText)
                self.panelPresenter?.show(
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

    @objc
    private func handleLiveSubtitlesNotification(_ notification: Notification) {
        handleLiveSubtitlesHotKey()
    }

    @objc
    private func handleMiniHUDNotification(_ notification: Notification) {
        handleMiniHUDHotKey()
    }

    // MARK: - Live Subtitles HotKey

    private func handleLiveSubtitlesHotKey() {
        let overlay = LiveSubtitlesOverlayPanel.shared
        let vm = LiveSubtitlesViewModel.shared

        if overlay.isVisible {
            vm.stop()
            overlay.orderOut(nil)
        } else {
            // 字号可能在设置页改过，而那时字幕条没显示、收不到 onChange。
            overlay.applyContentHeight(
                historyExpanded: vm.showHistoryDrawer,
                fontSize: vm.fontSize
            )
            overlay.positionAtScreenBottom()
            overlay.makeKeyAndOrderFront(nil)
            overlay.orderFrontRegardless()
            vm.start()
        }
    }

    // MARK: - Mini HUD HotKey

    private func handleMiniHUDHotKey() {
        guard SelectedTextReader.isTrusted(promptIfNeeded: true) else {
            return
        }

        if let selectedText = SelectedTextReader.read(),
           !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            showMiniHUD(with: selectedText)
            return
        }

        // 若无选中文本，回退至主面板
        handleTranslateHotKey()
    }

    private func showMiniHUD(with text: String) {
        guard let miniHUDPanel else { return }

        // 若主面板打开且未钉住，先隐藏主面板
        if let panel, panel.isVisible, !viewModel.isPinned {
            panel.orderOut(nil)
        }

        miniHUDViewModel.loadAndTranslate(text)
        miniHUDPanel.positionNearMouse()
        miniHUDPanel.markDisplayed()
        miniHUDPanel.makeKeyAndOrderFront(nil)
        miniHUDPanel.orderFrontRegardless()
    }

    private func expandMiniHUDToMainPanel() {
        let currentOriginal = miniHUDViewModel.originalText
        let currentTranslated = miniHUDViewModel.translatedText

        miniHUDViewModel.reset()
        miniHUDPanel?.orderOut(nil)

        viewModel.loadSelectedText(currentOriginal)
        if !currentTranslated.isEmpty {
            viewModel.translatedText = currentTranslated
        }

        panelPresenter?.show(
            reposition: !viewModel.isPinned,
            activateApp: true
        )
        if currentTranslated.isEmpty {
            viewModel.translate()
        }
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

    /// 气泡高度只由内容决定，因此不订阅 `isTranslating`。
    ///
    /// 主面板还需要它来决定 `keepGrowingOnly`；气泡的 `updateHeight` 没有这个
    /// 参数，订阅它只会在翻译结束时多算一次同样的高度。
    private func observeMiniHUDContentSize() {
        Publishers
            .CombineLatest(
                miniHUDViewModel.$originalText,
                miniHUDViewModel.$translatedText
            )
            .receive(on: RunLoop.main)
            .sink { [weak self] original, translated in
                self?.updateMiniHUDSize(
                    original: original,
                    translated: translated
                )
            }
            .store(in: &cancellables)
    }

    private func updateMiniHUDSize(
        original: String,
        translated: String
    ) {
        guard let miniHUDPanel, miniHUDPanel.isVisible else {
            return
        }

        miniHUDPanel.updateHeight(
            MiniHUDLayout.panelHeight(
                original: original,
                translated: translated
            ),
            animated: false
        )
    }

    private func updatePanelSize(
        original: String,
        translated: String,
        loading: Bool
    ) {

        panelPresenter?.apply(
            height:
                TranslatePanelLayout.panelHeight(
                    original: original,
                    translated: translated
                ),
            keepGrowingOnly: loading
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

    static let triggerLiveSubtitles =
        Notification.Name(
            "triggerLiveSubtitles"
        )

    static let triggerMiniHUD =
        Notification.Name(
            "triggerMiniHUD"
        )
}
