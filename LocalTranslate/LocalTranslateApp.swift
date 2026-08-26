import SwiftUI
import AppKit

@main
struct LocalTranslateApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self)
    private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var panel: FloatingPanel?
    private var hotKeyManager: HotKeyManager?

    private let viewModel = TranslationViewModel()

    func applicationDidFinishLaunching(
        _ notification: Notification
    ) {

        NSApp.setActivationPolicy(.accessory)

        let panel = FloatingPanel(
            content: ContentView(
                viewModel: viewModel
            )
        )

        self.panel = panel

        let hotKeyManager = HotKeyManager()

        hotKeyManager.register { [weak self] in
            self?.handleTranslateHotKey()
        }

        self.hotKeyManager = hotKeyManager

        // 第一次运行时请求辅助功能权限
        _ = SelectedTextReader.isTrusted(
            promptIfNeeded: true
        )
    }

    private func handleTranslateHotKey() {

        // 非常重要：
        // 必须先读取文字，再弹出 LocalTranslate。
        // 否则 LocalTranslate 自己会抢走系统焦点。

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

        // 把系统选中的文字交给 UI
        viewModel.loadSelectedText(selectedText)

        // 弹出窗口
        showPanel()

        // 自动开始翻译
        viewModel.translate()
    }

    private func showPanel() {

        guard let panel else {
            return
        }

        panel.center()
        panel.makeKeyAndOrderFront(nil)
    }
}
