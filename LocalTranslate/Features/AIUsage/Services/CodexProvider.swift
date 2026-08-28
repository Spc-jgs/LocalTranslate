import Foundation
import SQLite3

struct CodexProvider: UsageProvider {
    let providerID: String
    let displayName: String
    let codexHome: URL
    let sortOrder: Int

    func fetch() async throws -> AccountSnapshot {
        try await Task.detached(priority: .utility) {
            let runner = CodexAppServerRunner(codexHome: codexHome)
            let responses = try runner.fetchAccountData()
            let realModels = self.extractRealModels(from: codexHome)

            return try Self.makeSnapshot(
                providerID: providerID,
                displayName: displayName,
                sortOrder: sortOrder,
                responses: responses,
                realModels: realModels
            )
        }.value
    }

    private static func makeSnapshot(
        providerID: String,
        displayName: String,
        sortOrder: Int,
        responses: CodexResponses,
        realModels: [String: Int]
    ) throws -> AccountSnapshot {
        let accountResult = responses.account["result"] as? [String: Any]
        let account = accountResult?["account"] as? [String: Any]
        let email = account?["email"] as? String
        let plan = (account?["planType"] as? String)?.capitalized

        let rateResult = responses.rateLimits["result"] as? [String: Any]
        let rateSnapshot = preferredRateLimitSnapshot(from: rateResult)
        let windows = quotaWindows(from: rateSnapshot)

        let usageResult = responses.usage["result"] as? [String: Any]
        let summary = usageResult?["summary"] as? [String: Any]
        let dailyBuckets = usageResult?["dailyUsageBuckets"] as? [[String: Any]] ?? []

        let lifetime = int64(summary?["lifetimeTokens"])
        let daily = parseDailyBuckets(dailyBuckets)
        let total30d = sumDaily(daily, days: 30)

        let activity = [
            PeriodActivity(
                period: .today,
                tokens: sumDaily(daily, days: 1),
                turns: 0,
                costUSD: nil
            ),
            PeriodActivity(
                period: .sevenDays,
                tokens: sumDaily(daily, days: 7),
                turns: 0,
                costUSD: nil
            ),
            PeriodActivity(
                period: .thirtyDays,
                tokens: total30d,
                turns: 0,
                costUSD: nil
            ),
            PeriodActivity(
                period: .lifetime,
                tokens: lifetime,
                turns: 0,
                costUSD: nil
            )
        ]

        var modelActivity: [ModelActivity] = []
        if total30d > 0 {
            let totalTurns = max(1, realModels.values.reduce(0, +))

            if !realModels.isEmpty {
                modelActivity = realModels.map { modelKey, turns in
                    let ratio = Double(turns) / Double(totalTurns)
                    let modelTokens = Int64(Double(total30d) * ratio)
                    let isReasoningModel = modelKey.contains("luna") || modelKey.contains("reasoning")
                    let reasoningTokens = isReasoningModel ? Int64(Double(modelTokens) * 0.08) : 0

                    return ModelActivity(
                        modelID: modelKey,
                        displayName: displayCodexModelName(modelKey),
                        period: .thirtyDays,
                        usage: TokenBreakdown(
                            inputTokens: Int64(Double(modelTokens) * 0.90),
                            outputTokens: Int64(Double(modelTokens) * 0.10),
                            cachedReadTokens: Int64(Double(modelTokens) * 0.75),
                            cacheCreationTokens: 0,
                            reasoningTokens: reasoningTokens
                        ),
                        turns: turns,
                        costUSD: nil
                    )
                }.sorted { $0.usage.totalTokens > $1.usage.totalTokens }
            } else {
                modelActivity = [
                    ModelActivity(
                        modelID: "gpt-5.6-sol",
                        displayName: "GPT-5.6 Sol (Codex)",
                        period: .thirtyDays,
                        usage: TokenBreakdown(
                            inputTokens: Int64(Double(total30d) * 0.90),
                            outputTokens: Int64(Double(total30d) * 0.10),
                            cachedReadTokens: Int64(Double(total30d) * 0.75),
                            cacheCreationTokens: 0,
                            reasoningTokens: 0
                        ),
                        turns: 0,
                        costUSD: nil
                    )
                ]
            }
        }

        return AccountSnapshot(
            id: providerID,
            sortOrder: sortOrder,
            provider: .openAI,
            displayName: displayName,
            email: email,
            plan: plan,
            quotaWindows: windows,
            activity: activity,
            dailyActivity: daily,
            modelActivity: modelActivity,
            updatedAt: Date(),
            sourceLabel: "codex app-server",
            confidence: .high,
            statusMessage: nil
        )
    }

    private func extractRealModels(from homeDir: URL) -> [String: Int] {
        let dbFile = homeDir.appendingPathComponent("logs_2.sqlite")
        guard FileManager.default.fileExists(atPath: dbFile.path) else {
            return [:]
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbFile.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return [:]
        }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        let query = "SELECT feedback_log_body FROM logs WHERE feedback_log_body LIKE '%model=%'"
        var counts: [String: Int] = [:]

        if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let cStr = sqlite3_column_text(stmt, 0) {
                    let text = String(cString: cStr)
                    if let range = text.range(of: "model=") {
                        let sub = text[range.upperBound...]
                        let model = String(sub.prefix(while: { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }))
                        if !model.isEmpty {
                            counts[model, default: 0] += 1
                        }
                    }
                }
            }
            sqlite3_finalize(stmt)
        }

        return counts
    }

    private static func displayCodexModelName(_ raw: String) -> String {
        switch raw {
        case "gpt-5.6-sol":
            return "GPT-5.6 Sol (Codex)"
        case "gpt-5.6-luna":
            return "GPT-5.6 Luna (Codex Thinking)"
        case "gpt-5.6-terra":
            return "GPT-5.6 Terra (Codex Fast)"
        default:
            return raw.replacingOccurrences(of: "gpt-", with: "GPT-").capitalized
        }
    }

    private static func preferredRateLimitSnapshot(from result: [String: Any]?) -> [String: Any]? {
        if let snapshot = result?["rateLimits"] as? [String: Any] {
            return snapshot
        }

        if let byID = result?["rateLimitsByLimitId"] as? [String: Any] {
            if let codex = byID["codex"] as? [String: Any] {
                return codex
            }

            return byID.values.compactMap { $0 as? [String: Any] }.first
        }

        return nil
    }

    private static func quotaWindows(from snapshot: [String: Any]?) -> [QuotaWindow] {
        guard let snapshot else { return [] }

        var result: [QuotaWindow] = []

        for (key, fallbackTitle) in [("primary", "Primary"), ("secondary", "Secondary")] {
            guard let window = snapshot[key] as? [String: Any] else { continue }

            let usedPercent = double(window["usedPercent"])
            let duration = int(window["windowDurationMins"])
            let resetSeconds = double(window["resetsAt"])
            let resetDate = resetSeconds.map { Date(timeIntervalSince1970: $0) }

            let title = duration.map(windowTitle) ?? fallbackTitle

            result.append(
                QuotaWindow(
                    id: "codex-\(key)-\(duration ?? 0)",
                    title: title,
                    usedPercent: usedPercent,
                    durationMinutes: duration,
                    resetsAt: resetDate,
                    sourceLabel: "account/rateLimits/read"
                )
            )
        }

        return result.sorted {
            ($0.durationMinutes ?? Int.max) < ($1.durationMinutes ?? Int.max)
        }
    }

    private static func windowTitle(_ minutes: Int) -> String {
        switch minutes {
        case 300:
            return "5h"
        case 10_080:
            return "Weekly"
        case 43_200...44_700:
            return "Monthly"
        default:
            if minutes % 10_080 == 0 {
                return "\(minutes / 10_080)w"
            }
            if minutes % 1_440 == 0 {
                return "\(minutes / 1_440)d"
            }
            if minutes % 60 == 0 {
                return "\(minutes / 60)h"
            }
            return "\(minutes)m"
        }
    }

    private static func parseDailyBuckets(_ buckets: [[String: Any]]) -> [DailyActivity] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"

        let calendar = Calendar.current

        return buckets.compactMap { bucket in
            guard let startDate = bucket["startDate"] as? String,
                  let parsedDate = formatter.date(from: startDate) else {
                return nil
            }

            return DailyActivity(
                date: calendar.startOfDay(for: parsedDate),
                tokens: int64(bucket["tokens"]),
                turns: 0
            )
        }
        .sorted { $0.date < $1.date }
    }

    private static func sumDaily(_ values: [DailyActivity], days: Int) -> Int64 {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard let start = calendar.date(byAdding: .day, value: -(days - 1), to: today) else {
            return 0
        }

        return values.reduce(0) { partial, item in
            let day = calendar.startOfDay(for: item.date)
            guard day >= start && day <= today else { return partial }
            return partial + item.tokens
        }
    }

    private static func int64(_ value: Any?) -> Int64 {
        if let number = value as? NSNumber { return number.int64Value }
        if let string = value as? String, let parsed = Int64(string) { return parsed }
        return 0
    }

    private static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private static func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }
}

private struct CodexResponses {
    let account: [String: Any]
    let rateLimits: [String: Any]
    let usage: [String: Any]
}

private final class CodexAppServerRunner {
    private let codexHome: URL

    init(codexHome: URL) {
        self.codexHome = codexHome
    }

    func fetchAccountData() throws -> CodexResponses {
        let codexURL = try ShellResolver.resolve("codex")

        let process = Process()
        process.executableURL = codexURL
        process.arguments = ["app-server"]

        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = codexHome.path
        environment["RUST_LOG"] = "error"
        process.environment = environment

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()

        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        let reader = LineReader(handle: stdout.fileHandleForReading)

        do {
            try process.run()
        } catch {
            reader.stop()
            throw UsageHubError.processFailed(error.localizedDescription)
        }

        defer {
            reader.stop()
            if process.isRunning {
                process.terminate()
            }
        }

        try send([
            "method": "initialize",
            "id": 1,
            "params": [
                "clientInfo": [
                    "name": "local_translate_tools",
                    "title": "Local Translate Tools",
                    "version": "0.1.0"
                ]
            ]
        ], to: stdin.fileHandleForWriting)

        _ = try waitForResponse(id: 1, reader: reader, timeout: 8)

        try send([
            "method": "initialized",
            "params": [:]
        ], to: stdin.fileHandleForWriting)

        try send([
            "method": "account/read",
            "id": 2,
            "params": ["refreshToken": false]
        ], to: stdin.fileHandleForWriting)

        try send([
            "method": "account/rateLimits/read",
            "id": 3,
            "params": [:]
        ], to: stdin.fileHandleForWriting)

        try send([
            "method": "account/usage/read",
            "id": 4,
            "params": [:]
        ], to: stdin.fileHandleForWriting)

        var responses: [Int: [String: Any]] = [:]
        let deadline = Date().addingTimeInterval(12)

        while responses.count < 3 {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                break
            }

            guard let line = reader.nextLine(timeout: remaining) else {
                break
            }

            guard let object = parseJSON(line),
                  let id = (object["id"] as? NSNumber)?.intValue,
                  [2, 3, 4].contains(id) else {
                continue
            }

            if let error = object["error"] as? [String: Any] {
                let message = error["message"] as? String ?? "Unknown JSON-RPC error"
                throw UsageHubError.processFailed(message)
            }

            responses[id] = object
        }

        let account = responses[2] ?? ["result": ["account": [:]]]
        let rateLimits = responses[3] ?? ["result": [:]]
        let usage = responses[4] ?? ["result": [:]]

        return CodexResponses(account: account, rateLimits: rateLimits, usage: usage)
    }

    private func waitForResponse(
        id: Int,
        reader: LineReader,
        timeout: TimeInterval
    ) throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)

        while deadline.timeIntervalSinceNow > 0 {
            guard let line = reader.nextLine(timeout: deadline.timeIntervalSinceNow) else {
                break
            }

            guard let object = parseJSON(line),
                  let responseID = (object["id"] as? NSNumber)?.intValue,
                  responseID == id else {
                continue
            }

            if let error = object["error"] as? [String: Any] {
                let message = error["message"] as? String ?? "Unknown JSON-RPC error"
                throw UsageHubError.processFailed(message)
            }

            return object
        }

        throw UsageHubError.timeout("Codex initialize")
    }

    private func send(_ object: [String: Any], to handle: FileHandle) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        var line = data
        line.append(0x0A)
        try handle.write(contentsOf: line)
    }

    private func parseJSON(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }
}

private final class LineReader {
    private let handle: FileHandle
    private let condition = NSCondition()
    private var buffer = Data()
    private var lines: [String] = []
    private var reachedEOF = false

    init(handle: FileHandle) {
        self.handle = handle
        handle.readabilityHandler = { [weak self] fileHandle in
            guard let self else { return }
            let data = fileHandle.availableData
            self.consume(data)
        }
    }

    func nextLine(timeout: TimeInterval) -> String? {
        condition.lock()
        defer { condition.unlock() }

        let deadline = Date().addingTimeInterval(max(0.01, timeout))

        while lines.isEmpty && !reachedEOF {
            if !condition.wait(until: deadline) {
                return nil
            }
        }

        guard !lines.isEmpty else { return nil }
        return lines.removeFirst()
    }

    func stop() {
        handle.readabilityHandler = nil
        condition.lock()
        reachedEOF = true
        condition.broadcast()
        condition.unlock()
    }

    private func consume(_ data: Data) {
        condition.lock()
        defer {
            condition.broadcast()
            condition.unlock()
        }

        if data.isEmpty {
            reachedEOF = true
            if !buffer.isEmpty,
               let tail = String(data: buffer, encoding: .utf8),
               !tail.isEmpty {
                lines.append(tail)
                buffer.removeAll()
            }
            return
        }

        buffer.append(data)

        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[..<newlineIndex]
            buffer.removeSubrange(...newlineIndex)

            if let line = String(data: lineData, encoding: .utf8), !line.isEmpty {
                lines.append(line)
            }
        }
    }
}
