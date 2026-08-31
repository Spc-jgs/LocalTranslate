import Foundation

@main
struct AGYLocalQuotaClientTests {
    static func main() async throws {
        try parsesCurrentQuotaSummary()
        try parsesOneOfAndTopLevelShapes()
        try rejectsQuotaWithoutKnownUsage()
        parsesOnlyAuthenticatedAntigravityProcesses()
        parsesPortsAndBuildsLoopbackEndpoints()
        print("AGYLocalQuotaClientTests: 5 passed")

        if ProcessInfo.processInfo.environment["LOCALTRANSLATE_AGY_RUNTIME"] == "1" {
            let snapshot = try await AGYLocalQuotaClient().fetch()
            expect(!snapshot.quotaWindows.isEmpty, "真实 AGY 额度窗口为空")
            expect(snapshot.quotaWindows.allSatisfy { $0.usedPercent != nil },
                   "真实 AGY 额度包含未知使用率")
            print("AGY runtime: \(snapshot.quotaWindows.count) quota windows")
        }
    }

    private static func parsesCurrentQuotaSummary() throws {
        let data = Data(
            """
            {
              "response": {
                "groups": [
                  {
                    "displayName": "Gemini Models",
                    "buckets": [
                      {
                        "bucketId": "gemini-weekly",
                        "displayName": "Weekly Limit Remaining",
                        "remaining": { "remainingFraction": 0.8 },
                        "resetTime": "2026-09-04T03:10:48Z"
                      },
                      {
                        "bucketId": "gemini-5h",
                        "displayName": "Five Hour Limit Remaining",
                        "remaining": { "remainingFraction": 0.95 }
                      }
                    ]
                  },
                  {
                    "displayName": "Claude and GPT models",
                    "buckets": [
                      {
                        "bucketId": "3p-weekly",
                        "displayName": "Weekly Limit Remaining",
                        "remainingFraction": 0.6
                      }
                    ]
                  }
                ]
              }
            }
            """.utf8
        )
        let windows = try AGYLocalQuotaClient.parseQuotaSummary(data)
        expect(windows.map(\.title) == ["Gemini 5 小时", "Gemini 每周", "Claude/GPT 每周"],
               "额度标题或排序错误")
        expect(windows.map(\.durationMinutes) == [300, 10_080, 10_080],
               "额度周期错误")
        expect(abs((windows[0].usedPercent ?? -1) - 5) < 0.001,
               "remainingFraction 没有转换为 usedPercent")
        expect(windows[1].resetsAt != nil, "resetTime 没有解析")
    }

    private static func parsesOneOfAndTopLevelShapes() throws {
        let data = Data(
            """
            {
              "groups": [{
                "displayName": "Gemini Models",
                "buckets": [{
                  "bucketId": "gemini_session",
                  "displayName": "Session",
                  "remaining": { "case": "remainingFraction", "value": 0.5 }
                }]
              }]
            }
            """.utf8
        )
        let window = try AGYLocalQuotaClient.parseQuotaSummary(data)[0]
        expect(window.title == "Gemini 5 小时", "oneof quota shape 未解析")
        expect(window.usedPercent == 50, "oneof remaining value 错误")
    }

    private static func rejectsQuotaWithoutKnownUsage() throws {
        let data = Data(
            """
            {"response":{"groups":[{"displayName":"Gemini","buckets":[
              {"bucketId":"disabled","remainingFraction":0.5,"disabled":true},
              {"bucketId":"unknown","displayName":"Unknown","resetTime":"2026-09-04T03:10:48Z"}
            ]}]}}
            """.utf8
        )
        do {
            _ = try AGYLocalQuotaClient.parseQuotaSummary(data)
            expect(false, "没有真实额度时不应返回成功")
        } catch {
            // expected
        }
    }

    private static func parsesOnlyAuthenticatedAntigravityProcesses() {
        let output = """
        10 /Applications/Antigravity.app/Contents/Resources/bin/language_server --csrf_token secret --extension_server_port 6001 --extension_server_csrf_token extension
        11 /Applications/Antigravity.app/Contents/Resources/bin/language_server multicall schedule
        12 /tmp/language_server --csrf_token unrelated
        13 /Users/test/.local/bin/agy
        """
        let processes = AGYLocalQuotaClient.parseProcesses(output)
        expect(processes.map(\.pid) == [10, 13], "进程筛选错误")
        expect(processes[0].extensionPort == 6001, "扩展端口未解析")
        expect(processes[0].extensionCSRFToken == "extension", "扩展 token 未解析")
        expect(processes[1].isCLI, "agy CLI 未识别")
    }

    private static func parsesPortsAndBuildsLoopbackEndpoints() {
        let ports = AGYLocalQuotaClient.parseListeningPorts(
            "language 10 user TCP 127.0.0.1:5002 (LISTEN)\n"
                + "language 10 user TCP 127.0.0.1:5001 (LISTEN)\n"
                + "language 10 user TCP 127.0.0.1:5002 (LISTEN)\n"
        )
        expect(ports == [5001, 5002], "监听端口解析或去重错误")
        let process = AGYLocalProcess(
            pid: 10,
            csrfToken: "main",
            extensionPort: 6001,
            extensionCSRFToken: "extension",
            isCLI: false
        )
        let endpoints = AGYLocalQuotaClient.makeEndpoints(process: process, ports: ports)
        expect(endpoints.first == AGYLocalEndpoint(scheme: "https", port: 5001, csrfToken: "main"),
               "HTTPS 应优先探测")
        expect(endpoints.allSatisfy { $0.port > 0 }, "端点端口无效")
        expect(endpoints.contains(AGYLocalEndpoint(scheme: "http", port: 6001, csrfToken: "extension")),
               "扩展服务端点缺失")
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }
}
