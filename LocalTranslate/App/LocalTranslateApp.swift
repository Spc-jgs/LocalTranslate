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

    @ObservedObject
    private var assistantRuntime = AssistantRuntime.shared

    @AppStorage(AppSettings.Key.assistantLocalOnly)
    private var assistantLocalOnly = false

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

        Button("本机助手 (⌥⇧E)") {
            NotificationCenter.default.post(
                name: .triggerAssistant,
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

        Text(assistantRuntime.statusTitle)
        if assistantRuntime.phase == .idle,
           !assistantLocalOnly {
            Button("启动助手") {
                NotificationCenter.default.post(
                    name: .startAssistant,
                    object: nil
                )
            }
        }
        if assistantRuntime.phase != .idle {
            Button("停止助手") {
                NotificationCenter.default.post(
                    name: .stopAssistant,
                    object: nil
                )
            }
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

    private var assistantPanel:
        MiniHUDPanel?

    private var hotKeyManager:
        HotKeyManager?

    private var cancellables =
        Set<AnyCancellable>()

    private let viewModel =
        TranslationViewModel()

    private let miniHUDViewModel =
        MiniHUDViewModel()

    private let assistantViewModel =
        AssistantViewModel()

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
        miniHUD.onOrderOut = { [weak self] in
            SpeechReader.shared.stop()
            self?.miniHUDViewModel.cancelTranslation()
        }

        self.miniHUDPanel =
            miniHUD

        let assistantPanel = MiniHUDPanel(
            content: AssistantView(
                viewModel: assistantViewModel,
                onClose: { [weak self] in
                    self?.assistantPanel?.orderOut(nil)
                }
            ),
            initialSize: NSSize(width: 420, height: 350)
        )
        assistantPanel.onOrderOut = { [weak self] in
            self?.assistantViewModel.cancel()
        }
        self.assistantPanel = assistantPanel

        observeContentSize()
        observeMiniHUDContentSize()
        observePinState()
        observeMiniHUDPinState()
        observeAssistantPinState()

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
                    },
                    .explainSelection: { [weak self] in
                        self?.handleAssistantHotKey()
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

        NotificationCenter.default
            .addObserver(
                self,
                selector: #selector(handleAssistantNotification),
                name: .triggerAssistant,
                object: nil
            )

        NotificationCenter.default
            .addObserver(
                self,
                selector: #selector(handleStartAssistantNotification),
                name: .startAssistant,
                object: nil
            )

        NotificationCenter.default
            .addObserver(
                self,
                selector: #selector(handleStopAssistantNotification),
                name: .stopAssistant,
                object: nil
            )

        Task.detached(priority: .utility) {
            await AGYSessionProcess.shared.reclaimIfNeeded()
        }
    }

    func applicationWillTerminate(
        _ notification: Notification
    ) {
        assistantViewModel.shutdownResidentProcess()
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
                let outcome = try await ScreenshotOCRService.shared
                    .captureAndRecognizeText()
                self.applyScreenshotOutcome(outcome)
            } catch {
                self.presentScreenshotFailure(
                    "文字识别失败，请再试一次。"
                )
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

    @objc
    private func handleAssistantNotification(_ notification: Notification) {
        handleAssistantHotKey()
    }

    @objc
    private func handleStartAssistantNotification(
        _ notification: Notification
    ) {
        assistantViewModel.startResidentProcess()
    }

    @objc
    private func handleStopAssistantNotification(
        _ notification: Notification
    ) {
        assistantViewModel.stopResidentProcess()
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

        if let assistantPanel, assistantPanel.isVisible,
           !assistantViewModel.isPinned {
            assistantPanel.orderOut(nil)
        }

        if let selectedText = SelectedTextReader.read(),
           !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            showMiniHUD(with: selectedText)
            return
        }

        // 若无选中文本，回退至主面板
        handleTranslateHotKey()
    }

    /// 有选中文本就预填进输入框，没有就空框。都不自动开算。
    ///
    /// 注意这里**不要求**辅助功能权限：问命令这条路只需要键盘输入。没授权时
    /// 读不到选区，那就退化成输入框，而不是整个功能打不开。
    private func handleAssistantHotKey() {
        if let miniHUDPanel, miniHUDPanel.isVisible {
            miniHUDPanel.orderOut(nil)
        }

        let context = SelectionContextReader.isTrusted(promptIfNeeded: true)
            ? SelectionContextReader.read()
            : nil
        if let context,
           !context.selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
               .isEmpty {
            assistantViewModel.startWithSelection(context)
        } else if assistantViewModel.hasOpenSession {
            assistantViewModel.focusInput()
        } else {
            assistantViewModel.startWithQuestion()
        }

        if !assistantViewModel.isPinned {
            assistantPanel?.positionNearMouse(
                customSize: NSSize(width: 460, height: 380)
            )
        }
        assistantPanel?.markDisplayed()
        assistantPanel?.makeKeyAndOrderFront(nil)
        assistantPanel?.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
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

    private func applyScreenshotOutcome(_ outcome: ScreenshotOCROutcome) {
        switch outcome {
        case .cancelled, .permissionDenied, .alreadyCapturing:
            return

        case .noImage, .noText:
            presentScreenshotFailure(outcome.userMessage)

        case let .recognized(text):
            viewModel.loadSelectedText(text)
            panelPresenter?.show(
                reposition: !viewModel.isPinned,
                activateApp: true
            )
            viewModel.translate()
        }
    }

    private func presentScreenshotFailure(_ message: String?) {
        guard let message, !message.isEmpty else { return }
        viewModel.prepareManualInput(clearExisting: true)
        viewModel.errorMessage = message
        panelPresenter?.show(
            reposition: !viewModel.isPinned,
            activateApp: true
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

    private func observeMiniHUDPinState() {
        miniHUDViewModel.$isPinned
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] isPinned in
                guard let panel = self?.miniHUDPanel else { return }
                panel.isPinned = isPinned
                if isPinned, panel.isVisible {
                    panel.orderFrontRegardless()
                }
            }
            .store(in: &cancellables)
    }

    private func observeAssistantPinState() {
        assistantViewModel.$isPinned
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] isPinned in
                guard let panel = self?.assistantPanel else { return }
                panel.isPinned = isPinned
                if isPinned, panel.isVisible {
                    panel.orderFrontRegardless()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Dynamic Size

    private func
    observeContentSize() {

        Publishers
            .CombineLatest3(
                viewModel
                    .session
                    .$originalText,
                viewModel
                    .session
                    .$translatedText,
                viewModel
                    .session
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
                miniHUDViewModel.session.$originalText,
                miniHUDViewModel.session.$translatedText
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

    static let triggerAssistant =
        Notification.Name(
            "triggerAssistant"
        )

    static let startAssistant =
        Notification.Name(
            "startAssistant"
        )

    static let stopAssistant =
        Notification.Name(
            "stopAssistant"
        )
}
