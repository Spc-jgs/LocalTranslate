import Foundation

public struct SubtitleItem: Identifiable, Equatable {
    public let id: UUID
    public var originalText: String
    public var translatedText: String
    public var sourceLanguage: String
    public let createdAt: Date
    public var isFinal: Bool

    public init(
        id: UUID = UUID(),
        originalText: String,
        translatedText: String = "",
        sourceLanguage: String = "auto",
        createdAt: Date = Date(),
        isFinal: Bool = false
    ) {
        self.id = id
        self.originalText = originalText
        self.translatedText = translatedText
        self.sourceLanguage = sourceLanguage
        self.createdAt = createdAt
        self.isFinal = isFinal
    }
}

public enum SubtitleDisplayMode: String, CaseIterable, Identifiable {
    case bilingual = "bilingual"
    case chineseOnly = "chineseOnly"
    case originalOnly = "originalOnly"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .bilingual: return "双语"
        case .chineseOnly: return "仅译文"
        case .originalOnly: return "仅原文"
        }
    }

    public var iconName: String {
        switch self {
        case .bilingual: return "character.bubble.fill"
        case .chineseOnly: return "text.bubble"
        case .originalOnly: return "character"
        }
    }
}

public enum SubtitleSourceLanguage: String, CaseIterable, Identifiable {
    case english = "en-US"
    case japanese = "ja-JP"
    case korean = "ko-KR"
    case chinese = "zh-CN"
    case cantonese = "zh-HK"
    case french = "fr-FR"
    case german = "de-DE"
    case spanish = "es-ES"
    case russian = "ru-RU"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .english: return "英语 (English)"
        case .japanese: return "日语 (日本語)"
        case .korean: return "韩语 (한국어)"
        case .chinese: return "普通话 (中文)"
        case .cantonese: return "粤语 (廣東話)"
        case .french: return "法语 (Français)"
        case .german: return "德语 (Deutsch)"
        case .spanish: return "西班牙语 (Español)"
        case .russian: return "俄语 (Русский)"
        }
    }

    public var shortName: String {
        switch self {
        case .english: return "英语"
        case .japanese: return "日语"
        case .korean: return "韩语"
        case .chinese: return "中文"
        case .cantonese: return "粤语"
        case .french: return "法语"
        case .german: return "德语"
        case .spanish: return "西语"
        case .russian: return "俄语"
        }
    }

    public var needsTranslationToSimplifiedChinese: Bool {
        self != .chinese && self != .cantonese
    }
}
