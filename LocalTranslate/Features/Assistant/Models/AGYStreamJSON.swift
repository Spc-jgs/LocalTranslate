import Foundation

/// stream-json 的编解码。stdin 只写 `user` 事件；未知事件忽略。
///
/// `/clear` 之类的 slash 绝不能当 CLI 命令送进去——agy 1.1.27 会立刻
/// `status=ERROR` 并 exit 2，把常驻进程打死。见 TASK.md §14。
nonisolated enum AGYStreamJSON {
    enum Event: Equatable {
        case sessionInit(conversationID: String)
        case result(AGYTurnPayload)
        case ignored
    }

    static func encodeUser(_ content: String) -> String {
        let body: [String: Any] = [
            "event": "user",
            "message": ["content": content]
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: body,
            options: []
        ),
            let line = String(data: data, encoding: .utf8)
        else {
            return "{\"event\":\"user\",\"message\":{\"content\":\"\"}}\n"
        }
        return line + "\n"
    }

    /// 非法 JSON 返回 `nil`，调用方必须结束会话。未知 `event` 返回 `.ignored`。
    static func decodeLine(_ line: String) -> Event? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .ignored }
        guard let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              let event = obj["event"] as? String
        else { return nil }

        switch event {
        case "init":
            let cid = obj["conversation_id"] as? String ?? ""
            return .sessionInit(conversationID: cid)
        case "result":
            guard let payload = obj["result"] as? [String: Any],
                  let parsed = AGYTurnPayload(json: payload)
            else { return nil }
            return .result(parsed)
        default:
            return .ignored
        }
    }
}

nonisolated struct AGYTurnPayload: Equatable {
    let conversationID: String
    let status: String
    let response: String
    let error: String?
    let numTurns: Int
    let inputTokens: Int

    var isSuccess: Bool { status == "SUCCESS" }

    init(
        conversationID: String,
        status: String,
        response: String,
        error: String?,
        numTurns: Int,
        inputTokens: Int
    ) {
        self.conversationID = conversationID
        self.status = status
        self.response = response
        self.error = error
        self.numTurns = numTurns
        self.inputTokens = inputTokens
    }

    init?(json: [String: Any]) {
        guard let conversationID = json["conversation_id"] as? String,
              let status = json["status"] as? String
        else { return nil }
        self.conversationID = conversationID
        self.status = status
        self.response = Self.encodeResponse(json["response"])
        self.error = json["error"] as? String
        self.numTurns = json["num_turns"] as? Int ?? 0
        let usage = json["usage"] as? [String: Any]
        self.inputTokens = usage?["input_tokens"] as? Int ?? 0
    }

    /// `--json-schema` 下 response 有时是对象，有时是字符串。
    /// 只按 String 取会得到空串，SUCCESS 被当成「agy 不可用」。
    static func encodeResponse(_ raw: Any?) -> String {
        switch raw {
        case let text as String:
            return text
        case nil:
            return ""
        default:
            guard let raw, JSONSerialization.isValidJSONObject(raw),
                  let data = try? JSONSerialization.data(
                    withJSONObject: raw
                  ),
                  let text = String(data: data, encoding: .utf8)
            else { return "" }
            return text
        }
    }
}
