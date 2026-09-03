import Foundation
import SQLite3

/// 对本机真实日志做对账。
///
/// 存在的理由：AI 用量的两类缺陷都不会让构建或其它测试变红——数字只是悄悄
/// 错掉。夹具测试也挡不住，因为夹具是照着实现的假设造的，实现错在哪里，
/// 夹具就跟着错在哪里。两次实际发生的事故：
///
/// - AGY 把 `gen_metadata.idx` 和 `steps.idx` 当成一一对应来取事件时间，
///   而两者各自独立递增。2887 条记录里只有 39 条碰巧取对，24% 归错了日子。
/// - Codex 的分片扫描被 32 MB 预算截断后没有任何推进器，1.46 GB 日志只索引
///   了 37/248 个文件，OpenAI 的 90 天用量只显示出真值的 14%。
///
/// 所以这里的断言只有一个原则：**用一份独立写的实现复算，再和索引器比**。
/// 独立实现不复用被测代码的任何解析或关联逻辑；实现错了，两边就会分叉。
///
/// 读真实的 `~/.codex`、`~/.gemini` 等目录，只在本机有意义，不进 CI。
@main
struct AIUsageRealCorpusSmoke {
    private static var failures: [String] = []

    static func main() async {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let requested = Set(CommandLine.arguments.dropFirst())
        func wanted(_ id: String) -> Bool {
            requested.isEmpty || requested.contains(id)
        }

        let codexAccounts = [
            ("codex-plus-a", home.appendingPathComponent(".codex", isDirectory: true)),
            (
                "codex-plus-b",
                home.appendingPathComponent(".codex_account2", isDirectory: true)
            )
        ]

        for (providerID, codexHome) in codexAccounts where wanted(providerID) {
            guard FileManager.default.fileExists(atPath: codexHome.path) else {
                print("\(providerID): 跳过，本机没有 \(codexHome.lastPathComponent)")
                continue
            }
            await reconcileCodex(providerID: providerID, codexHome: codexHome)
        }

        if wanted("agy-antigravity") {
            let gemini = home.appendingPathComponent(".gemini", isDirectory: true)
            if FileManager.default.fileExists(atPath: gemini.path) {
                await reconcileAGY(providerID: "agy-antigravity", geminiDirectory: gemini)
            } else {
                print("agy-antigravity: 跳过，本机没有 ~/.gemini")
            }
        }

        guard failures.isEmpty else {
            print("──────────────────────────────────────────")
            for failure in failures { print("✗ \(failure)") }
            exit(1)
        }
        print("AIUsageRealCorpusSmoke: 对账通过")
    }

    // MARK: - Codex

    private static func reconcileCodex(providerID: String, codexHome: URL) async {
        let expected = independentCodexDailyTokens(codexHome: codexHome)
        let (actual, snapshot) = await scanToConvergence(providerID: providerID) {
            try await UsageActivityIndexer.shared.scanCodex(
                providerID: providerID,
                codexHome: codexHome,
                databaseURL: $0
            )
        }
        guard let snapshot else {
            record("\(providerID)：扫描没有产出快照")
            return
        }
        compare(
            providerID: providerID,
            expected: expected,
            actual: actual,
            snapshot: snapshot,
            expectedFiles: independentCodexFiles(codexHome: codexHome).count
        )
    }

    /// 独立复算 Codex 的每日 Token。只依赖 rollout 日志本身的语义：
    /// `last_token_usage` 是本轮增量（`total_token_usage` 是会话累计，不能相加），
    /// `input_tokens` 已经含 `cached_input_tokens`，模型身份来自最近一条
    /// `turn_context`。
    private static func independentCodexDailyTokens(codexHome: URL) -> [String: Int64] {
        var daily: [String: Int64] = [:]
        for file in independentCodexFiles(codexHome: codexHome) {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            var model = ""
            var previousSignature: String?
            var suppressingForkCopies = false
            var forkAnchor: Date?
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let data = line.data(using: .utf8),
                      let record = try? JSONSerialization.jsonObject(with: data)
                        as? [String: Any],
                      let payload = record["payload"] as? [String: Any] else { continue }

                if record["type"] as? String == "session_meta" {
                    // fork 出来的会话开头会复制父会话已经记过的 token_count，
                    // 那批记录的时间戳挤在一起。不去掉就是重复计数。
                    if isForked(payload), let stamp = record["timestamp"] as? String,
                       let date = isoDate(stamp) {
                        suppressingForkCopies = true
                        forkAnchor = date
                    }
                    continue
                }
                if record["type"] as? String == "turn_context" {
                    if let value = payload["model"] as? String, !value.isEmpty {
                        model = value
                    }
                    continue
                }
                guard payload["type"] as? String == "token_count",
                      !model.isEmpty,
                      let stamp = record["timestamp"] as? String,
                      let info = payload["info"] as? [String: Any],
                      let last = info["last_token_usage"] as? [String: Any] else { continue }

                let input = int64(last["input_tokens"])
                let output = int64(last["output_tokens"])
                guard input + output > 0 else { continue }
                let signature = [
                    input,
                    int64(last["cached_input_tokens"]),
                    int64(last["cache_write_input_tokens"]),
                    output,
                    min(output, int64(last["reasoning_output_tokens"]))
                ].map(String.init).joined(separator: ":")
                guard signature != previousSignature else { continue }
                previousSignature = signature

                guard let date = isoDate(stamp) else { continue }
                if suppressingForkCopies, let anchor = forkAnchor {
                    if date.timeIntervalSince(anchor) < 1 {
                        forkAnchor = date
                        continue
                    }
                    suppressingForkCopies = false
                }
                daily[localDay(date), default: 0] += input + output
            }
        }
        return daily
    }

    private static func isForked(_ payload: [String: Any]) -> Bool {
        if payload["forked_from_id"] is String { return true }
        guard let source = payload["source"] as? [String: Any],
              let subagent = source["subagent"] as? [String: Any],
              let spawn = subagent["thread_spawn"] as? [String: Any] else { return false }
        return spawn["parent_thread_id"] is String
    }

    private static func independentCodexFiles(codexHome: URL) -> [URL] {
        var files: [URL] = []
        for root in ["sessions", "archived_sessions"] {
            let directory = codexHome.appendingPathComponent(root, isDirectory: true)
            guard let walker = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let file as URL in walker where file.pathExtension == "jsonl" {
                guard let modified = modificationDate(file), modified >= windowStart else {
                    continue
                }
                files.append(file)
            }
        }
        return files
    }

    // MARK: - AGY

    private static func reconcileAGY(providerID: String, geminiDirectory: URL) async {
        let expected = independentAGYDailyTokens(geminiDirectory: geminiDirectory)
        let (actual, snapshot) = await scanToConvergence(providerID: providerID) {
            try await UsageActivityIndexer.shared.scanAGY(
                providerID: providerID,
                geminiDirectory: geminiDirectory,
                databaseURL: $0
            )
        }
        guard let snapshot else {
            record("\(providerID)：扫描没有产出快照")
            return
        }
        compare(
            providerID: providerID,
            expected: expected,
            actual: actual,
            snapshot: snapshot,
            expectedFiles: agyDatabases(in: geminiDirectory).count
        )
    }

    /// 独立复算 AGY 的每日 Token。这里刻意重写一份最小的 protobuf 读取，
    /// 不调用 `AGYUsageProtoParser`：这条链路上出过的事故正是「两表如何关联」
    /// 的假设错误，复用被测实现就等于把同一个假设抄两遍。
    private static func independentAGYDailyTokens(geminiDirectory: URL) -> [String: Int64] {
        var daily: [String: Int64] = [:]
        for file in agyDatabases(in: geminiDirectory) {
            // 先复制再读。AGY 有些会话库是 WAL 模式但 sidecar 已被清掉，
            // 直接只读打开会失败；复制到临时目录用读写模式打开，就不必在这里
            // 复刻被测代码的开库策略——那正是要独立验证的东西之一。
            guard let copy = temporaryCopy(of: file) else { continue }
            defer { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }

            var database: OpaquePointer?
            guard sqlite3_open(copy.path, &database) == SQLITE_OK, let database else {
                if let database { sqlite3_close_v2(database) }
                continue
            }
            defer { sqlite3_close_v2(database) }

            var stepTimes: [Int64: Date] = [:]
            forEachRow(database, "SELECT idx, substr(metadata, 1, 64) FROM steps") { statement in
                let index = sqlite3_column_int64(statement, 0)
                guard let bytes = blob(statement, column: 1) else { return }
                // steps.metadata 的 protobuf 路径 1.1 是 Unix 秒。
                guard let outer = submessage(bytes, field: 1),
                      let seconds = varint(outer, field: 1),
                      seconds > 1_600_000_000, seconds < 4_102_444_800 else { return }
                stepTimes[index] = Date(timeIntervalSince1970: TimeInterval(seconds))
            }

            forEachRow(database, "SELECT idx, data FROM gen_metadata") { statement in
                guard let bytes = blob(statement, column: 1),
                      let chat = submessage(bytes, field: 1) else { return }
                guard let usage = submessage(chat, field: 4) else { return }
                let tokens = [1, 2, 5, 9, 10].reduce(Int64(0)) {
                    $0 + Int64(varint(usage, field: $1) ?? 0)
                }
                guard tokens > 0 else { return }
                // 事件时间在这次生成自报的那一行 steps 上，不是同号行。
                guard let stepIndex = lastStepIndex(chat),
                      let occurredAt = stepTimes[stepIndex] else { return }
                daily[localDay(occurredAt), default: 0] += tokens
            }
        }
        return daily
    }

    /// 把库连同它的 `-wal` / `-shm` 复制到一个临时目录，返回副本路径。
    private static func temporaryCopy(of file: URL) -> URL? {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalTranslate-AGY-\(UUID().uuidString)", isDirectory: true)
        guard (try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )) != nil else { return nil }

        let destination = directory.appendingPathComponent(file.lastPathComponent)
        guard (try? FileManager.default.copyItem(at: file, to: destination)) != nil else {
            try? FileManager.default.removeItem(at: directory)
            return nil
        }
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: file.path + suffix)
            guard FileManager.default.fileExists(atPath: sidecar.path) else { continue }
            try? FileManager.default.copyItem(
                at: sidecar,
                to: URL(fileURLWithPath: destination.path + suffix)
            )
        }
        return destination
    }

    private static func agyDatabases(in geminiDirectory: URL) -> [URL] {
        let directories = [
            geminiDirectory.appendingPathComponent("antigravity", isDirectory: true),
            geminiDirectory
                .appendingPathComponent("antigravity/conversations", isDirectory: true),
            geminiDirectory
                .appendingPathComponent("antigravity-cli/conversations", isDirectory: true)
        ]
        var result: [URL] = []
        for directory in directories {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            result.append(contentsOf: files.filter { $0.pathExtension == "db" })
        }
        return result
    }

    /// `chat.20` 里 key 为 `last_step_index` 的那一对。
    private static func lastStepIndex(_ chat: [UInt8]) -> Int64? {
        for entry in submessages(chat, field: 20) {
            guard let key = string(entry, field: 1), key == "last_step_index",
                  let value = string(entry, field: 2) else { continue }
            return Int64(value)
        }
        return nil
    }

    // MARK: - 扫描到收敛

    /// 反复扫描直到索引器自己说「补齐完了」，或推进停滞。
    ///
    /// 收敛本身就是断言：分片扫描必须有走到头的路径。事故里 `catchUpPending`
    /// 只是一句 UI 文案，没有任何东西推进它，索引因此永远停在 14%。
    private static func scanToConvergence(
        providerID: String,
        _ scan: (URL) async throws -> IndexedActivitySnapshot
    ) async -> ([String: Int64], IndexedActivitySnapshot?) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalTranslate-Corpus-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("usage.sqlite")

        var snapshot: IndexedActivitySnapshot?
        var previousProgress: Int64 = -1
        var rounds = 0
        let maximumRounds = 200

        while rounds < maximumRounds {
            rounds += 1
            do {
                snapshot = try await scan(databaseURL)
            } catch {
                record("\(providerID)：第 \(rounds) 轮扫描抛出 \(type(of: error))")
                break
            }
            guard let current = snapshot else { break }
            if !current.catchUpPending { break }
            if current.indexedProgress == previousProgress {
                record(
                    "\(providerID)：第 \(rounds) 轮起补齐停滞在 "
                        + "\(current.indexedProgress)，catchUpPending 走不到头"
                )
                break
            }
            previousProgress = current.indexedProgress
        }

        if rounds >= maximumRounds {
            record("\(providerID)：\(maximumRounds) 轮仍未补齐完")
        }
        print("\(providerID): 分片 \(rounds) 轮收敛，文件 \(snapshot?.indexedFiles ?? 0) 个")

        var daily: [String: Int64] = [:]
        for entry in snapshot?.dailyActivity ?? [] {
            daily[localDay(entry.date), default: 0] += entry.tokens
        }
        return (daily, snapshot)
    }

    // MARK: - 比对

    private static func compare(
        providerID: String,
        expected: [String: Int64],
        actual: [String: Int64],
        snapshot: IndexedActivitySnapshot,
        expectedFiles: Int
    ) {
        if snapshot.indexedFiles < expectedFiles {
            record(
                "\(providerID)：只索引了 \(snapshot.indexedFiles)/\(expectedFiles) 个文件"
            )
        }

        let expectedTotal = expected.values.reduce(0, +)
        let actualTotal = actual.values.reduce(0, +)
        // 两边用同一套日志语义复算，剩下的只该是分片边界上的零头。
        let drift = expectedTotal == 0
            ? 0
            : Double(actualTotal - expectedTotal) / Double(expectedTotal)
        if abs(drift) > 0.005 {
            record(
                "\(providerID)：Token 总量 \(actualTotal) 对不上复算的 \(expectedTotal)"
                    + "（偏差 \(String(format: "%.1f%%", drift * 100))）"
            )
        }

        // 归日错误在总量上看不出来，只有逐日比对能发现。
        var misdated: [String] = []
        for day in Set(expected.keys).union(actual.keys).sorted() {
            let want = expected[day] ?? 0
            let got = actual[day] ?? 0
            let allowed = max(Int64(Double(want) * 0.05), 1024)
            if abs(got - want) > allowed {
                misdated.append("\(day) 期望 \(want) 实得 \(got)")
            }
        }
        if !misdated.isEmpty {
            record(
                "\(providerID)：\(misdated.count) 天的 Token 归日不符——"
                    + misdated.prefix(5).joined(separator: "；")
            )
        }

        print(
            "\(providerID): 复算 \(expectedTotal) / 索引 \(actualTotal)，"
                + "覆盖 \(snapshot.indexedFiles)/\(expectedFiles) 文件，"
                + "\(misdated.isEmpty ? "逐日一致" : "逐日有分叉")"
        )
    }

    private static func record(_ message: String) {
        failures.append(message)
    }

    // MARK: - 小工具

    private static let windowStart: Date = {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return calendar.date(byAdding: .day, value: -89, to: today) ?? today
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static func localDay(_ date: Date) -> String {
        dayFormatter.string(from: date)
    }

    private static func isoDate(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    private static func modificationDate(_ file: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate]
            as? Date
    }

    private static func int64(_ value: Any?) -> Int64 {
        max(0, (value as? NSNumber)?.int64Value ?? 0)
    }

    private static func forEachRow(
        _ database: OpaquePointer,
        _ sql: String,
        _ body: (OpaquePointer) -> Void
    ) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW { body(statement) }
    }

    private static func blob(_ statement: OpaquePointer, column: Int32) -> [UInt8]? {
        guard let pointer = sqlite3_column_blob(statement, column) else { return nil }
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0 else { return nil }
        return Array(UnsafeRawBufferPointer(start: pointer, count: count))
    }

    // MARK: - 独立的最小 protobuf 读取

    private static func varint(_ bytes: [UInt8], field: Int) -> UInt64? {
        var found: UInt64?
        var offset = 0
        func readVarint() -> UInt64? {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while offset < bytes.count, shift < 64 {
                let byte = bytes[offset]
                offset += 1
                result |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return result }
                shift += 7
            }
            return nil
        }
        while offset < bytes.count {
            guard let tag = readVarint() else { return found }
            let number = Int(tag >> 3)
            switch Int(tag & 7) {
            case 0:
                guard let value = readVarint() else { return found }
                if number == field, found == nil { found = value }
            case 2:
                guard let length = readVarint().flatMap(Int.init(exactly:)),
                      offset + length <= bytes.count else { return found }
                offset += length
            case 1:
                guard offset + 8 <= bytes.count else { return found }
                offset += 8
            case 5:
                guard offset + 4 <= bytes.count else { return found }
                offset += 4
            default:
                return found
            }
        }
        return found
    }

    private static func submessages(_ bytes: [UInt8], field: Int) -> [[UInt8]] {
        var result: [[UInt8]] = []
        var offset = 0
        func readVarint() -> UInt64? {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            while offset < bytes.count, shift < 64 {
                let byte = bytes[offset]
                offset += 1
                value |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
            }
            return nil
        }
        while offset < bytes.count {
            guard let tag = readVarint() else { return result }
            let number = Int(tag >> 3)
            switch Int(tag & 7) {
            case 0:
                guard readVarint() != nil else { return result }
            case 2:
                guard let length = readVarint().flatMap(Int.init(exactly:)),
                      offset + length <= bytes.count else { return result }
                if number == field {
                    result.append(Array(bytes[offset..<(offset + length)]))
                }
                offset += length
            case 1:
                guard offset + 8 <= bytes.count else { return result }
                offset += 8
            case 5:
                guard offset + 4 <= bytes.count else { return result }
                offset += 4
            default:
                return result
            }
        }
        return result
    }

    private static func submessage(_ bytes: [UInt8], field: Int) -> [UInt8]? {
        submessages(bytes, field: field).first
    }

    private static func string(_ bytes: [UInt8], field: Int) -> String? {
        submessage(bytes, field: field).flatMap { String(bytes: $0, encoding: .utf8) }
    }
}
