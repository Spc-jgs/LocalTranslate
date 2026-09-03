import Foundation
import SQLite3

private nonisolated let usageSQLiteTransient = unsafeBitCast(
    -1,
    to: sqlite3_destructor_type.self
)

nonisolated enum UsageIndexError: LocalizedError, Sendable {
    case sqlite(code: Int32, message: String)
    case invalidRow(String)

    var errorDescription: String? {
        switch self {
        case .sqlite(let code, let message):
            return "AI 用量索引错误（SQLite \(code)）：\(message)"
        case .invalidRow(let message):
            return "AI 用量索引数据无效：\(message)"
        }
    }
}

nonisolated struct IndexedSourceFile: Sendable {
    let id: Int64
    let providerID: String
    let accountID: String
    let path: String
    let inode: UInt64?
    let modificationTimeMS: Int64
    let fileSize: Int64
    let parsedOffset: Int64
    let parserVersion: Int
    let cursorState: Data?
    let anchorOffset: Int64?
    let anchorSHA256: Data?
    let scanStatus: String
}

nonisolated struct IndexedUsageEvent: Sendable {
    let eventKey: String
    let occurredAt: Date
    let modelID: String
    let usage: TokenBreakdown
    let turns: Int
    let costUSD: Double?
    let costKind: UsageCostKind?
}

nonisolated struct IndexedFileCommit: Sendable {
    let providerID: String
    let accountID: String
    let path: String
    let inode: UInt64?
    let modificationTimeMS: Int64
    let fileSize: Int64
    let parsedOffset: Int64
    let parserVersion: Int
    let cursorState: Data?
    let anchorOffset: Int64?
    let anchorSHA256: Data?
    let scanStatus: String
    let replaceExistingEvents: Bool
    let events: [IndexedUsageEvent]
}

nonisolated struct IndexedActivitySnapshot: Sendable {
    let periodActivity: [PeriodActivity]
    let dailyActivity: [DailyActivity]
    let modelActivity: [ModelActivity]
    let indexedFiles: Int
    /// 已解析字节（AGY 是已读行号）的总和。这是分片补齐的推进标尺：
    /// 两轮之间它不变，就说明这一片什么也没读进来，续扫只会空转。
    let indexedProgress: Int64
    let catchUpPending: Bool
}

nonisolated final class UsageIndex {
    static let schemaVersion = 1

    static var defaultDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".localtranslate", isDirectory: true)
            .appendingPathComponent("ai-usage", isDirectory: true)
    }

    static var defaultDatabaseURL: URL {
        defaultDirectoryURL.appendingPathComponent("usage-index.sqlite")
    }

    static func quarantineCorruptDatabase(at databaseURL: URL) throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        let fileManager = FileManager.default

        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: databaseURL.path + suffix)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            let destination = URL(
                fileURLWithPath: databaseURL.path + ".\(stamp).corrupt" + suffix
            )
            try fileManager.moveItem(at: source, to: destination)
        }
    }

    private let databaseURL: URL
    private var database: OpaquePointer?

    init(databaseURL: URL = UsageIndex.defaultDatabaseURL) throws {
        self.databaseURL = databaseURL
        try Self.prepareDirectory(databaseURL.deletingLastPathComponent())
        try open()
        try configure()
        try createSchema()
    }

    deinit {
        if let database {
            sqlite3_close_v2(database)
        }
    }

    func sourceFile(
        providerID: String,
        accountID: String,
        path: String
    ) throws -> IndexedSourceFile? {
        let statement = try prepare(
            """
            SELECT id, provider_id, account_id, path, inode, mtime_ms,
                   file_size, parsed_offset, parser_version, cursor_state,
                   anchor_offset, anchor_sha256, scan_status
            FROM source_file
            WHERE provider_id = ? AND account_id = ? AND path = ?
            """
        )
        defer { sqlite3_finalize(statement) }

        try bind(providerID, to: 1, in: statement)
        try bind(accountID, to: 2, in: statement)
        try bind(path, to: 3, in: statement)

        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW else {
            if result == SQLITE_DONE { return nil }
            throw sqliteError(result)
        }

        return IndexedSourceFile(
            id: sqlite3_column_int64(statement, 0),
            providerID: columnText(statement, 1),
            accountID: columnText(statement, 2),
            path: columnText(statement, 3),
            inode: sqlite3_column_type(statement, 4) == SQLITE_NULL
                ? nil
                : UInt64(bitPattern: sqlite3_column_int64(statement, 4)),
            modificationTimeMS: sqlite3_column_int64(statement, 5),
            fileSize: sqlite3_column_int64(statement, 6),
            parsedOffset: sqlite3_column_int64(statement, 7),
            parserVersion: Int(sqlite3_column_int(statement, 8)),
            cursorState: columnData(statement, 9),
            anchorOffset: sqlite3_column_type(statement, 10) == SQLITE_NULL
                ? nil
                : sqlite3_column_int64(statement, 10),
            anchorSHA256: columnData(statement, 11),
            scanStatus: columnText(statement, 12)
        )
    }

    func commit(_ commit: IndexedFileCommit) throws {
        try execute("BEGIN IMMEDIATE")

        do {
            let sourceID = try upsertSourceFile(commit)

            if commit.replaceExistingEvents {
                let delete = try prepare(
                    "DELETE FROM usage_event WHERE source_file_id = ?"
                )
                defer { sqlite3_finalize(delete) }
                sqlite3_bind_int64(delete, 1, sourceID)
                try stepDone(delete)
            }

            if !commit.events.isEmpty {
                let insert = try prepare(
                    """
                    INSERT INTO usage_event (
                        source_file_id, event_key, occurred_at_ms, local_day,
                        model_id, input_tokens, output_tokens,
                        cached_read_tokens, cache_write_tokens, reasoning_tokens,
                        turn_count, cost_microusd, cost_kind
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(source_file_id, event_key) DO UPDATE SET
                        occurred_at_ms = excluded.occurred_at_ms,
                        local_day = excluded.local_day,
                        model_id = excluded.model_id,
                        input_tokens = excluded.input_tokens,
                        output_tokens = excluded.output_tokens,
                        cached_read_tokens = excluded.cached_read_tokens,
                        cache_write_tokens = excluded.cache_write_tokens,
                        reasoning_tokens = excluded.reasoning_tokens,
                        turn_count = excluded.turn_count,
                        cost_microusd = excluded.cost_microusd,
                        cost_kind = excluded.cost_kind
                    """
                )
                defer { sqlite3_finalize(insert) }

                for event in commit.events {
                    sqlite3_reset(insert)
                    sqlite3_clear_bindings(insert)
                    sqlite3_bind_int64(insert, 1, sourceID)
                    try bind(event.eventKey, to: 2, in: insert)
                    sqlite3_bind_int64(
                        insert,
                        3,
                        Int64(event.occurredAt.timeIntervalSince1970 * 1_000)
                    )
                    try bind(Self.localDay(for: event.occurredAt), to: 4, in: insert)
                    try bind(event.modelID, to: 5, in: insert)
                    sqlite3_bind_int64(insert, 6, event.usage.inputTokens)
                    sqlite3_bind_int64(insert, 7, event.usage.outputTokens)
                    sqlite3_bind_int64(insert, 8, event.usage.cachedReadTokens)
                    sqlite3_bind_int64(insert, 9, event.usage.cacheCreationTokens)
                    sqlite3_bind_int64(insert, 10, event.usage.reasoningTokens)
                    sqlite3_bind_int(insert, 11, Int32(event.turns))

                    if let cost = event.costUSD {
                        sqlite3_bind_int64(insert, 12, Int64((cost * 1_000_000).rounded()))
                    } else {
                        sqlite3_bind_null(insert, 12)
                    }

                    if let kind = event.costKind {
                        try bind(kind.rawValue, to: 13, in: insert)
                    } else {
                        sqlite3_bind_null(insert, 13)
                    }

                    try stepDone(insert)
                }
            }

            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func pruneMissingFiles(
        providerID: String,
        accountID: String,
        livePaths: Set<String>
    ) throws {
        let query = try prepare(
            "SELECT id, path FROM source_file WHERE provider_id = ? AND account_id = ?"
        )
        defer { sqlite3_finalize(query) }
        try bind(providerID, to: 1, in: query)
        try bind(accountID, to: 2, in: query)

        var staleIDs: [Int64] = []
        while sqlite3_step(query) == SQLITE_ROW {
            let path = columnText(query, 1)
            if !livePaths.contains(path) {
                staleIDs.append(sqlite3_column_int64(query, 0))
            }
        }

        guard !staleIDs.isEmpty else { return }
        try execute("BEGIN IMMEDIATE")
        do {
            let delete = try prepare("DELETE FROM source_file WHERE id = ?")
            defer { sqlite3_finalize(delete) }
            for id in staleIDs {
                sqlite3_reset(delete)
                sqlite3_bind_int64(delete, 1, id)
                try stepDone(delete)
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func setRefreshState(
        providerID: String,
        accountID: String,
        succeeded: Bool,
        catchUpPending: Bool,
        error: String? = nil
    ) throws {
        let statement = try prepare(
            """
            INSERT INTO refresh_state (
                provider_id, account_id, last_attempt_ms, last_success_ms,
                coverage_start_day, coverage_end_day, catch_up_pending, last_error
            ) VALUES (?, ?, ?, ?, NULL, ?, ?, ?)
            ON CONFLICT(provider_id, account_id) DO UPDATE SET
                last_attempt_ms = excluded.last_attempt_ms,
                last_success_ms = CASE
                    WHEN excluded.last_success_ms IS NULL THEN refresh_state.last_success_ms
                    ELSE excluded.last_success_ms
                END,
                coverage_end_day = excluded.coverage_end_day,
                catch_up_pending = excluded.catch_up_pending,
                last_error = excluded.last_error
            """
        )
        defer { sqlite3_finalize(statement) }

        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        try bind(providerID, to: 1, in: statement)
        try bind(accountID, to: 2, in: statement)
        sqlite3_bind_int64(statement, 3, now)
        if succeeded {
            sqlite3_bind_int64(statement, 4, now)
        } else {
            sqlite3_bind_null(statement, 4)
        }
        try bind(Self.localDay(for: Date()), to: 5, in: statement)
        sqlite3_bind_int(statement, 6, catchUpPending ? 1 : 0)
        if let error {
            try bind(String(error.prefix(300)), to: 7, in: statement)
        } else {
            sqlite3_bind_null(statement, 7)
        }
        try stepDone(statement)
    }

    func aggregate(
        providerID: String,
        accountID: String,
        modelDisplayName: (String) -> String,
        catchUpPending: Bool
    ) throws -> IndexedActivitySnapshot {
        let daily = try aggregateDaily(providerID: providerID, accountID: accountID)
        let periods = try aggregatePeriods(
            providerID: providerID,
            accountID: accountID
        )
        let models = try aggregateModels(
            providerID: providerID,
            accountID: accountID,
            displayName: modelDisplayName
        )

        let countStatement = try prepare(
            """
            SELECT COUNT(*), COALESCE(SUM(parsed_offset), 0)
            FROM source_file
            WHERE provider_id = ? AND account_id = ?
            """
        )
        defer { sqlite3_finalize(countStatement) }
        try bind(providerID, to: 1, in: countStatement)
        try bind(accountID, to: 2, in: countStatement)
        var count = 0
        var progress: Int64 = 0
        if sqlite3_step(countStatement) == SQLITE_ROW {
            count = Int(sqlite3_column_int(countStatement, 0))
            progress = sqlite3_column_int64(countStatement, 1)
        }

        return IndexedActivitySnapshot(
            periodActivity: periods,
            dailyActivity: daily,
            modelActivity: models,
            indexedFiles: count,
            indexedProgress: progress,
            catchUpPending: catchUpPending
        )
    }

    private func aggregateDaily(
        providerID: String,
        accountID: String
    ) throws -> [DailyActivity] {
        let statement = try prepare(
            """
            SELECT e.local_day,
                   SUM(e.input_tokens + e.output_tokens),
                   SUM(e.turn_count)
            FROM usage_event e
            JOIN source_file f ON f.id = e.source_file_id
            WHERE f.provider_id = ? AND f.account_id = ?
              AND e.model_id NOT LIKE '__detail__:%'
            GROUP BY e.local_day
            ORDER BY e.local_day
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(providerID, to: 1, in: statement)
        try bind(accountID, to: 2, in: statement)

        var result: [DailyActivity] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let date = Self.dayFormatter.date(from: columnText(statement, 0)) else {
                continue
            }
            result.append(
                DailyActivity(
                    date: Calendar.current.startOfDay(for: date),
                    tokens: sqlite3_column_int64(statement, 1),
                    turns: Int(sqlite3_column_int64(statement, 2))
                )
            )
        }
        return result
    }

    private func aggregatePeriods(
        providerID: String,
        accountID: String
    ) throws -> [PeriodActivity] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        return try ActivityPeriod.allCases.map { period in
            let startDate: Date?
            switch period {
            case .today:
                startDate = today
            case .sevenDays:
                startDate = calendar.date(byAdding: .day, value: -6, to: today)
            case .thirtyDays:
                startDate = calendar.date(byAdding: .day, value: -29, to: today)
            case .ninetyDays:
                startDate = calendar.date(byAdding: .day, value: -89, to: today)
            case .lifetime:
                startDate = nil
            }

            var sql =
                """
                SELECT SUM(e.input_tokens + e.output_tokens),
                       SUM(e.turn_count),
                       SUM(e.cost_microusd),
                       SUM(CASE WHEN e.cost_microusd IS NULL THEN 1 ELSE 0 END)
                FROM usage_event e
                JOIN source_file f ON f.id = e.source_file_id
                WHERE f.provider_id = ? AND f.account_id = ?
                  AND e.model_id NOT LIKE '__detail__:%'
                """
            if startDate != nil {
                sql += " AND e.local_day >= ?"
            }

            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            try bind(providerID, to: 1, in: statement)
            try bind(accountID, to: 2, in: statement)
            if let startDate {
                try bind(Self.localDay(for: startDate), to: 3, in: statement)
            }

            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw sqliteError(sqlite3_errcode(database))
            }

            let tokens = sqlite3_column_int64(statement, 0)
            let turns = Int(sqlite3_column_int64(statement, 1))
            let missingCosts = sqlite3_column_int64(statement, 3)
            let cost: Double?
            if turns > 0, missingCosts == 0,
               sqlite3_column_type(statement, 2) != SQLITE_NULL {
                cost = Double(sqlite3_column_int64(statement, 2)) / 1_000_000
            } else {
                cost = nil
            }

            return PeriodActivity(
                period: period,
                tokens: tokens,
                turns: turns,
                costUSD: cost
            )
        }
    }

    private func aggregateModels(
        providerID: String,
        accountID: String,
        displayName: (String) -> String
    ) throws -> [ModelActivity] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let start7 = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        let start30 = calendar.date(byAdding: .day, value: -29, to: today) ?? today
        let start90 = calendar.date(byAdding: .day, value: -89, to: today) ?? today
        var result: [ModelActivity] = []

        for (period, start) in [
            (ActivityPeriod.today, today),
            (ActivityPeriod.sevenDays, start7),
            (ActivityPeriod.thirtyDays, start30),
            (ActivityPeriod.ninetyDays, start90)
        ] {
            let statement = try prepare(
                """
                SELECT CASE
                           WHEN e.model_id LIKE '__detail__:%'
                           THEN substr(e.model_id, 12)
                           ELSE e.model_id
                       END AS display_model_id,
                       SUM(e.input_tokens), SUM(e.output_tokens),
                       SUM(e.cached_read_tokens), SUM(e.cache_write_tokens),
                       SUM(e.reasoning_tokens), SUM(e.turn_count),
                       SUM(e.cost_microusd),
                       SUM(CASE
                               WHEN e.cost_microusd IS NULL
                                AND (e.input_tokens + e.output_tokens) > 0
                               THEN 1 ELSE 0
                           END),
                       MIN(e.cost_kind), MAX(e.cost_kind)
                FROM usage_event e
                JOIN source_file f ON f.id = e.source_file_id
                WHERE f.provider_id = ? AND f.account_id = ? AND e.local_day >= ?
                  AND e.model_id NOT LIKE '__total__:%'
                GROUP BY display_model_id
                ORDER BY SUM(e.input_tokens + e.output_tokens) DESC
                """
            )
            defer { sqlite3_finalize(statement) }
            try bind(providerID, to: 1, in: statement)
            try bind(accountID, to: 2, in: statement)
            try bind(Self.localDay(for: start), to: 3, in: statement)

            while sqlite3_step(statement) == SQLITE_ROW {
                let modelID = columnText(statement, 0)
                let turns = Int(sqlite3_column_int64(statement, 6))
                let missingCosts = sqlite3_column_int64(statement, 8)
                let cost: Double?
                if turns > 0, missingCosts == 0,
                   sqlite3_column_type(statement, 7) != SQLITE_NULL {
                    cost = Double(sqlite3_column_int64(statement, 7)) / 1_000_000
                } else {
                    cost = nil
                }

                let minimumKind = columnText(statement, 9)
                let maximumKind = columnText(statement, 10)
                let kind: UsageCostKind?
                if cost != nil, minimumKind == maximumKind {
                    kind = UsageCostKind(rawValue: minimumKind)
                } else if cost != nil {
                    kind = .estimated
                } else {
                    kind = nil
                }

                result.append(
                    ModelActivity(
                        modelID: modelID,
                        displayName: displayName(modelID),
                        period: period,
                        usage: TokenBreakdown(
                            inputTokens: sqlite3_column_int64(statement, 1),
                            outputTokens: sqlite3_column_int64(statement, 2),
                            cachedReadTokens: sqlite3_column_int64(statement, 3),
                            cacheCreationTokens: sqlite3_column_int64(statement, 4),
                            reasoningTokens: sqlite3_column_int64(statement, 5)
                        ),
                        turns: turns,
                        costUSD: cost,
                        costKind: kind
                    )
                )
            }
        }

        return result
    }

    private func upsertSourceFile(_ commit: IndexedFileCommit) throws -> Int64 {
        let statement = try prepare(
            """
            INSERT INTO source_file (
                provider_id, account_id, path, inode, mtime_ms, file_size,
                parsed_offset, parser_version, cursor_state, anchor_offset,
                anchor_sha256, scan_status, updated_at_ms
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(provider_id, account_id, path) DO UPDATE SET
                inode = excluded.inode,
                mtime_ms = excluded.mtime_ms,
                file_size = excluded.file_size,
                parsed_offset = excluded.parsed_offset,
                parser_version = excluded.parser_version,
                cursor_state = excluded.cursor_state,
                anchor_offset = excluded.anchor_offset,
                anchor_sha256 = excluded.anchor_sha256,
                scan_status = excluded.scan_status,
                updated_at_ms = excluded.updated_at_ms
            RETURNING id
            """
        )
        defer { sqlite3_finalize(statement) }

        try bind(commit.providerID, to: 1, in: statement)
        try bind(commit.accountID, to: 2, in: statement)
        try bind(commit.path, to: 3, in: statement)
        if let inode = commit.inode {
            sqlite3_bind_int64(statement, 4, Int64(bitPattern: inode))
        } else {
            sqlite3_bind_null(statement, 4)
        }
        sqlite3_bind_int64(statement, 5, commit.modificationTimeMS)
        sqlite3_bind_int64(statement, 6, commit.fileSize)
        sqlite3_bind_int64(statement, 7, commit.parsedOffset)
        sqlite3_bind_int(statement, 8, Int32(commit.parserVersion))
        try bind(commit.cursorState, to: 9, in: statement)
        if let anchorOffset = commit.anchorOffset {
            sqlite3_bind_int64(statement, 10, anchorOffset)
        } else {
            sqlite3_bind_null(statement, 10)
        }
        try bind(commit.anchorSHA256, to: 11, in: statement)
        try bind(commit.scanStatus, to: 12, in: statement)
        sqlite3_bind_int64(
            statement,
            13,
            Int64(Date().timeIntervalSince1970 * 1_000)
        )

        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw sqliteError(sqlite3_errcode(database))
        }
        return sqlite3_column_int64(statement, 0)
    }

    private func open() throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(databaseURL.path, &handle, flags, nil)
        guard result == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) }
                ?? "无法打开数据库"
            if let handle { sqlite3_close_v2(handle) }
            throw UsageIndexError.sqlite(code: result, message: message)
        }
        database = handle
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: databaseURL.path
        )
    }

    private func configure() throws {
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA synchronous = NORMAL")
        try execute("PRAGMA foreign_keys = ON")
        try execute("PRAGMA busy_timeout = 1000")
        try execute("PRAGMA cache_size = -4096")
        try execute("PRAGMA mmap_size = 0")
    }

    private func createSchema() throws {
        try execute(
            """
            CREATE TABLE IF NOT EXISTS schema_metadata (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            ) WITHOUT ROWID;

            CREATE TABLE IF NOT EXISTS source_file (
                id INTEGER PRIMARY KEY,
                provider_id TEXT NOT NULL,
                account_id TEXT NOT NULL,
                path TEXT NOT NULL,
                inode INTEGER,
                mtime_ms INTEGER NOT NULL,
                file_size INTEGER NOT NULL,
                parsed_offset INTEGER NOT NULL DEFAULT 0,
                parser_version INTEGER NOT NULL,
                cursor_state BLOB,
                anchor_offset INTEGER,
                anchor_sha256 BLOB,
                scan_status TEXT NOT NULL,
                updated_at_ms INTEGER NOT NULL,
                UNIQUE(provider_id, account_id, path)
            );

            CREATE TABLE IF NOT EXISTS usage_event (
                source_file_id INTEGER NOT NULL
                    REFERENCES source_file(id) ON DELETE CASCADE,
                event_key TEXT NOT NULL,
                occurred_at_ms INTEGER NOT NULL,
                local_day TEXT NOT NULL,
                model_id TEXT NOT NULL,
                input_tokens INTEGER NOT NULL,
                output_tokens INTEGER NOT NULL,
                cached_read_tokens INTEGER NOT NULL,
                cache_write_tokens INTEGER NOT NULL,
                reasoning_tokens INTEGER NOT NULL,
                turn_count INTEGER NOT NULL,
                cost_microusd INTEGER,
                cost_kind TEXT,
                PRIMARY KEY(source_file_id, event_key)
            ) WITHOUT ROWID;

            CREATE INDEX IF NOT EXISTS usage_event_day_model_idx
                ON usage_event(local_day, model_id);
            CREATE INDEX IF NOT EXISTS usage_event_time_idx
                ON usage_event(occurred_at_ms);

            CREATE TABLE IF NOT EXISTS refresh_state (
                provider_id TEXT NOT NULL,
                account_id TEXT NOT NULL,
                last_attempt_ms INTEGER,
                last_success_ms INTEGER,
                coverage_start_day TEXT,
                coverage_end_day TEXT,
                catch_up_pending INTEGER NOT NULL DEFAULT 0,
                last_error TEXT,
                PRIMARY KEY(provider_id, account_id)
            ) WITHOUT ROWID;
            """
        )

        let statement = try prepare(
            "INSERT OR REPLACE INTO schema_metadata(key, value) VALUES('schema_version', ?)"
        )
        defer { sqlite3_finalize(statement) }
        try bind(String(Self.schemaVersion), to: 1, in: statement)
        try stepDone(statement)

        try ensureTimeZoneMetadata()
        try setMetadata(key: "pricing_version", value: "codex-api-2026-08")
    }

    private func ensureTimeZoneMetadata() throws {
        let current = TimeZone.current.identifier
        let query = try prepare(
            "SELECT value FROM schema_metadata WHERE key = 'time_zone_identifier'"
        )
        let result = sqlite3_step(query)
        let previous = result == SQLITE_ROW ? columnText(query, 0) : nil
        sqlite3_finalize(query)

        if let previous, previous != current {
            try execute("BEGIN IMMEDIATE")
            do {
                try execute("DELETE FROM source_file")
                try execute("DELETE FROM refresh_state")
                try setMetadata(key: "time_zone_identifier", value: current)
                try execute("COMMIT")
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        } else if previous == nil {
            try setMetadata(key: "time_zone_identifier", value: current)
        }
    }

    private func setMetadata(key: String, value: String) throws {
        let statement = try prepare(
            "INSERT OR REPLACE INTO schema_metadata(key, value) VALUES(?, ?)"
        )
        defer { sqlite3_finalize(statement) }
        try bind(key, to: 1, in: statement)
        try bind(value, to: 2, in: statement)
        try stepDone(statement)
    }

    private func execute(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) }
                ?? database.map { String(cString: sqlite3_errmsg($0)) }
                ?? "unknown SQLite error"
            sqlite3_free(errorMessage)
            throw UsageIndexError.sqlite(code: result, message: message)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            throw sqliteError(result)
        }
        return statement
    }

    private func stepDone(_ statement: OpaquePointer?) throws {
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else {
            throw sqliteError(result)
        }
    }

    private func bind(
        _ value: String,
        to index: Int32,
        in statement: OpaquePointer?
    ) throws {
        let result = value.withCString {
            sqlite3_bind_text(statement, index, $0, -1, usageSQLiteTransient)
        }
        guard result == SQLITE_OK else { throw sqliteError(result) }
    }

    private func bind(
        _ value: Data?,
        to index: Int32,
        in statement: OpaquePointer?
    ) throws {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }

        let result = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(
                statement,
                index,
                bytes.baseAddress,
                Int32(bytes.count),
                usageSQLiteTransient
            )
        }
        guard result == SQLITE_OK else { throw sqliteError(result) }
    }

    private func columnText(_ statement: OpaquePointer?, _ index: Int32) -> String {
        guard let text = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: text)
    }

    private func columnData(_ statement: OpaquePointer?, _ index: Int32) -> Data? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let bytes = sqlite3_column_blob(statement, index) else {
            return nil
        }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index)))
    }

    private func sqliteError(_ code: Int32) -> UsageIndexError {
        let message = database.map { String(cString: sqlite3_errmsg($0)) }
            ?? "unknown SQLite error"
        return .sqlite(code: code, message: message)
    }

    private static func prepareDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )

        let applicationRoot = directory.deletingLastPathComponent()
        if applicationRoot.lastPathComponent == ".localtranslate" {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: applicationRoot.path
            )
        }

        var mutableDirectory = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutableDirectory.setResourceValues(values)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static func localDay(for date: Date) -> String {
        dayFormatter.string(from: date)
    }
}
