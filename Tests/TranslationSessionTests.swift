import Foundation
import Combine

@main
struct TranslationSessionTests {
    static func main() {
        MainActor.assumeIsolated {
            run()
        }
    }

    @MainActor
    private static func run() {
        emptyInputSetsErrorAndDoesNotStream()
        stalePartialIsDiscarded()
        cancellationDoesNotSurfaceAsError()
        copyUsesGenerationSoASecondCopyIsNotClearedByTheFirstTimer()
        hudCopyFallsBackToOriginalWhenTranslationIsEmpty()
        panelCopyDoesNotFallBackToOriginal()
        print("TranslationSessionTests: 6 passed")
    }

    @MainActor
    private static func emptyInputSetsErrorAndDoesNotStream() {
        let fake = FakeStream()
        let session = TranslationSession(stream: fake.run)
        session.beginTranslation(
            of: "   ",
            style: .standard,
            customPrompt: "",
            emptyMessage: "请输入需要翻译的内容"
        )
        expect(fake.started == 0, "空输入不该发请求")
        expect(
            session.errorMessage == "请输入需要翻译的内容",
            "空输入必须用调用方给的那句话，实际 \(session.errorMessage ?? "nil")"
        )
        expect(!session.isTranslating, "空输入不该进入翻译中")
    }

    @MainActor
    private static func stalePartialIsDiscarded() {
        let fake = FakeStream()
        fake.partials = ["旧译文"]
        fake.result = "完整旧译文"
        fake.holdBeforeFinish = true
        let session = TranslationSession(stream: fake.run)
        session.originalText = "first"
        session.beginTranslation(
            of: "first",
            style: .standard,
            customPrompt: "",
            emptyMessage: "empty"
        )
        spinUntil { fake.started == 1 }
        expect(fake.started == 1, "请求没有发出")
        expect(session.isTranslating, "发出请求后应处于翻译中")
        session.originalText = "second"
        fake.release()
        spinUntil { !session.isTranslating || session.translatedText == "完整旧译文" }
        expect(
            session.translatedText != "完整旧译文",
            "原文已改，旧流的完成结果必须丢掉"
        )
        expect(
            session.translatedText != "旧译文",
            "原文已改，旧流的 partial 必须丢掉"
        )
    }

    @MainActor
    private static func cancellationDoesNotSurfaceAsError() {
        let fake = FakeStream()
        fake.holdBeforeFinish = true
        fake.error = CancellationError()
        let session = TranslationSession(stream: fake.run)
        session.originalText = "hello"
        session.beginTranslation(
            of: "hello",
            style: .standard,
            customPrompt: "",
            emptyMessage: "empty"
        )
        spinUntil { fake.started == 1 }
        session.cancel()
        fake.release()
        spinUntil { !session.isTranslating }
        expect(session.errorMessage == nil, "取消不该变成错误文案")
        expect(!session.isTranslating, "取消后必须离开翻译中")
    }

    @MainActor
    private static func copyUsesGenerationSoASecondCopyIsNotClearedByTheFirstTimer() {
        let session = TranslationSession(stream: FakeStream().run)
        session.translatedText = "译文"
        session.copyTranslation(allowOriginalFallback: false, feedbackDuration: 0.05)
        expect(session.copied, "第一次复制应点亮")
        session.copyTranslation(allowOriginalFallback: false, feedbackDuration: 0.2)
        Thread.sleep(forTimeInterval: 0.08)
        expect(
            session.copied,
            "第二次复制的反馈不该被第一次的定时器清掉"
        )
    }

    @MainActor
    private static func hudCopyFallsBackToOriginalWhenTranslationIsEmpty() {
        let session = TranslationSession(stream: FakeStream().run)
        session.originalText = "cache"
        session.translatedText = ""
        session.copyTranslation(allowOriginalFallback: true, feedbackDuration: 1)
        expect(session.copied, "气泡在译文为空时应能复制原文")
    }

    @MainActor
    private static func panelCopyDoesNotFallBackToOriginal() {
        let session = TranslationSession(stream: FakeStream().run)
        session.originalText = "cache"
        session.translatedText = ""
        session.copyTranslation(allowOriginalFallback: false, feedbackDuration: 1)
        expect(!session.copied, "主面板没有译文时不应复制原文")
    }

    @MainActor
    private static func spinUntil(
        timeout: TimeInterval = 0.5,
        _ condition: () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }

    @MainActor
    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        guard condition() else {
            fatalError("TranslationSessionTests failed: \(message)")
        }
    }
}

@MainActor
private final class FakeStream: @unchecked Sendable {
    var started = 0
    var result = "译文"
    var partials: [String] = []
    var error: Error?
    var holdBeforeFinish = false
    private var continuation: CheckedContinuation<Void, Never>?

    func run(
        _ text: String,
        style: TranslationStyle,
        customPrompt: String,
        onPartial: @escaping @MainActor (String) -> Void
    ) async throws -> String {
        started += 1
        if holdBeforeFinish {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }
        for partial in partials {
            onPartial(partial)
        }
        if let error {
            throw error
        }
        return result
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
