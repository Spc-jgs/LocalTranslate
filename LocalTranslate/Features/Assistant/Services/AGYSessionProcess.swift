import Darwin
import Foundation

/// agy 常驻会话：stdin 保持打开，stdout/stderr 持续读，退出必须 waitpid。
///
/// 未唤起前零进程。`ensureReady()` 只等到 `init`，`ask()` 再写 user。
/// 调用方在后台队列等结果，不阻塞 MainActor。
final class AGYSessionProcess: @unchecked Sendable {
    static let shared = AGYSessionProcess()

    enum SessionError: LocalizedError {
        case binaryMissing
        case startFailed(String)
        case timeout
        case statusNotSuccess(String)
        case authenticationRequired
        case stdoutClosed
        case oversizedResponse
        case invalidResponse
        case cancelled

        var errorDescription: String? {
            switch self {
            case .binaryMissing:
                return "agy 未安装"
            case .startFailed(let reason):
                return reason
            case .timeout:
                return "agy 响应超时"
            case .statusNotSuccess(let message):
                return message
            case .authenticationRequired:
                return "agy 未登录"
            case .stdoutClosed:
                return "agy 进程已退出"
            case .oversizedResponse:
                return "agy 响应超过 1 MB 上限"
            case .invalidResponse:
                return "agy 返回的格式无效"
            case .cancelled:
                return "已取消"
            }
        }

        var degradeTrigger: AssistantDegradeTrigger {
            switch self {
            case .binaryMissing: return .binaryMissing
            case .timeout: return .timeout
            case .authenticationRequired: return .authenticationRequired
            case .stdoutClosed: return .stdoutClosed
            case .statusNotSuccess: return .statusNotSuccess
            case .cancelled: return .startFailed
            case .startFailed, .oversizedResponse, .invalidResponse:
                return .startFailed
            }
        }
    }

    private let queue = DispatchQueue(
        label: "localtranslate.assistant.agy"
    )

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var processGroupID: pid_t?

    private var stdoutRemainder = Data()
    private var turnBytes = 0
    private var stderrTail = Data()
    private var pending: PendingTurn?
    private var lastInputTokens = 0
    private var failures = 0
    private var currentConversationID: String?
    private var startedAt: Date?
    private var didReclaim = false

    private var startCoordinator = AGYStartCoordinator()
    private var readyWaiters: [CheckedContinuation<Void, Error>] = []
    private var initTimeoutWork: DispatchWorkItem?
    private var deferredPrompt: String?

    var isRunning: Bool {
        queue.sync { process?.isRunning == true }
    }

    var isReady: Bool {
        queue.sync {
            startCoordinator.phase == .ready
                && process?.isRunning == true
        }
    }

    var consecutiveFailures: Int {
        queue.sync { failures }
    }

    /// 用户点「启动助手」后允许再试；自动 ensure 仍受连续失败上限约束。
    func clearFailures() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.failures = 0
                continuation.resume()
            }
        }
    }

    private init() {}

    func ensureReady() async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.beginEnsure(continuation: continuation)
            }
        }
    }

    func ask(prompt: String) async throws -> AGYTurnPayload {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.beginTurn(
                    prompt: prompt,
                    continuation: continuation
                )
            }
        }
    }

    func resetSession() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.failPending(.cancelled)
                self.failReadyWaiters(.cancelled)
                self.stopBlocking()
                self.lastInputTokens = 0
                self.failures = 0
                continuation.resume()
            }
        }
    }

    /// App 退出路径：必须等到 waitpid，不能只发信号。
    func shutdownSync() {
        queue.sync {
            self.failPending(.cancelled)
            self.failReadyWaiters(.cancelled)
            self.stopBlocking()
        }
    }

    /// 启动补扫：只读我们自己的名单和 pidfile，不枚举 agy 状态目录。
    func reclaimIfNeeded() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.reclaimOnQueue()
                continuation.resume()
            }
        }
    }

    // MARK: - Ready / Turn

    private func beginEnsure(
        continuation: CheckedContinuation<Void, Error>
    ) {
        reconcilePhase()
        switch startCoordinator.ensure() {
        case .alreadyReady:
            continuation.resume()
        case .waitForExistingStart:
            readyWaiters.append(continuation)
        case .spawn:
            readyWaiters.append(continuation)
            spawn()
        }
    }

    private func beginTurn(
        prompt: String,
        continuation: CheckedContinuation<AGYTurnPayload, Error>
    ) {
        if pending != nil {
            continuation.resume(throwing: SessionError.startFailed(
                "上一问尚未结束"
            ))
            return
        }

        if AssistantSessionResetPolicy.shouldReset(
            inputTokens: lastInputTokens
        ) {
            failReadyWaiters(.cancelled)
            stopBlocking()
            lastInputTokens = 0
        }

        pending = PendingTurn(continuation: continuation)
        deferredPrompt = prompt
        turnBytes = 0

        reconcilePhase()
        switch startCoordinator.ensure() {
        case .alreadyReady:
            sendDeferredPromptIfAny()
        case .waitForExistingStart:
            break
        case .spawn:
            spawn()
        }
    }

    private func spawn() {
        do {
            try launch()
            scheduleInitTimeout()
        } catch let error as SessionError {
            abortStart(error)
        } catch {
            abortStart(
                .startFailed(error.localizedDescription)
            )
        }
    }

    private func abortStart(_ error: SessionError) {
        if pending == nil {
            failures += 1
        }
        startCoordinator.didStop()
        failReadyWaiters(error)
        failPending(error)
        deferredPrompt = nil
        publishRuntime()
    }

    private func scheduleInitTimeout() {
        initTimeoutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.handleInitTimeout()
        }
        initTimeoutWork = work
        queue.asyncAfter(
            deadline: .now() + .seconds(
                AGYLaunchSpec.initTimeoutSeconds
            ),
            execute: work
        )
    }

    private func handleInitTimeout() {
        guard startCoordinator.phase == .starting else { return }
        if pending == nil {
            failures += 1
        }
        failReadyWaiters(.timeout)
        failPending(.timeout)
        deferredPrompt = nil
        stopBlocking()
    }

    private func markReady() {
        guard startCoordinator.phase == .starting else { return }
        initTimeoutWork?.cancel()
        initTimeoutWork = nil
        startCoordinator.didBecomeReady()
        let waiters = readyWaiters
        readyWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        publishRuntime()
        sendDeferredPromptIfAny()
    }

    private func sendDeferredPromptIfAny() {
        guard let prompt = deferredPrompt else { return }
        deferredPrompt = nil
        guard let stdinHandle else {
            failPending(.startFailed("agy stdin 不可用"))
            stopBlocking()
            return
        }
        pending?.armTimeout(
            on: queue,
            seconds: AGYLaunchSpec.requestTimeoutSeconds
        ) { [weak self] in
            self?.failPending(.timeout)
            self?.stopBlocking()
        }
        let line = AGYStreamJSON.encodeUser(prompt)
        guard let data = line.data(using: .utf8) else {
            failPending(.invalidResponse)
            return
        }
        do {
            try stdinHandle.write(contentsOf: data)
        } catch {
            failPending(.startFailed("无法写入 agy stdin"))
            stopBlocking()
        }
    }

    private func reconcilePhase() {
        if startCoordinator.phase != .idle,
           process?.isRunning != true {
            initTimeoutWork?.cancel()
            initTimeoutWork = nil
            startCoordinator.didStop()
            failReadyWaiters(.stdoutClosed)
            if pending != nil {
                failPending(.stdoutClosed)
            }
            deferredPrompt = nil
        }
    }

    private func failReadyWaiters(_ error: SessionError) {
        let waiters = readyWaiters
        readyWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(throwing: error)
        }
    }

    // MARK: - Launch

    private func reclaimOnQueue() {
        guard !didReclaim else { return }
        AGYWorkspaceCleaner.reclaimOwnedConversations()
        AGYPidfileReaper.reapIfNeeded()
        didReclaim = true
    }

    private func launch() throws {
        reclaimOnQueue()
        if process != nil {
            destroyRunningProcess()
            forgetOwnedConversation()
            startedAt = nil
        }
        guard let binary = AGYLaunchSpec.binaryURL() else {
            throw SessionError.binaryMissing
        }
        try prepareWorkspace()

        let process = Process()
        process.executableURL = binary
        process.arguments = AGYLaunchSpec.arguments(
            schemaJSON: AssistantOutputSchema.jsonString
        )
        process.currentDirectoryURL = AGYLaunchSpec.workspaceDirectory
        process.environment = ProcessInfo.processInfo.environment

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        process.terminationHandler = { [weak self] _ in
            self?.queue.async {
                self?.handleTermination()
            }
        }

        do {
            try process.run()
        } catch {
            throw SessionError.startFailed(
                "无法启动 agy：\(error.localizedDescription)"
            )
        }

        let pid = process.processIdentifier
        _ = setpgid(pid, pid)

        self.process = process
        self.processGroupID = pid
        self.stdinPipe = stdinPipe
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe
        self.stdinHandle = stdinPipe.fileHandleForWriting
        self.stdoutHandle = stdoutPipe.fileHandleForReading
        self.stderrHandle = stderrPipe.fileHandleForReading
        self.stdoutRemainder = Data()
        self.stderrTail = Data()

        stdoutHandle?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.queue.async { self?.consumeStdout(data) }
        }
        stderrHandle?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.queue.async { self?.consumeStderr(data) }
        }

        startedAt = Date()
        AGYPidfileReaper.writeRecord(
            AGYPidRecord(
                pid: pid,
                pgid: pid,
                binaryPath: binary.path,
                cwd: AGYLaunchSpec.workspaceDirectory.path
            )
        )
        publishRuntime()
    }

    private func prepareWorkspace() throws {
        let dir = AGYLaunchSpec.workspaceDirectory
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true
        )
    }

    // MARK: - I/O

    private func consumeStdout(_ data: Data) {
        guard process != nil else { return }
        if AGYStdoutEOF.isClosed(
            dataEmpty: data.isEmpty,
            processRunning: process?.isRunning == true
        ) {
            failPending(.stdoutClosed)
            stopBlocking()
            return
        }
        if data.isEmpty { return }
        if pending != nil, deferredPrompt == nil {
            turnBytes += data.count
            if turnBytes > AGYLaunchSpec.responseByteLimit {
                failPending(.oversizedResponse)
                stopBlocking()
                return
            }
        }
        stdoutRemainder.append(data)
        let newline = Data([0x0A])
        while let range = stdoutRemainder.range(of: newline) {
            let lineData = stdoutRemainder.subdata(
                in: stdoutRemainder.startIndex..<range.lowerBound
            )
            stdoutRemainder.removeSubrange(
                stdoutRemainder.startIndex..<range.upperBound
            )
            handleLine(lineData)
        }
    }

    private func consumeStderr(_ data: Data) {
        guard process != nil, !data.isEmpty else { return }
        stderrTail.append(data)
        let overflow = stderrTail.count - AGYLaunchSpec.stderrTailLimit
        if overflow > 0 {
            stderrTail.removeFirst(overflow)
        }
        if let text = String(data: stderrTail, encoding: .utf8),
           AssistantDegradationPolicy.isAuthenticationFailure(text) {
            failPending(.authenticationRequired)
            failReadyWaiters(.authenticationRequired)
            stopBlocking()
        }
    }

    private func handleLine(_ data: Data) {
        guard let line = String(data: data, encoding: .utf8) else {
            failPending(.invalidResponse)
            stopBlocking()
            return
        }
        guard let event = AGYStreamJSON.decodeLine(line) else {
            failPending(.invalidResponse)
            stopBlocking()
            return
        }
        switch event {
        case .sessionInit(let cid):
            rememberConversation(cid)
            markReady()
        case .ignored:
            break
        case .result(let payload):
            rememberConversation(payload.conversationID)
            lastInputTokens = payload.inputTokens
            if AssistantDegradationPolicy.isAuthenticationFailure(
                payload.error ?? ""
            ) {
                failPending(.authenticationRequired)
                return
            }
            if payload.isSuccess {
                failures = 0
                pending?.resume(.success(payload))
                self.pending = nil
            } else {
                failPending(
                    .statusNotSuccess(
                        payload.error
                            ?? "agy 返回 \(payload.status)"
                    )
                )
            }
        }
    }

    private func handleTermination() {
        if pending != nil {
            if let text = String(data: stderrTail, encoding: .utf8),
               AssistantDegradationPolicy.isAuthenticationFailure(text) {
                failPending(.authenticationRequired)
            } else {
                failPending(.stdoutClosed)
            }
        }
        guard process != nil else { return }
        detachHandles()
        try? stdinHandle?.close()
        try? stdoutHandle?.close()
        try? stderrHandle?.close()
        stdinHandle = nil
        stdoutHandle = nil
        stderrHandle = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil
        finishStop()
    }

    // MARK: - Stop

    private func failPending(_ error: SessionError) {
        guard let pending else { return }
        if error != .cancelled {
            failures += 1
        }
        pending.resume(.failure(error))
        self.pending = nil
    }

    private func stopBlocking() {
        initTimeoutWork?.cancel()
        initTimeoutWork = nil
        deferredPrompt = nil
        failReadyWaiters(.stdoutClosed)
        destroyRunningProcess()
        forgetOwnedConversation()
        startedAt = nil
        startCoordinator.didStop()
        publishRuntime()
    }

    private func finishStop() {
        initTimeoutWork?.cancel()
        initTimeoutWork = nil
        deferredPrompt = nil
        failReadyWaiters(.stdoutClosed)
        forgetOwnedConversation()
        startedAt = nil
        process = nil
        processGroupID = nil
        startCoordinator.didStop()
        publishRuntime()
    }

    private func destroyRunningProcess() {
        let running = process
        detachHandles()
        guard let running else {
            stdinHandle = nil
            stdoutHandle = nil
            stderrHandle = nil
            stdinPipe = nil
            stdoutPipe = nil
            stderrPipe = nil
            process = nil
            processGroupID = nil
            return
        }
        let pgid = processGroupID ?? running.processIdentifier
        AGYProcessTerminator(
            closeStdin: {
                try? self.stdinHandle?.close()
                self.stdinHandle = nil
            },
            isRunning: { running.isRunning },
            sendSIGTERM: {
                running.terminate()
                if pgid > 0 { _ = killpg(pgid, SIGTERM) }
            },
            sendSIGKILL: {
                if pgid > 0 { _ = killpg(pgid, SIGKILL) }
                _ = kill(running.processIdentifier, SIGKILL)
            },
            waitpid: { running.waitUntilExit() },
            sleep: { Thread.sleep(forTimeInterval: $0) }
        ).run()
        try? stdoutHandle?.close()
        try? stderrHandle?.close()
        stdinHandle = nil
        stdoutHandle = nil
        stderrHandle = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil
        stdoutRemainder = Data()
        process = nil
        processGroupID = nil
    }

    private func forgetOwnedConversation() {
        let cid = currentConversationID
        currentConversationID = nil
        if let cid {
            AGYWorkspaceCleaner.deleteConversation(
                cid,
                stateRoot: AGYWorkspaceCleaner.agyStateRoot,
                ownedListURL: AGYWorkspaceCleaner.ownedListURL
            )
        }
        AGYPidfileReaper.removeRecord()
    }

    private func rememberConversation(_ raw: String) {
        guard let cid = AGYWorkspaceCleaner.normalizedCID(raw) else { return }
        currentConversationID = cid
        AGYWorkspaceCleaner.remember(cid)
    }

    private func publishRuntime() {
        let phase: AssistantProcessPhase
        switch startCoordinator.phase {
        case .idle: phase = .idle
        case .starting: phase = .starting
        case .ready: phase = .ready
        }
        let pid = process?.processIdentifier
        let started = startedAt
        DispatchQueue.main.async {
            AssistantRuntime.shared.apply(
                phase: phase,
                pid: pid,
                startedAt: started
            )
        }
    }

    private func detachHandles() {
        stdoutHandle?.readabilityHandler = nil
        stderrHandle?.readabilityHandler = nil
        process?.terminationHandler = nil
    }

    private final class PendingTurn {
        let continuation: CheckedContinuation<AGYTurnPayload, Error>
        private var timeoutWork: DispatchWorkItem?
        private var resumed = false

        init(
            continuation: CheckedContinuation<AGYTurnPayload, Error>
        ) {
            self.continuation = continuation
        }

        func armTimeout(
            on queue: DispatchQueue,
            seconds: Int,
            fire: @escaping () -> Void
        ) {
            timeoutWork?.cancel()
            let work = DispatchWorkItem(block: fire)
            timeoutWork = work
            queue.asyncAfter(
                deadline: .now() + .seconds(seconds),
                execute: work
            )
        }

        func resume(_ result: Result<AGYTurnPayload, Error>) {
            guard !resumed else { return }
            resumed = true
            timeoutWork?.cancel()
            continuation.resume(with: result)
        }
    }
}

extension AGYSessionProcess.SessionError: Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.binaryMissing, .binaryMissing),
             (.timeout, .timeout),
             (.authenticationRequired, .authenticationRequired),
             (.stdoutClosed, .stdoutClosed),
             (.oversizedResponse, .oversizedResponse),
             (.invalidResponse, .invalidResponse),
             (.cancelled, .cancelled):
            return true
        case (.startFailed(let a), .startFailed(let b)),
             (.statusNotSuccess(let a), .statusNotSuccess(let b)):
            return a == b
        default:
            return false
        }
    }
}
