import SwiftUI
import AppKit
import Combine

@MainActor
final class TranslationViewModel: ObservableObject {

    @Published var originalText = ""
    @Published var translatedText = ""

    @Published var isTranslating = false
    @Published var copied = false

    @Published var errorMessage: String?

    func loadSelectedText(_ text: String) {
        originalText = text
        translatedText = ""
        errorMessage = nil
    }

    func translate() {

        let text = originalText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        guard !text.isEmpty else {
            errorMessage = "没有需要翻译的文字"
            return
        }

        isTranslating = true
        errorMessage = nil
        translatedText = ""

        Task {
            do {
                let result = try await OllamaClient.shared.translate(text)

                translatedText = result
                isTranslating = false
            } catch {
                errorMessage = "翻译失败：\(error.localizedDescription)"
                isTranslating = false
            }
        }
    }

    func copyTranslation() {

        guard !translatedText.isEmpty else {
            return
        }

        NSPasteboard.general.clearContents()

        NSPasteboard.general.setString(
            translatedText,
            forType: .string
        )

        copied = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            self.copied = false
        }
    }
}
