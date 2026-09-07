import Foundation

@main
struct AssistantCleanupTests {
    static func main() {
        passed = 0
        whitelistPathsAreExactlyOneCID()
        invalidCIDYieldsNoPaths()
        neverTouchesCLILogs()
        ownedListStoresOnlyUUIDs()
        deletesOwnedAndLeavesForeign()
        pidfileKillRequiresAllThreeChecks()
        print("AssistantCleanupTests: \(passed) passed")
    }

    private static var passed = 0

    // MARK: - 白名单路径

    private static func whitelistPathsAreExactlyOneCID() {
        let root = URL(fileURLWithPath: "/tmp/agy-state")
        let cid = "cd067d3a-053a-45c2-bd73-51f4918d9700"
        let paths = AGYWorkspaceCleaner.paths(for: cid, stateRoot: root)
        let relative = Set(paths.map { relativePath($0, to: root) })
        expect(
            relative == Set([
                "conversations/\(cid).db",
                "conversations/\(cid).db-shm",
                "conversations/\(cid).db-wal",
                "brain/\(cid)",
                "annotations/\(cid).pbtxt",
                "presence/\(cid).lock"
            ]),
            "白名单路径必须恰好是该 cid 的六处，实际 \(relative)"
        )
    }

    private static func invalidCIDYieldsNoPaths() {
        let root = URL(fileURLWithPath: "/tmp/agy-state")
        for cid in ["*", "../other", "not-a-uuid", ""] {
            expect(
                AGYWorkspaceCleaner.paths(for: cid, stateRoot: root).isEmpty,
                "非法 cid 不得产生任何路径：\(cid)"
            )
        }
    }

    private static func neverTouchesCLILogs() {
        let root = URL(fileURLWithPath: "/tmp/agy-state")
        let paths = AGYWorkspaceCleaner.paths(
            for: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            stateRoot: root
        )
        expect(
            paths.allSatisfy { !$0.path.contains("/log/") },
            "不得生成 log/ 下的路径"
        )
        expect(
            !AGYWorkspaceCleaner.touchesCLILogs,
            "CLI 全局日志必须明确标为不动"
        )
    }

    private static func ownedListStoresOnlyUUIDs() {
        let parsed = AGYWorkspaceCleaner.parseOwnedList(
            Data(
                """
                ["cd067d3a-053a-45c2-bd73-51f4918d9700","not-a-uuid","../x",\
                "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"]
                """.utf8
            )
        )
        expect(
            parsed == [
                "cd067d3a-053a-45c2-bd73-51f4918d9700",
                "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
            ],
            "owned list 只保留 UUID，实际 \(parsed)"
        )
        let encoded = AGYWorkspaceCleaner.encodeOwnedList([
            "cd067d3a-053a-45c2-bd73-51f4918d9700",
            "请把这段 prompt 存下来"
        ])
        let text = String(data: encoded, encoding: .utf8) ?? ""
        expect(
            text.contains("cd067d3a-053a-45c2-bd73-51f4918d9700"),
            "合法 UUID 必须写回"
        )
        expect(
            !text.contains("prompt"),
            "owned list 不得写入提问或任何内容"
        )
        expect(
            AGYWorkspaceCleaner.parseOwnedList(Data("{\"prompt\":\"hi\"}".utf8))
                .isEmpty,
            "对象形状的文件必须当成空名单，不能当 cid"
        )
    }

    /// 给定 cid 只删该 cid；别人的会话和全局日志原样留下。
    private static func deletesOwnedAndLeavesForeign() {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("lt-cleaner-\(UUID().uuidString)")
        let state = temp.appendingPathComponent("state")
        let owned = temp.appendingPathComponent(
            "owned-conversations.json"
        )
        defer { try? FileManager.default.removeItem(at: temp) }

        let mine = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let foreign = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        writeFakeTree(stateRoot: state, cid: mine)
        writeFakeTree(stateRoot: state, cid: foreign)
        let log = state.appendingPathComponent("log/cli-today.log")
        try? FileManager.default.createDirectory(
            at: log.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? "keep".write(to: log, atomically: true, encoding: .utf8)
        try? AGYWorkspaceCleaner.encodeOwnedList([mine])
            .write(to: owned)

        AGYWorkspaceCleaner.reclaimOwnedConversations(
            ownedListURL: owned,
            stateRoot: state
        )

        expect(
            !FileManager.default.fileExists(
                atPath: state.appendingPathComponent(
                    "conversations/\(mine).db"
                ).path
            ),
            "我方 cid 的 db 应被删"
        )
        expect(
            !FileManager.default.fileExists(
                atPath: state.appendingPathComponent("brain/\(mine)").path
            ),
            "我方 cid 的 brain 目录应被删"
        )
        expect(
            FileManager.default.fileExists(
                atPath: state.appendingPathComponent(
                    "conversations/\(foreign).db"
                ).path
            ),
            "非我方 cid 一个文件都不能动"
        )
        expect(
            FileManager.default.fileExists(atPath: log.path),
            "CLI 全局日志必须留下"
        )
        let leftover = AGYWorkspaceCleaner.parseOwnedList(
            (try? Data(contentsOf: owned)) ?? Data("[]".utf8)
        )
        expect(
            leftover.isEmpty,
            "删成功后名单必须清空，实际 \(leftover)"
        )
    }

    // MARK: - 三重校验

    private static func pidfileKillRequiresAllThreeChecks() {
        let record = AGYPidRecord(
            pid: 4242,
            pgid: 4242,
            binaryPath: "/Users/me/.local/bin/agy",
            cwd: "/Users/me/.localtranslate/assistant/workspace"
        )
        expect(
            AGYPidfileReaper.shouldKill(
                record: record,
                snapshot: AGYProcessSnapshot(
                    isAlive: true,
                    executablePath: record.binaryPath,
                    cwd: record.cwd
                )
            ),
            "三项全中才杀"
        )
        expect(
            !AGYPidfileReaper.shouldKill(
                record: record,
                snapshot: AGYProcessSnapshot(
                    isAlive: false,
                    executablePath: record.binaryPath,
                    cwd: record.cwd
                )
            ),
            "pid 已死不杀"
        )
        expect(
            !AGYPidfileReaper.shouldKill(
                record: record,
                snapshot: AGYProcessSnapshot(
                    isAlive: true,
                    executablePath: "/usr/bin/yes",
                    cwd: record.cwd
                )
            ),
            "可执行文件对不上不杀（pid 可能已被复用）"
        )
        expect(
            !AGYPidfileReaper.shouldKill(
                record: record,
                snapshot: AGYProcessSnapshot(
                    isAlive: true,
                    executablePath: record.binaryPath,
                    cwd: "/Users/me/code/other-project"
                )
            ),
            "cwd 不是我们的 workspace 不杀"
        )
        expect(
            !AGYPidfileReaper.shouldKill(
                record: record,
                snapshot: AGYProcessSnapshot(
                    isAlive: true,
                    executablePath: nil,
                    cwd: record.cwd
                )
            ),
            "读不到可执行文件时放着不动"
        )
    }

    // MARK: -

    private static func writeFakeTree(stateRoot: URL, cid: String) {
        let files = AGYWorkspaceCleaner.paths(
            for: cid,
            stateRoot: stateRoot
        )
        for url in files {
            let isDirectory = url.pathExtension.isEmpty
            if isDirectory {
                try? FileManager.default.createDirectory(
                    at: url,
                    withIntermediateDirectories: true
                )
                try? "x".write(
                    to: url.appendingPathComponent("transcript.jsonl"),
                    atomically: true,
                    encoding: .utf8
                )
            } else {
                try? FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try? "x".write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    private static func relativePath(_ url: URL, to root: URL) -> String {
        let full = url.standardizedFileURL.path
        let prefix = root.standardizedFileURL.path + "/"
        if full.hasPrefix(prefix) {
            return String(full.dropFirst(prefix.count))
        }
        return full
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        if !condition() { fail(message) }
        passed += 1
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(
            Data("助手清理契约失败：\(message)\n".utf8)
        )
        exit(1)
    }
}
