import Darwin
import Foundation

/// cid 白名单清理与 pidfile 三重校验。
///
/// 只删我们写入 owned-conversations.json 的 UUID；绝不枚举
/// `~/.gemini/antigravity-cli/`，也绝不碰 `log/cli-*.log`。
nonisolated enum AGYWorkspaceCleaner {
    static let touchesCLILogs = false

    static var agyStateRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                ".gemini/antigravity-cli",
                isDirectory: true
            )
    }

    static var ownedListURL: URL {
        AGYLaunchSpec.assistantRoot
            .appendingPathComponent("owned-conversations.json")
    }

    static func normalizedCID(_ raw: String) -> String? {
        UUID(uuidString: raw)?.uuidString.lowercased()
    }

    static func paths(for rawCID: String, stateRoot: URL) -> [URL] {
        guard let cid = normalizedCID(rawCID) else { return [] }
        let conversations = stateRoot.appendingPathComponent(
            "conversations",
            isDirectory: true
        )
        return [
            conversations.appendingPathComponent("\(cid).db"),
            conversations.appendingPathComponent("\(cid).db-shm"),
            conversations.appendingPathComponent("\(cid).db-wal"),
            stateRoot.appendingPathComponent("brain/\(cid)", isDirectory: true),
            stateRoot.appendingPathComponent("annotations/\(cid).pbtxt"),
            stateRoot.appendingPathComponent("presence/\(cid).lock")
        ]
    }

    static func parseOwnedList(_ data: Data) -> [String] {
        guard let raw = try? JSONSerialization.jsonObject(with: data)
                as? [Any]
        else { return [] }
        var seen = Set<String>()
        var result: [String] = []
        for item in raw {
            guard let string = item as? String,
                  let cid = normalizedCID(string),
                  !seen.contains(cid)
            else { continue }
            seen.insert(cid)
            result.append(cid)
        }
        return result
    }

    static func encodeOwnedList(_ cids: [String]) -> Data {
        let normalized = parseOwnedList(
            (try? JSONSerialization.data(withJSONObject: cids)) ?? Data("[]".utf8)
        )
        return (try? JSONSerialization.data(
            withJSONObject: normalized,
            options: [.prettyPrinted]
        )) ?? Data("[]\n".utf8)
    }

    static func remember(
        _ rawCID: String,
        ownedListURL: URL = ownedListURL
    ) {
        guard let cid = normalizedCID(rawCID) else { return }
        var owned = loadOwned(ownedListURL)
        if !owned.contains(cid) { owned.append(cid) }
        saveOwned(owned, to: ownedListURL)
    }

    static func deleteConversation(
        _ rawCID: String,
        stateRoot: URL,
        ownedListURL: URL
    ) {
        guard let cid = normalizedCID(rawCID) else { return }
        _ = removeFiles(for: cid, stateRoot: stateRoot)
        saveOwned(
            loadOwned(ownedListURL).filter { $0 != cid },
            to: ownedListURL
        )
    }

    static func reclaimOwnedConversations(
        ownedListURL: URL = ownedListURL,
        stateRoot: URL = agyStateRoot
    ) {
        let owned = loadOwned(ownedListURL)
        var leftover: [String] = []
        for cid in owned {
            if !removeFiles(for: cid, stateRoot: stateRoot) {
                leftover.append(cid)
            }
        }
        saveOwned(leftover, to: ownedListURL)
    }

    private static func removeFiles(
        for cid: String,
        stateRoot: URL
    ) -> Bool {
        var failed = false
        for url in paths(for: cid, stateRoot: stateRoot)
        where FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                failed = true
            }
        }
        return !failed
    }

    private static func loadOwned(_ url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return parseOwnedList(data)
    }

    private static func saveOwned(_ cids: [String], to url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? encodeOwnedList(cids).write(to: url, options: .atomic)
    }
}

nonisolated struct AGYPidRecord: Codable, Equatable {
    var pid: Int32
    var pgid: Int32
    var binaryPath: String
    var cwd: String
}

nonisolated struct AGYProcessSnapshot: Equatable {
    var isAlive: Bool
    var executablePath: String?
    var cwd: String?
}

/// 层 4：全中才杀。任一不满足就放着——pid 会被系统回收复用。
nonisolated enum AGYPidfileReaper {
    static func shouldKill(
        record: AGYPidRecord,
        snapshot: AGYProcessSnapshot
    ) -> Bool {
        guard snapshot.isAlive else { return false }
        guard let executable = snapshot.executablePath,
              pathsEqual(executable, record.binaryPath)
        else { return false }
        guard let cwd = snapshot.cwd,
              pathsEqual(cwd, record.cwd)
        else { return false }
        return true
    }

    static func reapIfNeeded(
        pidfileURL: URL = AGYLaunchSpec.pidfileURL,
        inspect: (Int32) -> AGYProcessSnapshot = AGYProcessInspector.snapshot,
        terminate: (Int32) -> Void = { pid in _ = kill(pid, SIGTERM) },
        killHard: (Int32) -> Void = { pid in _ = kill(pid, SIGKILL) },
        isAlive: (Int32) -> Bool = { pid in kill(pid, 0) == 0 },
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) {
        guard let record = readRecord(at: pidfileURL) else { return }
        if shouldKill(record: record, snapshot: inspect(record.pid)) {
            terminate(record.pid)
            sleep(AGYLaunchSpec.sigtermExitWait)
            if isAlive(record.pid) {
                killHard(record.pid)
            }
        }
        if let current = readRecord(at: pidfileURL),
           current.pid == record.pid {
            try? FileManager.default.removeItem(at: pidfileURL)
        }
    }

    static func writeRecord(
        _ record: AGYPidRecord,
        to url: URL = AGYLaunchSpec.pidfileURL
    ) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(record) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func removeRecord(
        at url: URL = AGYLaunchSpec.pidfileURL
    ) {
        try? FileManager.default.removeItem(at: url)
    }

    static func readRecord(at url: URL) -> AGYPidRecord? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AGYPidRecord.self, from: data)
    }

    private static func pathsEqual(_ a: String, _ b: String) -> Bool {
        URL(fileURLWithPath: a).standardizedFileURL.path
            == URL(fileURLWithPath: b).standardizedFileURL.path
    }
}

nonisolated enum AGYProcessInspector {
    static func snapshot(pid: Int32) -> AGYProcessSnapshot {
        let alive = kill(pid, 0) == 0
        guard alive else {
            return AGYProcessSnapshot(
                isAlive: false,
                executablePath: nil,
                cwd: nil
            )
        }
        return AGYProcessSnapshot(
            isAlive: true,
            executablePath: executablePath(pid),
            cwd: workingDirectory(pid)
        )
    }

    private static func executablePath(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let count = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard count > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func workingDirectory(_ pid: Int32) -> String? {
        let size = MemoryLayout<proc_vnodepathinfo>.stride
        let info = UnsafeMutablePointer<proc_vnodepathinfo>.allocate(
            capacity: 1
        )
        defer { info.deallocate() }
        info.initialize(to: proc_vnodepathinfo())
        let got = proc_pidinfo(
            pid,
            PROC_PIDVNODEPATHINFO,
            0,
            info,
            Int32(size)
        )
        guard got == Int32(size) else { return nil }
        return withUnsafeBytes(of: &info.pointee.pvi_cdir.vip_path) { raw in
            guard let base = raw.baseAddress?
                .assumingMemoryBound(to: CChar.self)
            else { return nil }
            return String(cString: base)
        }
    }
}
