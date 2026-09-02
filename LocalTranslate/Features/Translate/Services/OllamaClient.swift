import Foundation
import NaturalLanguage

// MARK: - Chat Models

struct OllamaChatRequest: Encodable {

    /// 采样参数。
    ///
    /// 翻译是确定性任务：同一段原文两次翻译应当得到同一结果。模型自带的
    /// Modelfile 往往为对话调参（`qwen3.5:4b` 写的是 `temperature 1`），
    /// 不覆盖就会继承过来。实测同一段技术文本连翻三次会得到三种译文，
    /// 其中出现英文残留、擅自加括号解释、markdown 标记泄漏。
    struct Options: Encodable {
        let temperature: Double
    }

    let model: String
    let messages: [OllamaMessage]
    let stream: Bool
    let think: Bool
    let options: Options
    let keepAlive: String

    enum CodingKeys:
        String,
        CodingKey {

        case model
        case messages
        case stream
        case think
        case options

        case keepAlive =
            "keep_alive"
    }
}

struct OllamaMessage: Codable {

    let role: String
    let content: String
}

private struct OllamaStreamResponse:
    Decodable {

    let message: OllamaMessage?
    let done: Bool?
}

// MARK: - Show Request

private struct OllamaShowRequest:
    Encodable {

    let model: String
    let verbose: Bool
}

// MARK: - Installed Model

struct OllamaInstalledModel:
    Identifiable,
    Hashable {

    var id: String {
        name
    }

    let name: String
    let size: Int64

    let parameterSize: String?
    let quantizationLevel: String?

    let family: String?
    let format: String?

    var formattedSize: String {

        ByteCountFormatter.string(
            fromByteCount: size,
            countStyle: .file
        )
    }
}

// MARK: - Model Diagnostics

struct OllamaModelDiagnostics:
    Equatable {

    let nativeContextLength:
        Int?

    let runtimeContextLength:
        Int?

    let runtimeMemoryBytes:
        Int64?

    let isRunning:
        Bool

    // 当前 Ollama API
    // 没有直接暴露
    // OLLAMA_KV_CACHE_TYPE。
    let kvCacheQuantization:
        String?
}

// MARK: - Tags API

private struct OllamaTagsResponse:
    Decodable {

    let models:
        [OllamaTagModel]
}

private struct OllamaTagModel:
    Decodable {

    let name: String
    let size: Int64

    let details:
        OllamaTagDetails?
}

private struct OllamaTagDetails:
    Decodable {

    let format: String?
    let family: String?

    let parameterSize:
        String?

    let quantizationLevel:
        String?

    enum CodingKeys:
        String,
        CodingKey {

        case format
        case family

        case parameterSize =
            "parameter_size"

        case quantizationLevel =
            "quantization_level"
    }
}

// MARK: - PS API

private struct OllamaPSResponse:
    Decodable {

    let models:
        [OllamaRunningModel]
}

private struct OllamaRunningModel:
    Decodable {

    let name: String
    let model: String?

    let size: Int64

    let sizeVRAM:
        Int64?

    let contextLength:
        Int?

    enum CodingKeys:
        String,
        CodingKey {

        case name
        case model
        case size

        case sizeVRAM =
            "size_vram"

        case contextLength =
            "context_length"
    }
}

// MARK: - Translation Direction

/// 一次翻译的语言对。
///
/// 此前这里是个二元枚举，只有「中→英」和「英→中」两支，其余语言全部落到
/// `default` 再回退成「英→中」——选中一段日文，Prompt 会明确告诉模型
/// 「输入是英文」。现在源语言按实际识别结果写入，目标语言由用户配置。
nonisolated struct TranslationDirection {

    /// 识别出的源语言名；`nil` 表示没认出来。
    let sourceName: String?
    let targetName: String

    var instruction: String {

        guard let sourceName else {

            return """
            当前翻译目标语言固定为：

            \(targetName)

            必须把输入的自然语言内容翻译成自然、地道的\(targetName)，
            无论输入是哪种语言。

            即使输入非常短，也必须完成翻译。

            不得只做润色或改写。
            不得保持原文语言不变，除非内容属于代码、标识符、专有名称
            或明确不应该翻译的技术内容。
            """
        }

        return """
        当前翻译方向固定为：

        \(sourceName) → \(targetName)

        必须把输入中的\(sourceName)自然语言翻译成自然、
        符合\(targetName)母语者习惯的表达。

        即使输入非常短，例如只有两三个词或一个短句，也必须输出对应的\(targetName)。

        不得把输入改写成另一种\(sourceName)表达。
        不得只做\(sourceName)润色。
        不得保持\(sourceName)原样，除非内容属于代码、标识符、专有名称
        或明确不应该翻译的技术内容。
        """
    }
}

// MARK: - Errors

enum OllamaClientError:
    LocalizedError {

    case invalidURL

    case invalidResponse(
        statusCode: Int
    )

    /// 请求指定了模型，但 Ollama 说没有——这是 404 最常见的含义。
    case modelNotFound(
        model: String
    )

    case noModels

    var errorDescription:
        String? {

        switch self {

        case .invalidURL:

            return
                "Ollama 地址无效"

        case .invalidResponse(
            let statusCode
        ):

            return
                "Ollama 请求失败，HTTP \(statusCode)"

        case .modelNotFound(
            let model
        ):

            return
                OllamaFailure
                    .modelNotInstalledMessage(
                        model: model
                    )

        case .noModels:

            return
                "没有找到已安装的 Ollama 模型"
        }
    }
}

// MARK: - Client

@MainActor
final class OllamaClient {

    static let shared =
        OllamaClient()

    private init() {}

    // MARK: - Streaming Translation

    func translateStream(
        _ text: String,
        style: TranslationStyle,
        customPrompt: String,
        onPartialResult:
            @escaping
            @MainActor
            @Sendable
            (String) -> Void
    ) async throws -> String {

        let url =
            try makeURL(
                path: "/api/chat"
            )

        let direction =
            resolveDirection(
                text
            )

        let finalSystemPrompt =
            makeTranslationSystemPrompt(
                direction: direction,
                style: style,
                customPrompt:
                    customPrompt
            )

        // 固定到局部量：404 要报的是这次真正请求的模型，
        // 而不是显示报错时设置里恰好写着的那个。
        let requestedModel =
            AppSettings.model

        let body =
            OllamaChatRequest(
                model:
                    requestedModel,

                messages: [

                    OllamaMessage(
                        role: "system",
                        content:
                            finalSystemPrompt
                    ),

                    OllamaMessage(
                        role: "user",
                        content: """
                        请严格按照指定翻译方向处理下面的文本。

                        \(text)
                        """
                    )
                ],

                stream: true,

                think: false,

                options:
                    .init(
                        temperature: 0
                    ),

                keepAlive:
                    AppSettings.keepAlive
            )

        var request =
            URLRequest(
                url: url,
                timeoutInterval: 180
            )

        request.httpMethod =
            "POST"

        request.setValue(
            "application/json",
            forHTTPHeaderField:
                "Content-Type"
        )

        request.httpBody =
            try JSONEncoder()
                .encode(
                    body
                )

        let (
            bytes,
            response
        ) =
            try await
            URLSession.shared
                .bytes(
                    for: request
                )

        try Self.validate(
            response,
            requestedModel: requestedModel
        )

        var completeText =
            ""

        for try await line
            in bytes.lines {

            try Task
                .checkCancellation()

            let trimmedLine =
                line
                    .trimmingCharacters(
                        in:
                            .whitespacesAndNewlines
                    )

            guard
                !trimmedLine
                    .isEmpty
            else {
                continue
            }

            guard
                let data =
                    trimmedLine
                        .data(
                            using:
                                .utf8
                        )
            else {
                continue
            }

            let chunk =
                try JSONDecoder()
                    .decode(
                        OllamaStreamResponse.self,
                        from: data
                    )

            if
                let content =
                    chunk
                        .message?
                        .content,
                !content.isEmpty {

                completeText +=
                    content

                onPartialResult(
                    completeText
                )
            }

            if chunk.done == true {
                break
            }
        }

        return completeText
            .trimmingCharacters(
                in:
                    .whitespacesAndNewlines
            )
    }

    // MARK: - Prompt Composition

    private func
    makeTranslationSystemPrompt(
        direction:
            TranslationDirection,
        style:
            TranslationStyle,
        customPrompt:
            String
    ) -> String {

        let basePrompt =
            systemPrompt
            + "\n\n"
            + direction.instruction

        // 默认风格必须最大程度保持
        // 当前已经稳定的翻译行为。
        guard
            style != .standard
        else {

            return basePrompt
        }

        let styleInstruction:
            String

        switch style {

        case .standard:

            return basePrompt

        case .custom:

            let trimmedCustomPrompt =
                customPrompt
                    .trimmingCharacters(
                        in:
                            .whitespacesAndNewlines
                    )

            // 自定义为空时，
            // 效果等同默认翻译。
            guard
                !trimmedCustomPrompt
                    .isEmpty
            else {

                return basePrompt
            }

            styleInstruction =
                """
                用户选择了“自定义”翻译风格。

                以下内容是用户希望应用到译文表达方式上的附加偏好：

                --- 用户自定义风格开始 ---

                \(trimmedCustomPrompt)

                --- 用户自定义风格结束 ---
                """

        default:

            guard
                let instruction =
                    style
                        .promptInstruction
            else {

                return basePrompt
            }

            styleInstruction =
                instruction
        }

        return basePrompt
        + "\n\n"
        + """
        【翻译风格附加指令】

        \(styleInstruction)

        【风格指令优先级】

        上面的翻译风格只允许影响译文的表达方式。

        不得因为风格指令而改变：
        - 翻译方向
        - 原文事实
        - 原文含义
        - 信息完整性
        - 技术准确性
        - 代码与标识符保护规则
        - Markdown 与代码块保护规则
        - 输出格式要求

        如果风格指令与前面的基础翻译规则发生冲突，
        必须以前面的基础翻译规则为准。

        最终仍然只输出翻译完成后的文本，
        不得解释使用了什么风格。
        """
    }

    // MARK: - Installed Models

    func installedModels()
        async throws
        -> [OllamaInstalledModel] {

        let url =
            try makeURL(
                path: "/api/tags"
            )

        let request =
            URLRequest(
                url: url,
                timeoutInterval: 10
            )

        let (
            data,
            response
        ) =
            try await
            URLSession.shared
                .data(
                    for: request
                )

        try Self.validate(
            response,
            requestedModel: nil
        )

        let result =
            try JSONDecoder()
                .decode(
                    OllamaTagsResponse.self,
                    from: data
                )

        return result.models
            .map { model in

                OllamaInstalledModel(

                    name:
                        model.name,

                    size:
                        model.size,

                    parameterSize:
                        model
                            .details?
                            .parameterSize,

                    quantizationLevel:
                        model
                            .details?
                            .quantizationLevel,

                    family:
                        model
                            .details?
                            .family,

                    format:
                        model
                            .details?
                            .format
                )
            }
            .sorted {

                $0.name
                    .localizedCaseInsensitiveCompare(
                        $1.name
                    )
                ==
                .orderedAscending
            }
    }

    func installedModelNames()
        async throws
        -> [String] {

        let models =
            try await
            installedModels()

        return models
            .map(
                \.name
            )
    }

    // MARK: - Model Diagnostics

    func modelDiagnostics(
        for modelName: String
    ) async throws
        -> OllamaModelDiagnostics {

        let nativeContext =
            try await
            nativeContextLength(
                for:
                    modelName
            )

        let runningModels =
            try await
            runningModels()

        let runningModel =
            runningModels.first {
                item in

                item.name
                ==
                modelName
                ||
                item.model
                ==
                modelName
            }

        return OllamaModelDiagnostics(

            nativeContextLength:
                nativeContext,

            runtimeContextLength:
                runningModel?
                    .contextLength,

            runtimeMemoryBytes:
                runningModel?
                    .sizeVRAM,

            isRunning:
                runningModel != nil,

            kvCacheQuantization:
                nil
        )
    }

    // MARK: - Native Context

    private func nativeContextLength(
        for modelName: String
    ) async throws
        -> Int? {

        let url =
            try makeURL(
                path: "/api/show"
            )

        let body =
            OllamaShowRequest(
                model:
                    modelName,
                verbose:
                    false
            )

        var request =
            URLRequest(
                url: url,
                timeoutInterval: 15
            )

        request.httpMethod =
            "POST"

        request.setValue(
            "application/json",
            forHTTPHeaderField:
                "Content-Type"
        )

        request.httpBody =
            try JSONEncoder()
                .encode(
                    body
                )

        let (
            data,
            response
        ) =
            try await
            URLSession.shared
                .data(
                    for:
                        request
                )

        try Self.validate(
            response,
            requestedModel: modelName
        )

        guard
            let root =
                try JSONSerialization
                    .jsonObject(
                        with: data
                    )
                as? [String: Any],

            let modelInfo =
                root[
                    "model_info"
                ]
                as? [String: Any]

        else {

            return nil
        }

        return
            extractNativeContextLength(
                from:
                    modelInfo
            )
    }

    private func
    extractNativeContextLength(
        from modelInfo:
            [String: Any]
    ) -> Int? {

        if
            let architecture =
                modelInfo[
                    "general.architecture"
                ]
                as? String {

            let key =
                "\(architecture).context_length"

            if
                let value =
                    integerValue(
                        modelInfo[
                            key
                        ]
                    ) {

                return value
            }
        }

        let candidates =
            modelInfo
                .compactMap {
                    key,
                    value
                    -> (String, Int)?
                    in

                    guard
                        key.hasSuffix(
                            ".context_length"
                        )
                    else {

                        return nil
                    }

                    if
                        key.contains(
                            ".vision."
                        )
                        ||
                        key.contains(
                            ".audio."
                        ) {

                        return nil
                    }

                    guard
                        let context =
                            integerValue(
                                value
                            )
                    else {

                        return nil
                    }

                    return (
                        key,
                        context
                    )
                }

        return candidates
            .sorted {
                $0.0.count
                <
                $1.0.count
            }
            .first?
            .1
    }

    private func integerValue(
        _ value: Any?
    ) -> Int? {

        if
            let number =
                value
                as? NSNumber {

            return
                number
                    .intValue
        }

        if
            let string =
                value
                as? String {

            return
                Int(
                    string
                )
        }

        return nil
    }

    // MARK: - Running Models

    private func runningModels()
        async throws
        -> [OllamaRunningModel] {

        let url =
            try makeURL(
                path: "/api/ps"
            )

        let request =
            URLRequest(
                url: url,
                timeoutInterval: 10
            )

        let (
            data,
            response
        ) =
            try await
            URLSession.shared
                .data(
                    for:
                        request
                )

        try Self.validate(
            response,
            requestedModel: nil
        )

        let result =
            try JSONDecoder()
                .decode(
                    OllamaPSResponse.self,
                    from: data
                )

        return
            result.models
    }

    // MARK: - Language Detection

    /// 解析本次翻译的语言对。
    ///
    /// 原文已经是目标语言时翻到 `counterpart`：选中文的人选中一段中文，
    /// 要的是英文，而不是把中文再润色一遍。
    private func resolveDirection(
        _ text: String
    ) -> TranslationDirection {

        let target =
            AppSettings.targetLanguage

        let cleanedText =
            text
                .trimmingCharacters(
                    in:
                        .whitespacesAndNewlines
                )

        guard
            let detected =
                detectLanguage(
                    cleanedText
                )
        else {

            // 认不出来就不假装知道，只固定目标语言。
            return TranslationDirection(
                sourceName: nil,
                targetName:
                    target.displayName
            )
        }

        if TranslationLanguage
            .matching(detected) == target {

            let counterpart =
                target.counterpart

            return TranslationDirection(
                sourceName:
                    target.displayName,
                targetName:
                    counterpart.displayName
            )
        }

        return TranslationDirection(
            sourceName:
                TranslationLanguage
                    .sourceName(
                        for: detected
                    ),
            targetName:
                target.displayName
        )
    }

    private func detectLanguage(
        _ text: String
    ) -> NLLanguage? {

        guard !text.isEmpty else {
            return nil
        }

        let recognizer =
            NLLanguageRecognizer()

        recognizer.processString(
            text
        )

        if let dominant =
            recognizer.dominantLanguage,
           dominant != .undetermined {

            return dominant
        }

        // 短句常识别不出来，而中日韩可以按字形兜底。
        if containsMeaningfulChinese(
            text
        ) {

            return .simplifiedChinese
        }

        return nil
    }

    private func
    containsMeaningfulChinese(
        _ text: String
    ) -> Bool {

        let chineseCount =
            text
                .unicodeScalars
                .filter {
                    scalar in

                    let value =
                        scalar.value

                    return
                        (value >= 0x4E00 && value <= 0x9FFF)
                        ||
                        (value >= 0x3400 && value <= 0x4DBF)
                }
                .count

        let meaningfulCount =
            text
                .filter {
                    character in

                    !character.isWhitespace
                    &&
                    !character.isPunctuation
                }
                .count

        guard meaningfulCount > 0 else {
            return false
        }

        return
            Double(chineseCount)
            /
            Double(meaningfulCount)
            >= 0.15
    }

    // MARK: - URL

    /// 四个请求路径共用的响应校验。
    ///
    /// `requestedModel` 非空时，404 按「模型未安装」解释——这是 Ollama 对
    /// 带模型的请求返回 404 的唯一常见原因；`/api/tags`、`/api/ps` 不带模型，
    /// 它们的 404 只是普通的 HTTP 失败。
    private static func validate(
        _ response: URLResponse,
        requestedModel: String?
    ) throws {

        guard
            let httpResponse =
                response
                as? HTTPURLResponse
        else {

            throw
                OllamaClientError
                    .invalidResponse(
                        statusCode: -1
                    )
        }

        let statusCode =
            httpResponse.statusCode

        guard
            !(200...299)
                .contains(statusCode)
        else {

            return
        }

        if statusCode == 404,
           let requestedModel {

            throw
                OllamaClientError
                    .modelNotFound(
                        model:
                            requestedModel
                    )
        }

        throw
            OllamaClientError
                .invalidResponse(
                    statusCode:
                        statusCode
                )
    }

    private func makeURL(
        path: String
    ) throws -> URL {

        do {
            return try OllamaEndpoint.url(
                path: path
            )
        } catch {
            throw
                OllamaClientError
                    .invalidURL
        }
    }

    // MARK: - System Prompt

    private let systemPrompt = """
    你是一个面向程序员、技术文档和互联网内容的专业本地化翻译器。

    翻译目标不是逐字对应，而是在准确保留原意的前提下，让结果像目标语言使用者自然写出来的内容。

    必须遵守以下规则：

    1. 准确传达原文的真实含义、语气、情绪、上下文和隐含含义，不要逐字硬译。

    2. 不要擅自增加、删除、解释或总结原文信息。

    3. 技术内容必须保持准确。程序设计、软件工程、AI、互联网、API、框架、工具和计算机相关内容中的专业含义不得因为本地化而改变。

    4. 以下技术内容原则上保持英文原样，不要翻译：
       - 代码
       - 变量名
       - 常量名
       - 函数名
       - 方法名
       - 类名
       - 接口名
       - 类型名
       - property 名称
       - parameter 名称
       - API 名称
       - CLI 命令
       - command line flag
       - environment variable
       - 文件名
       - 文件路径
       - URL
       - JSON key
       - HTTP method
       - package 名称
       - framework 名称
       - library 名称
       - SDK 名称
       - product 名称
       - model 名称
       - Git branch、commit、tag 等标识符

    5. Swift、Java、JavaScript、TypeScript、Python、Go、Rust 等技术文本中的 API 标识符、modifier、property、method、parameter 等必须保持英文原样。

       例如：
       frame
       width
       maxHeight
       body
       View
       String
       Request
       Response
       URLSession
       Spring Boot
       Redis
       Docker
       Git
       Ollama

       不要把 frame 翻译成“帧”、width 翻译成“宽度”、maxHeight 翻译成“最大高度”，除非它们在原文中明确作为普通自然语言使用，而不是技术标识符。

    6. Markdown 行内代码和代码块中的内容保持原样，不得修改其中的字符、大小写或格式。

    7. 如果输入同时包含自然语言和代码：
       - 只翻译自然语言部分。
       - 代码部分保持原样。
       - 保持自然语言与代码之间原本的逻辑关系。

    8. 如果输入完全是代码、命令、JSON、配置文件或其他无需翻译的技术内容，则原样返回，不要为了产生翻译结果而强行修改内容。

    9. 技术术语根据中文技术社区的自然使用习惯处理。
       常见且通常直接使用英文的术语可以保留英文，不要为了中文化而强行翻译。
       例如 API、SDK、Prompt、Token、Agent、Framework 等应根据上下文选择最自然的表达。

    10. 对社交媒体、论坛、聊天内容：
        - 优先保留原文语气。
        - 可以自然口语化。
        - 保留幽默、讽刺、调侃、吐槽等表达。
        - 避免明显的机器翻译腔。

    11. 对正式文章、新闻、技术文档：
        - 保持清晰、准确和自然。
        - 不要擅自口语化。

    12. 对俚语、习惯表达、网络用语：
        - 翻译其真实含义。
        - 不要机械逐词对应。
        - 如果目标语言存在自然的对应表达，优先使用自然表达。

    13. 严格保留原文的段落换行、列表项（如 •, -, 1. 2. 等）和基本排版结构。
        列表中的每一个项目必须单独占一行并换行，严禁将列表项合并在同一行。
        段落之间必须保持原有的空行与换行。

    14. 不解释翻译过程。

    15. 不说明自己进行了什么处理。

    16. 不输出分析、备注、翻译建议或替代版本。

    17. 不添加：
        “翻译：”
        “Translation:”
        “以下是翻译结果：”
        或任何类似前缀。

    18. 不使用引号包裹整个翻译结果，除非原文本身需要引号。

    19. 最终只输出处理完成后的文本。
    """
}
