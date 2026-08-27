import Foundation

enum AppSettings {

    enum Key {
        static let model = "ollamaModel"
        static let baseURL = "ollamaBaseURL"
        static let keepAlive = "ollamaKeepAlive"
        static let translationStyle = "translationStyle"
        static let customPrompt = "customTranslationPrompt"
    }

    static let defaultModel = "qwen3.5:4b"
    static let defaultBaseURL = "http://localhost:11434"
    static let defaultKeepAlive = "10m"
    static let defaultTranslationStyleRaw = TranslationStyle.standard.rawValue
    static let defaultCustomPrompt = ""

    static var model: String {
        UserDefaults.standard.string(
            forKey: Key.model
        ) ?? defaultModel
    }

    static var baseURL: String {
        UserDefaults.standard.string(
            forKey: Key.baseURL
        ) ?? defaultBaseURL
    }

    static var keepAlive: String {
        UserDefaults.standard.string(
            forKey: Key.keepAlive
        ) ?? defaultKeepAlive
    }

    static var translationStyle: TranslationStyle {
        let rawValue = UserDefaults.standard.string(
            forKey: Key.translationStyle
        ) ?? defaultTranslationStyleRaw

        return TranslationStyle(rawValue: rawValue)
            ?? .standard
    }

    static var customPrompt: String {
        UserDefaults.standard.string(
            forKey: Key.customPrompt
        ) ?? defaultCustomPrompt
    }
}
