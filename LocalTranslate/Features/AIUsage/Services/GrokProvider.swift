import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct GrokProvider: UsageProvider {
    let providerID = "grok-supergrok"
    let sortOrder = 30

    func fetch() async throws -> AccountSnapshot {
        async let remote = fetchRemoteGracefully()
        async let local = UsageActivityIndexer.shared.scanGrok(
            providerID: providerID
        )
        let localSnapshot = try await local
        let remoteOutcome = await remote

        let combinedStatus = [
            remoteOutcome.snapshot?.statusMessage,
            remoteOutcome.errorMessage,
            localSnapshot.catchUpPending ? "本地历史正在分片补齐" : nil,
            hasPendingModelEvidence(localSnapshot)
                ? "当前会话已识别模型，Token 与活动次数将在任务完成后落盘"
                : nil
        ].compactMap { $0 }.joined(separator: "；")

        return AccountSnapshot(
            id: providerID,
            sortOrder: sortOrder,
            provider: .xAI,
            billingKind: .subscription,
            displayName: "SuperGrok",
            email: remoteOutcome.credentials?.email,
            plan: remoteOutcome.snapshot?.plan,
            quotaWindows: remoteOutcome.snapshot?.quotaWindows ?? [],
            activity: localSnapshot.periodActivity,
            dailyActivity: localSnapshot.dailyActivity,
            modelActivity: localSnapshot.modelActivity,
            updatedAt: Date(),
            sourceLabel: remoteOutcome.snapshot == nil
                ? "Grok 本机增量索引"
                : "Grok billing + 本机增量索引",
            confidence: remoteOutcome.errorMessage == nil ? .high : .medium,
            statusMessage: combinedStatus.isEmpty ? nil : combinedStatus,
            schemaVersion: 4,
            quotaAvailable: remoteOutcome.snapshot != nil,
            activityAvailable: true
        )
    }

    private func hasPendingModelEvidence(_ snapshot: IndexedActivitySnapshot) -> Bool {
        snapshot.modelActivity.contains {
            $0.period == .today && $0.turns == 0 && $0.usage.totalTokens == 0
        }
    }

    private func fetchRemoteGracefully() async -> GrokRemoteOutcome {
        do {
            let credentials = try GrokCredentialsStore.load()
            let snapshot = try await fetchRemote(credentials: credentials)
            return GrokRemoteOutcome(
                credentials: credentials,
                snapshot: snapshot,
                errorMessage: nil
            )
        } catch {
            return GrokRemoteOutcome(
                credentials: nil,
                snapshot: nil,
                errorMessage: error.localizedDescription
            )
        }
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

        let usedPercent = explicitPercent

        let title: String
        switch periodType {
        case "USAGE_PERIOD_TYPE_WEEKLY":
            title = "每周"
        case "USAGE_PERIOD_TYPE_MONTHLY":
            title = "每月"
        default:
            if let start = periodStart,
               let end = periodEnd {
                let days = Calendar.current.dateComponents([.day], from: start, to: end).day ?? 0
                title = days <= 8 ? "每周" : "额度"
            } else {
                title = "额度"
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
            statusMessage: explicitPercent == nil
                ? "Grok 当前未返回可验证的使用比例，仅显示额度周期与重置时间。"
                : nil
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
private nonisolated struct GrokRemoteSnapshot: Sendable {
    let plan: String
    let quotaWindows: [QuotaWindow]
    let statusMessage: String?
}

private nonisolated struct GrokRemoteOutcome: Sendable {
    let credentials: GrokCredentials?
    let snapshot: GrokRemoteSnapshot?
    let errorMessage: String?
}

private nonisolated struct GrokCredentials: Sendable {
    let accessToken: String
    let userID: String
    let email: String?
}

private nonisolated enum GrokCredentialsStore {
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
