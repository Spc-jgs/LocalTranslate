import Foundation

@main
struct OllamaFailureTests {
    static func main() {
        connectionRefusedNamesOllamaAndTheEndpoint()
        connectionFailuresNeverLeakTheRawURLSessionString()
        modelNotFoundGivesTheExactPullCommand()
        timeoutIsNotReportedAsNotRunning()
        unknownErrorsStillSayWhichSubsystemFailed()
        localizedErrorsKeepTheirOwnDescription()
        print("OllamaFailureTests: 6 passed")
    }

    /// 用户报告的原始现象：Ollama 没启动时只显示
    /// "Could not connect to the server."，看不出跟 Ollama 有关。
    private static func connectionRefusedNamesOllamaAndTheEndpoint() {
        let message = OllamaFailure.message(
            for: URLError(.cannotConnectToHost)
        )
        expect(
            message.contains("Ollama"),
            "连接失败必须点名 Ollama，实际：\(message)"
        )
        expect(
            message.contains(OllamaEndpoint.normalizedBase()),
            "连接失败必须给出实际地址，实际：\(message)"
        )
        expect(
            message.contains("ollama serve"),
            "连接失败必须告诉用户怎么启动，实际：\(message)"
        )
    }

    /// 这是缺陷的本体：任何一类连不上，都不能退化成系统那句无指向的英文。
    private static func connectionFailuresNeverLeakTheRawURLSessionString() {
        let codes: [URLError.Code] = [
            .cannotConnectToHost,
            .cannotFindHost,
            .networkConnectionLost,
            .dnsLookupFailed
        ]

        for code in codes {
            let error = URLError(code)
            let message = OllamaFailure.message(for: error)
            expect(
                message != error.localizedDescription,
                "\(code) 仍然直接透传了系统描述"
            )
            expect(
                message.contains("Ollama"),
                "\(code) 的说明没提 Ollama：\(message)"
            )
        }
    }

    /// 模型没装时给的必须是能直接粘进终端的命令，而不是 "HTTP 404"。
    private static func modelNotFoundGivesTheExactPullCommand() {
        let model = "qwen3.5:4b"
        let message = OllamaFailure.modelNotInstalledMessage(model: model)
        expect(
            message.contains("ollama pull \(model)"),
            "缺模型必须给出可执行命令，实际：\(message)"
        )
        expect(
            !message.contains("404"),
            "不该把 HTTP 状态码抛给用户：\(message)"
        )
    }

    /// 超时和「没在运行」是两回事：模型首次加载慢也会超时，
    /// 此时叫用户去 `ollama serve` 是错误建议。
    private static func timeoutIsNotReportedAsNotRunning() {
        let message = OllamaFailure.message(for: URLError(.timedOut))
        expect(
            !message.contains("ollama serve"),
            "超时不该建议启动服务：\(message)"
        )
        expect(
            message.contains("超时"),
            "超时应如实说明：\(message)"
        )
    }

    /// 认不出的错误也要说清是哪一段失败的，不能只剩一句系统英文。
    private static func unknownErrorsStillSayWhichSubsystemFailed() {
        struct Opaque: Error {}
        let message = OllamaFailure.message(for: Opaque())
        expect(
            message.contains("Ollama"),
            "兜底文案必须点名子系统：\(message)"
        )
    }

    /// 已经自带说明的错误，不该被兜底文案覆盖掉。
    private static func localizedErrorsKeepTheirOwnDescription() {
        struct Described: LocalizedError {
            var errorDescription: String? { "没有找到已安装的 Ollama 模型" }
        }
        let message = OllamaFailure.message(for: Described())
        expect(
            message == "没有找到已安装的 Ollama 模型",
            "自带描述被改写了：\(message)"
        )
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        guard condition() else {
            fatalError("OllamaFailureTests failed: \(message)")
        }
    }
}
