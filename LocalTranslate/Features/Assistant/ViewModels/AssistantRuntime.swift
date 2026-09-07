import Combine
import Foundation

/// 助手进程三态。纯值，不进 MainActor。
nonisolated enum AssistantProcessPhase: Equatable {
    case idle
    case starting
    case ready
}

/// 助手常驻进程的可见状态。菜单栏和设置页读这里，不轮询、不设 Timer。
@MainActor
final class AssistantRuntime: ObservableObject {
    static let shared = AssistantRuntime()

    @Published private(set) var phase: AssistantProcessPhase = .idle
    @Published private(set) var pid: Int32?
    @Published private(set) var startedAt: Date?

    private init() {}

    var isRunning: Bool { phase != .idle }

    func apply(
        phase: AssistantProcessPhase,
        pid: Int32?,
        startedAt: Date?
    ) {
        self.phase = phase
        self.pid = phase == .idle ? nil : pid
        self.startedAt = phase == .idle ? nil : startedAt
    }

    var statusTitle: String {
        switch phase {
        case .idle: return "助手：未运行"
        case .starting: return "助手：启动中"
        case .ready: return "助手：运行中"
        }
    }

    var processDetail: String {
        switch phase {
        case .idle: return "未运行"
        case .starting: return "启动中"
        case .ready: return "运行中 · pid \(pidText)"
        }
    }

    var pidText: String {
        pid.map { String($0) } ?? "—"
    }

    var uptimeText: String {
        guard let startedAt else { return "—" }
        let seconds = max(0, Int(Date().timeIntervalSince(startedAt)))
        let minutes = seconds / 60
        let rest = seconds % 60
        if minutes == 0 { return "\(rest) 秒" }
        return "\(minutes) 分 \(rest) 秒"
    }
}
