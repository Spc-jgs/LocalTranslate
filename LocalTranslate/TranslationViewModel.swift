import Foundation
import Combine
import AppKit

@MainActor
final class TranslationViewModel: ObservableObject {

    @Published var originalText = ""
    @Published var translatedText = ""

    @Published var isTranslating = false
    @Published var copied = false
    @Published var isPinned = false

    @Published var errorMessage: String?

    @Published var inputFocusRequest = 0

    private var translationTask:
        Task<Void, Never>?

    // MARK: - Selected Text

    func loadSelectedText(
        _ text: String
    ) {

        cancelTranslation()

        originalText = text
        translatedText = ""
        errorMessage = nil
    }

    // MARK: - Manual Input

    func prepareManualInput(
        clearExisting: Bool = false
    ) {

        cancelTranslation()

        errorMessage = nil

        if clearExisting {
            originalText = ""
            translatedText = ""
        }
    }

    func requestInputFocus() {
        inputFocusRequest += 1
    }

    func updateOriginalTextFromUser(
        _ text: String
    ) {

        guard text != originalText else {
            return
        }

        cancelTranslation()

        originalText = text
        translatedText = ""
        errorMessage = nil
    }

    func clearAll() {

        cancelTranslation()

        originalText = ""
        translatedText = ""
        errorMessage = nil

        requestInputFocus()
    }

    // MARK: - Translate

    func translate() {

        let text =
            originalText
                .trimmingCharacters(
                    in:
                        .whitespacesAndNewlines
                )

        guard !text.isEmpty else {

            errorMessage =
                "请输入需要翻译的内容"

            requestInputFocus()

            return
        }

        cancelTranslation()

        translatedText = ""
        errorMessage = nil
        isTranslating = true

        translationTask =
            Task { [weak self] in

                guard let self else {
                    return
                }

                do {

                    let result =
                        try await
                        OllamaClient.shared
                            .translateStream(
                                text
                            ) {
                                [weak self]
                                partialResult in

                                guard
                                    let self
                                else {
                                    return
                                }

                                let currentText =
                                    self
                                        .originalText
                                        .trimmingCharacters(
                                            in:
                                                .whitespacesAndNewlines
                                        )

                                // 用户中途已经改了原文，
                                // 不再接收旧流。
                                guard
                                    currentText
                                    == text
                                else {
                                    return
                                }

                                self.translatedText =
                                    partialResult
                            }

                    guard
                        !Task.isCancelled
                    else {
                        return
                    }

                    let currentText =
                        self.originalText
                            .trimmingCharacters(
                                in:
                                    .whitespacesAndNewlines
                            )

                    guard
                        currentText == text
                    else {
                        return
                    }

                    self.translatedText =
                        result

                    self.isTranslating =
                        false

                    self.translationTask =
                        nil

                } catch is CancellationError {

                    self.isTranslating =
                        false

                    self.translationTask =
                        nil

                } catch {

                    guard
                        !Task.isCancelled
                    else {
                        return
                    }

                    self.errorMessage =
                        "翻译失败：\(error.localizedDescription)"

                    self.isTranslating =
                        false

                    self.translationTask =
                        nil
                }
            }
    }

    private func cancelTranslation() {

        translationTask?.cancel()
        translationTask = nil

        isTranslating = false
    }

    // MARK: - Pin

    func togglePinned() {
        isPinned.toggle()
    }

    // MARK: - Copy

    func copyTranslation() {

        guard
            !translatedText.isEmpty
        else {
            return
        }

        NSPasteboard.general
            .clearContents()

        NSPasteboard.general
            .setString(
                translatedText,
                forType: .string
            )

        copied = true

        DispatchQueue.main
            .asyncAfter(
                deadline:
                    .now() + 1.5
            ) {
                [weak self] in

                self?.copied = false
            }
    }
}
