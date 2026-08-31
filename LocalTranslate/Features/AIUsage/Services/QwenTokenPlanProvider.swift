import Foundation

struct QwenTokenPlanProvider: UsageProvider {
    static let chinaBaseURL =
        "https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1"

    let providerID = "alibaba-qwen-token-plan-cn"
    let sortOrder = 40

    func fetch() async throws -> AccountSnapshot {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let qwenHome = home.appendingPathComponent(".qwen", isDirectory: true)
        let configured = detectsChinaTokenPlan(in: qwenHome)
        let usageURL = qwenHome.appendingPathComponent("usage_record.jsonl")

        guard configured else {
            return snapshot(
                activity: nil,
                status: "未检测到百炼中国区 Token Plan 配置。Qwen Code 配置后会自动识别 BAILIAN_TOKEN_PLAN_API_KEY 与中国区专属 Base URL。"
            )
        }

        guard FileManager.default.fileExists(atPath: usageURL.path) else {
            return snapshot(
                activity: nil,
                status: "已识别百炼中国区 Token Plan API Key，但 Qwen Code 尚未生成 usage_record.jsonl；完成一次会话后会显示本机 Token 用量。"
            )
        }

        let local = try await UsageActivityIndexer.shared.scanQwen(
            providerID: providerID,
            qwenHome: qwenHome
        )
        let status = local.catchUpPending
            ? "Qwen Code 本机用量正在分片补齐；Credits 与套餐余额以百炼控制台为准。"
            : "展示 Qwen Code 对该 Token Plan 配置记录的本机 Token；Credits 抵扣与套餐余额以百炼控制台为准。"
        return snapshot(activity: local, status: status)
    }

    private func snapshot(
        activity: IndexedActivitySnapshot?,
        status: String
    ) -> AccountSnapshot {
        AccountSnapshot(
            id: providerID,
            sortOrder: sortOrder,
            provider: .alibaba,
            billingKind: .apiKey,
            displayName: "百炼 Qwen Token Plan",
            email: nil,
            plan: "中国区 API Key",
            quotaWindows: [],
            activity: activity?.periodActivity ?? [],
            dailyActivity: activity?.dailyActivity ?? [],
            modelActivity: activity?.modelActivity ?? [],
            updatedAt: Date(),
            sourceLabel: "Qwen Code usage_record.jsonl",
            confidence: activity == nil ? .low : .high,
            statusMessage: status,
            schemaVersion: AccountSnapshot.currentSchemaVersion,
            quotaAvailable: true,
            activityAvailable: true
        )
    }

    private func detectsChinaTokenPlan(in qwenHome: URL) -> Bool {
        let environment = ProcessInfo.processInfo.environment
        if environment["OPENAI_BASE_URL"] == Self.chinaBaseURL,
           hasTokenPlanKey(environment["BAILIAN_TOKEN_PLAN_API_KEY"]
                ?? environment["OPENAI_API_KEY"]) {
            return true
        }

        let settingsURL = qwenHome.appendingPathComponent("settings.json")
        if let data = try? Data(contentsOf: settingsURL),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           settingsContainTokenPlan(object) {
            return true
        }

        let dotenvURL = qwenHome.appendingPathComponent(".env")
        if let text = try? String(contentsOf: dotenvURL, encoding: .utf8) {
            return dotenvContainsTokenPlan(text)
        }
        return false
    }

    private func settingsContainTokenPlan(_ object: [String: Any]) -> Bool {
        guard let providers = object["modelProviders"] as? [String: Any] else {
            return false
        }
        for rawModels in providers.values {
            guard let models = rawModels as? [[String: Any]] else { continue }
            if models.contains(where: { model in
                model["baseUrl"] as? String == Self.chinaBaseURL
                    && ((model["envKey"] as? String) == "BAILIAN_TOKEN_PLAN_API_KEY"
                        || (model["envKey"] as? String) == "OPENAI_API_KEY")
            }) {
                return true
            }
        }
        return false
    }

    private func dotenvContainsTokenPlan(_ text: String) -> Bool {
        var values: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"),
                  let separator = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<separator])
                .replacingOccurrences(of: "export ", with: "")
                .trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            values[key] = value
        }
        return values["OPENAI_BASE_URL"] == Self.chinaBaseURL
            && hasTokenPlanKey(
                values["BAILIAN_TOKEN_PLAN_API_KEY"] ?? values["OPENAI_API_KEY"]
            )
    }

    private func hasTokenPlanKey(_ value: String?) -> Bool {
        value?.trimmingCharacters(in: .whitespacesAndNewlines)
            .hasPrefix("sk-sp-") == true
    }
}
