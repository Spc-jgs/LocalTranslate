import Foundation

struct CachedTranscriptEntry: Codable, Sendable {
    let mtime: TimeInterval
    let fileSize: Int64
    let dayTokens: [String: DayTokenCount]
    let totalTokens: Int64
    let totalTurns: Int
    let totalReasoning: Int64
}

struct DayTokenCount: Codable, Sendable {
    var tokens: Int64
    var turns: Int
    var reasoning: Int64
}

final class AGYCacheStore: @unchecked Sendable {
    static let shared = AGYCacheStore()

    private let cacheFileURL: URL
    private var inMemoryCache: [String: CachedTranscriptEntry] = [:]
    private let lock = NSLock()

    private init() {
        let fileManager = FileManager.default
        let cachesDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory

        let appCacheDir = cachesDirectory.appendingPathComponent("LocalTranslate", isDirectory: true)
        try? fileManager.createDirectory(at: appCacheDir, withIntermediateDirectories: true)

        self.cacheFileURL = appCacheDir.appendingPathComponent("agy_transcripts_cache.json")
        loadFromDisk()
    }

    func get(path: String, mtime: TimeInterval, size: Int64) -> CachedTranscriptEntry? {
        lock.lock()
        defer { lock.unlock() }

        guard let entry = inMemoryCache[path] else { return nil }
        if abs(entry.mtime - mtime) < 0.001 && entry.fileSize == size {
            return entry
        }
        return nil
    }

    func set(path: String, entry: CachedTranscriptEntry) {
        lock.lock()
        defer { lock.unlock() }
        inMemoryCache[path] = entry
    }

    func saveToDisk() {
        lock.lock()
        let snapshot = inMemoryCache
        lock.unlock()

        Task.detached(priority: .background) { [cacheFileURL = self.cacheFileURL] in
            do {
                let encoder = JSONEncoder()
                let data = try encoder.encode(snapshot)
                try data.write(to: cacheFileURL, options: .atomic)
            } catch {
                // Ignore background cache write failures
            }
        }
    }

    private func loadFromDisk() {
        guard FileManager.default.fileExists(atPath: cacheFileURL.path),
              let data = try? Data(contentsOf: cacheFileURL) else {
            return
        }

        do {
            let decoder = JSONDecoder()
            inMemoryCache = try decoder.decode([String: CachedTranscriptEntry].self, from: data)
        } catch {
            inMemoryCache = [:]
        }
    }
}
