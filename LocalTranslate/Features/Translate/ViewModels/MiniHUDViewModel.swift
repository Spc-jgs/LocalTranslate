import Foundation
import Combine
import AppKit

@MainActor
final class MiniHUDViewModel: ObservableObject {

    @Published var originalText = ""
    @Published var translatedText = ""
    @Published var isTranslating = false
    @Published var copied = false
    @Published var isPinned = false
    @Published var errorMessage: String?

    private var translationTask: Task<Void, Never>?
    private var copyFeedbackGeneration = 0

    func loadAndTranslate(_ text: String) {
        cancelTranslation()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        originalText = trimmed
        translatedText = ""
        errorMessage = nil

        guard !trimmed.isEmpty else {
            errorMessage = "未检测到选中文本"
            return
        }

        let translationStyle = AppSettings.translationStyle
        let customPrompt = AppSettings.customPrompt
        isTranslating = true

        translationTask = Task { [weak self] in
            guard let self else { return }

            do {
                let result = try await OllamaClient.shared.translateStream(
                    trimmed,
                    style: translationStyle,
                    customPrompt: customPrompt
                ) { [weak self] partialResult in
                    guard let self else { return }
                    guard self.originalText == trimmed else { return }
                    self.translatedText = partialResult
                }

                guard !Task.isCancelled else { return }
                guard self.originalText == trimmed else { return }
                self.translatedText = result
                self.isTranslating = false
            } catch {
                guard !Task.isCancelled else { return }
                self.errorMessage = error.localizedDescription
                self.isTranslating = false
            }
        }
    }

    func cancelTranslation() {
        translationTask?.cancel()
        translationTask = nil
        isTranslating = false
    }

    func togglePinned() {
        isPinned.toggle()
    }

    func copyTranslation() {
        let text = translatedText.isEmpty ? originalText : translatedText
        guard !text.isEmpty else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        copied = true
        copyFeedbackGeneration += 1
        let generation = copyFeedbackGeneration

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, self.copyFeedbackGeneration == generation else { return }
            self.copied = false
        }
    }

    func reset() {
        cancelTranslation()
        originalText = ""
        translatedText = ""
        errorMessage = nil
        copied = false
    }
}
