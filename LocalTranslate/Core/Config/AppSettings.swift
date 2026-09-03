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
        static let targetLanguage = "translationTargetLanguage"

        // MARK: Live Subtitles

        static let liveSourceLanguage = "liveSubtitlesSourceLanguage"
        static let liveDisplayMode = "liveSubtitlesDisplayMode"
        static let liveFontSize = "liveSubtitlesFontSize"
        static let liveDiagnosticsLog = "liveSubtitlesDiagnosticsLog"

        // MARK: AI Usage

        static let usageProviderConfigurations = "aiUsageProviderConfigurations"
    }

    // MARK: - Translate

    static let defaultModel = "qwen3.5:4b"
    static let defaultBaseURL = "http://127.0.0.1:11434"
    static let defaultKeepAlive = "10m"
    static let defaultTranslationStyleRaw = TranslationStyle.standard.rawValue
    static let defaultCustomPrompt = ""
    static let defaultTargetLanguage = TranslationLanguage.simplifiedChinese

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

    /// 翻译目标语言。原文已经是它时翻到 `counterpart`。
    static var targetLanguage: TranslationLanguage {
        guard let raw = UserDefaults.standard.string(
            forKey: Key.targetLanguage
        ), let language = TranslationLanguage(rawValue: raw) else {
            return defaultTargetLanguage
        }
        return language
    }

    // MARK: - Live Subtitles

    static let defaultLiveFontSize: CGFloat = 26

    static var liveFontSize: CGFloat {
        let stored = CGFloat(
            UserDefaults.standard.double(
                forKey: Key.liveFontSize
            )
        )
        return liveFontSizeRange.contains(stored)
            ? stored
            : defaultLiveFontSize
    }
    static let liveFontSizeRange: ClosedRange<CGFloat> = 16...34
    static let liveFontSizeStep: CGFloat = 2

    /// 是否把实时字幕的节奏诊断写到磁盘。
    ///
    /// 默认关闭：实时字幕的基线之一就是「不写盘」，不能因为想看数据就让所有人
    /// 一直付这个代价。要调字幕节奏时打开，跑一段访谈，再关掉。
    static var liveDiagnosticsLogEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Key.liveDiagnosticsLog) }
        set {
            UserDefaults.standard.set(newValue, forKey: Key.liveDiagnosticsLog)
        }
    }
}
