import SwiftUI
import AppKit
import Combine

@main
struct LocalTranslateApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self)
    private var appDelegate

    var body: some Scene {

        MenuBarExtra {

            Button("显示翻译窗口") {
                NotificationCenter.default.post(
                    name: .showTranslatePanel,
                    object: nil
                )
            }

            Divider()

            SettingsLink {
                Label("设置…", systemImage: "gear")
            }

            Divider()

            Button("退出 Local Translate") {
                NSApp.terminate(nil)
            }

        } label: {
            Image(systemName: "character.book.closed")
        }

        Settings {
            SettingsView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var panel: FloatingPanel?
    private var hotKeyManager: HotKeyManager?

    private var cancellables = Set<AnyCancellable>()

    private var showPanelObserver: NSObjectProtocol?

    private let viewModel = TranslationViewModel()

    func applicationDidFinishLaunching(
        _ notification: Notification
    ) {

        // 后台工具模式，不显示普通 Dock 图标
        NSApp.setActivationPolicy(.accessory)

        // 创建悬浮窗口
        let panel = FloatingPanel(
            content: ContentView(
                viewModel: viewModel
            )
        )

        self.panel = panel

        // 监听内容变化，动态调整窗口高度
        observeContentSize()

        // 注册全局快捷键
        let hotKeyManager = HotKeyManager()

        hotKeyManager.register { [weak self] in
            self?.handleTranslateHotKey()
        }

        self.hotKeyManager = hotKeyManager

        // 监听菜单栏“显示翻译窗口”
        showPanelObserver = NotificationCenter.default.addObserver(
            forName: .showTranslatePanel,
            object: nil,
            queue: .main
        ) { [weak self] _ in

            Task { @MainActor in
                self?.showPanel()
            }
        }
    }

    func applicationWillTerminate(
        _ notification: Notification
    ) {

        if let showPanelObserver {
            NotificationCenter.default.removeObserver(
                showPanelObserver
            )
        }
    }

    // MARK: - Global HotKey

    private func handleTranslateHotKey() {

        // 必须先读取其他 App 中的选中文字，
        // 再让 LocalTranslate 自己获得焦点。

        guard SelectedTextReader.isTrusted(
            promptIfNeeded: true
        ) else {
            return
        }

        guard let selectedText = SelectedTextReader.read() else {

            viewModel.originalText = ""
            viewModel.translatedText = ""
            viewModel.errorMessage = "没有读取到选中的文字"

            showPanel()

            return
        }

        // 加载当前选中文字
        viewModel.loadSelectedText(
            selectedText
        )

        // 显示窗口
        showPanel()

        // 自动翻译
        viewModel.translate()
    }

    // MARK: - Panel

    private func showPanel() {

        guard let panel else {
            return
        }

        let mouseLocation = NSEvent.mouseLocation

        let screen = NSScreen.screens.first {
            NSMouseInRect(
                mouseLocation,
                $0.frame,
                false
            )
        } ?? NSScreen.main

        guard let screen else {

            panel.center()
            panel.makeKeyAndOrderFront(nil)

            return
        }

        let visibleFrame = screen.visibleFrame
        let panelSize = panel.frame.size

        let gap: CGFloat = 18
        let margin: CGFloat = 16

        // 默认出现在鼠标右下方
        var x = mouseLocation.x + gap
        var y = mouseLocation.y
            - panelSize.height
            - gap

        // 右边空间不够 → 放左边
        if x + panelSize.width
            > visibleFrame.maxX - margin {

            x = mouseLocation.x
                - panelSize.width
                - gap
        }

        // 防止左侧越界
        if x < visibleFrame.minX + margin {

            x = visibleFrame.minX + margin
        }

        // 下方空间不够 → 放鼠标上方
        if y < visibleFrame.minY + margin {

            y = mouseLocation.y + gap
        }

        // 防止顶部越界
        if y + panelSize.height
            > visibleFrame.maxY - margin {

            y = visibleFrame.maxY
                - panelSize.height
                - margin
        }

        panel.setFrameOrigin(
            NSPoint(
                x: x,
                y: y
            )
        )

        panel.makeKeyAndOrderFront(nil)
    }

    // MARK: - Dynamic Size

    private func observeContentSize() {

        Publishers.CombineLatest3(
            viewModel.$originalText,
            viewModel.$translatedText,
            viewModel.$isTranslating
        )
        .receive(
            on: RunLoop.main
        )
        .sink { [weak self] original,
                 translated,
                 loading in

            self?.updatePanelSize(
                original: original,
                translated: translated,
                loading: loading
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

        let originalLines = estimatedLines(
            for: original,
            charactersPerLine: 54
        )

        let translationLines = loading
            ? 1
            : estimatedLines(
                for: translated,
                charactersPerLine: 28
            )

        let originalHeight =
            CGFloat(
                max(
                    originalLines,
                    2
                )
            ) * 20

        let translationHeight =
            CGFloat(
                max(
                    translationLines,
                    2
                )
            ) * 25

        let desiredHeight =
            145
            + originalHeight
            + translationHeight

        let finalHeight = min(
            max(desiredHeight, 220),
            520
        )

        resizePanel(
            panel,
            toHeight: finalHeight
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
                separatedBy: .newlines
            )
            .reduce(0) {
                result,
                line in

                let length = max(
                    line.count,
                    1
                )

                let lines = Int(
                    ceil(
                        Double(length)
                        / Double(
                            charactersPerLine
                        )
                    )
                )

                return result + max(
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
            panel.frame.height - height
        ) > 2 else {
            return
        }

        var frame = panel.frame

        // 保持窗口顶部位置不变
        let top = frame.maxY

        frame.size.height = height
        frame.origin.y = top - height

        if let screen = panel.screen {

            let visible = screen.visibleFrame

            if frame.minY
                < visible.minY + 12 {

                frame.origin.y =
                    visible.minY + 12
            }

            if frame.maxY
                > visible.maxY - 12 {

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

// MARK: - Notifications

extension Notification.Name {

    static let showTranslatePanel =
        Notification.Name(
            "showTranslatePanel"
        )
}
