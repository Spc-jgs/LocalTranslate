import Foundation

struct ClaudeProvider: UsageProvider {
    let providerID = "claude-subscription"
    let sortOrder = 22

    func fetch() async throws -> AccountSnapshot {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let claudeHome = home.appendingPathComponent(".claude", isDirectory: true)
        let stateURL = home.appendingPathComponent(".claude.json")
        let state = loadJSONObject(at: stateURL)
        let account = state?["oauthAccount"] as? [String: Any]
        let quota = quotaSnapshot(from: state)

        guard FileManager.default.fileExists(atPath: claudeHome.path) else {
            return emptySnapshot(
                plan: planName(account?["organizationType"]),
                status: "未检测到 ~/.claude；登录 Claude Code 后会自动读取订阅与本机会话用量。"
            )
        }

        let local = try await UsageActivityIndexer.shared.scanClaude(
            providerID: providerID,
            claudeHome: claudeHome
        )
        let catchUp = UsageCatchUpProgress(indexed: local)
        var messages: [String] = []
        if let progress = catchUp.statusText {
            messages.append(progress)
        }
        if let fetchedAt = quota.fetchedAt, !quota.isFresh {
            messages.append(
                "Claude 额度缓存停留在 \(fetchedAt.formatted(date: .abbreviated, time: .shortened))，已隐藏过期比例；请在 Claude Code 中运行 /usage 刷新"
            )
        } else if quota.windows.isEmpty {
            messages.append("当前没有可验证的 Claude 订阅额度缓存；本机 Token 活动仍可用")
        }

        return AccountSnapshot(
            id: providerID,
            sortOrder: sortOrder,
            provider: .anthropic,
            billingKind: .subscription,
            displayName: "Claude",
            email: account?["emailAddress"] as? String,
            plan: planName(account?["organizationType"]),
            quotaWindows: quota.windows,
            activity: local.periodActivity,
            dailyActivity: local.dailyActivity,
            modelActivity: local.modelActivity,
            updatedAt: Date(),
            sourceLabel: "Claude Code 本机会话 + CLI 额度缓存",
            confidence: quota.windows.isEmpty ? .medium : .high,
            statusMessage: messages.isEmpty ? nil : messages.joined(separator: "；") + "。",
            schemaVersion: AccountSnapshot.currentSchemaVersion,
            quotaAvailable: !quota.windows.isEmpty,
            activityAvailable: true,
            catchUp: catchUp,
            quotaStatus: UsageDataStatus(
                quality: quota.windows.isEmpty ? .unavailable : .cached,
                updatedAt: quota.fetchedAt
            ),
            activityStatus: UsageDataStatus(quality: .observed, updatedAt: Date())
        )
    }

    private func emptySnapshot(plan: String?, status: String) -> AccountSnapshot {
        AccountSnapshot(
            id: providerID,
            sortOrder: sortOrder,
            provider: .anthropic,
            billingKind: .subscription,
            displayName: "Claude",
            email: nil,
            plan: plan,
            quotaWindows: [],
            activity: [],
            dailyActivity: [],
            modelActivity: [],
            updatedAt: Date(),
            sourceLabel: "Claude Code 本机状态",
            confidence: .low,
            statusMessage: status,
            schemaVersion: AccountSnapshot.currentSchemaVersion,
            quotaAvailable: false,
            activityAvailable: false,
            catchUp: nil,
            quotaStatus: UsageDataStatus(quality: .unavailable, updatedAt: nil),
            activityStatus: UsageDataStatus(quality: .unavailable, updatedAt: nil)
        )
    }

    private func loadJSONObject(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func planName(_ value: Any?) -> String? {
        guard let raw = value as? String else { return nil }
        switch raw.lowercased() {
        case "claude_pro": return "Claude Pro"
        case "claude_max": return "Claude Max"
        case "claude_team": return "Claude Team"
        case "claude_enterprise": return "Claude Enterprise"
        default:
            return raw.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private func quotaSnapshot(
        from state: [String: Any]?
    ) -> (windows: [QuotaWindow], fetchedAt: Date?, isFresh: Bool) {
        guard let cache = state?["cachedUsageUtilization"] as? [String: Any],
              let fetchedAtMS = number(cache["fetchedAtMs"]) else {
            return ([], nil, false)
        }
        let fetchedAt = Date(timeIntervalSince1970: fetchedAtMS / 1_000)
        let isFresh = abs(Date().timeIntervalSince(fetchedAt)) <= 6 * 60 * 60
        guard isFresh,
              let utilization = cache["utilization"] as? [String: Any] else {
            return ([], fetchedAt, false)
        }

        let windows = [
            quotaWindow(
                id: "claude-five-hour",
                title: "5 小时窗口",
                durationMinutes: 5 * 60,
                object: utilization["five_hour"]
            ),
            quotaWindow(
                id: "claude-seven-day",
                title: "7 天窗口",
                durationMinutes: 7 * 24 * 60,
                object: utilization["seven_day"]
            )
        ].compactMap { $0 }
        return (windows, fetchedAt, true)
    }

    private func quotaWindow(
        id: String,
        title: String,
        durationMinutes: Int,
        object: Any?
    ) -> QuotaWindow? {
        guard let object = object as? [String: Any] else { return nil }
        let used = number(object["utilization"])
        let reset = parseDate(object["resets_at"])
        guard used != nil || reset != nil else { return nil }
        return QuotaWindow(
            id: id,
            title: title,
            usedPercent: used.map { max(0, min(100, $0)) },
            durationMinutes: durationMinutes,
            resetsAt: reset,
            sourceLabel: "Claude Code /usage 缓存"
        )
    }

    private func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private func parseDate(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}
