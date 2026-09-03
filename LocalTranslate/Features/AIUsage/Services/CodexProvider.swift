import Foundation

nonisolated struct CodexProvider: UsageProvider {
    let providerID: String
    let displayName: String
    let codexHome: URL
    let sortOrder: Int

    func fetch() async throws -> AccountSnapshot {
        async let responses = fetchAccountData()
        async let localUsage = UsageActivityIndexer.shared.scanCodex(
            providerID: providerID,
            codexHome: codexHome
        )
        let responseValue = await responses
        let localResult: Result<IndexedActivitySnapshot, Error>
        do {
            localResult = .success(try await localUsage)
        } catch {
            localResult = .failure(error)
        }
        let localValue: IndexedActivitySnapshot
        let activityError: String?
        switch localResult {
        case .success(let value):
            localValue = value
            activityError = nil
        case .failure(let error):
            localValue = IndexedActivitySnapshot(
                periodActivity: [],
                dailyActivity: [],
                modelActivity: [],
                indexedFiles: 0,
                indexedProgress: 0,
                catchUpPending: false
            )
            activityError = error.localizedDescription
        }

        return Self.makeSnapshot(
            providerID: providerID,
            displayName: displayName,
            sortOrder: sortOrder,
            responses: responseValue,
            localUsage: localValue,
            activityError: activityError
        )
    }

    private func fetchAccountData() async -> CodexResponses {
        let cancellation = CodexProcessCancellation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    guard !cancellation.isCancelled else {
                        continuation.resume(
                            returning: CodexResponses.cancelled
                        )
                        return
                    }

                    let runner = CodexAppServerRunner(codexHome: codexHome)
                    continuation.resume(
                        returning: runner.fetchAccountDataGracefully(
                            cancellation: cancellation
                        )
                    )
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private static func makeSnapshot(
        providerID: String,
        displayName: String,
        sortOrder: Int,
        responses: CodexResponses,
        localUsage: IndexedActivitySnapshot,
        activityError: String?
    ) -> AccountSnapshot {
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
        let serverDaily = parseDailyBuckets(dailyBuckets)
        let daily = mergeDailyActivity(
            server: serverDaily,
            local: localUsage.dailyActivity
        )
        let localByPeriod = Dictionary(
            uniqueKeysWithValues: localUsage.periodActivity.map { ($0.period, $0) }
        )

        let activity = [
            PeriodActivity(
                period: .today,
                tokens: sumDaily(daily, days: 1),
                turns: sumTurns(daily, days: 1),
                costUSD: localByPeriod[.today]?.costUSD
            ),
            PeriodActivity(
                period: .sevenDays,
                tokens: sumDaily(daily, days: 7),
                turns: sumTurns(daily, days: 7),
                costUSD: localByPeriod[.sevenDays]?.costUSD
            ),
            PeriodActivity(
                period: .thirtyDays,
                tokens: sumDaily(daily, days: 30),
                turns: sumTurns(daily, days: 30),
                costUSD: localByPeriod[.thirtyDays]?.costUSD
            ),
            PeriodActivity(
                period: .lifetime,
                tokens: lifetime,
                turns: 0,
                costUSD: nil
            )
        ]
        let combinedStatus = [
            responses.statusMessage,
            activityError,
            localUsage.catchUpPending ? "本地历史正在分片补齐" : nil
        ].compactMap { $0 }.joined(separator: "；")

        return AccountSnapshot(
            id: providerID,
            sortOrder: sortOrder,
            provider: .openAI,
            billingKind: .subscription,
            displayName: displayName,
            email: email,
            plan: plan,
            quotaWindows: windows,
            activity: activity,
            dailyActivity: daily,
            modelActivity: localUsage.modelActivity,
            updatedAt: Date(),
            sourceLabel: !serverDaily.isEmpty && localUsage.indexedFiles > 0
                ? "Codex 服务端日统计 + 本机模型索引"
                : (localUsage.indexedFiles > 0
                    ? "Codex 本机增量索引"
                    : "Codex app-server"),
            confidence: responses.hasError || activityError != nil ? .medium : .high,
            statusMessage: combinedStatus.isEmpty ? nil : combinedStatus,
            schemaVersion: AccountSnapshot.currentSchemaVersion,
            quotaAvailable: !windows.isEmpty,
            activityAvailable: activityError == nil || !serverDaily.isEmpty,
            catchUp: UsageCatchUpProgress(
                pending: localUsage.catchUpPending,
                progress: localUsage.indexedProgress
            )
        )
    }

    static func displayCodexModelName(_ raw: String) -> String {
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
            return "5 小时"
        case 10_080:
            return "每周"
        case 43_200...44_700:
            return "每月"
        default:
            if minutes % 10_080 == 0 {
                return "\(minutes / 10_080) 周"
            }
            if minutes % 1_440 == 0 {
                return "\(minutes / 1_440) 天"
            }
            if minutes % 60 == 0 {
                return "\(minutes / 60) 小时"
            }
            return "\(minutes) 分钟"
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

    static func mergeDailyActivity(
        server: [DailyActivity],
        local: [DailyActivity]
    ) -> [DailyActivity] {
        let calendar = Calendar.current
        var localByDay = Dictionary(
            uniqueKeysWithValues: local.map {
                (calendar.startOfDay(for: $0.date), $0)
            }
        )
        var merged = server.map { item in
            let day = calendar.startOfDay(for: item.date)
            let localItem = localByDay.removeValue(forKey: day)
            return DailyActivity(
                date: day,
                tokens: item.tokens,
                turns: localItem?.turns ?? 0
            )
        }
        merged.append(contentsOf: localByDay.values)
        return merged.sorted { $0.date < $1.date }
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

    private static func sumTurns(_ values: [DailyActivity], days: Int) -> Int {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard let start = calendar.date(byAdding: .day, value: -(days - 1), to: today) else {
            return 0
        }

        return values.reduce(0) { partial, item in
            let day = calendar.startOfDay(for: item.date)
            guard day >= start && day <= today else { return partial }
            return partial + item.turns
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

nonisolated enum CodexAPIPriceCatalog {
    private struct Price {
        let inputPerMillion: Double
        let cachedInputPerMillion: Double
        let outputPerMillion: Double
    }

    // Promotional GPT-5.6 prices published by OpenAI and guaranteed through
    // 2026-11-21. Stop estimating after that date instead of showing stale prices.
    private static let validBefore = Date(timeIntervalSince1970: 1_795_305_600)

    private static let prices: [String: Price] = [
        "gpt-5.6": Price(
            inputPerMillion: 4,
            cachedInputPerMillion: 0.4,
            outputPerMillion: 20
        ),
        "gpt-5.6-sol": Price(
            inputPerMillion: 4,
            cachedInputPerMillion: 0.4,
            outputPerMillion: 20
        ),
        "gpt-5.6-terra": Price(
            inputPerMillion: 2,
            cachedInputPerMillion: 0.2,
            outputPerMillion: 12
        ),
        "gpt-5.6-luna": Price(
            inputPerMillion: 0.2,
            cachedInputPerMillion: 0.02,
            outputPerMillion: 1.2
        )
    ]

    static func estimate(
        modelID: String,
        usage: TokenBreakdown,
        now: Date = Date()
    ) -> Double? {
        guard now < validBefore,
              let price = prices[modelID] else {
            return nil
        }

        let isLongContext = usage.inputTokens > 272_000
        let inputMultiplier = isLongContext ? 2.0 : 1.0
        let outputMultiplier = isLongContext ? 1.5 : 1.0
        let million = 1_000_000.0

        let freshInputCost = Double(usage.freshInputTokens)
            / million
            * price.inputPerMillion
            * inputMultiplier
        let cachedInputCost = Double(usage.cachedReadTokens)
            / million
            * price.cachedInputPerMillion
            * inputMultiplier
        let cacheWriteCost = Double(usage.cacheCreationTokens)
            / million
            * price.inputPerMillion
            * 1.25
            * inputMultiplier
        let outputCost = Double(usage.outputTokens)
            / million
            * price.outputPerMillion
            * outputMultiplier

        return freshInputCost + cachedInputCost + cacheWriteCost + outputCost
    }
}

private nonisolated struct CodexResponses {
    let account: [String: Any]
    let rateLimits: [String: Any]
    let usage: [String: Any]
    let hasError: Bool
    let statusMessage: String?

    // 字段是 [String: Any]，类型无法是 Sendable；该值本身不可变。
    nonisolated(unsafe) static let cancelled = CodexResponses(
        account: [:],
        rateLimits: [:],
        usage: [:],
        hasError: true,
        statusMessage: "刷新已取消"
    )
}

private nonisolated final class CodexProcessCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var process: Process?

    var isCancelled: Bool {
        lock.lock()
        let value = cancelled
        lock.unlock()
        return value
    }

    func attach(_ process: Process) {
        lock.lock()
        self.process = process
        let shouldTerminate = cancelled
        lock.unlock()

        if shouldTerminate, process.isRunning {
            process.terminate()
        }
    }

    func detach() {
        lock.lock()
        process = nil
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let process = process
        lock.unlock()

        if let process, process.isRunning {
            process.terminate()
        }
    }
}

private nonisolated final class CodexAppServerRunner {
    private let codexHome: URL

    init(codexHome: URL) {
        self.codexHome = codexHome
    }

    func fetchAccountDataGracefully(
        cancellation: CodexProcessCancellation
    ) -> CodexResponses {
        guard !cancellation.isCancelled else { return .cancelled }
        guard let codexURL = try? ShellResolver.resolve("codex") else {
            return CodexResponses(
                account: [:],
                rateLimits: [:],
                usage: [:],
                hasError: true,
                statusMessage: "未安装 Codex CLI"
            )
        }

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
            cancellation.attach(process)
        } catch {
            reader.stop()
            return CodexResponses(
                account: [:],
                rateLimits: [:],
                usage: [:],
                hasError: true,
                statusMessage: error.localizedDescription
            )
        }

        defer {
            cancellation.detach()
            reader.stop()
            if process.isRunning {
                process.terminate()
            }
        }

        _ = try? send([
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

        _ = try? waitForResponse(id: 1, reader: reader, timeout: 5)

        _ = try? send([
            "method": "initialized",
            "params": [:]
        ], to: stdin.fileHandleForWriting)

        _ = try? send([
            "method": "account/read",
            "id": 2,
            "params": ["refreshToken": false]
        ], to: stdin.fileHandleForWriting)

        _ = try? send([
            "method": "account/rateLimits/read",
            "id": 3,
            "params": [:]
        ], to: stdin.fileHandleForWriting)

        _ = try? send([
            "method": "account/usage/read",
            "id": 4,
            "params": [:]
        ], to: stdin.fileHandleForWriting)

        var responses: [Int: [String: Any]] = [:]
        let deadline = Date().addingTimeInterval(8)
        var capturedErrorMessage: String? = nil

        while responses.count < 3, !cancellation.isCancelled {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }

            guard let line = reader.nextLine(timeout: remaining) else {
                break
            }

            guard let object = parseJSON(line),
                  let id = (object["id"] as? NSNumber)?.intValue,
                  [2, 3, 4].contains(id) else {
                continue
            }

            if let error = object["error"] as? [String: Any] {
                // Method-level soft error (e.g. usage query timeout from upstream)
                let message = error["message"] as? String ?? "Upstream timeout"
                capturedErrorMessage = message
                responses[id] = ["result": [:]]
                continue
            }

            responses[id] = object
        }

        let account = responses[2] ?? ["result": ["account": [:]]]
        let rateLimits = responses[3] ?? ["result": [:]]
        let usage = responses[4] ?? ["result": [:]]

        return CodexResponses(
            account: account,
            rateLimits: rateLimits,
            usage: usage,
            hasError: capturedErrorMessage != nil,
            statusMessage: capturedErrorMessage
        )
    }

    private func waitForResponse(
        id: Int,
        reader: LineReader,
        timeout: TimeInterval
    ) throws -> [String: Any]? {
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

            return object
        }

        return nil
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

/// `readabilityHandler` 在任意线程回调；全部可变状态由 `condition` 保护。
private nonisolated final class LineReader: @unchecked Sendable {
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
