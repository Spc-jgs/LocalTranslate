import Foundation

nonisolated enum TranslationStyle: String, CaseIterable, Identifiable, Codable {

    case standard
    case natural
    case concise
    case formal
    case literal
    case custom

    var id: String {
        rawValue
    }

    // MARK: - UI

    var title: String {
        switch self {

        case .standard:
            return "默认"

        case .natural:
            return "自然"

        case .concise:
            return "简洁"

        case .formal:
            return "正式"

        case .literal:
            return "直译"

        case .custom:
            return "自定义"
        }
    }

    var shortDescription: String {
        switch self {

        case .standard:
            return "保持当前默认翻译方式"

        case .natural:
            return "更符合母语表达习惯，减少机器翻译感"

        case .concise:
            return "减少冗余，让表达更精炼直接"

        case .formal:
            return "适合工作、邮件、文档等正式场景"

        case .literal:
            return "尽量保留原文结构、措辞和信息顺序"

        case .custom:
            return "使用设置中填写的自定义附加 Prompt"
        }
    }

    // MARK: - Prompt

    var promptInstruction: String? {
        switch self {

        case .standard:
            return nil

        case .natural:
            return """
            翻译风格：自然。
            让译文更像目标语言母语者自然写出的内容。
            在不改变原意、语气、事实、信息量与原文排版结构的前提下，可以适度调整句式和措辞，避免生硬的机器翻译腔。
            严格保留原文的列表分行与段落换行结构。
            """

        case .concise:
            return """
            翻译风格：简洁。
            在完整保留原文有效信息、语气、含义与排版结构的前提下，让译文更精炼、直接，减少不必要的冗余表达。
            不得把翻译变成摘要，不得省略重要信息或合并列表项，保留换行。
            """

        case .formal:
            return """
            翻译风格：正式。
            使用自然、专业、克制的表达，适合工作沟通、邮件、正式文章和文档。
            保持原文的真实含义和确定程度，不要擅自提高礼貌程度、权威性或正式程度之外的语义。
            """

        case .literal:
            return """
            翻译风格：直译。
            在目标语言仍然通顺可读的前提下，尽量保留原文的句式结构、措辞关系、强调方式和信息顺序。
            避免不必要的改写、本地化发挥或风格润色。
            """

        case .custom:
            return nil
        }
    }
}
