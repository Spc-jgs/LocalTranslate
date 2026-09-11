import Foundation
import Combine
import AppKit

@MainActor
final class MiniHUDViewModel: ObservableObject {
    let session: TranslationSession

    @Published var isPinned = false

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

    func loadAndTranslate(_ text: String) {
        SpeechReader.shared.stop()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        originalText = trimmed
        session.beginTranslation(
            of: trimmed,
            style: AppSettings.translationStyle,
            customPrompt: AppSettings.customPrompt,
            emptyMessage: "未检测到选中文本"
        )
    }

    func cancelTranslation() {
        session.cancel()
    }

    func togglePinned() {
        isPinned.toggle()
    }

    func copyTranslation() {
        session.copyTranslation(
            allowOriginalFallback: true,
            feedbackDuration: 1.2
        )
    }

    func reset() {
        session.reset()
        isPinned = false
    }
}
