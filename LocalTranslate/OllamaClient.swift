import Foundation

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

final class OllamaClient {
    static let shared = OllamaClient()

    private init() {}

    func translate(_ text: String) async throws -> String {
        guard let url = URL(string: "http://localhost:11434/api/chat") else {
            throw URLError(.badURL)
        }

        let systemPrompt = """
        你是一名专业本地化翻译。

        自动判断输入语言：
        - 英文翻译成自然流畅、符合中国人表达习惯的中文。
        - 中文翻译成自然地道的英文。

        不要逐字硬译。
        保留原文的语气、情绪、幽默和隐含含义。
        技术内容中的 API、class、method、framework、变量名和专业术语保持准确。
        社交媒体内容要口语自然。

        只输出最终翻译结果。
        不解释。
        不加引号。
        不添加“翻译：”等前缀。
        """

        let body = OllamaChatRequest(
            model: "qwen3.8:27b",
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
            keepAlive: "30m"
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type"
        )

        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let result = try JSONDecoder().decode(
            OllamaChatResponse.self,
            from: data
        )

        return result.message.content
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
