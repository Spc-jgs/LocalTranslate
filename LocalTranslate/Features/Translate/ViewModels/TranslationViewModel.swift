import Foundation
import Combine
import AppKit

@MainActor
final class TranslationViewModel: ObservableObject {
    let session: TranslationSession

    @Published var isPinned = false
    @Published var inputFocusRequest = 0

    private var cancellables = Set<AnyCancellable>()

    var originalText: String {
        get { session.originalText }
        set { session.originalText = newValue }
    }

    var translatedText: String {
        get { session.translatedText }
        set { session.translatedText = newValue }
    }

    var isTranslating: Bool { session.isTranslating }

    var copied: Bool { session.copied }

    var errorMessage: String? {
        get { session.errorMessage }
        set { session.errorMessage = newValue }
    }

    init(session existing: TranslationSession? = nil) {
        let session = existing ?? .ollama()
        self.session = session
        session.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    // MARK: - Selected Text

    func loadSelectedText(_ text: String) {
        session.cancel()
        originalText = text
        translatedText = ""
        errorMessage = nil
    }

    // MARK: - Manual Input

    func prepareManualInput(clearExisting: Bool = false) {
        session.cancel()
        errorMessage = nil
        if clearExisting {
            originalText = ""
            translatedText = ""
        }
    }

    func requestInputFocus() {
        inputFocusRequest += 1
    }

    func updateOriginalTextFromUser(_ text: String) {
        guard text != originalText else { return }
        session.cancel()
        originalText = text
        translatedText = ""
        errorMessage = nil
    }

    func clearAll() {
        session.reset()
        requestInputFocus()
    }

    // MARK: - Translate

    func translate() {
        let text = originalText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if text.isEmpty {
            session.beginTranslation(
                of: text,
                style: AppSettings.translationStyle,
                customPrompt: AppSettings.customPrompt,
                emptyMessage: "请输入需要翻译的内容"
            )
            requestInputFocus()
            return
        }

        SpeechReader.shared.stop()
        session.beginTranslation(
            of: text,
            style: AppSettings.translationStyle,
            customPrompt: AppSettings.customPrompt,
            emptyMessage: "请输入需要翻译的内容"
        )
    }

    // MARK: - Pin

    func togglePinned() {
        isPinned.toggle()
    }

    // MARK: - Copy

    func copyTranslation() {
        session.copyTranslation(
            allowOriginalFallback: false,
            feedbackDuration: 1.5
        )
    }
}
