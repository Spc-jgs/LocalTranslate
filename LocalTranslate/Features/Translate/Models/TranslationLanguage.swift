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
