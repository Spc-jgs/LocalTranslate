import Foundation
import NaturalLanguage

/// 翻译的目标语言。
///
/// 源语言不在这里枚举：它由 `NLLanguageRecognizer` 从原文里认出来，能认多少
/// 就支持多少。只有目标语言需要用户挑选，才需要一份受控列表。
nonisolated enum TranslationLanguage:
    String,
    CaseIterable,
    Identifiable,
    Codable,
    Sendable {

    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case english = "en"
    case japanese = "ja"
    case korean = "ko"
    case french = "fr"
    case german = "de"
    case spanish = "es"
    case russian = "ru"

    var id: String { rawValue }

    /// 界面上的名字，同时也是写进 Prompt 的语言称呼。
    var displayName: String {
        switch self {
        case .simplifiedChinese: return "简体中文"
        case .traditionalChinese: return "繁體中文"
        case .english: return "英文"
        case .japanese: return "日文"
        case .korean: return "韩文"
        case .french: return "法文"
        case .german: return "德文"
        case .spanish: return "西班牙文"
        case .russian: return "俄文"
        }
    }

    var nlLanguage: NLLanguage {
        switch self {
        case .simplifiedChinese: return .simplifiedChinese
        case .traditionalChinese: return .traditionalChinese
        case .english: return .english
        case .japanese: return .japanese
        case .korean: return .korean
        case .french: return .french
        case .german: return .german
        case .spanish: return .spanish
        case .russian: return .russian
        }
    }

    /// 朗读时用的语音代码。
    ///
    /// **不能**直接用 `rawValue`：不带地区码时系统挑出来的声音很意外——
    /// 本机实测 `"en"` 给 Karen[en-AU]（澳洲口音）、`"fr"` 给 Amélie[fr-CA]
    /// （加拿大法语）、`"zh-Hant"` 给 Tingting[zh-CN]（繁中配普通话音）。
    var speechLanguageCode: String {
        switch self {
        case .simplifiedChinese: return "zh-CN"
        case .traditionalChinese: return "zh-TW"
        case .english: return "en-US"
        case .japanese: return "ja-JP"
        case .korean: return "ko-KR"
        case .french: return "fr-FR"
        case .german: return "de-DE"
        case .spanish: return "es-ES"
        case .russian: return "ru-RU"
        }
    }

    /// 原文已经是目标语言时翻到哪里去。
    ///
    /// 选中文的人选中一段中文按下快捷键，想要的是英文，而不是把中文再润色一遍；
    /// 反过来选英文的人选中英文，想要的是中文。
    var counterpart: TranslationLanguage {
        switch self {
        case .simplifiedChinese, .traditionalChinese:
            return .english
        default:
            return .simplifiedChinese
        }
    }

    /// `NLLanguage` 到目标语言的对应，用于判断原文是否已经是目标语言。
    static func matching(_ language: NLLanguage) -> TranslationLanguage? {
        allCases.first { $0.nlLanguage == language }
    }

    /// 识别出的源语言在 Prompt 里怎么称呼。
    ///
    /// 不局限于本枚举：认出土耳其语就说土耳其语，交给系统本地化取名，
    /// 取不到就退回语言代码本身。
    static func sourceName(for language: NLLanguage) -> String {
        if let known = matching(language) {
            return known.displayName
        }

        let code = language.rawValue
        let chinese = Locale(identifier: "zh-Hans")
        if let localized = chinese.localizedString(forLanguageCode: code),
           !localized.isEmpty,
           localized != code {
            return localized
        }
        return code
    }
}

// MARK: - 朗读原文时的语言判定

extension TranslationLanguage {

    /// 单词的识别置信度低于这个值时，一律当英文。
    ///
    /// 实测（候选集约束到本枚举的 9 种语言）：30 个英文技术词里有 5 个被判成
    /// 别的语言，而且是**高**置信度——`cache` 法语 0.80、`idempotent` 德语
    /// 0.70、`coroutine` 法语 0.68、`queue` 法语 0.60。这些恰是划词最常选的词，
    /// 用法语音念 `cache` 会让人以为功能坏了。
    ///
    /// 扫描阈值后取 0.85：英文 30/30 全对，同时保住真外语单词——`Bonjour`
    /// 0.91、`merci` 0.88、`croissant` 0.99、`Schadenfreude` 1.00 都在线上。
    /// 代价是 `Autobahn`（德语 0.70）会被当英文念。
    ///
    /// 不取 0.80 是因为 `cache` 恰好落在 0.80，卡边界上靠浮点数运气。
    static let singleWordConfidenceFloor = 0.85

    /// 朗读一段原文该用哪种语音；判不出来返回 `nil`，由调用方禁用按钮。
    ///
    /// 字形优先——假名、谚文、西里尔、汉字都是确定的，不需要猜。只有拉丁
    /// 字母才交给识别器，且单词走上面那条置信度下限。
    static func speechLanguage(forSource text: String) -> TranslationLanguage? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else { return nil }

        if let byScript = languageByScript(trimmed) {
            return byScript
        }

        return latinLanguage(trimmed)
    }

    /// 按字形判定。日文与韩文可能夹杂汉字，因此必须先于汉字判断。
    private static func languageByScript(
        _ text: String
    ) -> TranslationLanguage? {

        var hasHan = false

        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3040...0x30FF:            // 平假名与片假名
                return .japanese
            case 0x1100...0x11FF,            // 谚文字母
                 0x3130...0x318F,
                 0xAC00...0xD7AF:            // 谚文音节
                return .korean
            case 0x0400...0x04FF:            // 西里尔字母
                return .russian
            case 0x4E00...0x9FFF,            // 汉字
                 0x3400...0x4DBF:
                hasHan = true
            default:
                continue
            }
        }

        return hasHan ? .simplifiedChinese : nil
    }

    private static func latinLanguage(
        _ text: String
    ) -> TranslationLanguage? {

        let recognizer = NLLanguageRecognizer()

        // 不约束候选集时单词会被判到 100 多种语言里去——`scheduler` 会变成
        // 挪威语，`sushi` 会变成印尼语。
        recognizer.languageConstraints = allCases.map(\.nlLanguage)
        recognizer.processString(text)

        guard let dominant = recognizer.dominantLanguage,
              dominant != .undetermined,
              let language = matching(dominant) else {
            return isSingleWord(text) ? .english : nil
        }

        guard isSingleWord(text) else { return language }

        let confidence = recognizer
            .languageHypotheses(withMaximum: 1)[dominant] ?? 0

        return confidence < singleWordConfidenceFloor ? .english : language
    }

    /// 多于一个词时识别可信（实测两词起置信度就到 0.95 以上），单词不可信。
    private static func isSingleWord(_ text: String) -> Bool {
        text.split(whereSeparator: \Character.isWhitespace).count <= 1
    }
}
