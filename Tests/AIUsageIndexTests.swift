import Foundation

@main
struct AIUsageIndexTests {
    static func main() async throws {
        try sqliteCommitAndAggregate()
        try sqliteUpsertDoesNotDuplicate()
        try sqliteReplaceAndCascade()
        try sqliteWALReopenIsConsistent()
        try await scanExecutorIsSerial()
        try await scanExecutorCancellationStopsWork()
        print("AIUsageIndexTests: 6 passed")
    }

    private static func sqliteCommitAndAggregate() throws {
        try withTemporaryIndex { index in
            try index.commit(
                commit(
                    path: "/fixture/a.jsonl",
                    events: [event(key: "10", input: 100, output: 25)]
                )
            )

            let snapshot = try index.aggregate(
                providerID: "codex",
                accountID: "account-a",
                modelDisplayName: { $0 },
                catchUpPending: false
            )
            expect(snapshot.indexedFiles == 1, "source file was not indexed")
            expect(
                snapshot.periodActivity.first(where: { $0.period == .today })?.tokens == 125,
                "today aggregate is incorrect"
            )
            expect(snapshot.modelActivity.first?.usage.inputTokens == 100, "model input mismatch")
        }
    }

    private static func sqliteUpsertDoesNotDuplicate() throws {
        try withTemporaryIndex { index in
            try index.commit(
                commit(
                    path: "/fixture/a.jsonl",
                    events: [event(key: "10", input: 100, output: 25)]
                )
            )
            try index.commit(
                commit(
                    path: "/fixture/a.jsonl",
                    replace: false,
                    events: [event(key: "10", input: 200, output: 50)]
                )
            )

            let snapshot = try index.aggregate(
                providerID: "codex",
                accountID: "account-a",
                modelDisplayName: { $0 },
                catchUpPending: false
            )
            expect(
                snapshot.periodActivity.first(where: { $0.period == .today })?.tokens == 250,
                "event UPSERT duplicated an existing event"
            )
        }
    }

    private static func sqliteReplaceAndCascade() throws {
        try withTemporaryIndex { index in
            try index.commit(
                commit(
                    path: "/fixture/a.jsonl",
                    events: [event(key: "10", input: 100, output: 25)]
                )
            )
            try index.commit(
                commit(
                    path: "/fixture/a.jsonl",
                    events: [event(key: "20", input: 10, output: 5)]
                )
            )

            var snapshot = try index.aggregate(
                providerID: "codex",
                accountID: "account-a",
                modelDisplayName: { $0 },
                catchUpPending: false
            )
            expect(
                snapshot.periodActivity.first(where: { $0.period == .today })?.tokens == 15,
                "file replacement retained stale events"
            )

            try index.pruneMissingFiles(
                providerID: "codex",
                accountID: "account-a",
                livePaths: []
            )
            snapshot = try index.aggregate(
                providerID: "codex",
                accountID: "account-a",
                modelDisplayName: { $0 },
                catchUpPending: false
            )
            expect(snapshot.indexedFiles == 0, "missing source was not pruned")
            expect(
                snapshot.periodActivity.first(where: { $0.period == .today })?.tokens == 0,
                "cascade did not remove source events"
            )
        }
    }

    private static func sqliteWALReopenIsConsistent() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalTranslate-AIUsage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("usage.sqlite")

        do {
            let index = try UsageIndex(databaseURL: databaseURL)
            try index.commit(
                commit(
                    path: "/fixture/a.jsonl",
                    events: [event(key: "10", input: 7, output: 3)]
                )
            )
        }

        let reopened = try UsageIndex(databaseURL: databaseURL)
        let snapshot = try reopened.aggregate(
            providerID: "codex",
            accountID: "account-a",
            modelDisplayName: { $0 },
            catchUpPending: false
        )
        expect(
            snapshot.periodActivity.first(where: { $0.period == .today })?.tokens == 10,
            "WAL reopen lost committed data"
        )
    }

    private static func scanExecutorIsSerial() async throws {
        let probe = SerialProbe()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    _ = try await UsageScanExecutor.shared.submit(
                        budget: .standard(seconds: 2)
                    ) { _, _ in
                        probe.enter()
                        Thread.sleep(forTimeInterval: 0.02)
                        probe.leave()
                        return true
                    }
                }
            }
            try await group.waitForAll()
        }

        expect(probe.maximumConcurrent == 1, "heavy scan executor ran concurrently")
    }

    private static func scanExecutorCancellationStopsWork() async throws {
        let task = Task {
            try await UsageScanExecutor.shared.submit(
                budget: .standard(seconds: 5)
            ) { cancellation, _ in
                while true {
                    try cancellation.check()
                    Thread.sleep(forTimeInterval: 0.005)
                }
            }
        }

        try await Task.sleep(for: .milliseconds(30))
        task.cancel()

        do {
            _ = try await task.value
            fatalError("cancelled scan unexpectedly completed")
        } catch is CancellationError {
            // Expected cooperative cancellation.
        }
    }

    private static func withTemporaryIndex(
        _ body: (UsageIndex) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalTranslate-AIUsage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(UsageIndex(databaseURL: directory.appendingPathComponent("usage.sqlite")))
    }

    private static func commit(
        path: String,
        replace: Bool = true,
        events: [IndexedUsageEvent]
    ) -> IndexedFileCommit {
        IndexedFileCommit(
            providerID: "codex",
            accountID: "account-a",
            path: path,
            inode: 1,
            modificationTimeMS: 1,
            fileSize: 100,
            parsedOffset: 100,
            parserVersion: 1,
            cursorState: nil,
            anchorOffset: nil,
            anchorSHA256: nil,
            scanStatus: "complete",
            replaceExistingEvents: replace,
            events: events
        )
    }

    private static func event(
        key: String,
        input: Int64,
        output: Int64
    ) -> IndexedUsageEvent {
        IndexedUsageEvent(
            eventKey: key,
            occurredAt: Date(),
            modelID: "gpt-test",
            usage: TokenBreakdown(inputTokens: input, outputTokens: output),
            turns: 1,
            costUSD: 0.001,
            costKind: .estimated
        )
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        if !condition() {
            fatalError(message)
        }
    }
}

private final class SerialProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    private(set) var maximumConcurrent = 0

    func enter() {
        lock.lock()
        current += 1
        maximumConcurrent = max(maximumConcurrent, current)
        lock.unlock()
    }

    func leave() {
        lock.lock()
        current -= 1
        lock.unlock()
    }
}
