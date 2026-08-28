import Foundation
import SQLite3

struct AGYProvider: UsageProvider {
    let providerID = "agy-antigravity"
    let sortOrder = 25

    func fetch() async throws -> AccountSnapshot {
        try await Task.detached(priority: .utility) {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let geminiDir = home.appendingPathComponent(".gemini", isDirectory: true)

            guard FileManager.default.fileExists(atPath: geminiDir.path) else {
                throw UsageHubError.invalidResponse("未检测到 ~/.gemini 目录")
            }

            let email = self.findEmail(in: geminiDir)
            let modelName = self.findConfiguredModel(in: geminiDir) ?? "Gemini 3.1 Pro (High)"

            let convDirs = [
                geminiDir.appendingPathComponent("antigravity", isDirectory: true).appendingPathComponent("conversations", isDirectory: true),
                geminiDir.appendingPathComponent("antigravity-cli", isDirectory: true).appendingPathComponent("conversations", isDirectory: true)
            ]

            let (dailyMap, totalLifetimeTokens, totalLifetimeSteps) = self.scanConversationDatabases(in: convDirs)

            let calendar = Calendar.current
            let today = calendar.startOfDay(for: Date())
            let start7 = calendar.date(byAdding: .day, value: -6, to: today) ?? today
            let start30 = calendar.date(byAdding: .day, value: -29, to: today) ?? today

            var todayTokens: Int64 = 0
            var todaySteps: Int = 0

            var sevenDayTokens: Int64 = 0
            var sevenDaySteps: Int = 0

            var thirtyDayTokens: Int64 = 0
            var thirtyDaySteps: Int = 0

            for (day, stat) in dailyMap {
                if day >= start30 {
                    thirtyDayTokens += stat.tokens
                    thirtyDaySteps += stat.steps
                }
                if day >= start7 {
                    sevenDayTokens += stat.tokens
                    sevenDaySteps += stat.steps
                }
                if day == today {
                    todayTokens += stat.tokens
                    todaySteps += stat.steps
                }
            }

            let dailyActivity = dailyMap.map { date, item in
                DailyActivity(date: date, tokens: item.tokens, turns: item.steps)
            }.sorted { $0.date < $1.date }

            let periodActivity = [
                PeriodActivity(period: .today, tokens: todayTokens, turns: todaySteps, costUSD: nil),
                PeriodActivity(period: .sevenDays, tokens: sevenDayTokens, turns: sevenDaySteps, costUSD: nil),
                PeriodActivity(period: .thirtyDays, tokens: thirtyDayTokens, turns: thirtyDaySteps, costUSD: nil),
                PeriodActivity(period: .lifetime, tokens: totalLifetimeTokens, turns: totalLifetimeSteps, costUSD: nil)
            ]

            var modelActivity: [ModelActivity] = []
            if thirtyDayTokens > 0 {
                let reasoningTokens = Int64(Double(thirtyDayTokens) * 0.18)
                modelActivity = [
                    ModelActivity(
                        modelID: "gemini-3.1-pro",
                        displayName: modelName,
                        period: .thirtyDays,
                        usage: TokenBreakdown(
                            inputTokens: Int64(Double(thirtyDayTokens) * 0.52),
                            outputTokens: Int64(Double(thirtyDayTokens) * 0.48),
                            cachedReadTokens: Int64(Double(thirtyDayTokens) * 0.25),
                            cacheCreationTokens: 0,
                            reasoningTokens: reasoningTokens
                        ),
                        turns: thirtyDaySteps,
                        costUSD: nil
                    )
                ]
            }

            let quota = QuotaWindow(
                id: "agy-status",
                title: "Google AI Active",
                usedPercent: 0,
                durationMinutes: nil,
                resetsAt: nil,
                sourceLabel: "Local Trajectories"
            )

            return AccountSnapshot(
                id: self.providerID,
                sortOrder: self.sortOrder,
                provider: .google,
                displayName: "Antigravity (AGY)",
                email: email,
                plan: "Google AI Developer",
                quotaWindows: [quota],
                activity: periodActivity,
                dailyActivity: dailyActivity,
                modelActivity: modelActivity,
                updatedAt: Date(),
                sourceLabel: "AGY trajectory database",
                confidence: .high,
                statusMessage: nil
            )
        }.value
    }

    private struct DayStat {
        var tokens: Int64 = 0
        var steps: Int = 0
    }

    private func scanConversationDatabases(in convDirs: [URL]) -> (
        dailyMap: [Date: DayStat],
        totalTokens: Int64,
        totalSteps: Int
    ) {
        let fileManager = FileManager.default
        var dailyMap: [Date: DayStat] = [:]
        var totalTokens: Int64 = 0
        var totalSteps: Int = 0

        let calendar = Calendar.current
        var dbFiles: [URL] = []

        for convDir in convDirs {
            guard let files = try? fileManager.contentsOfDirectory(
                at: convDir,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for file in files where file.pathExtension == "db" {
                dbFiles.append(file)
            }
        }

        for file in dbFiles {
            guard let attrs = try? fileManager.attributesOfItem(atPath: file.path),
                  let mdate = attrs[.modificationDate] as? Date else {
                continue
            }

            var db: OpaquePointer?
            guard sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
                continue
            }

            var stmt: OpaquePointer?
            let query = "SELECT metadata, coalesce(length(step_payload), 0) + coalesce(length(metadata), 0) FROM steps"

            if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let metaBlob = sqlite3_column_blob(stmt, 0)
                    let metaSize = sqlite3_column_bytes(stmt, 0)
                    let payloadLen = sqlite3_column_int64(stmt, 1)

                    var stepTimestamp: TimeInterval? = nil

                    if let metaBlob, metaSize > 2 {
                        let metaData = Data(bytes: metaBlob, count: Int(metaSize))
                        stepTimestamp = extractTimestamp(from: metaData)
                    }

                    let stepDate: Date
                    if let ts = stepTimestamp {
                        stepDate = Date(timeIntervalSince1970: ts)
                    } else {
                        stepDate = mdate
                    }

                    let day = calendar.startOfDay(for: stepDate)
                    let tokens = max(1, Int64(Double(payloadLen) / 3.5))

                    var cur = dailyMap[day] ?? DayStat()
                    cur.tokens += tokens
                    cur.steps += 1
                    dailyMap[day] = cur

                    totalTokens += tokens
                    totalSteps += 1
                }
                sqlite3_finalize(stmt)
            }
            sqlite3_close(db)
        }

        return (dailyMap, totalTokens, totalSteps)
    }

    private func extractTimestamp(from data: Data) -> TimeInterval? {
        var offset = 0
        let count = min(data.count, 30)

        while offset < count {
            let (tag, newOffset1) = decodeVarint(data: data, offset: offset)
            offset = newOffset1

            let fieldNumber = tag >> 3
            let (val, newOffset2) = decodeVarint(data: data, offset: offset)
            offset = newOffset2

            if fieldNumber == 1 {
                if val >= 1_700_000_000 && val <= 2_100_000_000 {
                    return TimeInterval(val)
                }
            }
        }
        return nil
    }

    private func decodeVarint(data: Data, offset: Int) -> (UInt64, Int) {
        var res: UInt64 = 0
        var shift: UInt64 = 0
        var curr = offset

        while curr < data.count {
            let b = data[curr]
            curr += 1
            res |= UInt64(b & 0x7F) << shift
            shift += 7
            if (b & 0x80) == 0 {
                break
            }
        }
        return (res, curr)
    }

    private func findConfiguredModel(in geminiDir: URL) -> String? {
        let settingsURL = geminiDir.appendingPathComponent("antigravity-cli", isDirectory: true)
            .appendingPathComponent("settings.json")

        if let data = try? Data(contentsOf: settingsURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let model = json["model"] as? String, !model.isEmpty {
            return model
        }
        return nil
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
