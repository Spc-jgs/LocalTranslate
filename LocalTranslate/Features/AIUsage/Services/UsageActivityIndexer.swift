import CryptoKit
import Foundation
import SQLite3

nonisolated final class UsageActivityIndexer: @unchecked Sendable {
    static let shared = UsageActivityIndexer()

    private init() {}

    func scanCodex(
        providerID: String,
        codexHome: URL,
        databaseURL: URL = UsageIndex.defaultDatabaseURL
    ) async throws -> IndexedActivitySnapshot {
        try await UsageScanExecutor.shared.submit(
            budget: .standard()
        ) { cancellation, budget in
            try withRecoveringUsageIndex(databaseURL: databaseURL) { index in
                try CodexIncrementalIndexer(
                    providerID: providerID,
                    accountID: providerID,
                    codexHome: codexHome
                ).scan(index: index, cancellation: cancellation, budget: budget)
            }
        }
    }

    func scanGrok(
        providerID: String,
        sessionsURL: URL? = nil,
        databaseURL: URL = UsageIndex.defaultDatabaseURL
    ) async throws -> IndexedActivitySnapshot {
        let snapshot = try await UsageScanExecutor.shared.submit(
            budget: .standard()
        ) { cancellation, budget in
            try withRecoveringUsageIndex(databaseURL: databaseURL) { index in
                try GrokIncrementalIndexer(
                    providerID: providerID,
                    accountID: providerID,
                    sessionsURL: sessionsURL
                ).scan(index: index, cancellation: cancellation, budget: budget)
            }
        }

        if sessionsURL == nil,
           databaseURL.standardizedFileURL == UsageIndex.defaultDatabaseURL.standardizedFileURL,
           snapshot.indexedFiles > 0 {
            removeLegacyGrokCache()
        }
        return snapshot
    }

    func scanAGY(
        providerID: String,
        geminiDirectory: URL? = nil,
        databaseURL: URL = UsageIndex.defaultDatabaseURL
    ) async throws -> IndexedActivitySnapshot {
        try await UsageScanExecutor.shared.submit(
            budget: .standard(
                maximumBytes: 128 * 1024 * 1024,
                seconds: 5
            )
        ) { cancellation, budget in
            try withRecoveringUsageIndex(databaseURL: databaseURL) { index in
                try AGYIncrementalIndexer(
                    providerID: providerID,
                    accountID: providerID,
                    geminiDirectory: geminiDirectory
                ).scan(index: index, cancellation: cancellation, budget: budget)
            }
        }
    }

    private func removeLegacyGrokCache() {
        let fileManager = FileManager.default
        let cacheRoot = fileManager.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first
        let legacyURL = cacheRoot?
            .appendingPathComponent("LocalTranslate", isDirectory: true)
            .appendingPathComponent("grok_sessions_cache.json")
        if let legacyURL, fileManager.fileExists(atPath: legacyURL.path) {
            try? fileManager.removeItem(at: legacyURL)
        }
    }
}

private nonisolated func withRecoveringUsageIndex<T>(
    databaseURL: URL,
    operation: (UsageIndex) throws -> T
) throws -> T {
    func attempt() throws -> T {
        try operation(UsageIndex(databaseURL: databaseURL))
    }

    do {
        return try attempt()
    } catch UsageIndexError.sqlite(let code, _)
        where code == SQLITE_CORRUPT || code == SQLITE_NOTADB {
        try UsageIndex.quarantineCorruptDatabase(at: databaseURL)
        return try attempt()
    }
}

private nonisolated struct UsageFileMetadata {
    let path: String
    let inode: UInt64?
    let modificationTimeMS: Int64
    let fileSize: Int64
    let modificationDate: Date

    init?(url: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: url.path
        ), let size = (attributes[.size] as? NSNumber)?.int64Value,
        let date = attributes[.modificationDate] as? Date else {
            return nil
        }

        path = url.path
        inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        modificationDate = date
        modificationTimeMS = Int64(date.timeIntervalSince1970 * 1_000)
        fileSize = max(0, size)
    }
}

private nonisolated struct JSONLScanResult {
    let safeOffset: Int64
    let reachedEOF: Bool
}

private nonisolated func scanJSONLLines(
    file: URL,
    startOffset: Int64,
    meter: inout UsageScanMeter,
    consume: (Data, Int64) throws -> Void
) throws -> JSONLScanResult {
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    try handle.seek(toOffset: UInt64(max(0, startOffset)))

    var buffer = Data()
    var bufferStartOffset = startOffset
    var reachedEOF = false

    while !meter.isExhausted {
        try meter.check()
        let readCount = Int(min(Int64(64 * 1024), meter.remainingBytes))
        guard readCount > 0 else { break }

        let chunk = try handle.read(upToCount: readCount) ?? Data()
        if chunk.isEmpty {
            reachedEOF = true
            break
        }

        buffer.append(chunk)
        try meter.record(bytes: chunk.count)

        while let newline = buffer.firstIndex(of: 0x0A) {
            try meter.check()
            let lineEndOffset = bufferStartOffset + Int64(newline) + 1
            if newline > buffer.startIndex {
                try consume(Data(buffer[..<newline]), lineEndOffset)
            }
            buffer.removeSubrange(...newline)
            bufferStartOffset = lineEndOffset
        }
    }

    return JSONLScanResult(
        safeOffset: bufferStartOffset,
        reachedEOF: reachedEOF && buffer.isEmpty
    )
}

private nonisolated func anchor(
    for file: URL,
    parsedOffset: Int64
) -> (offset: Int64, digest: Data)? {
    guard parsedOffset > 0,
          let handle = try? FileHandle(forReadingFrom: file) else {
        return nil
    }
    defer { try? handle.close() }

    let start = max(0, parsedOffset - 4_096)
    do {
        try handle.seek(toOffset: UInt64(start))
        let bytes = try handle.read(upToCount: Int(parsedOffset - start)) ?? Data()
        guard bytes.count == Int(parsedOffset - start) else { return nil }
        return (start, Data(SHA256.hash(data: bytes)))
    } catch {
        return nil
    }
}

private nonisolated func anchorMatches(
    _ state: IndexedSourceFile,
    file: URL
) -> Bool {
    guard state.parsedOffset > 0,
          let expectedOffset = state.anchorOffset,
          let expectedDigest = state.anchorSHA256,
          let handle = try? FileHandle(forReadingFrom: file) else {
        return state.parsedOffset == 0
    }
    defer { try? handle.close() }

    do {
        try handle.seek(toOffset: UInt64(expectedOffset))
        let count = Int(state.parsedOffset - expectedOffset)
        let data = try handle.read(upToCount: count) ?? Data()
        return data.count == count && Data(SHA256.hash(data: data)) == expectedDigest
    } catch {
        return false
    }
}

private nonisolated func unchanged(
    state: IndexedSourceFile?,
    metadata: UsageFileMetadata,
    parserVersion: Int
) -> Bool {
    guard let state else { return false }
    return state.parserVersion == parserVersion
        && state.inode == metadata.inode
        && state.fileSize == metadata.fileSize
        && state.modificationTimeMS == metadata.modificationTimeMS
        && state.scanStatus == "complete"
}

private nonisolated func canResumeJSONL(
    state: IndexedSourceFile?,
    metadata: UsageFileMetadata,
    parserVersion: Int,
    file: URL
) -> Bool {
    guard let state else { return false }
    return state.parserVersion == parserVersion
        && state.inode == metadata.inode
        && metadata.fileSize >= state.parsedOffset
        && state.scanStatus != "retryable_failure"
        && anchorMatches(state, file: file)
}

private nonisolated struct CodexCursor: Codable {
    var model = ""
    var lastUsageSignature: String?
    var sawSessionMeta = false
    var suppressingForkCopies = false
    var forkCopyAnchor: Date?
}

private nonisolated struct CodexIncrementalIndexer {
    static let parserVersion = 1
    static let interestingPatterns = [
        Data("\"session_meta\"".utf8),
        Data("\"turn_context\"".utf8),
        Data("\"token_count\"".utf8)
    ]

    let providerID: String
    let accountID: String
    let codexHome: URL

    func scan(
        index: UsageIndex,
        cancellation: UsageScanCancellation,
        budget: UsageScanBudget
    ) throws -> IndexedActivitySnapshot {
        var meter = UsageScanMeter(budget: budget, cancellation: cancellation)
        let files = candidateFiles()
        let livePaths = Set(files.map { $0.metadata.path })
        var catchUpPending = false

        for candidate in files {
            try meter.check()
            let file = candidate.url
            let metadata = candidate.metadata
            let old = try index.sourceFile(
                providerID: providerID,
                accountID: accountID,
                path: metadata.path
            )

            if unchanged(
                state: old,
                metadata: metadata,
                parserVersion: Self.parserVersion
            ) {
                continue
            }

            if meter.isExhausted {
                catchUpPending = true
                break
            }

            let resumes = canResumeJSONL(
                state: old,
                metadata: metadata,
                parserVersion: Self.parserVersion,
                file: file
            )
            let startOffset = resumes ? old?.parsedOffset ?? 0 : 0
            var cursor = resumes
                ? decodeCursor(old?.cursorState) ?? CodexCursor()
                : CodexCursor()
            var events: [IndexedUsageEvent] = []

            let result = try scanJSONLLines(
                file: file,
                startOffset: startOffset,
                meter: &meter
            ) { line, lineEndOffset in
                guard Self.interestingPatterns.contains(where: {
                    line.range(of: $0) != nil
                }) else {
                    return
                }
                if let event = parse(line: line, endOffset: lineEndOffset, cursor: &cursor) {
                    events.append(event)
                }
            }

            let digest = anchor(for: file, parsedOffset: result.safeOffset)
            let postScanMetadata = UsageFileMetadata(url: file)
            let sourceChanged = postScanMetadata.map {
                $0.inode != metadata.inode
                    || $0.fileSize != metadata.fileSize
                    || $0.modificationTimeMS != metadata.modificationTimeMS
            } ?? true
            let status = sourceChanged
                ? "retryable_failure"
                : (result.reachedEOF ? "complete" : "partial")
            catchUpPending = catchUpPending || status == "partial"
                || status == "retryable_failure"

            try index.commit(
                IndexedFileCommit(
                    providerID: providerID,
                    accountID: accountID,
                    path: metadata.path,
                    inode: metadata.inode,
                    modificationTimeMS: metadata.modificationTimeMS,
                    fileSize: metadata.fileSize,
                    parsedOffset: result.safeOffset,
                    parserVersion: Self.parserVersion,
                    cursorState: try? JSONEncoder().encode(cursor),
                    anchorOffset: digest?.offset,
                    anchorSHA256: digest?.digest,
                    scanStatus: status,
                    replaceExistingEvents: !resumes,
                    events: events
                )
            )

            if meter.isExhausted {
                catchUpPending = true
                break
            }
        }

        if !catchUpPending {
            try index.pruneMissingFiles(
                providerID: providerID,
                accountID: accountID,
                livePaths: livePaths
            )
        }
        try index.setRefreshState(
            providerID: providerID,
            accountID: accountID,
            succeeded: true,
            catchUpPending: catchUpPending
        )

        return try index.aggregate(
            providerID: providerID,
            accountID: accountID,
            modelDisplayName: CodexProvider.displayCodexModelName,
            catchUpPending: catchUpPending
        )
    }

    private func candidateFiles() -> [(url: URL, metadata: UsageFileMetadata)] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let start90 = calendar.date(byAdding: .day, value: -89, to: today) ?? today
        let roots = [
            codexHome.appendingPathComponent("sessions", isDirectory: true),
            codexHome.appendingPathComponent("archived_sessions", isDirectory: true)
        ]
        var result: [(URL, UsageFileMetadata)] = []

        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let file as URL in enumerator where file.pathExtension == "jsonl" {
                guard let metadata = UsageFileMetadata(url: file),
                      metadata.modificationDate >= start90 else { continue }
                result.append((file, metadata))
            }
        }

        return result.sorted {
            if $0.1.modificationDate == $1.1.modificationDate {
                return $0.1.path < $1.1.path
            }
            return $0.1.modificationDate > $1.1.modificationDate
        }
    }

    private func parse(
        line: Data,
        endOffset: Int64,
        cursor: inout CodexCursor
    ) -> IndexedUsageEvent? {
        guard let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let payload = record["payload"] as? [String: Any] else {
            return nil
        }

        if record["type"] as? String == "session_meta" {
            guard !cursor.sawSessionMeta else { return nil }
            cursor.sawSessionMeta = true
            if isForkedSession(payload),
               let timestamp = parseDate(record["timestamp"]) {
                cursor.suppressingForkCopies = true
                cursor.forkCopyAnchor = timestamp
            }
            return nil
        }

        if record["type"] as? String == "turn_context" {
            if let model = payload["model"] as? String, !model.isEmpty {
                cursor.model = model
            }
            return nil
        }

        guard payload["type"] as? String == "token_count",
              !cursor.model.isEmpty,
              let timestamp = parseDate(record["timestamp"]),
              let info = payload["info"] as? [String: Any],
              let last = info["last_token_usage"] as? [String: Any] else {
            return nil
        }

        let input = positiveInt64(last["input_tokens"])
        let cached = positiveInt64(last["cached_input_tokens"])
        let cacheWrite = positiveInt64(last["cache_write_input_tokens"])
        let output = positiveInt64(last["output_tokens"])
        let reasoning = min(output, positiveInt64(last["reasoning_output_tokens"]))
        let signature = "\(input):\(cached):\(cacheWrite):\(output):\(reasoning)"
        guard signature != cursor.lastUsageSignature else { return nil }
        cursor.lastUsageSignature = signature

        if cursor.suppressingForkCopies, let anchor = cursor.forkCopyAnchor {
            if timestamp.timeIntervalSince(anchor) < 1 {
                cursor.forkCopyAnchor = timestamp
                return nil
            }
            cursor.suppressingForkCopies = false
        }

        let usage = TokenBreakdown(
            inputTokens: input,
            outputTokens: output,
            cachedReadTokens: min(cached, input),
            cacheCreationTokens: min(cacheWrite, input),
            reasoningTokens: reasoning
        )
        guard usage.totalTokens > 0 else { return nil }

        let cost = CodexAPIPriceCatalog.estimate(modelID: cursor.model, usage: usage)
        return IndexedUsageEvent(
            eventKey: String(endOffset),
            occurredAt: timestamp,
            modelID: cursor.model,
            usage: usage,
            turns: 1,
            costUSD: cost,
            costKind: cost == nil ? nil : .estimated
        )
    }

    private func decodeCursor(_ data: Data?) -> CodexCursor? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(CodexCursor.self, from: data)
    }

    private func parseDate(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }

    private func isForkedSession(_ payload: [String: Any]) -> Bool {
        if payload["forked_from_id"] is String { return true }
        guard let source = payload["source"] as? [String: Any],
              let subagent = source["subagent"] as? [String: Any],
              let spawn = subagent["thread_spawn"] as? [String: Any] else {
            return false
        }
        return spawn["parent_thread_id"] is String
    }

    private func positiveInt64(_ value: Any?) -> Int64 {
        if let number = value as? NSNumber { return max(0, number.int64Value) }
        if let string = value as? String, let number = Int64(string) {
            return max(0, number)
        }
        return 0
    }
}

private nonisolated struct GrokIncrementalIndexer {
    static let parserVersion = 2
    static let target = Data("turn_completed".utf8)

    let providerID: String
    let accountID: String
    let sessionsURL: URL?

    func scan(
        index: UsageIndex,
        cancellation: UsageScanCancellation,
        budget: UsageScanBudget
    ) throws -> IndexedActivitySnapshot {
        var meter = UsageScanMeter(budget: budget, cancellation: cancellation)
        let files = candidateFiles()
        let livePaths = Set(files.map { $0.metadata.path })
        var catchUpPending = false

        for candidate in files {
            try meter.check()
            let old = try index.sourceFile(
                providerID: providerID,
                accountID: accountID,
                path: candidate.metadata.path
            )
            if unchanged(
                state: old,
                metadata: candidate.metadata,
                parserVersion: Self.parserVersion
            ) { continue }

            if meter.isExhausted {
                catchUpPending = true
                break
            }

            let resumes = canResumeJSONL(
                state: old,
                metadata: candidate.metadata,
                parserVersion: Self.parserVersion,
                file: candidate.url
            )
            let startOffset = resumes ? old?.parsedOffset ?? 0 : 0
            var events: [IndexedUsageEvent] = []
            let result = try scanJSONLLines(
                file: candidate.url,
                startOffset: startOffset,
                meter: &meter
            ) { line, endOffset in
                guard line.range(of: Self.target) != nil else { return }
                events.append(contentsOf: parse(line: line, endOffset: endOffset))
            }

            let digest = anchor(for: candidate.url, parsedOffset: result.safeOffset)
            let postScanMetadata = UsageFileMetadata(url: candidate.url)
            let sourceChanged = postScanMetadata.map {
                $0.inode != candidate.metadata.inode
                    || $0.fileSize != candidate.metadata.fileSize
                    || $0.modificationTimeMS != candidate.metadata.modificationTimeMS
            } ?? true
            let status = sourceChanged
                ? "retryable_failure"
                : (result.reachedEOF ? "complete" : "partial")
            catchUpPending = catchUpPending || status == "partial"
                || status == "retryable_failure"
            try index.commit(
                IndexedFileCommit(
                    providerID: providerID,
                    accountID: accountID,
                    path: candidate.metadata.path,
                    inode: candidate.metadata.inode,
                    modificationTimeMS: candidate.metadata.modificationTimeMS,
                    fileSize: candidate.metadata.fileSize,
                    parsedOffset: result.safeOffset,
                    parserVersion: Self.parserVersion,
                    cursorState: nil,
                    anchorOffset: digest?.offset,
                    anchorSHA256: digest?.digest,
                    scanStatus: status,
                    replaceExistingEvents: !resumes,
                    events: events
                )
            )

            if meter.isExhausted {
                catchUpPending = true
                break
            }
        }

        if !catchUpPending {
            try index.pruneMissingFiles(
                providerID: providerID,
                accountID: accountID,
                livePaths: livePaths
            )
        }
        try index.setRefreshState(
            providerID: providerID,
            accountID: accountID,
            succeeded: true,
            catchUpPending: catchUpPending
        )
        return try index.aggregate(
            providerID: providerID,
            accountID: accountID,
            modelDisplayName: displayModelName,
            catchUpPending: catchUpPending
        )
    }

    private func candidateFiles() -> [(url: URL, metadata: UsageFileMetadata)] {
        let root = sessionsURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grok", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var result: [(URL, UsageFileMetadata)] = []
        for case let file as URL in enumerator where file.lastPathComponent == "updates.jsonl" {
            if let metadata = UsageFileMetadata(url: file) {
                result.append((file, metadata))
            }
        }
        return result.sorted { $0.1.modificationDate > $1.1.modificationDate }
    }

    private func parse(line: Data, endOffset: Int64) -> [IndexedUsageEvent] {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let params = object["params"] as? [String: Any],
              let update = params["update"] as? [String: Any],
              update["sessionUpdate"] as? String == "turn_completed",
              let usage = update["usage"] as? [String: Any],
              let date = turnDate(object: object, params: params) else {
            return []
        }

        let promptID = (update["prompt_id"] as? String).flatMap {
            $0.isEmpty ? nil : $0
        } ?? "offset-\(endOffset)"
        var result: [IndexedUsageEvent] = []
        let topBreakdown = tokenBreakdown(usage)
        let topCost = trustedCost(usage)

        if let modelUsage = usage["modelUsage"] as? [String: Any] {
            for (modelID, raw) in modelUsage.sorted(by: { $0.key < $1.key }) {
                guard let model = raw as? [String: Any] else { continue }
                let breakdown = tokenBreakdown(model)
                guard breakdown.totalTokens > 0 else { continue }
                let cost = trustedCost(model)
                result.append(
                    IndexedUsageEvent(
                        eventKey: "\(promptID)::\(modelID)",
                        occurredAt: date,
                        modelID: "__detail__:\(modelID)",
                        usage: breakdown,
                        turns: 1,
                        costUSD: cost,
                        costKind: cost == nil ? nil : .recorded
                    )
                )
            }
        }

        if !result.isEmpty {
            var total = topBreakdown
            if total.totalTokens == 0 {
                total = result.reduce(into: TokenBreakdown()) {
                    $0.add($1.usage)
                }
            }
            result.append(
                IndexedUsageEvent(
                    eventKey: "\(promptID)::total",
                    occurredAt: date,
                    modelID: "__total__:grok",
                    usage: total,
                    turns: 1,
                    costUSD: topCost,
                    costKind: topCost == nil ? nil : .recorded
                )
            )
        } else {
            guard topBreakdown.totalTokens > 0 else { return [] }
            result.append(
                IndexedUsageEvent(
                    eventKey: promptID,
                    occurredAt: date,
                    modelID: "grok-unknown",
                    usage: topBreakdown,
                    turns: 1,
                    costUSD: topCost,
                    costKind: topCost == nil ? nil : .recorded
                )
            )
        }
        return result
    }

    private func turnDate(
        object: [String: Any],
        params: [String: Any]
    ) -> Date? {
        if let meta = params["_meta"] as? [String: Any],
           let milliseconds = number(meta["agentTimestampMs"]),
           milliseconds > 0 {
            return Date(timeIntervalSince1970: milliseconds / 1_000)
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
        guard !bool(object["usageIsIncomplete"]),
              !bool(object["costIsPartial"]),
              let ticks = number(object["costUsdTicks"]), ticks != 0 else {
            return nil
        }
        return ticks / 10_000_000_000
    }

    private func displayModelName(_ modelID: String) -> String {
        let cleaned = modelID.replacingOccurrences(of: "-build", with: "")
        return cleaned.hasPrefix("grok-")
            ? cleaned.replacingOccurrences(of: "grok-", with: "Grok ")
            : cleaned
    }

    private func int64(_ value: Any?) -> Int64 {
        if let number = value as? NSNumber { return max(0, number.int64Value) }
        if let string = value as? String, let number = Int64(string) {
            return max(0, number)
        }
        return 0
    }

    private func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private func bool(_ value: Any?) -> Bool {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        return false
    }
}

private nonisolated final class AGYProgressContext {
    let cancellation: UsageScanCancellation
    let deadline: ContinuousClock.Instant

    init(cancellation: UsageScanCancellation, deadline: ContinuousClock.Instant) {
        self.cancellation = cancellation
        self.deadline = deadline
    }

    func shouldInterrupt() -> Bool {
        if .now >= deadline { return true }
        do {
            try cancellation.check()
            return false
        } catch {
            return true
        }
    }
}

private nonisolated func agyProgressCallback(
    context: UnsafeMutableRawPointer?
) -> Int32 {
    guard let context else { return 0 }
    let value = Unmanaged<AGYProgressContext>
        .fromOpaque(context)
        .takeUnretainedValue()
    return value.shouldInterrupt() ? 1 : 0
}

private nonisolated struct AGYIncrementalIndexer {
    static let parserVersion = 1
    static let rowsPerDatabase = 10_000
    static let totalRowLimit = 50_000

    let providerID: String
    let accountID: String
    let geminiDirectory: URL?

    func scan(
        index: UsageIndex,
        cancellation: UsageScanCancellation,
        budget: UsageScanBudget
    ) throws -> IndexedActivitySnapshot {
        var meter = UsageScanMeter(budget: budget, cancellation: cancellation)
        let files = candidateFiles()
        let livePaths = Set(files.map { $0.metadata.path })
        var totalRows = 0
        var catchUpPending = false

        for candidate in files {
            try meter.check()
            let old = try index.sourceFile(
                providerID: providerID,
                accountID: accountID,
                path: candidate.metadata.path
            )
            if unchanged(
                state: old,
                metadata: candidate.metadata,
                parserVersion: Self.parserVersion
            ) { continue }

            if meter.isExhausted || totalRows >= Self.totalRowLimit {
                catchUpPending = true
                break
            }

            let resumes = old?.parserVersion == Self.parserVersion
                && old?.inode == candidate.metadata.inode
                && old?.fileSize == candidate.metadata.fileSize
                && old?.modificationTimeMS == candidate.metadata.modificationTimeMS
                && old?.scanStatus == "partial"
            let afterRowID = resumes ? old?.parsedOffset ?? 0 : 0
            let result = try scanDatabase(
                candidate.url,
                modificationDate: candidate.metadata.modificationDate,
                afterRowID: afterRowID,
                cancellation: cancellation,
                deadline: budget.deadline,
                meter: &meter,
                maximumRows: min(
                    Self.rowsPerDatabase,
                    Self.totalRowLimit - totalRows
                )
            )
            totalRows += result.events.count
            catchUpPending = catchUpPending || !result.reachedEnd

            try index.commit(
                IndexedFileCommit(
                    providerID: providerID,
                    accountID: accountID,
                    path: candidate.metadata.path,
                    inode: candidate.metadata.inode,
                    modificationTimeMS: candidate.metadata.modificationTimeMS,
                    fileSize: candidate.metadata.fileSize,
                    parsedOffset: result.lastRowID,
                    parserVersion: Self.parserVersion,
                    cursorState: nil,
                    anchorOffset: nil,
                    anchorSHA256: nil,
                    scanStatus: result.reachedEnd ? "complete" : "partial",
                    replaceExistingEvents: !resumes,
                    events: result.events
                )
            )
        }

        if !catchUpPending {
            try index.pruneMissingFiles(
                providerID: providerID,
                accountID: accountID,
                livePaths: livePaths
            )
        }
        try index.setRefreshState(
            providerID: providerID,
            accountID: accountID,
            succeeded: true,
            catchUpPending: catchUpPending
        )
        return try index.aggregate(
            providerID: providerID,
            accountID: accountID,
            modelDisplayName: { _ in "AGY 活动估算" },
            catchUpPending: catchUpPending
        )
    }

    private func candidateFiles() -> [(url: URL, metadata: UsageFileMetadata)] {
        let gemini = geminiDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".gemini", isDirectory: true)
        let directories = [
            gemini.appendingPathComponent("antigravity/conversations", isDirectory: true),
            gemini.appendingPathComponent("antigravity-cli/conversations", isDirectory: true)
        ]
        var result: [(URL, UsageFileMetadata)] = []
        for directory in directories {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            for file in files where file.pathExtension == "db" {
                if let metadata = UsageFileMetadata(url: file) {
                    result.append((file, metadata))
                }
            }
        }
        return result.sorted { $0.1.modificationDate > $1.1.modificationDate }
    }

    private func scanDatabase(
        _ file: URL,
        modificationDate: Date,
        afterRowID: Int64,
        cancellation: UsageScanCancellation,
        deadline: ContinuousClock.Instant,
        meter: inout UsageScanMeter,
        maximumRows: Int
    ) throws -> (events: [IndexedUsageEvent], lastRowID: Int64, reachedEnd: Bool) {
        var database: OpaquePointer?
        let openResult = sqlite3_open_v2(
            file.path,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX,
            nil
        )
        guard openResult == SQLITE_OK, let database else {
            if let database { sqlite3_close_v2(database) }
            return ([], afterRowID, false)
        }
        defer { sqlite3_close_v2(database) }

        let progress = AGYProgressContext(
            cancellation: cancellation,
            deadline: deadline
        )
        sqlite3_progress_handler(
            database,
            1_000,
            agyProgressCallback,
            Unmanaged.passUnretained(progress).toOpaque()
        )
        defer { sqlite3_progress_handler(database, 0, nil, nil) }

        let sql =
            """
            SELECT rowid, metadata,
                   coalesce(length(step_payload), 0) + coalesce(length(metadata), 0)
            FROM steps
            WHERE rowid > ?
            ORDER BY rowid
            LIMIT ?
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            return ([], afterRowID, false)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, afterRowID)
        sqlite3_bind_int(statement, 2, Int32(maximumRows + 1))

        var events: [IndexedUsageEvent] = []
        var lastRowID = afterRowID
        var reachedEnd = false
        while true {
            try meter.check()
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE {
                reachedEnd = true
                break
            }
            if step == SQLITE_INTERRUPT { throw CancellationError() }
            guard step == SQLITE_ROW else { break }

            if events.count >= maximumRows {
                reachedEnd = false
                break
            }

            let rowID = sqlite3_column_int64(statement, 0)
            let blob = sqlite3_column_blob(statement, 1)
            let blobSize = Int(sqlite3_column_bytes(statement, 1))
            let payloadLength = max(0, sqlite3_column_int64(statement, 2))
            let date: Date
            if let blob, blobSize > 2 {
                let data = Data(bytes: blob, count: blobSize)
                date = extractTimestamp(from: data).map {
                    Date(timeIntervalSince1970: $0)
                } ?? modificationDate
            } else {
                date = modificationDate
            }

            if events.count < maximumRows {
                let tokens = max(1, Int64(Double(payloadLength) / 3.5))
                events.append(
                    IndexedUsageEvent(
                        eventKey: String(rowID),
                        occurredAt: date,
                        modelID: "agy-activity-estimate",
                        usage: TokenBreakdown(inputTokens: tokens),
                        turns: 1,
                        costUSD: nil,
                        costKind: nil
                    )
                )
                lastRowID = rowID
                try meter.record(bytes: Int(min(payloadLength, Int64(Int.max))))
            }
        }

        return (
            events,
            lastRowID,
            reachedEnd
        )
    }

    private func extractTimestamp(from data: Data) -> TimeInterval? {
        var offset = 0
        let count = min(data.count, 30)
        while offset < count {
            let (tag, nextTag) = decodeVarint(data: data, offset: offset)
            offset = nextTag
            guard offset < count else { break }
            let (value, nextValue) = decodeVarint(data: data, offset: offset)
            offset = nextValue
            if tag >> 3 == 1, value >= 1_700_000_000, value <= 2_100_000_000 {
                return TimeInterval(value)
            }
        }
        return nil
    }

    private func decodeVarint(data: Data, offset: Int) -> (UInt64, Int) {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        var current = offset
        while current < data.count, shift < 64 {
            let byte = data[current]
            current += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { break }
            shift += 7
        }
        return (result, current)
    }
}
