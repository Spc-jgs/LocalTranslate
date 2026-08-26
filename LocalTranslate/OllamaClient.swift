import Foundation

// MARK: - Chat Models

struct OllamaChatRequest: Encodable {
    let model: String
    let messages: [OllamaMessage]
    let stream: Bool
    let think: Bool
    let keepAlive: String

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case stream
        case think
        case keepAlive = "keep_alive"
    }
}

struct OllamaMessage: Codable {
    let role: String
    let content: String
}

struct OllamaChatResponse: Decodable {
    let message: OllamaMessage
}

// MARK: - Tags Models

private struct OllamaTagsResponse: Decodable {
    let models: [OllamaTagModel]
}

private struct OllamaTagModel: Decodable {
    let name: String
}

// MARK: - Errors

enum OllamaClientError: LocalizedError {

    case invalidURL
    case invalidResponse(statusCode: Int)
    case noModels

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Ollama 地址无效"

        case .invalidResponse(let statusCode):
            return "Ollama 请求失败，HTTP \(statusCode)"

        case .noModels:
            return "没有找到已安装的 Ollama 模型"
        }
    }
}

// MARK: - Client

final class OllamaClient {

    static let shared = OllamaClient()

    private init() {}

    // MARK: Translation

    func translate(_ text: String) async throws -> String {

        let url = try makeURL(
            path: "/api/chat"
        )

        let body = OllamaChatRequest(
            model: AppSettings.model,
            messages: [
                OllamaMessage(
                    role: "system",
                    content: systemPrompt
                ),
                OllamaMessage(
                    role: "user",
                    content: text
                )
            ],
            stream: false,
            think: false,
            keepAlive: AppSettings.keepAlive
        )

        var request = URLRequest(
            url: url,
            timeoutInterval: 180
        )

        request.httpMethod = "POST"

        request.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type"
        )

        request.httpBody = try JSONEncoder().encode(
            body
        )

        let (data, response) = try await URLSession.shared.data(
            for: request
        )

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OllamaClientError.invalidResponse(
                statusCode: -1
            )
        }

        guard (200...299).contains(
            httpResponse.statusCode
        ) else {
            throw OllamaClientError.invalidResponse(
                statusCode: httpResponse.statusCode
            )
        }

        let result = try JSONDecoder().decode(
            OllamaChatResponse.self,
            from: data
        )

        return result.message.content
            .trimmingCharacters(
                in: .whitespacesAndNewlines
            )
    }

    // MARK: Installed Models

    func installedModelNames() async throws -> [String] {

        let url = try makeURL(
            path: "/api/tags"
        )

        let request = URLRequest(
            url: url,
            timeoutInterval: 10
        )

        let (data, response) = try await URLSession.shared.data(
            for: request
        )

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OllamaClientError.invalidResponse(
                statusCode: -1
            )
        }

        guard (200...299).contains(
            httpResponse.statusCode
        ) else {
            throw OllamaClientError.invalidResponse(
                statusCode: httpResponse.statusCode
            )
        }

        let result = try JSONDecoder().decode(
            OllamaTagsResponse.self,
            from: data
        )

        return result.models
            .map(\.name)
            .sorted {
                $0.localizedCaseInsensitiveCompare($1)
                    == .orderedAscending
            }
    }

    // MARK: URL

    private func makeURL(
        path: String
    ) throws -> URL {

        let baseURL = AppSettings.baseURL
            .trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            .trimmingCharacters(
                in: CharacterSet(
                    charactersIn: "/"
                )
            )

        guard let url = URL(
            string: baseURL + path
        ) else {
            throw OllamaClientError.invalidURL
        }

        return url
    }

    // MARK: System Prompt

    private let systemPrompt = """
    你是一个面向程序员、技术文档和互联网内容的专业本地化翻译器。

    你的任务是自动判断输入语言并进行翻译：

    - 英文内容 → 翻译成自然、流畅、符合简体中文母语者表达习惯的中文。
    - 中文内容 → 翻译成自然、地道、符合英语母语者表达习惯的英文。

    翻译目标不是逐字对应，而是在准确保留原意的前提下，让结果像目标语言使用者自然写出来的内容。

    必须遵守以下规则：

    1. 准确传达原文的真实含义、语气、情绪、上下文和隐含含义，不要逐字硬译。

    2. 不要擅自增加、删除、解释或总结原文信息。

    3. 技术内容必须保持准确。程序设计、软件工程、AI、互联网、API、框架、工具和计算机相关内容中的专业含义不得因为本地化而改变。

    4. 以下技术内容原则上保持英文原样，不要翻译成中文：
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

    13. 保留原文的段落、列表和基本结构。
        不要无故把一段文字拆成多段，也不要把多段文字合并。

    14. 不解释翻译过程。

    15. 不说明自己进行了什么处理。

    16. 不输出分析、备注、翻译建议或替代版本。

    17. 不添加“翻译：”“Translation:”“以下是翻译结果：”或任何类似前缀。

    18. 不使用引号包裹整个翻译结果，除非原文本身需要引号。

    19. 最终只输出处理完成后的文本。
    """
}
