import Foundation

nonisolated enum GrokRequestPolicy {
    static let allowedHost = "cli-chat-proxy.grok.com"
    static let maximumResponseBytes = 1_048_576

    static func allows(_ url: URL?) -> Bool {
        url?.scheme?.lowercased() == "https"
            && url?.host?.lowercased() == allowedHost
            && url?.user == nil
            && url?.password == nil
    }
}
