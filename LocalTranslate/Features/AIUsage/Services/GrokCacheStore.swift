import Foundation

struct CachedModelRecord: Codable, Sendable {
    let usage: TokenBreakdown
    let costUSD: Double?
}

struct CachedTurn: Codable, Sendable {
    let date: Date
    let usage: TokenBreakdown
    let costUSD: Double?
    let models: [String: CachedModelRecord]
}

struct CachedFileEntry: Codable, Sendable {
    var fileSize: UInt64
    var modificationDate: Date?
    var turnsByPromptID: [String: CachedTurn]
}

final class GrokCacheStore: @unchecked Sendable {
    static let shared = GrokCacheStore()

    private let lock = NSLock()
    private var entries: [String: CachedFileEntry] = [:]
    private var isDirty = false
    private let cacheFileURL: URL

    private init() {
        let fileManager = FileManager.default
        let cachesDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory

        let appCacheDir = cachesDirectory.appendingPathComponent("LocalTranslate", isDirectory: true)
        try? fileManager.createDirectory(at: appCacheDir, withIntermediateDirectories: true)

        self.cacheFileURL = appCacheDir.appendingPathComponent("grok_sessions_cache.json")
        loadFromDisk()
    }

    func getEntry(for path: String) -> CachedFileEntry? {
        lock.lock()
        defer { lock.unlock() }
        return entries[path]
    }

    func setEntry(_ entry: CachedFileEntry, for path: String) {
        lock.lock()
        entries[path] = entry
        isDirty = true
        lock.unlock()
    }

    func pruneStaleEntries(validPaths: Set<String>) {
        lock.lock()
        let oldKeys = Set(entries.keys)
        let removedKeys = oldKeys.subtracting(validPaths)
        if !removedKeys.isEmpty {
            for key in removedKeys {
                entries.removeValue(forKey: key)
            }
            isDirty = true
        }
        lock.unlock()
    }

    func allTurns() -> [CachedTurn] {
        lock.lock()
        defer { lock.unlock() }

        var turnsByPromptID: [String: CachedTurn] = [:]
        for entry in entries.values {
            for (promptID, turn) in entry.turnsByPromptID {
                turnsByPromptID[promptID] = turn
            }
        }
        return Array(turnsByPromptID.values)
    }

    func saveIfDirty() {
        lock.lock()
        guard isDirty else {
            lock.unlock()
            return
        }
        let copy = entries
        isDirty = false
        lock.unlock()

        Task.detached(priority: .background) { [cacheFileURL = self.cacheFileURL] in
            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(copy)
                try data.write(to: cacheFileURL, options: .atomic)
            } catch {
                // Ignore background cache write failures
            }
        }
    }

    private func loadFromDisk() {
        guard FileManager.default.fileExists(atPath: cacheFileURL.path) else { return }
        do {
            let data = try Data(contentsOf: cacheFileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let loaded = try decoder.decode([String: CachedFileEntry].self, from: data)
            self.entries = loaded
        } catch {
            // If cache is corrupted, start fresh
            self.entries = [:]
        }
    }
}
