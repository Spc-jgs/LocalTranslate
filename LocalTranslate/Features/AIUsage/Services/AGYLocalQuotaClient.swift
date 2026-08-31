import Foundation

nonisolated struct AGYLocalQuotaSnapshot: Sendable {
    let quotaWindows: [QuotaWindow]
    let email: String?
    let plan: String?
    let sourceLabel: String
}

/// 从正在运行的 Antigravity 本机 language server 读取官方额度。
///
/// 该内部接口没有稳定的公开 schema，因此网络边界保持在本类型内：只连接
/// `127.0.0.1`，只信任回环地址上的自签名证书，并让 Provider 在协议变化时软失败。
nonisolated struct AGYLocalQuotaClient: Sendable {
    static let quotaSummaryPath =
        "/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary"
    static let userStatusPath =
        "/exa.language_server_pb.LanguageServerService/GetUserStatus"

    private let requestTimeout: TimeInterval

    init(requestTimeout: TimeInterval = 2) {
        self.requestTimeout = requestTimeout
    }

    func fetch() async throws -> AGYLocalQuotaSnapshot {
        let processes = try await Task.detached(priority: .utility) {
            let output = try Self.runProcess(
                executable: "/bin/ps",
                arguments: ["-axo", "pid=,command="]
            )
            return Self.parseProcesses(output)
        }.value

        guard !processes.isEmpty else {
            throw UsageHubError.invalidResponse("Antigravity 未运行，无法读取实时额度")
        }

        var lastError: Error?
        for process in processes {
            try Task.checkCancellation()
            do {
                let ports = try await listeningPorts(for: process.pid)
                let endpoints = Self.makeEndpoints(process: process, ports: ports)
                for endpoint in endpoints {
                    try Task.checkCancellation()
                    do {
                        let quotaData = try await request(
                            path: Self.quotaSummaryPath,
                            body: ["forceRefresh": true],
                            endpoint: endpoint
                        )
                        let windows = try Self.parseQuotaSummary(quotaData)
                        let identity = try? await request(
                            path: Self.userStatusPath,
                            body: Self.defaultRequestBody,
                            endpoint: endpoint
                        )
                        let parsedIdentity = identity.flatMap(Self.parseIdentity)
                        return AGYLocalQuotaSnapshot(
                            quotaWindows: windows,
                            email: parsedIdentity?.email,
                            plan: parsedIdentity?.plan,
                            sourceLabel: "AGY 本机额度接口"
                        )
                    } catch {
                        lastError = error
                    }
                }
            } catch {
                lastError = error
            }
        }

        throw lastError
            ?? UsageHubError.invalidResponse("Antigravity 本机额度接口不可用")
    }

    private func listeningPorts(for pid: Int) async throws -> [Int] {
        try await Task.detached(priority: .utility) {
            let output = try Self.runProcess(
                executable: "/usr/sbin/lsof",
                arguments: [
                    "-nP", "-a", "-p", String(pid),
                    "-iTCP", "-sTCP:LISTEN"
                ]
            )
            let ports = Self.parseListeningPorts(output)
            guard !ports.isEmpty else {
                throw UsageHubError.invalidResponse("Antigravity 未暴露本机额度端口")
            }
            return ports
        }.value
    }

    private func request(
        path: String,
        body: [String: Any],
        endpoint: AGYLocalEndpoint
    ) async throws -> Data {
        guard let url = URL(
            string: "\(endpoint.scheme)://127.0.0.1:\(endpoint.port)\(path)"
        ) else {
            throw UsageHubError.invalidResponse("Antigravity 本机地址无效")
        }

        let encoded = try JSONSerialization.data(withJSONObject: body)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = encoded
        request.timeoutInterval = requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        if let token = endpoint.csrfToken, !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "X-Codeium-Csrf-Token")
        }

        let (data, response) = try await AGYLoopbackSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UsageHubError.invalidResponse("Antigravity 未返回 HTTP 响应")
        }
        guard http.statusCode == 200 else {
            throw UsageHubError.http(http.statusCode, "Antigravity 本机额度接口拒绝请求")
        }
        return data
    }

    static func parseQuotaSummary(_ data: Data) throws -> [QuotaWindow] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageHubError.invalidResponse("AGY 额度响应不是 JSON 对象")
        }
        let payload = (root["response"] as? [String: Any])
            ?? (root["summary"] as? [String: Any])
            ?? root
        let groups = payload["groups"] as? [[String: Any]] ?? []

        var windows: [QuotaWindow] = []
        var hasKnownQuota = false
        for group in groups {
            let groupName = nonEmpty(group["displayName"] as? String) ?? "额度"
            for bucket in group["buckets"] as? [[String: Any]] ?? [] {
                if (bucket["disabled"] as? Bool) == true { continue }
                guard let bucketID = nonEmpty(bucket["bucketId"] as? String) else {
                    continue
                }
                let fraction = remainingFraction(in: bucket)
                let reset = parseDate(bucket["resetTime"])
                guard fraction != nil || reset != nil else { continue }

                if fraction != nil { hasKnownQuota = true }
                let bucketName = nonEmpty(bucket["displayName"] as? String) ?? bucketID
                let cadence = quotaCadence(bucketID: bucketID, displayName: bucketName)
                windows.append(
                    QuotaWindow(
                        id: "agy-quota-\(bucketID)",
                        title: "\(displayGroupName(groupName)) \(cadence.title)",
                        usedPercent: fraction.map {
                            (1 - min(1, max(0, $0))) * 100
                        },
                        durationMinutes: cadence.minutes,
                        resetsAt: reset,
                        sourceLabel: "RetrieveUserQuotaSummary"
                    )
                )
            }
        }

        guard hasKnownQuota else {
            throw UsageHubError.invalidResponse("AGY 额度响应没有可用额度")
        }
        return windows.sorted {
            let lhsGroup = quotaGroupRank($0.title)
            let rhsGroup = quotaGroupRank($1.title)
            if lhsGroup != rhsGroup { return lhsGroup < rhsGroup }
            return ($0.durationMinutes ?? Int.max) < ($1.durationMinutes ?? Int.max)
        }
    }

    static func parseProcesses(_ output: String) -> [AGYLocalProcess] {
        output.split(separator: "\n").compactMap { rawLine in
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = line.split(
                maxSplits: 1,
                omittingEmptySubsequences: true,
                whereSeparator: { $0.isWhitespace }
            )
            guard parts.count == 2, let pid = Int(parts[0]) else { return nil }
            let command = String(parts[1])
            let lower = command.lowercased()

            let isLanguageServer = lower.range(
                of: #"(^|[/\\])language(?:_|-)server(?:[_-][a-z0-9]+)*(?:\.exe)?(\s|$)"#,
                options: .regularExpression
            ) != nil
            let isAntigravity = lower.contains("antigravity.app/")
                || lower.contains("/gemini.app/")
                || (lower.contains("--app_data_dir") && lower.contains("antigravity"))
            let isCLI = lower.range(
                of: #"(^|[/\\])(agy|antigravity-cli|antigravity_cli)(\s|$)"#,
                options: .regularExpression
            ) != nil
            guard (isLanguageServer && isAntigravity) || isCLI else { return nil }

            let token = extractFlag("--csrf_token", from: command)
            guard isCLI || token != nil else { return nil }
            return AGYLocalProcess(
                pid: pid,
                csrfToken: token,
                extensionPort: extractFlag("--extension_server_port", from: command)
                    .flatMap(Int.init),
                extensionCSRFToken: extractFlag(
                    "--extension_server_csrf_token",
                    from: command
                ),
                isCLI: isCLI
            )
        }
    }

    static func parseListeningPorts(_ output: String) -> [Int] {
        guard let regex = try? NSRegularExpression(pattern: #":(\d+)\s+\(LISTEN\)"#) else {
            return []
        }
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        var ports = Set<Int>()
        regex.enumerateMatches(in: output, range: range) { match, _, _ in
            guard let match,
                  let valueRange = Range(match.range(at: 1), in: output),
                  let value = Int(output[valueRange]) else { return }
            ports.insert(value)
        }
        return ports.sorted()
    }

    static func makeEndpoints(
        process: AGYLocalProcess,
        ports: [Int]
    ) -> [AGYLocalEndpoint] {
        var endpoints: [AGYLocalEndpoint] = []
        for port in ports {
            endpoints.append(
                AGYLocalEndpoint(
                    scheme: "https",
                    port: port,
                    csrfToken: process.isCLI ? nil : process.csrfToken
                )
            )
            endpoints.append(
                AGYLocalEndpoint(
                    scheme: "http",
                    port: port,
                    csrfToken: process.isCLI ? nil : process.csrfToken
                )
            )
        }
        if let port = process.extensionPort {
            for token in [process.extensionCSRFToken, process.csrfToken].compactMap({ $0 }) {
                let endpoint = AGYLocalEndpoint(
                    scheme: "http",
                    port: port,
                    csrfToken: token
                )
                if !endpoints.contains(endpoint) { endpoints.append(endpoint) }
            }
        }
        return endpoints
    }

    private static let defaultRequestBody: [String: Any] = [
        "metadata": [
            "ideName": "antigravity",
            "extensionName": "antigravity",
            "ideVersion": "unknown",
            "locale": "en"
        ]
    ]

    private static func runProcess(
        executable: String,
        arguments: [String]
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            throw UsageHubError.processFailed("无法运行 \(executable)")
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw UsageHubError.processFailed(
                message.flatMap(nonEmpty) ?? "\(executable) 退出码 \(process.terminationStatus)"
            )
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func extractFlag(_ flag: String, from command: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: flag)
        guard let regex = try? NSRegularExpression(
            pattern: "\(escaped)[=\\s]+([^\\s]+)",
            options: .caseInsensitive
        ) else { return nil }
        let range = NSRange(command.startIndex..<command.endIndex, in: command)
        guard let match = regex.firstMatch(in: command, range: range),
              let valueRange = Range(match.range(at: 1), in: command) else {
            return nil
        }
        return String(command[valueRange])
    }

    private static func remainingFraction(in bucket: [String: Any]) -> Double? {
        if let value = number(bucket["remainingFraction"]) { return value }
        guard let remaining = bucket["remaining"] as? [String: Any] else { return nil }
        if let value = number(remaining["remainingFraction"]) { return value }
        if remaining["case"] as? String == "remainingFraction" {
            return number(remaining["value"])
        }
        return nil
    }

    private static func parseIdentity(_ data: Data) -> (email: String?, plan: String?)? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = root["userStatus"] as? [String: Any] else { return nil }
        let planStatus = status["planStatus"] as? [String: Any]
        let planInfo = planStatus?["planInfo"] as? [String: Any]
        return (
            nonEmpty(status["email"] as? String),
            nonEmpty(planInfo?["planName"] as? String)
        )
    }

    private static func parseDate(_ value: Any?) -> Date? {
        if let number = number(value) {
            return Date(timeIntervalSince1970: number)
        }
        guard let text = value as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }

    private static func displayGroupName(_ raw: String) -> String {
        let lower = raw.lowercased()
        if lower.contains("gemini") { return "Gemini" }
        if lower.contains("claude") || lower.contains("gpt") { return "Claude/GPT" }
        return raw
    }

    private static func quotaCadence(
        bucketID: String,
        displayName: String
    ) -> (title: String, minutes: Int?) {
        let value = "\(bucketID) \(displayName)"
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        if value.contains("weekly") { return ("每周", 10_080) }
        if value.contains("5h") || value.contains("5-hour")
            || value.contains("five hour") || value.contains("session") {
            return ("5 小时", 300)
        }
        return (displayName, nil)
    }

    private static func quotaGroupRank(_ title: String) -> Int {
        if title.hasPrefix("Gemini") { return 0 }
        if title.hasPrefix("Claude/GPT") { return 1 }
        return 2
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

nonisolated struct AGYLocalProcess: Sendable {
    let pid: Int
    let csrfToken: String?
    let extensionPort: Int?
    let extensionCSRFToken: String?
    let isCLI: Bool
}

nonisolated struct AGYLocalEndpoint: Sendable, Equatable {
    let scheme: String
    let port: Int
    let csrfToken: String?
}

private nonisolated final class AGYLoopbackSessionDelegate: NSObject,
    URLSessionDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.host == "127.0.0.1",
              challenge.protectionSpace.authenticationMethod
                == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // CSRF token 只允许留在回环地址，拒绝本机服务把请求重定向到外部主机。
        completionHandler(request.url?.host == "127.0.0.1" ? request : nil)
    }
}

private nonisolated enum AGYLoopbackSession {
    private static let delegate = AGYLoopbackSessionDelegate()
    static let shared: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForResource = 4
        return URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
    }()
}
