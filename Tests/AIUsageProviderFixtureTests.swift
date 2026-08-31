import Foundation
import SQLite3

@main
struct AIUsageProviderFixtureTests {
    static func main() async throws {
        try await codexUnchangedAndAppendAreIncremental()
        try await codexTruncateRebuildsSingleFile()
        try await codexHalfLineWaitsForNewline()
        try await grokPromptUpsertDoesNotDuplicate()
        try await grokModelDetailsDoNotInflateAccountTotals()
        try await grokCurrentFormatPreservesModelEvidence()
        try await grokEvidenceDoesNotHideCompletedReferenceCost()
        try await agyDatabaseCacheHitAndChangeRebuild()
        try await agyWALHeaderWithoutSidecarsOpensImmutable()
        try await claudeUsageIsIncremental()
        try await qwenUsageSummaryIsIncremental()
        codexServerDailyOverridesOverlappingLocalHistory()
        referencePriceCatalogMatchesPublishedRates()
        try await corruptIndexIsQuarantinedAndRebuilt()
        print("AIUsageProviderFixtureTests: 14 passed")
    }

    private static func codexUnchangedAndAppendAreIncremental() async throws {
        try await withFixture { root, databaseURL in
            let file = try makeCodexFile(
                root: root,
                usageLines: [(10, 5)]
            )
            var snapshot = try await UsageActivityIndexer.shared.scanCodex(
                providerID: "codex-fixture",
                codexHome: root,
                databaseURL: databaseURL
            )
            expect(todayTokens(snapshot) == 15, "initial Codex fixture total is wrong")

            snapshot = try await UsageActivityIndexer.shared.scanCodex(
                providerID: "codex-fixture",
                codexHome: root,
                databaseURL: databaseURL
            )
            expect(todayTokens(snapshot) == 15, "unchanged Codex file duplicated events")

            try appendLine(tokenLine(input: 20, output: 10), to: file)
            snapshot = try await UsageActivityIndexer.shared.scanCodex(
                providerID: "codex-fixture",
                codexHome: root,
                databaseURL: databaseURL
            )
            expect(todayTokens(snapshot) == 45, "Codex append did not resume from cursor")
        }
    }

    private static func codexTruncateRebuildsSingleFile() async throws {
        try await withFixture { root, databaseURL in
            let file = try makeCodexFile(
                root: root,
                usageLines: [(10, 5), (20, 10)]
            )
            _ = try await UsageActivityIndexer.shared.scanCodex(
                providerID: "codex-truncate",
                codexHome: root,
                databaseURL: databaseURL
            )

            try codexDocument(usageLines: [(7, 3)]).write(
                to: file,
                atomically: true,
                encoding: .utf8
            )
            let snapshot = try await UsageActivityIndexer.shared.scanCodex(
                providerID: "codex-truncate",
                codexHome: root,
                databaseURL: databaseURL
            )
            expect(todayTokens(snapshot) == 10, "Codex truncate retained stale events")
        }
    }

    private static func codexHalfLineWaitsForNewline() async throws {
        try await withFixture { root, databaseURL in
            let sessions = root.appendingPathComponent("sessions", isDirectory: true)
            try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
            let file = sessions.appendingPathComponent("half.jsonl")
            let prefix = sessionMetaLine() + "\n" + turnContextLine() + "\n"
            let partial = prefix + tokenLine(input: 11, output: 4)
            try partial.write(to: file, atomically: true, encoding: .utf8)

            var snapshot = try await UsageActivityIndexer.shared.scanCodex(
                providerID: "codex-half",
                codexHome: root,
                databaseURL: databaseURL
            )
            expect(todayTokens(snapshot) == 0, "unterminated JSONL line was committed")
            expect(snapshot.catchUpPending, "unterminated JSONL was not marked partial")

            try appendRaw("\n", to: file)
            snapshot = try await UsageActivityIndexer.shared.scanCodex(
                providerID: "codex-half",
                codexHome: root,
                databaseURL: databaseURL
            )
            expect(todayTokens(snapshot) == 15, "completed JSONL tail was not indexed")
        }
    }

    private static func grokPromptUpsertDoesNotDuplicate() async throws {
        try await withFixture { root, databaseURL in
            let session = root.appendingPathComponent("workspace/session", isDirectory: true)
            try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
            let file = session.appendingPathComponent("updates.jsonl")
            try (grokLine(promptID: "prompt-1", input: 12, output: 3) + "\n")
                .write(to: file, atomically: true, encoding: .utf8)

            var snapshot = try await UsageActivityIndexer.shared.scanGrok(
                providerID: "grok-fixture",
                sessionsURL: root,
                databaseURL: databaseURL
            )
            expect(todayTokens(snapshot) == 15, "initial Grok fixture total is wrong")

            try appendLine(
                grokLine(promptID: "prompt-1", input: 20, output: 5),
                to: file
            )
            snapshot = try await UsageActivityIndexer.shared.scanGrok(
                providerID: "grok-fixture",
                sessionsURL: root,
                databaseURL: databaseURL
            )
            expect(todayTokens(snapshot) == 25, "Grok prompt UPSERT duplicated old usage")
            expect(
                snapshot.modelActivity.contains {
                    $0.period == .today
                        && $0.modelID == "grok-4"
                        && $0.usage.totalTokens == 25
                },
                "Grok model detail was not separated from account totals"
            )
        }
    }

    private static func corruptIndexIsQuarantinedAndRebuilt() async throws {
        try await withFixture { root, databaseURL in
            _ = try makeCodexFile(root: root, usageLines: [(9, 6)])
            try Data("not a sqlite database".utf8).write(to: databaseURL)

            let snapshot = try await UsageActivityIndexer.shared.scanCodex(
                providerID: "codex-corrupt",
                codexHome: root,
                databaseURL: databaseURL
            )
            expect(todayTokens(snapshot) == 15, "corrupt index was not rebuilt")

            let siblings = try FileManager.default.contentsOfDirectory(
                at: databaseURL.deletingLastPathComponent(),
                includingPropertiesForKeys: nil
            )
            expect(
                siblings.contains { $0.lastPathComponent.contains(".corrupt") },
                "corrupt index was not quarantined"
            )
        }
    }

    private static func grokModelDetailsDoNotInflateAccountTotals() async throws {
        try await withFixture { root, databaseURL in
            let session = root.appendingPathComponent("workspace/session", isDirectory: true)
            try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
            let file = session.appendingPathComponent("updates.jsonl")
            let line = json([
                "timestamp": Date().timeIntervalSince1970,
                "params": [
                    "update": [
                        "sessionUpdate": "turn_completed",
                        "prompt_id": "multi-model",
                        "usage": [
                            "inputTokens": 30,
                            "outputTokens": 10,
                            "modelUsage": [
                                "grok-a": ["inputTokens": 20, "outputTokens": 5],
                                "grok-b": ["inputTokens": 10, "outputTokens": 5]
                            ]
                        ]
                    ]
                ]
            ])
            try (line + "\n").write(to: file, atomically: true, encoding: .utf8)

            let snapshot = try await UsageActivityIndexer.shared.scanGrok(
                providerID: "grok-multi",
                sessionsURL: root,
                databaseURL: databaseURL
            )
            expect(todayTokens(snapshot) == 40, "Grok model detail inflated account totals")
            expect(
                snapshot.modelActivity.filter { $0.period == .today }.count == 2,
                "Grok model detail rows were not preserved"
            )
        }
    }

    private static func grokCurrentFormatPreservesModelEvidence() async throws {
        try await withFixture { root, databaseURL in
            let session = root.appendingPathComponent("workspace/session", isDirectory: true)
            try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
            let file = session.appendingPathComponent("events.jsonl")
            let line = json([
                "type": "turn_started",
                "ts": timestamp(),
                "session_id": "session-current",
                "turn_number": 0,
                "model_id": "grok-4.6"
            ])
            try (line + "\n").write(to: file, atomically: true, encoding: .utf8)

            let snapshot = try await UsageActivityIndexer.shared.scanGrok(
                providerID: "grok-current",
                sessionsURL: root,
                databaseURL: databaseURL
            )
            let model = snapshot.modelActivity.first {
                $0.period == .today && $0.modelID == "grok-4.6-build"
            }
            expect(model != nil, "current Grok model evidence was not indexed")
            expect(model?.turns == 0, "Grok model evidence invented a completed turn")
            expect(model?.usage.totalTokens == 0, "Grok model evidence invented token usage")
            expect(todayTokens(snapshot) == 0, "Grok model evidence inflated account tokens")
        }
    }

    private static func grokEvidenceDoesNotHideCompletedReferenceCost() async throws {
        try await withFixture { root, databaseURL in
            let session = root.appendingPathComponent("workspace/session", isDirectory: true)
            try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
            let started = json([
                "type": "turn_started",
                "ts": timestamp(),
                "session_id": "session-priced",
                "turn_number": 0,
                "model_id": "grok-4.6"
            ])
            try (started + "\n").write(
                to: session.appendingPathComponent("events.jsonl"),
                atomically: true,
                encoding: .utf8
            )
            let completed = json([
                "timestamp": Date().timeIntervalSince1970,
                "params": [
                    "update": [
                        "sessionUpdate": "turn_completed",
                        "prompt_id": "priced",
                        "usage": [
                            "inputTokens": 100_000,
                            "cachedReadTokens": 50_000,
                            "outputTokens": 10_000,
                            "modelUsage": [
                                "grok-4.6-build": [
                                    "inputTokens": 100_000,
                                    "cachedReadTokens": 50_000,
                                    "outputTokens": 10_000
                                ]
                            ]
                        ]
                    ]
                ]
            ])
            try (completed + "\n").write(
                to: session.appendingPathComponent("updates.jsonl"),
                atomically: true,
                encoding: .utf8
            )

            let snapshot = try await UsageActivityIndexer.shared.scanGrok(
                providerID: "grok-priced",
                sessionsURL: root,
                databaseURL: databaseURL
            )
            let model = snapshot.modelActivity.first {
                $0.period == .today && $0.modelID == "grok-4.6-build"
            }
            expect(model?.turns == 1, "Grok model evidence duplicated the completed turn")
            expect(model?.costUSD != nil, "Grok model evidence hid the reference price")
            expect(model?.costKind == .estimated, "Grok reference price was not marked estimated")
        }
    }

    private static func agyDatabaseCacheHitAndChangeRebuild() async throws {
        try await withFixture { root, databaseURL in
            let conversations = root
                .appendingPathComponent("antigravity/conversations", isDirectory: true)
            try FileManager.default.createDirectory(
                at: conversations,
                withIntermediateDirectories: true
            )
            let source = conversations.appendingPathComponent("fixture.db")
            var database: OpaquePointer?
            expect(sqlite3_open(source.path, &database) == SQLITE_OK, "AGY fixture open failed")
            defer { sqlite3_close_v2(database) }
            expect(
                sqlite3_exec(
                    database,
                    "CREATE TABLE steps(metadata BLOB, step_payload BLOB);"
                        + "INSERT INTO steps VALUES(zeroblob(0), zeroblob(350));"
                        + "INSERT INTO steps VALUES(zeroblob(0), zeroblob(700));",
                    nil,
                    nil,
                    nil
                ) == SQLITE_OK,
                "AGY fixture setup failed"
            )

            var snapshot = try await UsageActivityIndexer.shared.scanAGY(
                providerID: "agy-fixture",
                geminiDirectory: root,
                databaseURL: databaseURL
            )
            expect(todayTokens(snapshot) == 300, "AGY initial estimate is wrong")

            snapshot = try await UsageActivityIndexer.shared.scanAGY(
                providerID: "agy-fixture",
                geminiDirectory: root,
                databaseURL: databaseURL
            )
            expect(todayTokens(snapshot) == 300, "unchanged AGY database duplicated rows")

            expect(
                sqlite3_exec(
                    database,
                    "INSERT INTO steps VALUES(zeroblob(0), zeroblob(350));",
                    nil,
                    nil,
                    nil
                ) == SQLITE_OK,
                "AGY fixture append failed"
            )
            snapshot = try await UsageActivityIndexer.shared.scanAGY(
                providerID: "agy-fixture",
                geminiDirectory: root,
                databaseURL: databaseURL
            )
            expect(todayTokens(snapshot) == 400, "changed AGY database was not rebuilt")
        }
    }

    private static func agyWALHeaderWithoutSidecarsOpensImmutable() async throws {
        try await withFixture { root, databaseURL in
            let conversations = root
                .appendingPathComponent("antigravity/conversations", isDirectory: true)
            try FileManager.default.createDirectory(
                at: conversations,
                withIntermediateDirectories: true
            )
            let source = conversations.appendingPathComponent("wal.db")
            var database: OpaquePointer?
            expect(sqlite3_open(source.path, &database) == SQLITE_OK, "AGY WAL open failed")
            expect(
                sqlite3_exec(
                    database,
                    "PRAGMA journal_mode=WAL;"
                        + "CREATE TABLE steps(metadata BLOB, step_payload BLOB);"
                        + "INSERT INTO steps VALUES(zeroblob(0), zeroblob(350));"
                        + "PRAGMA wal_checkpoint(TRUNCATE);",
                    nil,
                    nil,
                    nil
                ) == SQLITE_OK,
                "AGY WAL fixture setup failed"
            )
            sqlite3_close_v2(database)
            for suffix in ["-wal", "-shm"] {
                try? FileManager.default.removeItem(
                    at: URL(fileURLWithPath: source.path + suffix)
                )
            }
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o555],
                ofItemAtPath: conversations.path
            )
            defer {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o755],
                    ofItemAtPath: conversations.path
                )
            }

            let snapshot = try await UsageActivityIndexer.shared.scanAGY(
                providerID: "agy-wal-fixture",
                geminiDirectory: root,
                databaseURL: databaseURL
            )
            expect(todayTokens(snapshot) == 100, "AGY immutable WAL fallback lost rows")
            expect(!snapshot.catchUpPending, "AGY immutable WAL fallback stayed partial")
        }
    }

    private static func claudeUsageIsIncremental() async throws {
        try await withFixture { root, databaseURL in
            let projects = root.appendingPathComponent("projects/fixture", isDirectory: true)
            try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
            let file = projects.appendingPathComponent("session.jsonl")
            try (claudeLine(id: "msg-1", fresh: 10, cached: 20, output: 5) + "\n")
                .write(to: file, atomically: true, encoding: .utf8)

            var snapshot = try await UsageActivityIndexer.shared.scanClaude(
                providerID: "claude-fixture",
                claudeHome: root,
                databaseURL: databaseURL
            )
            expect(todayTokens(snapshot) == 35, "Claude initial usage is wrong")

            try appendLine(
                claudeLine(id: "msg-2", fresh: 2, cached: 3, output: 4),
                to: file
            )
            snapshot = try await UsageActivityIndexer.shared.scanClaude(
                providerID: "claude-fixture",
                claudeHome: root,
                databaseURL: databaseURL
            )
            expect(todayTokens(snapshot) == 44, "Claude append was not incremental")
        }
    }

    private static func qwenUsageSummaryIsIncremental() async throws {
        try await withFixture { root, databaseURL in
            let file = root.appendingPathComponent("usage_record.jsonl")
            try (qwenLine(sessionID: "one", input: 12, output: 3, cached: 4) + "\n")
                .write(to: file, atomically: true, encoding: .utf8)

            var snapshot = try await UsageActivityIndexer.shared.scanQwen(
                providerID: "qwen-fixture",
                qwenHome: root,
                databaseURL: databaseURL
            )
            expect(todayTokens(snapshot) == 15, "Qwen initial usage is wrong")

            try appendLine(
                qwenLine(sessionID: "two", input: 8, output: 2, cached: 1),
                to: file
            )
            snapshot = try await UsageActivityIndexer.shared.scanQwen(
                providerID: "qwen-fixture",
                qwenHome: root,
                databaseURL: databaseURL
            )
            expect(todayTokens(snapshot) == 25, "Qwen append was not incremental")
        }
    }

    private static func codexServerDailyOverridesOverlappingLocalHistory() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let merged = CodexProvider.mergeDailyActivity(
            server: [DailyActivity(date: yesterday, tokens: 100, turns: 0)],
            local: [
                DailyActivity(date: yesterday, tokens: 999, turns: 7),
                DailyActivity(date: today, tokens: 50, turns: 2)
            ]
        )
        let byDay = Dictionary(uniqueKeysWithValues: merged.map {
            (calendar.startOfDay(for: $0.date), $0)
        })
        expect(byDay[yesterday]?.tokens == 100, "Codex server history was not authoritative")
        expect(byDay[yesterday]?.turns == 7, "Codex local turn detail was discarded")
        expect(byDay[today]?.tokens == 50, "Codex unreported local day was discarded")
    }

    private static func referencePriceCatalogMatchesPublishedRates() {
        let claude = UsageReferencePriceCatalog.estimateClaude(
            modelID: "claude-opus-5-20260801",
            usage: TokenBreakdown(
                inputTokens: 400_000,
                outputTokens: 10_000,
                cachedReadTokens: 200_000,
                cacheCreationTokens: 100_000
            ),
            oneHourCacheCreationTokens: 100_000
        )
        expect(abs((claude ?? 0) - 1.85) < 0.000_001, "Claude reference price is wrong")

        let grok = UsageReferencePriceCatalog.estimateGrok(
            modelID: "grok-4.6-build",
            usage: TokenBreakdown(
                inputTokens: 250_000,
                outputTokens: 10_000,
                cachedReadTokens: 200_000
            )
        )
        expect(abs((grok ?? 0) - 0.52) < 0.000_001, "Grok long-context price is wrong")
    }

    private static func withFixture(
        _ body: (URL, URL) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalTranslate-Provider-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try await body(root, directory.appendingPathComponent("usage.sqlite"))
    }

    private static func makeCodexFile(
        root: URL,
        usageLines: [(Int64, Int64)]
    ) throws -> URL {
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let file = sessions.appendingPathComponent("fixture.jsonl")
        try codexDocument(usageLines: usageLines).write(
            to: file,
            atomically: true,
            encoding: .utf8
        )
        return file
    }

    private static func codexDocument(
        usageLines: [(Int64, Int64)]
    ) -> String {
        ([sessionMetaLine(), turnContextLine()]
            + usageLines.map { tokenLine(input: $0.0, output: $0.1) })
            .joined(separator: "\n") + "\n"
    }

    private static func sessionMetaLine() -> String {
        json(["type": "session_meta", "timestamp": timestamp(), "payload": [:]])
    }

    private static func turnContextLine() -> String {
        json([
            "type": "turn_context",
            "timestamp": timestamp(),
            "payload": ["model": "gpt-5.6-luna"]
        ])
    }

    private static func tokenLine(input: Int64, output: Int64) -> String {
        json([
            "type": "event_msg",
            "timestamp": timestamp(),
            "payload": [
                "type": "token_count",
                "info": [
                    "last_token_usage": [
                        "input_tokens": input,
                        "cached_input_tokens": 0,
                        "cache_write_input_tokens": 0,
                        "output_tokens": output,
                        "reasoning_output_tokens": 0
                    ]
                ]
            ]
        ])
    }

    private static func grokLine(
        promptID: String,
        input: Int64,
        output: Int64
    ) -> String {
        json([
            "timestamp": Date().timeIntervalSince1970,
            "params": [
                "update": [
                    "sessionUpdate": "turn_completed",
                    "prompt_id": promptID,
                    "usage": [
                        "inputTokens": input,
                        "outputTokens": output,
                        "modelUsage": [
                            "grok-4": [
                                "inputTokens": input,
                                "outputTokens": output
                            ]
                        ]
                    ]
                ]
            ]
        ])
    }

    private static func claudeLine(
        id: String,
        fresh: Int64,
        cached: Int64,
        output: Int64
    ) -> String {
        json([
            "type": "assistant",
            "timestamp": timestamp(),
            "requestId": id,
            "message": [
                "id": id,
                "model": "claude-opus-5",
                "usage": [
                    "input_tokens": fresh,
                    "cache_read_input_tokens": cached,
                    "cache_creation_input_tokens": 0,
                    "output_tokens": output
                ]
            ]
        ])
    }

    private static func qwenLine(
        sessionID: String,
        input: Int64,
        output: Int64,
        cached: Int64
    ) -> String {
        json([
            "version": 1,
            "sessionId": sessionID,
            "timestamp": Int64(Date().timeIntervalSince1970 * 1_000),
            "models": [
                "qwen3.8-max": [
                    "requests": 1,
                    "inputTokens": input,
                    "outputTokens": output,
                    "cachedTokens": cached,
                    "thoughtsTokens": 0,
                    "totalTokens": input + output
                ]
            ]
        ])
    }

    private static func appendLine(_ line: String, to file: URL) throws {
        try appendRaw(line + "\n", to: file)
    }

    private static func appendRaw(_ text: String, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    private static func json(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    private static func todayTokens(_ snapshot: IndexedActivitySnapshot) -> Int64 {
        snapshot.periodActivity.first { $0.period == .today }?.tokens ?? 0
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        if !condition() { fatalError(message) }
    }
}
