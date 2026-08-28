import Foundation

enum ProviderKind: String, Codable, Sendable {
    case openAI = "OpenAI"
    case google = "Google"
    case xAI = "xAI"
}

enum DataConfidence: String, Codable, Sendable {
    case high = "High"
    case medium = "Medium"
    case low = "Low"
}

enum ActivityPeriod: String, CaseIterable, Codable, Sendable, Identifiable {
    case today = "Today"
    case sevenDays = "7 Days"
    case thirtyDays = "30 Days"
    case lifetime = "Lifetime"

    var id: String { rawValue }
}

struct QuotaWindow: Identifiable, Codable, Sendable {
    let id: String
    let title: String
    let usedPercent: Double?
    let durationMinutes: Int?
    let resetsAt: Date?
    let sourceLabel: String

    var remainingPercent: Double? {
        guard let usedPercent else { return nil }
        return max(0, min(100, 100 - usedPercent))
    }
}

struct TokenBreakdown: Codable, Sendable, Equatable {
    var inputTokens: Int64
    var outputTokens: Int64
    var cachedReadTokens: Int64
    var cacheCreationTokens: Int64
    var reasoningTokens: Int64

    init(
        inputTokens: Int64 = 0,
        outputTokens: Int64 = 0,
        cachedReadTokens: Int64 = 0,
        cacheCreationTokens: Int64 = 0,
        reasoningTokens: Int64 = 0
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedReadTokens = cachedReadTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.reasoningTokens = reasoningTokens
    }

    var totalTokens: Int64 {
        inputTokens + outputTokens
    }

    var freshInputTokens: Int64 {
        max(0, inputTokens - cachedReadTokens - cacheCreationTokens)
    }

    var normalOutputTokens: Int64 {
        max(0, outputTokens - reasoningTokens)
    }

    mutating func add(_ other: TokenBreakdown) {
        inputTokens += other.inputTokens
        outputTokens += other.outputTokens
        cachedReadTokens += other.cachedReadTokens
        cacheCreationTokens += other.cacheCreationTokens
        reasoningTokens += other.reasoningTokens
    }
}

struct PeriodActivity: Identifiable, Codable, Sendable {
    let period: ActivityPeriod
    let tokens: Int64
    let turns: Int
    let costUSD: Double?

    var id: String { period.id }
}

struct DailyActivity: Identifiable, Codable, Sendable {
    let date: Date
    let tokens: Int64
    let turns: Int

    var id: Date { date }
}

struct ModelActivity: Identifiable, Codable, Sendable {
    let modelID: String
    let displayName: String
    let period: ActivityPeriod
    let usage: TokenBreakdown
    let turns: Int
    let costUSD: Double?

    var id: String { "\(period.rawValue)::\(modelID)" }
}

struct AccountSnapshot: Identifiable, Codable, Sendable {
    let id: String
    let sortOrder: Int
    let provider: ProviderKind
    let displayName: String
    let email: String?
    let plan: String?
    let quotaWindows: [QuotaWindow]
    let activity: [PeriodActivity]
    let dailyActivity: [DailyActivity]
    let modelActivity: [ModelActivity]
    let updatedAt: Date
    let sourceLabel: String
    let confidence: DataConfidence
    let statusMessage: String?

    func activity(for period: ActivityPeriod) -> PeriodActivity? {
        activity.first { $0.period == period }
    }
}

protocol UsageProvider: Sendable {
    var providerID: String { get }
    func fetch() async throws -> AccountSnapshot
}

enum UsageHubError: LocalizedError, Sendable {
    case executableNotFound(String)
    case processFailed(String)
    case timeout(String)
    case invalidResponse(String)
    case missingCredentials(String)
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .executableNotFound(let name):
            return "找不到可执行文件：\(name)"
        case .processFailed(let message):
            return "进程执行失败：\(message)"
        case .timeout(let message):
            return "请求超时：\(message)"
        case .invalidResponse(let message):
            return "返回数据无法解析：\(message)"
        case .missingCredentials(let message):
            return "缺少登录凭据：\(message)"
        case .http(let code, let message):
            return "HTTP \(code)：\(message)"
        }
    }
}
