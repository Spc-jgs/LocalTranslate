import Foundation

/// 共享的 Ollama 地址解析。
///
/// 这里只做纯传输层的地址规范化，不持有任何 Feature 的会话、模型或状态机，
/// 因此不违反 `Translate` 与 `LiveSubtitles` 之间的特性隔离边界。
nonisolated enum OllamaEndpoint {

    enum EndpointError: LocalizedError {
        case invalidURL

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "Ollama 地址无效"
            }
        }
    }

    enum PrivacyBoundary: Equatable {
        case loopback
        case encryptedRemote(host: String)
        case insecureRemote(host: String)
        case invalid
    }

    /// 去掉首尾空白与结尾斜杠，并把 `localhost` 映射为 `127.0.0.1`。
    ///
    /// macOS URLSession 会优先解析 IPv6 的 `::1`，而 Ollama 默认只监听
    /// IPv4 的 `127.0.0.1`，直接使用 `localhost` 会得到 Connection Refused。
    static func normalizedBase(
        _ rawBaseURL: String = AppSettings.baseURL
    ) -> String {
        var base = rawBaseURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        if base.hasPrefix("http://localhost:") {
            base = base.replacingOccurrences(
                of: "http://localhost:",
                with: "http://127.0.0.1:"
            )
        } else if base == "http://localhost" {
            base = "http://127.0.0.1"
        }

        return base
    }

    /// 拼接规范化后的 base 与 `/api/...` 路径。
    static func url(
        path: String,
        baseURL rawBaseURL: String = AppSettings.baseURL
    ) throws -> URL {
        guard let url = URL(string: normalizedBase(rawBaseURL) + path),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil,
              url.user == nil,
              url.password == nil else {
            throw EndpointError.invalidURL
        }

        return url
    }

    static func privacyBoundary(
        _ rawBaseURL: String = AppSettings.baseURL
    ) -> PrivacyBoundary {
        guard let url = URL(string: normalizedBase(rawBaseURL)),
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(),
              ["http", "https"].contains(scheme),
              url.user == nil,
              url.password == nil else { return .invalid }
        if ["127.0.0.1", "::1", "localhost"].contains(host) {
            return .loopback
        }
        return scheme == "https"
            ? .encryptedRemote(host: host)
            : .insecureRemote(host: host)
    }
}
