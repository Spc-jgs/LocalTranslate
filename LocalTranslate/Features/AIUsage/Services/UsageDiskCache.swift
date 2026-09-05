import Foundation

final class UsageDiskCache: @unchecked Sendable {
    static let shared = UsageDiskCache()

    private static let coalesceInterval: DispatchTimeInterval = .seconds(2)

    private let cacheFileURL: URL
    private let writeQueue = DispatchQueue(
        label: "com.localtranslate.ai-usage-cache",
        qos: .utility
    )

    /// 仅在 writeQueue 上访问。
    private var pendingAccounts: [AccountSnapshot]?
    private var hasScheduledWrite = false

    init(cacheFileURL: URL? = nil) {
        let fileManager = FileManager.default
        let cachesDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory

        let appCacheDir = cachesDirectory.appendingPathComponent("LocalTranslate", isDirectory: true)
        let resolvedCacheFileURL = cacheFileURL
            ?? appCacheDir.appendingPathComponent("ai_usage_snapshots.json")
        let resolvedDirectory = resolvedCacheFileURL.deletingLastPathComponent()
        try? fileManager.createDirectory(
            at: resolvedDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: resolvedDirectory.path
        )

        self.cacheFileURL = resolvedCacheFileURL
    }

    func load() -> [AccountSnapshot] {
        guard FileManager.default.fileExists(atPath: cacheFileURL.path),
              let data = try? Data(contentsOf: cacheFileURL) else {
            return []
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([AccountSnapshot].self, from: data)
        } catch {
            return []
        }
    }

    /// 合并短时间内的重复写入。
    ///
    /// 一轮刷新会让每个 Provider 各自 publish 一次，而每次 publish 都保存
    /// 全量快照——六个 Provider 就是把同一个文件重写六遍。这里只保留最后
    /// 一份，落盘推迟一小段时间。
    func save(_ accounts: [AccountSnapshot]) {
        writeQueue.async { [weak self] in
            guard let self else { return }
            self.pendingAccounts = accounts

            if accounts.isEmpty {
                self.hasScheduledWrite = false
                self.pendingAccounts = nil
                self.writeNow([])
                return
            }

            guard !self.hasScheduledWrite else { return }
            self.hasScheduledWrite = true

            self.writeQueue.asyncAfter(deadline: .now() + Self.coalesceInterval) {
                [weak self] in
                guard let self else { return }
                self.hasScheduledWrite = false
                guard let pending = self.pendingAccounts else { return }
                self.pendingAccounts = nil
                self.writeNow(pending)
            }
        }
    }

    /// 退出前把尚未落盘的快照写掉，避免丢掉最后一轮刷新。
    func flush() {
        writeQueue.sync {
            guard let pending = pendingAccounts else { return }
            pendingAccounts = nil
            writeNow(pending)
        }
    }

    private func writeNow(_ accounts: [AccountSnapshot]) {
        do {
            if accounts.isEmpty {
                if FileManager.default.fileExists(atPath: cacheFileURL.path) {
                    try FileManager.default.removeItem(at: cacheFileURL)
                }
                return
            }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(accounts)
            try data.write(to: cacheFileURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: cacheFileURL.path
            )
        } catch {
            // Ignore background cache write failures
        }
    }
}
