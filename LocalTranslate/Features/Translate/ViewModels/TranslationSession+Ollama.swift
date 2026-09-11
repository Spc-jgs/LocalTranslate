import Foundation

extension TranslationSession {
    /// 面板和气泡共用的本机 Ollama 流。错误文案走 `OllamaFailure`，
    /// 会话本身不认识 Ollama。
    static func ollama() -> TranslationSession {
        TranslationSession(
            stream: { text, style, prompt, onPartial in
                try await OllamaClient.shared.translateStream(
                    text,
                    style: style,
                    customPrompt: prompt,
                    onPartialResult: onPartial
                )
            },
            errorMessageFor: { OllamaFailure.message(for: $0) }
        )
    }
}
