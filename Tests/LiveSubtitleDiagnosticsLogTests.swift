import Foundation

@main
struct LiveSubtitleDiagnosticsLogTests {
    static func main() {
        keepsOnlyTheMostRecentSessions()
        leavesRoomForTheSessionAboutToStart()
        doesNothingBelowTheLimit()
        print("LiveSubtitleDiagnosticsLogTests: 3 passed")
    }

    /// 目录只增不减不会有任何征兆，直到某天占了几个 G。
    private static func keepsOnlyTheMostRecentSessions() {
        let files = (0..<25).map { index in
            (
                url: URL(fileURLWithPath: "/tmp/session-\(index).log"),
                modifiedAt: Date(timeIntervalSince1970: Double(index))
            )
        }
        let expired = LiveSubtitleDiagnosticsLog.expiredSessions(
            files,
            retaining: 20
        )
        expect(expired.count == 6, "该删的数量不对：\(expired.count)")
        // 最旧的先删，最新的一个都不能碰。
        expect(
            expired.contains(URL(fileURLWithPath: "/tmp/session-0.log")),
            "最旧的会话没有被清掉"
        )
        expect(
            !expired.contains(URL(fileURLWithPath: "/tmp/session-24.log")),
            "最新的会话被误删了"
        )
    }

    /// 删到 limit - 1，给马上要创建的这一个留位置，否则每跑一次就超一个。
    private static func leavesRoomForTheSessionAboutToStart() {
        let files = (0..<20).map { index in
            (
                url: URL(fileURLWithPath: "/tmp/s\(index).log"),
                modifiedAt: Date(timeIntervalSince1970: Double(index))
            )
        }
        let expired = LiveSubtitleDiagnosticsLog.expiredSessions(
            files,
            retaining: 20
        )
        expect(
            files.count - expired.count == 19,
            "清理后没有给新会话留出位置，剩 \(files.count - expired.count) 个"
        )
    }

    private static func doesNothingBelowTheLimit() {
        let files = (0..<5).map { index in
            (
                url: URL(fileURLWithPath: "/tmp/s\(index).log"),
                modifiedAt: Date(timeIntervalSince1970: Double(index))
            )
        }
        expect(
            LiveSubtitleDiagnosticsLog.expiredSessions(files, retaining: 20)
                .isEmpty,
            "没到上限就开始删文件了"
        )
    }

    private static func expect(_ condition: Bool, _ message: String) {
        if !condition {
            FileHandle.standardError.write(Data("✗ \(message)\n".utf8))
            exit(1)
        }
    }
}
