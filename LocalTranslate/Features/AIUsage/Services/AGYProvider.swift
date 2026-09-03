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

        async let quotaResult = fetchQuota()
        async let activityResult = fetchActivity()
        let quota = await quotaResult
        let activity = await activityResult

        if case .failure(let quotaError) = quota,
           case .failure(let activityError) = activity {
            throw UsageHubError.invalidResponse(
                "AGY 额度与活动均不可用：\(quotaError.localizedDescription)；"
                    + activityError.localizedDescription
            )
        }

        let quotaValue = try? quota.get()
        let activityValue = (try? activity.get()) ?? Self.emptyActivity
        let quotaError: String?
        switch quota {
        case .success:
            quotaError = nil
        case .failure(let error):
            quotaError = error.localizedDescription
        }
        let activityError: String?
        let activityAvailable: Bool
        switch activity {
        case .success:
            activityError = nil
            activityAvailable = true
        case .failure(let error):
            activityError = error.localizedDescription
            activityAvailable = false
        }
        let activityIsEstimated = activityValue.modelActivity.contains {
            $0.modelID == "agy-activity-estimate"
        }
        let activityHasWaitingModel = activityValue.modelActivity.contains {
            $0.modelID != "agy-activity-estimate"
                && $0.turns == 0
                && $0.usage.totalTokens == 0
        }
        let catchUp = UsageCatchUpProgress(indexed: activityValue)
        let status = [
            quotaError.map { "实时额度不可用：\($0)" },
            activityAvailable && activityIsEstimated
                ? "本地活动量是按轨迹字节数换算的估算值，不代表官方 Token 用量。"
                : nil,
            activityHasWaitingModel
                ? "已识别本机会话模型；缺少可验证事件时间的 Token 不归入今日，等待上游落盘。"
                : nil,
            catchUp.statusText,
            activityError.map { "活动索引不可用：\($0)" }
        ].compactMap { $0 }.joined(separator: "；")

        let sourceLabel: String
        switch (quotaValue != nil, activityAvailable) {
        case (true, true):
            if activityIsEstimated {
                sourceLabel = "AGY 本机额度接口 + 本机活动估算"
            } else if activityHasWaitingModel {
                sourceLabel = "AGY 本机额度接口 + 本机会话模型证据"
            } else {
                sourceLabel = "AGY 本机额度接口 + 本机 Token 索引"
            }
        case (true, false):
            sourceLabel = "AGY 本机额度接口"
        case (false, true):
            if activityIsEstimated {
                sourceLabel = "AGY 本机增量索引（活动估算）"
            } else if activityHasWaitingModel {
                sourceLabel = "AGY 本机会话模型证据"
            } else {
                sourceLabel = "AGY 本机 Token 索引"
            }
        case (false, false):
            sourceLabel = "AGY 数据不可用"
        }

        return AccountSnapshot(
            id: providerID,
            sortOrder: sortOrder,
            provider: .google,
            billingKind: quotaValue == nil ? .local : .subscription,
            displayName: "Antigravity (AGY)",
            email: quotaValue?.email ?? findEmail(in: geminiDir),
            plan: quotaValue?.plan,
            quotaWindows: quotaValue?.quotaWindows ?? [],
            activity: activityValue.periodActivity,
            dailyActivity: activityValue.dailyActivity,
            modelActivity: activityValue.modelActivity,
            updatedAt: Date(),
            sourceLabel: sourceLabel,
            confidence: activityIsEstimated || activityHasWaitingModel
                ? .low
                : (quotaValue == nil ? .medium : .high),
            statusMessage: status,
            schemaVersion: AccountSnapshot.currentSchemaVersion,
            quotaAvailable: quotaValue != nil,
            activityAvailable: activityAvailable,
            catchUp: catchUp
        )
    }

    private func fetchQuota() async -> Result<AGYLocalQuotaSnapshot, Error> {
        do {
            return .success(try await AGYLocalQuotaClient().fetch())
        } catch {
            return .failure(error)
        }
    }

    private func fetchActivity() async -> Result<IndexedActivitySnapshot, Error> {
        do {
            return .success(
                try await UsageActivityIndexer.shared.scanAGY(providerID: providerID)
            )
        } catch {
            return .failure(error)
        }
    }

    private static let emptyActivity = IndexedActivitySnapshot(
        periodActivity: [],
        dailyActivity: [],
        modelActivity: [],
        indexedFiles: 0,
        candidateFiles: 0,
        indexedProgress: 0,
        catchUpPending: false
    )

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
