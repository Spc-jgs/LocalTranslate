import Foundation

/// agy 常驻进程的启动契约：参数、路径、超时。
///
/// 这些数字全部来自 TASK.md 的实测，不是估算。改阈值或超时必须同时改测试。
nonisolated enum AGYLaunchSpec {
    /// 官方 headless 写法：`--model` 是家族，`--effort` 是档位。
    /// `agy models` 里的 `gemini-3.8-flash-medium` 是两者的合成别名；
    /// 裸 `gemini-3.8-flash` 不带 `--effort` 会 ERROR（要求 low/medium/high）。
    /// 合成 slug 再配冲突的 `--effort` 也会 ERROR。
    /// https://antigravity.google/docs/cli/headless/
    static let modelID = "gemini-3.8-flash"
    /// Gemini 3.8 Flash 的官方默认 thinking level 就是 medium。
    static let effort = "medium"

    /// 面板上来源标注：家族 + 档位，避免只写 slug 看不出 effort。
    static var sourceModelID: String { "\(modelID) · \(effort)" }
    /// 只挡真卡死；agy 默认 5 分钟。high 档 20s 经常不够，medium 仍沿用 60s。
    static let requestTimeoutSeconds = 60
    /// 只等 `init`，不含模型推理。本机约 5s。
    static let initTimeoutSeconds = 15
    static let stdinExitWait: TimeInterval = 2
    static let sigtermExitWait: TimeInterval = 2
    static let responseByteLimit = 1_048_576
    static let consecutiveFailuresBeforeGivingUp = 3
    static let stderrTailLimit = 65_536

    static var assistantRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                ".localtranslate/assistant",
                isDirectory: true
            )
    }

    static var workspaceDirectory: URL {
        assistantRoot.appendingPathComponent(
            "workspace",
            isDirectory: true
        )
    }

    static var pidfileURL: URL {
        assistantRoot.appendingPathComponent("agy.pid.json")
    }

    /// 只认我们自己会安装的位置，不 `pkill agy`，也不扫用户的别的拷贝。
    static func binaryURL() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/agy",
            "/opt/homebrew/bin/agy",
            "/usr/local/bin/agy"
        ]
        return candidates.first {
            FileManager.default.isExecutableFile(atPath: $0)
        }.map { URL(fileURLWithPath: $0) }
    }

    static func arguments(schemaJSON: String) -> [String] {
        [
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--model", modelID,
            "--effort", effort,
            "--sandbox",
            "--disable-slash-commands",
            "--print-timeout", "\(requestTimeoutSeconds)s",
            "--json-schema", schemaJSON
        ]
    }
}

/// 把 spawn 和提问拆开：打开面板只 `ensure`，提交才发 user 事件。
/// 启动中的第二次 ensure/ask 必须共用这一次 spawn。
nonisolated struct AGYStartCoordinator {
    enum Phase: Equatable {
        case idle
        case starting
        case ready
    }

    enum Decision: Equatable {
        case spawn
        case waitForExistingStart
        case alreadyReady
    }

    private(set) var phase: Phase = .idle

    mutating func ensure() -> Decision {
        switch phase {
        case .idle:
            phase = .starting
            return .spawn
        case .starting:
            return .waitForExistingStart
        case .ready:
            return .alreadyReady
        }
    }

    mutating func didBecomeReady() {
        phase = .ready
    }

    mutating func didStop() {
        phase = .idle
    }
}

/// `readabilityHandler` 空 Data 在进程仍在跑时可能只是一次空读；
/// 只有进程已经退了才当成 stdout 关闭。
nonisolated enum AGYStdoutEOF {
    static func isClosed(
        dataEmpty: Bool,
        processRunning: Bool
    ) -> Bool {
        dataEmpty && !processRunning
    }
}

/// 层 1：关 stdin → 等 → SIGTERM → 等 → SIGKILL → waitpid。
/// 发完信号就返回不算完成；waitpid 是完成条件。
nonisolated struct AGYProcessTerminator {
    var closeStdin: () -> Void
    var isRunning: () -> Bool
    var sendSIGTERM: () -> Void
    var sendSIGKILL: () -> Void
    var waitpid: () -> Void
    var sleep: (TimeInterval) -> Void

    func run() {
        closeStdin()
        if isRunning() {
            sleep(AGYLaunchSpec.stdinExitWait)
        }
        if isRunning() {
            sendSIGTERM()
            sleep(AGYLaunchSpec.sigtermExitWait)
        }
        if isRunning() {
            sendSIGKILL()
        }
        waitpid()
    }
}
