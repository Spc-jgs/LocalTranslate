import Foundation

/// 实时字幕的节奏诊断，写到 `~/.localtranslate/live-subtitles/`。
///
/// 存在的理由：字幕好不好读是个体感问题，而调节奏的每个参数——改写间隔、
/// commit 定格、preview 取词上界——都只能靠「跑一段真实访谈再看」来判断。
/// 靠印象比较前后两版并不可靠，之前就发生过：改完展示层才发现追加路径在旧的
/// 取词方式下几乎永远命中不了，而那是读代码推断出来的，不是测出来的。
///
/// 三层粒度，因为单看流水看不出趋势：
///
/// - `caption`：每次字幕真正上屏，记下是追加还是改写、距上次多久；
/// - `segment`：每句定稿时汇总，这句在屏幕上一共变了几次；
/// - `session`：停止时给一份总表，这才是能回答「有没有变好」的东西。
///
/// 默认关闭。开着才创建文件、才持有句柄，停止即关闭——空闲态不留东西。
nonisolated final class LiveSubtitleDiagnosticsLog: @unchecked Sendable {
    /// 一次会话的数据分散在 ViewModel 和翻译服务两处，共用同一份记录才拼得起来。
    static let shared = LiveSubtitleDiagnosticsLog()

    /// 保留最近多少个会话文件。不设上限就是又一个只增不减的目录。
    static let retainedSessions = 20

    /// 该删掉哪些会话日志。
    ///
    /// 抽成纯函数是为了能测：目录只增不减这类问题不会有任何征兆，直到某天
    /// 占了几个 G。保留最近的 `limit - 1` 个，给马上要创建的这一个留位置。
    static func expiredSessions(
        _ files: [(url: URL, modifiedAt: Date)],
        retaining limit: Int = retainedSessions
    ) -> [URL] {
        guard limit > 0, files.count >= limit else { return [] }
        return files
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .dropFirst(limit - 1)
            .map(\.url)
    }

    static var directoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".localtranslate", isDirectory: true)
            .appendingPathComponent("live-subtitles", isDirectory: true)
    }

    private let queue = DispatchQueue(
        label: "com.shaopc.LocalTranslate.live-subtitle-log",
        qos: .utility
    )
    private var handle: FileHandle?
    private(set) var fileURL: URL?

    // 会话累计。只在 queue 上读写。
    private var startedAt: Date?
    private var captionChanges = 0
    private var rewrites = 0
    private var appends = 0
    private var holdsByCause: [String: Int] = [:]
    private var segments = 0
    private var changesPerSegment: [Int] = []
    private var anchorMoves = 0
    private var anchorHolds = 0
    private var plannerWindows = 0
    private var plannerDrains = 0
    private var commitsAccepted = 0
    private var commitBlocks: [String: Int] = [:]
    /// 每次改写时，新旧译文的公共前缀占新译文的比例。
    private var rewriteOverlaps: [Double] = []
    /// 被擦掉重写的字数，与最终定稿的字数。两者之比是 re-translation 文献里的
    /// normalized erasure——每产出一个字，屏幕上被擦掉重写了几个字。
    /// 论文给的朴素基线是 2.11，加上偏置搜索与掩码后能降到二十分之一。
    private var erasedCharacters = 0
    private var emittedCharacters = 0
    private var lags: [Double] = []
    private var firstTokenMS: [Int] = []

    // 当前这一句的累计。
    private var segmentChanges = 0
    private var segmentRewrites = 0

    private init() {}

    // MARK: - 生命周期

    func begin() {
        queue.async { [self] in
            guard handle == nil else { return }
            let directory = Self.directoryURL
            try? FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            pruneOldSessions(in: directory)

            let stamp = Self.fileStampFormatter.string(from: Date())
            let url = directory.appendingPathComponent("session-\(stamp).log")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            handle = try? FileHandle(forWritingTo: url)
            fileURL = url
            startedAt = Date()
            resetCounters()
            write("session start at=\(Self.timeFormatter.string(from: Date()))")
        }
    }

    /// 会话总表。单条流水看不出趋势，能回答「有没有变好」的是这一份。
    func end(reason: String) {
        queue.async { [self] in
            guard handle != nil else { return }
            let duration = startedAt.map { Date().timeIntervalSince($0) } ?? 0
            let perSegment = changesPerSegment
            write("")
            write("=== session summary")
            write(String(format: "duration=%.0fs segments=%d", duration, segments))
            write(
                "captionChanges=\(captionChanges) "
                    + "appends=\(appends) rewrites=\(rewrites) "
                    + "rewriteRatio=\(percent(rewrites, of: captionChanges))"
            )
            write(
                "changesPerSegment avg=\(average(perSegment.map(Double.init))) "
                    + "max=\(perSegment.max() ?? 0)"
            )
            write(
                "holds "
                    + (holdsByCause.isEmpty
                        ? "none"
                        : holdsByCause
                            .sorted { $0.value > $1.value }
                            .map { "\($0.key)=\($0.value)" }
                            .joined(separator: " "))
            )
            write(
                "previewAnchor held=\(anchorHolds) moved=\(anchorMoves) "
                    + "stability=\(percent(anchorHolds, of: anchorHolds + anchorMoves))"
            )
            write(
                "planner drains=\(plannerDrains) windows=\(plannerWindows)"
            )
            write(
                "commit accepted=\(commitsAccepted) blocked="
                    + (commitBlocks.isEmpty
                        ? "none"
                        : commitBlocks
                            .sorted { $0.value > $1.value }
                            .map { "\($0.key):\($0.value)" }
                            .joined(separator: ","))
            )
            write(
                "rewriteOverlap avg=\(average(rewriteOverlaps)) "
                    + "p90=\(percentile(rewriteOverlaps, 0.9))"
            )
            // 和 re-translation 论文的基线 2.11 对齐着看。
            write(
                "normalizedErasure="
                    + (emittedCharacters > 0
                        ? String(
                            format: "%.2f",
                            Double(erasedCharacters) / Double(emittedCharacters)
                        )
                        : "n/a")
                    + " erased=\(erasedCharacters) emitted=\(emittedCharacters)"
            )
            write("displayLag avg=\(average(lags))s p90=\(percentile(lags, 0.9))s")
            write(
                "firstToken avg=\(average(firstTokenMS.map(Double.init)))ms "
                    + "p90=\(percentile(firstTokenMS.map(Double.init), 0.9))ms"
            )
            write("stopped reason=\(reason)")
            try? handle?.close()
            handle = nil
            startedAt = nil
        }
    }

    // MARK: - 记录

    /// 字幕真正上屏。`kind` 是 append / replace。
    ///
    /// `commonPrefix` 是新旧译文的公共前缀字数。这是判断改写性质的关键：
    /// 比例高说明模型只是在尾部扩展、前面略作调整，展示层还有得救；比例低
    /// 说明每次都是从头重新翻译，那就只能从请求侧解决。
    func caption(
        kind: String,
        gapMS: Int,
        length: Int,
        previousLength: Int,
        commonPrefix: Int,
        isCommitted: Bool
    ) {
        queue.async { [self] in
            guard handle != nil else { return }
            captionChanges += 1
            segmentChanges += 1
            if kind == "replace" {
                rewrites += 1
                segmentRewrites += 1
                if length > 0 {
                    rewriteOverlaps.append(
                        Double(commonPrefix) / Double(length)
                    )
                }
                erasedCharacters += max(previousLength - commonPrefix, 0)
            } else {
                appends += 1
            }
            write(
                "caption kind=\(kind) gap=\(gapMS)ms len=\(length) "
                    + "common=\(commonPrefix) committed=\(isCommitted)"
            )
        }
    }

    /// planner 这一轮切出了几个窗口，还剩多少词没切。
    /// 「一句都没 commit」到底是切不出来还是切出来了被挡住，靠这一行区分。
    func plannerDrain(force: Bool, windows: Int, pendingWords: Int) {
        queue.async { [self] in
            guard handle != nil else { return }
            plannerDrains += 1
            plannerWindows += windows
            guard windows > 0 || force else { return }
            write(
                "planner drain force=\(force) windows=\(windows) "
                    + "pending=\(pendingWords)"
            )
        }
    }

    /// 整句翻译回来了，但没能上字幕条。`reason` 指出卡在哪一道。
    func commitBlocked(
        reason: String,
        windowEnd: Double,
        displayedEnd: Double
    ) {
        queue.async { [self] in
            guard handle != nil else { return }
            commitBlocks[reason, default: 0] += 1
            write(
                "commit blocked reason=\(reason) "
                    + String(
                        format: "windowEnd=%.2f displayedEnd=%.2f",
                        windowEnd,
                        displayedEnd
                    )
            )
        }
    }

    func commitAccepted(windowEnd: Double, displayedEnd: Double) {
        queue.async { [self] in
            guard handle != nil else { return }
            commitsAccepted += 1
            write(
                "commit accepted "
                    + String(
                        format: "windowEnd=%.2f displayedEnd=%.2f",
                        windowEnd,
                        displayedEnd
                    )
            )
        }
    }

    /// 一次上屏被压住了。`cause` 是 throttle（改写太密）或 commitHold（整句定格中）。
    func hold(cause: String) {
        queue.async { [self] in
            guard handle != nil else { return }
            holdsByCause[cause, default: 0] += 1
        }
    }

    /// preview 的取词起点是否和上一次相同。起点不停挪动，译文就只能整段重写。
    ///
    /// `bounded` 表示这次是否因为超过上界而被截断——上一版只在截断时才记，
    /// 于是占多数的未截断情况一条数据都没有。
    func previewAnchor(held: Bool, words: Int, bounded: Bool) {
        queue.async { [self] in
            guard handle != nil else { return }
            if held { anchorHolds += 1 } else { anchorMoves += 1 }
            write("anchor held=\(held) words=\(words) bounded=\(bounded)")
        }
    }

    /// 一句话定稿。这一行回答「这句在屏幕上折腾了几次」。
    func segmentCommitted(words: Int, characters: Int, lag: Double) {
        queue.async { [self] in
            guard handle != nil else { return }
            segments += 1
            emittedCharacters += characters
            changesPerSegment.append(segmentChanges)
            lags.append(lag)
            write(
                "segment done changes=\(segmentChanges) "
                    + "rewrites=\(segmentRewrites) words=\(words) "
                    + String(format: "lag=%.2fs", lag)
            )
            segmentChanges = 0
            segmentRewrites = 0
        }
    }

    func translationMetrics(firstTokenMS value: Int) {
        queue.async { [self] in
            guard handle != nil, value >= 0 else { return }
            firstTokenMS.append(value)
        }
    }

    // MARK: - 内部

    private func resetCounters() {
        captionChanges = 0
        rewrites = 0
        appends = 0
        holdsByCause.removeAll()
        segments = 0
        changesPerSegment.removeAll()
        anchorMoves = 0
        anchorHolds = 0
        plannerWindows = 0
        plannerDrains = 0
        commitsAccepted = 0
        commitBlocks.removeAll()
        rewriteOverlaps.removeAll()
        erasedCharacters = 0
        emittedCharacters = 0
        lags.removeAll()
        firstTokenMS.removeAll()
        segmentChanges = 0
        segmentRewrites = 0
    }

    private func write(_ line: String) {
        guard let handle else { return }
        try? handle.write(contentsOf: Data((line + "\n").utf8))
    }

    private func pruneOldSessions(in directory: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let logs = files
            .filter { $0.pathExtension == "log" }
            .map { (url: $0, modifiedAt: modified($0)) }
        for file in Self.expiredSessions(logs) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
    }

    private func percent(_ value: Int, of total: Int) -> String {
        guard total > 0 else { return "n/a" }
        return String(format: "%.0f%%", Double(value) / Double(total) * 100)
    }

    private func average(_ values: [Double]) -> String {
        guard !values.isEmpty else { return "n/a" }
        return String(format: "%.2f", values.reduce(0, +) / Double(values.count))
    }

    private func percentile(_ values: [Double], _ q: Double) -> String {
        guard !values.isEmpty else { return "n/a" }
        let sorted = values.sorted()
        let index = min(
            sorted.count - 1,
            max(0, Int((Double(sorted.count - 1) * q).rounded()))
        )
        return String(format: "%.2f", sorted[index])
    }

    private static let fileStampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
}
