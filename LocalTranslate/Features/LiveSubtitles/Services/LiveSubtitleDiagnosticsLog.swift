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
    private var holdsByThrottle = 0
    private var holdsByCommitHold = 0
    private var segments = 0
    private var changesPerSegment: [Int] = []
    private var anchorMoves = 0
    private var anchorHolds = 0
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
                "holds throttle=\(holdsByThrottle) commitHold=\(holdsByCommitHold)"
            )
            write(
                "previewAnchor held=\(anchorHolds) moved=\(anchorMoves) "
                    + "stability=\(percent(anchorHolds, of: anchorHolds + anchorMoves))"
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
    func caption(
        kind: String,
        gapMS: Int,
        length: Int,
        isCommitted: Bool
    ) {
        queue.async { [self] in
            guard handle != nil else { return }
            captionChanges += 1
            segmentChanges += 1
            if kind == "replace" {
                rewrites += 1
                segmentRewrites += 1
            } else {
                appends += 1
            }
            write(
                "caption kind=\(kind) gap=\(gapMS)ms len=\(length) "
                    + "committed=\(isCommitted)"
            )
        }
    }

    /// 一次上屏被压住了。`cause` 是 throttle（改写太密）或 commitHold（整句定格中）。
    func hold(cause: String) {
        queue.async { [self] in
            guard handle != nil else { return }
            if cause == "commitHold" {
                holdsByCommitHold += 1
            } else {
                holdsByThrottle += 1
            }
        }
    }

    /// preview 的取词起点是否和上一次相同。起点不停挪动，译文就只能整段重写。
    func previewAnchor(held: Bool, words: Int) {
        queue.async { [self] in
            guard handle != nil else { return }
            if held { anchorHolds += 1 } else { anchorMoves += 1 }
            write("anchor held=\(held) words=\(words)")
        }
    }

    /// 一句话定稿。这一行回答「这句在屏幕上折腾了几次」。
    func segmentCommitted(words: Int, lag: Double) {
        queue.async { [self] in
            guard handle != nil else { return }
            segments += 1
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
        holdsByThrottle = 0
        holdsByCommitHold = 0
        segments = 0
        changesPerSegment.removeAll()
        anchorMoves = 0
        anchorHolds = 0
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
