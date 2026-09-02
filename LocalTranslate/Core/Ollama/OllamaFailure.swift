import Foundation

/// 把 Ollama 链路的失败翻译成用户能照着做的一句话。
///
/// 这是个本地工具：它最常见的失败不是网络抖动，而是「依赖的本地服务没开」
/// 和「模型没装」。这两件事 URLSession 只会说 "Could not connect to the
/// server."，用户看不出跟 Ollama 有关，更不知道下一步做什么。
///
/// 只做诊断，不持有任何会话或状态机，因此放在共享层：
/// `Translate` 与 `LiveSubtitles` 都能用，而不用互相依赖。
nonisolated enum OllamaFailure {

    /// 面向用户的失败说明。
    ///
    /// 依次尝试：传输层诊断 → 错误自己的 `errorDescription` → 系统描述。
    static func message(for error: Error) -> String {
        if let transport = transportMessage(for: error) {
            return transport
        }

        if let described = (error as? LocalizedError)?.errorDescription {
            return described
        }

        // 兜底：至少说清楚是 Ollama 这一段失败的。
        return "Ollama 请求失败：\(error.localizedDescription)"
    }

    /// 传输层诊断；不是这类失败时返回 `nil`，交给上层的错误描述。
    static func transportMessage(for error: Error) -> String? {
        guard let urlError = error as? URLError else { return nil }

        switch urlError.code {
        case .cannotConnectToHost,
             .cannotFindHost,
             .networkConnectionLost,
             .dnsLookupFailed:
            return notRunningMessage()

        case .timedOut:
            return """
                Ollama 响应超时。模型首次加载可能较慢，稍后重试；\
                或在设置里选一个更小的模型。
                """

        default:
            return nil
        }
    }

    /// 模型没装时的说明，带上可直接复制的命令。
    static func modelNotInstalledMessage(model: String) -> String {
        """
        模型「\(model)」未安装。在终端执行：ollama pull \(model)
        """
    }

    private static func notRunningMessage(
        baseURL: String = AppSettings.baseURL
    ) -> String {
        """
        连不上 Ollama（\(OllamaEndpoint.normalizedBase(baseURL))）。\
        请确认它正在运行：在终端执行 ollama serve。
        """
    }
}
