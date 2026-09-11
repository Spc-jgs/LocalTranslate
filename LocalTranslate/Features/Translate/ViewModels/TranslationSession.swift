import Foundation
import AppKit
import Combine

/// 一次翻译请求的共享执行器。面板和气泡各自持有一份，窗口生命周期不合并。
///
/// 负责：发起流式请求、用原文身份丢掉 stale 回调、取消、带 generation 的复制反馈。
/// 不负责：钉住、焦点、OCR、朗读——那些是窗口自己的事。
@MainActor
final class TranslationSession: ObservableObject {

    typealias Streamer = (
        _ text: String,
        _ style: TranslationStyle,
        _ customPrompt: String,
        _ onPartial: @escaping @MainActor (String) -> Void
    ) async throws -> String

    @Published var originalText = ""
    @Published var translatedText = ""
    @Published var isTranslating = false
    @Published var copied = false
    @Published var errorMessage: String?

    private let stream: Streamer
    private let errorMessageFor: (Error) -> String
    private var translationTask: Task<Void, Never>?
    private var requestGeneration = 0
    private var copyFeedbackGeneration = 0

    init(
        stream: @escaping Streamer,
        errorMessageFor: @escaping (Error) -> String = { error in
            error.localizedDescription
        }
    ) {
        self.stream = stream
        self.errorMessageFor = errorMessageFor
    }

    func beginTranslation(
        of text: String,
        style: TranslationStyle,
        customPrompt: String,
        emptyMessage: String
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            cancel()
            errorMessage = emptyMessage
            return
        }

        cancel()
        translatedText = ""
        errorMessage = nil
        isTranslating = true
        requestGeneration += 1
        let generation = requestGeneration
        let requested = trimmed

        translationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.stream(
                    requested,
                    style,
                    customPrompt
                ) { [weak self] partial in
                    guard let self else { return }
                    guard self.requestGeneration == generation,
                          self.matches(requested) else { return }
                    self.translatedText = partial
                }

                guard !Task.isCancelled else { return }
                guard self.requestGeneration == generation else { return }
                guard self.matches(requested) else {
                    self.isTranslating = false
                    self.translationTask = nil
                    return
                }
                self.translatedText = result
                self.isTranslating = false
                self.translationTask = nil
            } catch is CancellationError {
                guard self.requestGeneration == generation else { return }
                self.isTranslating = false
                self.translationTask = nil
            } catch {
                guard !Task.isCancelled else { return }
                guard self.requestGeneration == generation else { return }
                self.errorMessage = self.errorMessageFor(error)
                self.isTranslating = false
                self.translationTask = nil
            }
        }
    }

    func cancel() {
        requestGeneration += 1
        translationTask?.cancel()
        translationTask = nil
        isTranslating = false
    }

    func copyTranslation(
        allowOriginalFallback: Bool,
        feedbackDuration: TimeInterval
    ) {
        let text: String
        if !translatedText.isEmpty {
            text = translatedText
        } else if allowOriginalFallback {
            text = originalText
        } else {
            return
        }
        guard !text.isEmpty else { return }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        copyFeedbackGeneration += 1
        let generation = copyFeedbackGeneration
        guard feedbackDuration > 0 else { return }

        DispatchQueue.main.asyncAfter(
            deadline: .now() + feedbackDuration
        ) { [weak self] in
            guard let self,
                  self.copyFeedbackGeneration == generation else { return }
            self.copied = false
        }
    }

    func reset() {
        cancel()
        originalText = ""
        translatedText = ""
        errorMessage = nil
        copied = false
    }

    private func matches(_ requested: String) -> Bool {
        originalText.trimmingCharacters(in: .whitespacesAndNewlines)
            == requested
    }
}
