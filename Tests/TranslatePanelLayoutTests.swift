import AppKit
import Foundation

@main
struct TranslatePanelLayoutTests {
    @MainActor
    static func main() {
        shortTranslationNeverMovesTheWindow()
        streamingNeverExceedsTheFinalHeight()
        longTranslationStillGrowsTheWindow()
        heightIsAPureFunctionOfContent()
        miniHUDShortTranslationNeverMovesThePanel()
        print("TranslatePanelLayoutTests: 5 passed")
    }

    /// 窗口只在跨过这个阈值时才重排（`PanelPresenter.heightChangeThreshold`）。
    private static let moveThreshold: CGFloat = 8

    /// 用户报告的现象：选中一个单词翻译，窗口会抖一下。
    ///
    /// 成因是「翻译途中才有的高度」——已发起但无 token 时的占位高度比常见译文
    /// 的最终高度还大，于是先长后缩。这里逐字模拟一次完整的流式翻译，
    /// 要求全程不越过重排阈值。
    @MainActor
    private static func shortTranslationNeverMovesTheWindow() {
        let cases: [(String, String)] = [
            ("scheduler", "调度器"),
            ("queue", "队列"),
            ("Looks good", "看起来不错"),
            ("The queue drains.", "队列已清空。")
        ]

        for (source, translation) in cases {
            let start = TranslatePanelLayout.panelHeight(
                original: source,
                translated: ""
            )

            for prefix in prefixes(of: translation) {
                let height = TranslatePanelLayout.panelHeight(
                    original: source,
                    translated: prefix
                )
                expect(
                    abs(height - start) < moveThreshold,
                    "\"\(source)\" moved the window at \"\(prefix)\": "
                        + "\(start) → \(height)"
                )
            }
        }
    }

    /// 流式途中的任何一帧都不应高过最终结果，否则结束时必然缩回去。
    @MainActor
    private static func streamingNeverExceedsTheFinalHeight() {
        let translation = String(
            repeating: "调度器会在后台 actor 中清空队列，因此过期的响应不会覆盖新修订。",
            count: 4
        )
        let final = TranslatePanelLayout.panelHeight(
            original: "x",
            translated: translation
        )

        for prefix in prefixes(of: translation) {
            let height = TranslatePanelLayout.panelHeight(
                original: "x",
                translated: prefix
            )
            expect(
                height <= final,
                "streaming height \(height) exceeded final \(final)"
            )
        }
    }

    /// 消除抖动不能把动态高度一起改死：长译文仍要撑高窗口。
    @MainActor
    private static func longTranslationStillGrowsTheWindow() {
        let unit = "调度器会在后台 actor 中清空队列，因此过期的响应不会覆盖新修订。"
        let short = TranslatePanelLayout.panelHeight(
            original: "x",
            translated: unit
        )
        let long = TranslatePanelLayout.panelHeight(
            original: "x",
            translated: String(repeating: unit, count: 6)
        )
        expect(
            long > short + moveThreshold,
            "a long translation must still grow the window (\(short) vs \(long))"
        )
        expect(
            long <= TranslatePanelLayout.baseHeight
                + TranslatePanelLayout.translationMaximumHeight,
            "window height must stay bounded"
        )
    }

    /// 高度必须是内容的纯函数：同样的原文与译文，两次调用结果一致。
    @MainActor
    private static func heightIsAPureFunctionOfContent() {
        let source = "The scheduler drains the queue."
        let translation = "调度器会清空队列。"
        let first = TranslatePanelLayout.panelHeight(
            original: source,
            translated: translation
        )
        let second = TranslatePanelLayout.panelHeight(
            original: source,
            translated: translation
        )
        expect(first == second, "panel height must be deterministic")
    }

    /// 划词气泡走的是同一套逻辑，同样不能抖。
    @MainActor
    private static func miniHUDShortTranslationNeverMovesThePanel() {
        let source = "scheduler"
        let start = MiniHUDLayout.panelHeight(original: source, translated: "")

        for prefix in prefixes(of: "调度器") {
            let height = MiniHUDLayout.panelHeight(
                original: source,
                translated: prefix
            )
            expect(
                abs(height - start) < moveThreshold,
                "mini HUD moved at \"\(prefix)\": \(start) → \(height)"
            )
        }
    }

    /// 模拟流式：从第一个字符到完整译文的每一个前缀。
    private static func prefixes(of text: String) -> [String] {
        (1...text.count).map { String(text.prefix($0)) }
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        guard condition() else {
            fatalError("TranslatePanelLayoutTests failed: \(message)")
        }
    }
}
