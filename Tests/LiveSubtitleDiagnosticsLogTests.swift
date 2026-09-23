import Foundation

@main
struct LiveSubtitleDiagnosticsLogTests {
    static func main() {
        keepsOnlyTheMostRecentSessions()
        leavesRoomForTheSessionAboutToStart()
        doesNothingBelowTheLimit()
        emptyStageSamplesWriteNA()
        populatedStageSamplesWritePercentiles()
        print("LiveSubtitleDiagnosticsLogTests: 5 passed")
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

    /// 没有样本时写 n/a，不断言毫秒——否则没开过诊断的总会表会骗人。
    private static func emptyStageSamplesWriteNA() {
        let line = LiveSubtitleDiagnosticsLog.stagePercentileLine(
            name: "commitHold",
            samplesMS: []
        )
        expect(
            line == "commitHold p50=n/a p90=n/a",
            "空样本格式不对：\(line)"
        )
    }

    /// 有样本只检查总表里出现该阶段的 p50/p90，具体毫秒随语料变。
    private static func populatedStageSamplesWritePercentiles() {
        let line = LiveSubtitleDiagnosticsLog.stagePercentileLine(
            name: "pageTurnWait",
            samplesMS: [100, 200, 800]
        )
        expect(
            line.hasPrefix("pageTurnWait p50="),
            "翻页等待行缺少阶段名：\(line)"
        )
        expect(line.contains("p90="), "翻页等待行缺少 p90：\(line)")
        expect(!line.contains("n/a"), "有样本不应写 n/a：\(line)")
    }

    private static func expect(_ condition: Bool, _ message: String) {
        if !condition {
            FileHandle.standardError.write(Data("✗ \(message)\n".utf8))
            exit(1)
        }
    }
}
