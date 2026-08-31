import Foundation

/// 全部 UserDefaults key 与默认值的唯一出处。
///
/// 任何 Feature 都不再内联裸字符串 key：key 一旦分散，读与写就会各自漂移。
nonisolated enum AppSettings {

    enum Key {

        // MARK: Translate

        static let model = "ollamaModel"
        static let baseURL = "ollamaBaseURL"
        static let keepAlive = "ollamaKeepAlive"
        static let translationStyle = "translationStyle"
        static let customPrompt = "customTranslationPrompt"

        // MARK: Live Subtitles

        static let liveSourceLanguage = "liveSubtitlesSourceLanguage"
        static let liveDisplayMode = "liveSubtitlesDisplayMode"
        static let liveFontSize = "liveSubtitlesFontSize"
        static let liveClickThrough = "liveSubtitlesClickThrough"

        // MARK: AI Usage

        static let usageProviderConfigurations = "aiUsageProviderConfigurations"
    }

    // MARK: - Translate

    static let defaultModel = "qwen3.5:4b"
    static let defaultBaseURL = "http://127.0.0.1:11434"
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

    // MARK: - Live Subtitles

    static let defaultLiveFontSize: CGFloat = 26
    static let liveFontSizeRange: ClosedRange<CGFloat> = 16...34
    static let liveFontSizeStep: CGFloat = 2

    static var liveClickThrough: Bool {
        UserDefaults.standard.bool(
            forKey: Key.liveClickThrough
        )
    }
}
