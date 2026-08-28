import Foundation

final class UsageDiskCache: @unchecked Sendable {
    static let shared = UsageDiskCache()

    private let cacheFileURL: URL

    private init() {
        let fileManager = FileManager.default
        let cachesDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory

        let appCacheDir = cachesDirectory.appendingPathComponent("LocalTranslate", isDirectory: true)
        try? fileManager.createDirectory(at: appCacheDir, withIntermediateDirectories: true)

        self.cacheFileURL = appCacheDir.appendingPathComponent("ai_usage_snapshots.json")
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

    func save(_ accounts: [AccountSnapshot]) {
        guard !accounts.isEmpty else { return }

        Task.detached(priority: .background) { [cacheFileURL = self.cacheFileURL] in
            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(accounts)
                try data.write(to: cacheFileURL, options: .atomic)
            } catch {
                // Ignore background cache write failures
            }
        }
    }
}
