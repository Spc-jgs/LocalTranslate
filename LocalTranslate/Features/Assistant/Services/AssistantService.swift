import Foundation

/// 本机助手：把一句自然语言变成可执行命令，或把一段报错栈变成"先看哪一行"。
///
/// 这两类活和早先那个词义分诊有个根本区别——**输入自带上下文**。报错栈、你打的
/// 那句话，信息全在输入里，不需要从别的 App 刨前后文。分诊卡死在拿不到上下文，
/// 助手绕开了这件事。
///
/// 失败模式也不同：命令对不对你扫一眼就知道，结论指向哪一行你点过去就能核。
/// 本地模型该干的正是这种"错了你立刻能发现"的活。
nonisolated struct AssistantService: Sendable {
    private struct Request: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }

        struct Options: Encodable {
            let temperature: Double
            let numPredict: Int

            enum CodingKeys: String, CodingKey {
                case temperature
                case numPredict = "num_predict"
            }
        }

        struct Schema: Encodable {
            struct Property: Encodable {
                let type: String
                let values: [String]?

                enum CodingKeys: String, CodingKey {
                    case type
                    case values = "enum"
                }
            }

            let type = "object"
            let properties: [String: Property]
            let required: [String]
        }

        let model: String
        let messages: [Message]
        let stream = false
        let think = false
        let format: Schema
        let options: Options
        let keepAlive: String

        enum CodingKeys: String, CodingKey {
            case model, messages, stream, think, format, options
            case keepAlive = "keep_alive"
        }
    }

    private struct Response: Decodable {
        struct Message: Decodable { let content: String }
        let message: Message
    }

    private struct ModelAnswer: Decodable {
        let kind: AssistantAnswerKind
        let primary: String
        let note: String
    }

    enum ServiceError: LocalizedError {
        case emptyInput
        case invalidResponse
        case http(Int)
        case oversizedResponse

        var errorDescription: String? {
            switch self {
            case .emptyInput: return "没有可分析的内容"
            case .invalidResponse: return "本地模型返回的格式无效"
            case .http(let code): return "Ollama 请求失败（HTTP \(code)）"
            case .oversizedResponse: return "Ollama 响应超过 1 MB 上限"
            }
        }
    }

    /// 本地通道。升级档在设计里是 agy 常驻会话（P2），不是更大的本地模型——
    /// 27B 实测只有 15~25 tok/s 且常驻 17.7 GB，两项都输给 agy 的 190 MB / 2s。
    func answer(
        mode: AssistantMode,
        input: String,
        context: SelectionContext?,
        model: String,
        keepAlive: String
    ) async throws -> AssistantAnswer {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ServiceError.emptyInput }

        let url = try OllamaEndpoint.url(path: "/api/chat")
        let body = Request(
            model: model,
            messages: [
                .init(role: "system", content: Self.systemPrompt),
                .init(
                    role: "user",
                    content: Self.userMessage(
                        mode: mode,
                        input: trimmed,
                        context: context
                    )
                )
            ],
            format: Self.schema,
            options: .init(temperature: 0, numPredict: 420),
            keepAlive: keepAlive
        )
        var request = URLRequest(url: url, timeoutInterval: 90)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ServiceError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw ServiceError.http(http.statusCode)
        }
        guard data.count <= 1_048_576 else { throw ServiceError.oversizedResponse }

        let envelope = try JSONDecoder().decode(Response.self, from: data)
        guard let content = envelope.message.content.data(using: .utf8) else {
            throw ServiceError.invalidResponse
        }
        let decoded = try JSONDecoder().decode(ModelAnswer.self, from: content)
        let primary = Self.trim(decoded.primary, maximumCharacters: 600)
        return AssistantAnswer(
            kind: decoded.kind,
            primary: primary.isEmpty ? "本地模型没有给出可用的答案。" : primary,
            note: Self.trim(decoded.note, maximumCharacters: 300),
            // 破坏性由代码判定，不问模型——它自己说"安全"不构成安全。
            hazard: decoded.kind == .command
                ? DestructiveCommandPolicy.hazard(in: primary)
                : nil,
            modelID: model
        )
    }

    private static func userMessage(
        mode: AssistantMode,
        input: String,
        context: SelectionContext?
    ) -> String {
        switch mode {
        case .askQuestion:
            return """
                <question>
                \(AssistantInputBounds.prefix(input, limit: 2_000))
                </question>
                """
        case .analyzeSelection:
            let adjacent = context?.adjacentText ?? ""
            let surrounding = adjacent.isEmpty
                ? "<context unavailable=\"true\"/>"
                : """
                    <context>
                    \(AssistantInputBounds.prefix(adjacent, limit: 800))
                    </context>
                    """
            return """
                <selection>
                \(AssistantInputBounds.prefix(input, limit: AssistantInputBounds.selectionLimit))
                </selection>
                \(surrounding)
                """
        }
    }

    private static func trim(_ value: String, maximumCharacters: Int) -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > maximumCharacters else { return normalized }
        return String(normalized.prefix(maximumCharacters)) + "…"
    }

    private static let schema = Request.Schema(
        properties: [
            "kind": .init(
                type: "string",
                values: ["command", "diagnosis", "explanation"]
            ),
            "primary": .init(type: "string", values: nil),
            "note": .init(type: "string", values: nil)
        ],
        required: ["kind", "primary", "note"]
    )

    // 提示词的分段与共享规则见 AssistantPromptParts；这里只引用，不复制。
    private static let systemPrompt = AssistantPromptParts.local
}
