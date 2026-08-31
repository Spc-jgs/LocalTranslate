import Foundation

struct AGYProvider: UsageProvider {
    let providerID = "agy-antigravity"
    let sortOrder = 25

    func fetch() async throws -> AccountSnapshot {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let geminiDir = home.appendingPathComponent(".gemini", isDirectory: true)

        guard FileManager.default.fileExists(atPath: geminiDir.path) else {
            throw UsageHubError.invalidResponse("未检测到 ~/.gemini 目录")
        }

        let email = findEmail(in: geminiDir)
        let local = try await UsageActivityIndexer.shared.scanAGY(
            providerID: providerID
        )
        let status = local.catchUpPending
            ? "AGY 活动量按本地轨迹字节数估算；历史正在分片补齐。"
            : "AGY 暂无可验证的实时额度与 Token 明细；活动量按本地轨迹字节数估算。"

        return AccountSnapshot(
            id: providerID,
            sortOrder: sortOrder,
            provider: .google,
            billingKind: .local,
            displayName: "Antigravity (AGY)",
            email: email,
            plan: "Google AI Developer",
            quotaWindows: [],
            activity: local.periodActivity,
            dailyActivity: local.dailyActivity,
            modelActivity: [],
            updatedAt: Date(),
            sourceLabel: "AGY 本机增量索引（字符量估算）",
            confidence: .low,
            statusMessage: status,
            schemaVersion: 4,
            quotaAvailable: false,
            activityAvailable: true
        )
    }

    private func findEmail(in geminiDir: URL) -> String? {
        let oauthURL = geminiDir.appendingPathComponent("jetski-standalone-oauth-token")

        if let data = try? Data(contentsOf: oauthURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let email = json["email"] as? String, !email.isEmpty {
                return email
            }
            if let token = json["token"] as? [String: Any],
               let email = token["email"] as? String, !email.isEmpty {
                return email
            }
        }
        return nil
    }
}
