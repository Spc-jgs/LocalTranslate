import Foundation

nonisolated struct UsageScanBudget: Sendable {
    let maximumBytes: Int64
    let deadline: ContinuousClock.Instant

    static func standard(
        maximumBytes: Int64 = 32 * 1024 * 1024,
        seconds: Double = 1
    ) -> UsageScanBudget {
        UsageScanBudget(
            maximumBytes: maximumBytes,
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
                            returning: try operation(cancellation, budget)
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
