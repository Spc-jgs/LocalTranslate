import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct GrokProvider: UsageProvider {
    let providerID = "grok-supergrok"
    let sortOrder = 30

    func fetch() async throws -> AccountSnapshot {
        try await Task.detached(priority: .utility) {
            let credentials = try GrokCredentialsStore.load()

            async let remote = self.fetchRemote(credentials: credentials)
            async let local = GrokActivityScanner.shared.scan()

            let remoteSnapshot = try await remote
            let localSnapshot = try await local

            return AccountSnapshot(
                id: self.providerID,
                sortOrder: self.sortOrder,
                provider: .xAI,
                displayName: "SuperGrok",
                email: credentials.email,
                plan: remoteSnapshot.plan,
                quotaWindows: remoteSnapshot.quotaWindows,
                activity: localSnapshot.periodActivity,
                dailyActivity: localSnapshot.dailyActivity,
                modelActivity: localSnapshot.modelActivity30d,
                updatedAt: Date(),
                sourceLabel: "Grok billing + local turn ledger",
                confidence: .high,
                statusMessage: remoteSnapshot.statusMessage
            )
        }.value
    }

    private func fetchRemote(credentials: GrokCredentials) async throws -> GrokRemoteSnapshot {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        let session = URLSession(configuration: config)

        async let billing = requestJSON(
            session: session,
            urlString: "https://cli-chat-proxy.grok.com/v1/billing?format=credits",
            credentials: credentials
        )

        async let settings = requestJSON(
            session: session,
            urlString: "https://cli-chat-proxy.grok.com/v1/settings",
            credentials: credentials
        )

        let billingJSON = try await billing
        let settingsJSON = try await settings

        let billingConfig = billingJSON["config"] as? [String: Any] ?? [:]
        let currentPeriod = billingConfig["currentPeriod"] as? [String: Any] ?? [:]

        let plan = (settingsJSON["subscription_tier_display"] as? String)
            ?? (billingJSON["subscriptionTier"] as? String)
            ?? "SuperGrok"

        let periodType = currentPeriod["type"] as? String
        let periodStart = parseISODate(currentPeriod["start"] as? String)
            ?? parseISODate(billingConfig["billingPeriodStart"] as? String)
        let periodEnd = parseISODate(currentPeriod["end"] as? String)
            ?? parseISODate(billingConfig["billingPeriodEnd"] as? String)

        let explicitPercent = number(billingConfig["creditUsagePercent"])

        let inferredZero = explicitPercent == nil && periodEnd != nil
        let usedPercent = explicitPercent ?? (inferredZero ? 0.0 : nil)

        let title: String
        switch periodType {
        case "USAGE_PERIOD_TYPE_WEEKLY":
            title = "Weekly"
        case "USAGE_PERIOD_TYPE_MONTHLY":
            title = "Monthly"
        default:
            if let start = periodStart,
               let end = periodEnd {
                let days = Calendar.current.dateComponents([.day], from: start, to: end).day ?? 0
                title = days <= 8 ? "Weekly" : "Usage"
            } else {
                title = "Usage"
            }
        }

        let durationMinutes: Int?
        if let start = periodStart, let end = periodEnd {
            durationMinutes = Int(end.timeIntervalSince(start) / 60)
        } else {
            durationMinutes = nil
        }

        let quota = QuotaWindow(
            id: "grok-\(title.lowercased())",
            title: title,
            usedPercent: usedPercent,
            durationMinutes: durationMinutes,
            resetsAt: periodEnd,
            sourceLabel: "Grok billing"
        )

        return GrokRemoteSnapshot(
            plan: plan,
            quotaWindows: [quota],
            statusMessage: inferredZero ? "Usage percent currently encoded as proto3 default 0%." : nil
        )
    }

    private func requestJSON(
        session: URLSession,
        urlString: String,
        credentials: GrokCredentials
    ) async throws -> [String: Any] {
        guard let url = URL(string: urlString) else {
            throw UsageHubError.invalidResponse("Invalid Grok URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("xai-grok-cli", forHTTPHeaderField: "X-XAI-Token-Auth")
        request.setValue(credentials.userID, forHTTPHeaderField: "x-userid")
        request.setValue("1.0.5", forHTTPHeaderField: "x-grok-client-version")
        request.setValue("interactive", forHTTPHeaderField: "x-grok-client-mode")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw UsageHubError.invalidResponse("Grok response is not HTTP")
        }

        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            let safeBody = String(body.prefix(300))
            throw UsageHubError.http(http.statusCode, safeBody)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageHubError.invalidResponse("Grok JSON root is not an object")
        }

        return json
    }

    private func parseISODate(_ value: String?) -> Date? {
        guard let value else { return nil }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }

        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }
}

private struct GrokRemoteSnapshot: Sendable {
    let plan: String
    let quotaWindows: [QuotaWindow]
    let statusMessage: String?
}

private struct GrokCredentials: Sendable {
    let accessToken: String
    let userID: String
    let email: String?
}

private enum GrokCredentialsStore {
    static func load() throws -> GrokCredentials {
        let authURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grok", isDirectory: true)
            .appendingPathComponent("auth.json")

        guard FileManager.default.fileExists(atPath: authURL.path) else {
            throw UsageHubError.missingCredentials("~/.grok/auth.json 不存在，请先执行 grok login")
        }

        let data = try Data(contentsOf: authURL)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageHubError.invalidResponse("~/.grok/auth.json 根节点不是对象")
        }

        var candidate: [String: Any]?

        for (scope, rawValue) in root {
            guard scope.hasPrefix("https://auth.x.ai::"),
                  let entry = rawValue as? [String: Any],
                  let key = entry["key"] as? String,
                  !key.isEmpty else {
                continue
            }
            candidate = entry
            break
        }

        guard let entry = candidate,
              let accessToken = entry["key"] as? String,
              let userID = entry["user_id"] as? String,
              !accessToken.isEmpty,
              !userID.isEmpty else {
            throw UsageHubError.missingCredentials("没有找到可用的 Grok OIDC credential")
        }

        return GrokCredentials(
            accessToken: accessToken,
            userID: userID,
            email: entry["email"] as? String
        )
    }
}

private struct GrokActivitySnapshot: Sendable {
    let periodActivity: [PeriodActivity]
    let dailyActivity: [DailyActivity]
    let modelActivity30d: [ModelActivity]
}

private actor GrokActivityScanner {
    static let shared = GrokActivityScanner()

    private static let targetBytes = "turn_completed".data(using: .utf8)!

    func scan() throws -> GrokActivitySnapshot {
        let sessionsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grok", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)

        guard FileManager.default.fileExists(atPath: sessionsURL.path) else {
            GrokCacheStore.shared.pruneStaleEntries(validPaths: [])
            GrokCacheStore.shared.saveIfDirty()
            return GrokActivitySnapshot(
                periodActivity: zeroPeriods(),
                dailyActivity: [],
                modelActivity30d: []
            )
        }

        let files = updatesFiles(in: sessionsURL)
        let livePaths = Set(files.map(\.path))

        GrokCacheStore.shared.pruneStaleEntries(validPaths: livePaths)

        for file in files {
            try refreshCache(for: file)
        }

        GrokCacheStore.shared.saveIfDirty()

        let turns = GrokCacheStore.shared.allTurns()
        return buildSnapshot(from: turns)
    }

    private func refreshCache(for file: URL) throws {
        let path = file.path
        let values = try file.resourceValues(forKeys: [
            .fileSizeKey,
            .contentModificationDateKey
        ])

        let reportedSize = UInt64(max(0, values.fileSize ?? 0))
        let modificationDate = values.contentModificationDate

        if let existing = GrokCacheStore.shared.getEntry(for: path),
           existing.fileSize == reportedSize,
           sameDate(modificationDate, existing.modificationDate) {
            // Unchanged file: 0 disk reads, immediate cache hit!
            return
        }

        var entry = GrokCacheStore.shared.getEntry(for: path) ?? CachedFileEntry(
            fileSize: 0,
            modificationDate: nil,
            turnsByPromptID: [:]
        )

        // Read using memory mapping for zero-copy efficiency
        guard let data = try? Data(contentsOf: file, options: [.alwaysMapped, .uncached]) else {
            return
        }

        if reportedSize < entry.fileSize {
            // Truncated file, reset
            entry.turnsByPromptID.removeAll(keepingCapacity: true)
            parseBytes(data, fromOffset: 0, into: &entry)
        } else {
            let startOffset = Int(entry.fileSize)
            parseBytes(data, fromOffset: startOffset, into: &entry)
        }

        entry.fileSize = reportedSize
        entry.modificationDate = modificationDate
        GrokCacheStore.shared.setEntry(entry, for: path)
    }

    private func parseBytes(_ data: Data, fromOffset startOffset: Int, into entry: inout CachedFileEntry) {
        guard !data.isEmpty, startOffset < data.count else { return }

        let target = Self.targetBytes
        var searchRange = (data.startIndex + startOffset)..<data.endIndex
        var nextMissingID = entry.turnsByPromptID.count

        while let found = data.range(of: target, options: [], in: searchRange) {
            // Backtrack to start of line
            var lineStart = found.lowerBound
            while lineStart > data.startIndex && data[lineStart - 1] != 0x0A {
                lineStart -= 1
            }

            // Forward to end of line
            var lineEnd = found.upperBound
            while lineEnd < data.endIndex && data[lineEnd] != 0x0A && data[lineEnd] != 0x0D {
                lineEnd += 1
            }

            let lineData = data.subdata(in: lineStart..<lineEnd)
            searchRange = min(lineEnd + 1, data.endIndex)..<data.endIndex

            guard let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let params = object["params"] as? [String: Any],
                  let update = params["update"] as? [String: Any],
                  update["sessionUpdate"] as? String == "turn_completed",
                  let usage = update["usage"] as? [String: Any],
                  let date = self.turnDate(object: object, params: params) else {
                continue
            }

            let promptID: String
            if let value = update["prompt_id"] as? String, !value.isEmpty {
                promptID = value
            } else {
                promptID = "missing-\(nextMissingID)"
                nextMissingID += 1
            }

            let topUsage = self.tokenBreakdown(usage)
            let topCost = self.trustedCost(usage)

            var models: [String: CachedModelRecord] = [:]
            if let modelUsage = usage["modelUsage"] as? [String: Any] {
                for (modelID, rawModel) in modelUsage {
                    guard let model = rawModel as? [String: Any] else { continue }
                    let modelBreakdown = self.tokenBreakdown(model)
                    guard modelBreakdown.totalTokens > 0 else { continue }

                    models[modelID] = CachedModelRecord(
                        usage: modelBreakdown,
                        costUSD: self.trustedCost(model)
                    )
                }
            }

            entry.turnsByPromptID[promptID] = CachedTurn(
                date: date,
                usage: topUsage,
                costUSD: topCost,
                models: models
            )
        }
    }

    private func updatesFiles(in root: URL) -> [URL] {
        let fileManager = FileManager.default
        guard let topDirs = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var result: [URL] = []

        for topDir in topDirs {
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: topDir.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }

            guard let sessionDirs = try? fileManager.contentsOfDirectory(
                at: topDir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for sessionDir in sessionDirs {
                let candidate = sessionDir.appendingPathComponent("updates.jsonl")
                if fileManager.fileExists(atPath: candidate.path) {
                    result.append(candidate)
                }
            }
        }

        return result.sorted { $0.path < $1.path }
    }

    private func buildSnapshot(from turns: [CachedTurn]) -> GrokActivitySnapshot {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let start7 = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        let start30 = calendar.date(byAdding: .day, value: -29, to: today) ?? today

        let todayTurns = turns.filter { calendar.startOfDay(for: $0.date) == today }
        let sevenDayTurns = turns.filter { calendar.startOfDay(for: $0.date) >= start7 }
        let thirtyDayTurns = turns.filter { calendar.startOfDay(for: $0.date) >= start30 }

        let periodActivity = [
            aggregatePeriod(.today, turns: todayTurns),
            aggregatePeriod(.sevenDays, turns: sevenDayTurns),
            aggregatePeriod(.thirtyDays, turns: thirtyDayTurns),
            aggregatePeriod(.lifetime, turns: turns)
        ]

        return GrokActivitySnapshot(
            periodActivity: periodActivity,
            dailyActivity: aggregateDaily(turns: turns),
            modelActivity30d: aggregateModels(turns: thirtyDayTurns)
        )
    }

    private func turnDate(object: [String: Any], params: [String: Any]) -> Date? {
        if let meta = params["_meta"] as? [String: Any],
           let ms = number(meta["agentTimestampMs"]),
           ms > 0 {
            return Date(timeIntervalSince1970: ms / 1000)
        }

        if let seconds = number(object["timestamp"]), seconds > 0 {
            return Date(timeIntervalSince1970: seconds)
        }

        return nil
    }

    private func tokenBreakdown(_ object: [String: Any]) -> TokenBreakdown {
        TokenBreakdown(
            inputTokens: int64(object["inputTokens"]),
            outputTokens: int64(object["outputTokens"]),
            cachedReadTokens: int64(object["cachedReadTokens"]),
            cacheCreationTokens: int64(object["cacheCreationTokens"]),
            reasoningTokens: int64(object["reasoningTokens"])
        )
    }

    private func trustedCost(_ object: [String: Any]) -> Double? {
        let incomplete = bool(object["usageIsIncomplete"])
        let partial = bool(object["costIsPartial"])
        guard !incomplete, !partial else { return nil }

        guard let ticks = number(object["costUsdTicks"]), ticks != 0 else {
            return nil
        }

        return ticks / 10_000_000_000
    }

    private func aggregatePeriod(_ period: ActivityPeriod, turns: [CachedTurn]) -> PeriodActivity {
        let totalTokens = turns.reduce(Int64(0)) { $0 + $1.usage.totalTokens }
        let costs = turns.compactMap(\.costUSD)
        let hasCompleteCost = costs.count == turns.count && !turns.isEmpty

        return PeriodActivity(
            period: period,
            tokens: totalTokens,
            turns: turns.count,
            costUSD: hasCompleteCost ? costs.reduce(0, +) : nil
        )
    }

    private func aggregateDaily(turns: [CachedTurn]) -> [DailyActivity] {
        struct MutableDay {
            var tokens: Int64 = 0
            var turns: Int = 0
        }

        let calendar = Calendar.current
        var byDay: [Date: MutableDay] = [:]

        for turn in turns {
            let day = calendar.startOfDay(for: turn.date)
            var item = byDay[day] ?? MutableDay()
            item.tokens += turn.usage.totalTokens
            item.turns += 1
            byDay[day] = item
        }

        return byDay.map { day, item in
            DailyActivity(
                date: day,
                tokens: item.tokens,
                turns: item.turns
            )
        }
        .sorted { $0.date < $1.date }
    }

    private func aggregateModels(turns: [CachedTurn]) -> [ModelActivity] {
        struct MutableModel {
            var usage = TokenBreakdown()
            var turns = 0
            var costUSD: Double = 0
            var costComplete = true
        }

        var byModel: [String: MutableModel] = [:]

        for turn in turns {
            for (modelID, record) in turn.models {
                var item = byModel[modelID] ?? MutableModel()
                item.usage.add(record.usage)
                item.turns += 1

                if let cost = record.costUSD {
                    item.costUSD += cost
                } else {
                    item.costComplete = false
                }

                byModel[modelID] = item
            }
        }

        return byModel.map { modelID, item in
            ModelActivity(
                modelID: modelID,
                displayName: displayModelName(modelID),
                period: .thirtyDays,
                usage: item.usage,
                turns: item.turns,
                costUSD: item.costComplete ? item.costUSD : nil
            )
        }
        .sorted { $0.usage.totalTokens > $1.usage.totalTokens }
    }

    private func displayModelName(_ modelID: String) -> String {
        let cleaned = modelID.replacingOccurrences(of: "-build", with: "")
        if cleaned.hasPrefix("grok-") {
            return cleaned.replacingOccurrences(of: "grok-", with: "Grok ")
        }
        return cleaned
    }

    private func zeroPeriods() -> [PeriodActivity] {
        ActivityPeriod.allCases.map {
            PeriodActivity(period: $0, tokens: 0, turns: 0, costUSD: nil)
        }
    }

    private func sameDate(_ lhs: Date?, _ rhs: Date?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            return abs(lhs.timeIntervalSince(rhs)) < 0.001
        default:
            return false
        }
    }

    private func int64(_ value: Any?) -> Int64 {
        if let number = value as? NSNumber { return number.int64Value }
        if let string = value as? String, let parsed = Int64(string) { return parsed }
        return 0
    }

    private func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private func bool(_ value: Any?) -> Bool {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        return false
    }
}
