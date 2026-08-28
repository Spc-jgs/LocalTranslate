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

public enum SubtitleSourceLanguage: String, CaseIterable, Identifiable {
    case auto = "auto"
    case japanese = "ja-JP"
    case english = "en-US"
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
        case .auto: return "自动识别"
        case .japanese: return "日语 (日本語)"
        case .english: return "英语 (English)"
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
        case .auto: return "自动"
        case .japanese: return "日语"
        case .english: return "英语"
        case .korean: return "韩语"
        case .chinese: return "中文"
        case .cantonese: return "粤语"
        case .french: return "法语"
        case .german: return "德语"
        case .spanish: return "西语"
        case .russian: return "俄语"
        }
    }
}
