import Foundation

nonisolated struct UsageScanBudget: Sendable {
    let maximumBytes: Int64
    let seconds: Double
    let deadline: ContinuousClock.Instant

    static func standard(
        maximumBytes: Int64 = 32 * 1024 * 1024,
        seconds: Double = 1
    ) -> UsageScanBudget {
        UsageScanBudget(
            maximumBytes: maximumBytes,
            seconds: seconds,
            deadline: .now.advanced(by: .milliseconds(Int64(seconds * 1_000)))
        )
    }

    /// 重新起算截止时间。预算是给**读取**的，不是给排队和准备的：构造 budget
    /// 到真正开始读之间还隔着串行队列调度、候选文件枚举和索引开库。这段时间
    /// 一旦吃掉整个时限，这一轮就一个字节也读不进来，`parsedOffset` 原地不动，
    /// 而 `catchUpPending` 仍是 true——分片补齐从此空转，索引永远停在半路。
    func started() -> UsageScanBudget {
        UsageScanBudget(
            maximumBytes: maximumBytes,
            seconds: seconds,
            deadline: .now.advanced(by: .milliseconds(Int64(seconds * 1_000)))
        )
    }
}

nonisolated final class UsageScanCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func check() throws {
        lock.lock()
        let value = cancelled
        lock.unlock()

        if value {
            throw CancellationError()
        }
    }
}

nonisolated final class UsageScanExecutor: @unchecked Sendable {
    static let shared = UsageScanExecutor()

    private let queue = DispatchQueue(
        label: "com.shaopc.LocalTranslate.ai-usage-scan",
        qos: .utility
    )

    private init() {}

    func submit<T: Sendable>(
        budget: UsageScanBudget,
        operation: @escaping @Sendable (
            UsageScanCancellation,
            UsageScanBudget
        ) throws -> T
    ) async throws -> T {
        let cancellation = UsageScanCancellation()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do {
                        try cancellation.check()
                        continuation.resume(
                            returning: try operation(cancellation, budget.started())
                        )
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }
}

nonisolated struct UsageScanMeter {
    private(set) var bytesRead: Int64 = 0
    let budget: UsageScanBudget
    let cancellation: UsageScanCancellation

    var isExhausted: Bool {
        bytesRead >= budget.maximumBytes || .now >= budget.deadline
    }

    var remainingBytes: Int64 {
        max(0, budget.maximumBytes - bytesRead)
    }

    mutating func record(bytes: Int) throws {
        bytesRead += Int64(bytes)
        try check()
    }

    func check() throws {
        try cancellation.check()
    }
}
