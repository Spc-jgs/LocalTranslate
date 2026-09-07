import Foundation

@main
struct AssistantAGYChannelTests {
    static func main() {
        passed = 0
        resetThresholdIs272kAndExclusive()
        degradationTable()
        sourceCaptions()
        launchArgumentsPinTheSafetyFlags()
        streamJSONRoundTrip()
        streamJSONReadsUsageAndError()
        unknownEventsAreSkipped()
        stopSequenceClosesStdinBeforeSignals()
        stopSequenceSkipsSignalsIfAlreadyDead()
        agyPromptDisablesToolsAndWrapsInput()
        capturedContextOnlyWhenDraftIsPristine()
        schemaIsShared()
        schemaParsesFencedOrConcatenatedJSON()
        schemaParsesProseThenJSONFromLiveAGY()
        schemaParsesProseOnlyAsExplanation()
        streamJSONReadsObjectResponse()
        startCoordinatorCoalescesSpawn()
        emptyStdoutWhileRunningIsNotClosed()
        print("AssistantAGYChannelTests: \(passed) passed")
    }

    private static var passed = 0

    // MARK: - Token 阈值

    /// 超过才重置；等于 272K 仍留下一轮，避免边界上无谓重启。
    private static func resetThresholdIs272kAndExclusive() {
        expect(
            AssistantSessionResetPolicy.inputTokenThreshold == 272_000,
            "阈值必须是 272_000，单一出处"
        )
        expect(
            !AssistantSessionResetPolicy.shouldReset(inputTokens: 0),
            "空会话不该重置"
        )
        expect(
            !AssistantSessionResetPolicy.shouldReset(inputTokens: 272_000),
            "等于阈值不该重置"
        )
        expect(
            AssistantSessionResetPolicy.shouldReset(inputTokens: 272_001),
            "超过阈值必须重置"
        )
    }

    // MARK: - 降级

    private static func degradationTable() {
        let model = "qwen3.5:4b"
        expect(
            AssistantDegradationPolicy.shouldAttemptAGY(
                localOnly: false,
                binaryAvailable: true,
                consecutiveFailures: 0
            ),
            "默认应走 agy"
        )
        expect(
            !AssistantDegradationPolicy.shouldAttemptAGY(
                localOnly: true,
                binaryAvailable: true,
                consecutiveFailures: 0
            ),
            "只用本地时不得拉起 agy"
        )
        expect(
            !AssistantDegradationPolicy.shouldAttemptAGY(
                localOnly: false,
                binaryAvailable: false,
                consecutiveFailures: 0
            ),
            "没有 agy 二进制不得尝试启动"
        )
        expect(
            !AssistantDegradationPolicy.shouldAttemptAGY(
                localOnly: false,
                binaryAvailable: true,
                consecutiveFailures: 3
            ),
            "连续失败三次后不得无限重试"
        )
        expect(
            AssistantDegradationPolicy.shouldAttemptAGY(
                localOnly: false,
                binaryAvailable: true,
                consecutiveFailures: 2
            ),
            "两次失败后仍允许再试一次"
        )

        let unavailable = AssistantDegradationPolicy.notice(
            for: .startFailed,
            localModel: model
        )
        expect(
            unavailable.contains("agy 不可用")
                && unavailable.contains(model),
            "启动失败必须明说改用本地模型"
        )

        let auth = AssistantDegradationPolicy.notice(
            for: .authenticationRequired,
            localModel: model
        )
        expect(
            auth.contains("未登录") && auth.contains("终端"),
            "认证失败必须让用户去终端跑一次 agy，不得自己弹 OAuth"
        )

        expect(
            AssistantDegradationPolicy.isAuthenticationFailure(
                "authentication required"
            ),
            "应识别 authentication required"
        )
        expect(
            !AssistantDegradationPolicy.isAuthenticationFailure(
                "git rebase onto main"
            ),
            "普通错误文本不该被当成认证失败"
        )
    }

    private static func sourceCaptions() {
        let agy = AssistantAnswer(
            kind: .explanation,
            primary: "p",
            note: "n",
            hazard: nil,
            modelID: "gemini-3.8-flash · medium",
            source: .agy
        )
        let local = AssistantAnswer(
            kind: .explanation,
            primary: "p",
            note: "n",
            hazard: nil,
            modelID: "qwen3.5:4b",
            source: .local
        )
        expect(
            agy.sourceCaption == "agy · gemini-3.8-flash · medium",
            "agy 来源标注不对"
        )
        expect(
            local.sourceCaption == "本地 · qwen3.5:4b",
            "本地来源标注不对"
        )
    }

    // MARK: - 启动参数

    private static func launchArgumentsPinTheSafetyFlags() {
        let args = AGYLaunchSpec.arguments(
            schemaJSON: AssistantOutputSchema.jsonString
        )
        expect(args.contains("--sandbox"), "必须加 --sandbox")
        expect(
            args.contains("--disable-slash-commands"),
            "必须禁用 slash：/clear 会把 stream-json 会话打死"
        )
        expect(
            args.contains("--input-format")
                && args.contains("stream-json"),
            "必须走 stream-json 输入"
        )
        expect(
            args.contains("--output-format")
                && args.contains("stream-json"),
            "必须走 stream-json 输出"
        )
        expect(
            args.contains("--print-timeout") && args.contains("60s"),
            "单次请求上界必须是 60s"
        )
        expect(
            AGYLaunchSpec.modelID == "gemini-3.8-flash",
            "模型必须是家族 slug，档位走 --effort"
        )
        expect(
            AGYLaunchSpec.effort == "medium",
            "档位必须是 medium"
        )
        expect(
            args.contains("--model")
                && args.contains("gemini-3.8-flash")
                && !args.contains("gemini-3.8-flash-medium")
                && !args.contains("gemini-3.8-flash-high"),
            "必须传 --model gemini-3.8-flash，不得用合成 slug"
        )
        expect(
            args.contains("--effort") && args.contains("medium"),
            "必须传 --effort medium"
        )
        expect(
            args.contains("--json-schema")
                && args.contains(AssistantOutputSchema.jsonString),
            "json-schema 必须与本地通道同一份"
        )
        expect(
            !args.contains("--add-dir"),
            "不得把项目目录交给它"
        )
        expect(
            !args.contains("--dangerously-skip-permissions"),
            "不得放开全部工具权限"
        )
        expect(
            !args.contains("--continue") && !args.contains("-c"),
            "常驻进程必须开新会话，不得 --continue"
        )
        expect(
            AGYLaunchSpec.workspaceDirectory.path.hasSuffix(
                "/.localtranslate/assistant/workspace"
            ),
            "cwd 必须钉在我们建的空目录"
        )
        expect(
            AGYLaunchSpec.requestTimeoutSeconds == 60,
            "超时常量必须是 60 秒"
        )
        expect(
            AGYLaunchSpec.initTimeoutSeconds == 15,
            "等 init 的上限必须是 15 秒"
        )
        expect(
            AGYLaunchSpec.responseByteLimit == 1_048_576,
            "单次响应必须有 1 MB 上界"
        )
        expect(
            AGYLaunchSpec.consecutiveFailuresBeforeGivingUp == 3,
            "连续失败上限必须是 3"
        )
    }

    // MARK: - stream-json

    private static func streamJSONRoundTrip() {
        let line = AGYStreamJSON.encodeUser("/clear")
        expect(line.hasSuffix("\n"), "每条 stdin 消息必须是一行")
        expect(
            !line.contains("\n\n"),
            "user 消息不得夹空行，否则下一行会被当成新事件"
        )
        guard let obj = decodeJSON(line) else {
            fail("user 消息不是 JSON")
        }
        expect(obj["event"] as? String == "user", "event 必须是 user")
        let message = obj["message"] as? [String: Any]
        expect(
            message?["content"] as? String == "/clear",
            "/clear 只能作为 user 正文，不能当成 CLI slash"
        )
    }

    private static func streamJSONReadsUsageAndError() {
        let resultLine = """
            {"event":"result","result":{"conversation_id":"cid-1","status":"SUCCESS","response":"{\\"kind\\":\\"command\\",\\"primary\\":\\"lsof -i :8080\\",\\"note\\":\\"看谁占了端口\\"}","duration_seconds":2.6,"num_turns":1,"usage":{"input_tokens":16556,"output_tokens":7,"thinking_tokens":0,"cache_read_tokens":0,"total_tokens":16563}}}
            """
        switch AGYStreamJSON.decodeLine(resultLine) {
        case .result(let payload):
            expect(payload.conversationID == "cid-1", "cid 丢失")
            expect(payload.status == "SUCCESS", "status 丢失")
            expect(payload.inputTokens == 16_556, "input_tokens 不是真值")
            expect(payload.numTurns == 1, "num_turns 丢失")
            expect(
                payload.response.contains("lsof"),
                "response 丢失"
            )
        default:
            fail("SUCCESS result 未解码")
        }

        let errorLine = """
            {"event":"result","result":{"conversation_id":"cid-1","status":"ERROR","response":"","error":"/clear is not available in print mode","duration_seconds":1,"num_turns":2,"usage":{"input_tokens":21017,"output_tokens":14,"thinking_tokens":0,"cache_read_tokens":12203,"total_tokens":21031}}}
            """
        switch AGYStreamJSON.decodeLine(errorLine) {
        case .result(let payload):
            expect(payload.status == "ERROR", "ERROR status 丢失")
            expect(
                payload.error?.contains("/clear") == true,
                "error 正文丢失"
            )
            expect(
                !payload.isSuccess,
                "status != SUCCESS 不得当作成答"
            )
        default:
            fail("ERROR result 未解码")
        }

        let initLine = """
            {"event":"init","conversation_id":"cid-1","init":{"cwd":"/tmp","tools":[]}}
            """
        switch AGYStreamJSON.decodeLine(initLine) {
        case .sessionInit(let cid):
            expect(cid == "cid-1", "init 的 cid 丢失")
        default:
            fail("init 未解码")
        }
    }

    private static func unknownEventsAreSkipped() {
        switch AGYStreamJSON.decodeLine(
            #"{"event":"reset"}"#
        ) {
        case .ignored:
            passed += 1
        default:
            fail("未知 event 必须忽略，不得当错误结束会话")
        }
        expect(
            AGYStreamJSON.decodeLine("not-json") == nil,
            "非法 JSON 必须让调用方结束会话"
        )
    }

    // MARK: - 五层退出（层 1 的顺序）

    private static func stopSequenceClosesStdinBeforeSignals() {
        var events: [String] = []
        var running = true
        AGYProcessTerminator(
            closeStdin: { events.append("stdin") },
            isRunning: { running },
            sendSIGTERM: { events.append("term") },
            sendSIGKILL: {
                events.append("kill")
                running = false
            },
            waitpid: { events.append("waitpid") },
            sleep: { _ in events.append("sleep") }
        ).run()
        expect(
            events == [
                "stdin", "sleep", "term", "sleep", "kill", "waitpid"
            ],
            "停进程顺序必须是关 stdin → 等 → SIGTERM → 等 → SIGKILL → waitpid，实际 \(events)"
        )
        expect(
            AGYLaunchSpec.stdinExitWait == 2
                && AGYLaunchSpec.sigtermExitWait == 2,
            "两段等待必须是 2 秒"
        )
    }

    private static func stopSequenceSkipsSignalsIfAlreadyDead() {
        var events: [String] = []
        AGYProcessTerminator(
            closeStdin: { events.append("stdin") },
            isRunning: { false },
            sendSIGTERM: { events.append("term") },
            sendSIGKILL: { events.append("kill") },
            waitpid: { events.append("waitpid") },
            sleep: { _ in events.append("sleep") }
        ).run()
        expect(
            events == ["stdin", "waitpid"],
            "进程已退后不得再发信号，但仍必须 waitpid，实际 \(events)"
        )
    }

    // MARK: - 提示词与 schema

    private static func agyPromptDisablesToolsAndWrapsInput() {
        let question = AssistantPromptParts.agyPrompt(
            mode: .askQuestion,
            input: "合并最近三个提交",
            context: nil
        )
        expect(
            question.hasPrefix(AssistantPromptParts.agyPrefix),
            "agy 通道必须带禁用工具前缀"
        )
        expect(
            question.contains("<question>")
                && question.contains("合并最近三个提交"),
            "问题必须包在 question 标签里"
        )
        expect(
            !question.contains(AssistantPromptParts.localPersona),
            "agy 通道不得混入本地人设"
        )

        let selection = AssistantPromptParts.agyPrompt(
            mode: .analyzeSelection,
            input: "NullPointerException at Foo.swift:12",
            context: SelectionContext(
                selectedText: "NullPointerException at Foo.swift:12",
                before: "retry",
                after: "nil",
                sourceApp: nil,
                captureQuality: .surroundingText
            )
        )
        expect(
            selection.contains("<selection>")
                && selection.contains("<context>"),
            "一字未改的选区才附带前后文"
        )
    }

    /// 框里还是原文才带采集上下文；一改字或从空框打字，都不带。
    private static func capturedContextOnlyWhenDraftIsPristine() {
        let original = "NullPointerException at Foo.swift:12"
        expect(
            AssistantDraft.shouldAttachCapturedContext(
                draft: original,
                originalSelection: original
            ),
            "原文一字未改应附带上下文"
        )
        expect(
            !AssistantDraft.shouldAttachCapturedContext(
                draft: original + "\n再问一句",
                originalSelection: original
            ),
            "改过框里的字不得附带上下文"
        )
        expect(
            !AssistantDraft.shouldAttachCapturedContext(
                draft: "合并最近三个提交",
                originalSelection: original
            ),
            "换成手打的问题不得附带上下文"
        )
        expect(
            !AssistantDraft.shouldAttachCapturedContext(
                draft: "合并最近三个提交",
                originalSelection: ""
            ),
            "没有选区时不得附带上下文"
        )
        expect(
            !AssistantDraft.shouldAttachCapturedContext(
                draft: original + " ",
                originalSelection: original
            ),
            "多一个空格也算改过"
        )
    }

    private static func schemaIsShared() {
        let json = AssistantOutputSchema.jsonString
        guard let obj = decodeJSON(json + "\n") else {
            fail("schema 不是 JSON")
        }
        expect(obj["type"] as? String == "object", "schema type")
        let required = obj["required"] as? [String]
        expect(
            required == ["kind", "primary", "note"],
            "schema required 必须与本地通道相同"
        )
        let decoded = try? AssistantOutputSchema.parse(
            """
            {"kind":"command","primary":"lsof -i :8080","note":"看端口"}
            """
        )
        expect(decoded?.kind == .command, "schema 解析 kind")
        expect(decoded?.primary == "lsof -i :8080", "schema 解析 primary")
    }

    /// agy 实测会把 schema 包进 markdown，后面再跟一段带额外字段的 JSON。
    /// 从第一个 `{` 取到最后一个 `}` 会拼成非法对象，必须取第一段完整 JSON。
    private static func schemaParsesFencedOrConcatenatedJSON() {
        let messy = """
            ```json
            {
              "kind": "explanation",
              "primary": "1+1等于2。"
            }
            ```
            {"kind":"explanation","note":"extra","primary":"1+1等于2。","toolAction":"Finishing task"}
            """
        let decoded = try? AssistantOutputSchema.parse(messy)
        expect(decoded?.kind == .explanation, "围栏 JSON 的 kind")
        expect(decoded?.primary == "1+1等于2。", "围栏 JSON 的 primary")
        expect(decoded?.note == "", "缺 note 时应为空串，不得整段解析失败")
    }

    /// 2026-09-07 本机 agy 1.1.27 实测：SUCCESS 的 response 是一句散文
    /// 再跟 schema JSON（还带 toolAction）。丢掉这段会显示「agy 不可用」。
    private static func schemaParsesProseThenJSONFromLiveAGY() {
        let live = """
            1 + 1 等于 2。
            {"kind":"explanation","note":"已完成计算并直接给出结论。","primary":"1 + 1 等于 2。","toolAction":"Answering question","toolSummary":"Math calculation"}
            """
        let decoded = try? AssistantOutputSchema.parse(live)
        expect(decoded?.kind == .explanation, "散文+JSON 的 kind")
        expect(
            decoded?.primary == "1 + 1 等于 2。",
            "必须取 JSON 里的 primary，不能把整段散文当失败"
        )
        expect(
            decoded?.note == "已完成计算并直接给出结论。",
            "散文+JSON 的 note"
        )
    }

    /// schema 走了 finish 工具、response 只剩中文时，仍应展示，不得降级。
    private static func schemaParsesProseOnlyAsExplanation() {
        let live = "该表述是一项针对初始化（init）阶段的耗时限制要求。"
        let decoded = try? AssistantOutputSchema.parse(live)
        expect(decoded?.kind == .explanation, "无 JSON 时 kind 应为 explanation")
        expect(
            decoded?.primary == live,
            "无 JSON 的 SUCCESS 正文必须原样留下"
        )
    }

    private static func streamJSONReadsObjectResponse() {
        let resultLine = """
            {"event":"result","result":{"conversation_id":"cid-1","status":"SUCCESS","response":{"kind":"explanation","primary":"1+1等于2。","note":""},"duration_seconds":1,"num_turns":1,"usage":{"input_tokens":1,"output_tokens":1,"thinking_tokens":0,"cache_read_tokens":0,"total_tokens":2}}}
            """
        switch AGYStreamJSON.decodeLine(resultLine) {
        case .result(let payload):
            expect(payload.isSuccess, "对象 response 仍是 SUCCESS")
            expect(
                payload.response.contains("1+1等于2。"),
                "对象 response 必须编回 JSON 字符串，实际 \(payload.response)"
            )
        default:
            fail("对象 response 未解码")
        }
    }

    // MARK: - 启动合并

    /// 打开面板和提交必须共用同一次 spawn，否则会打死刚拉起的进程再开一个。
    private static func startCoordinatorCoalescesSpawn() {
        var coordinator = AGYStartCoordinator()
        expect(
            coordinator.ensure() == .spawn,
            "空闲第一次必须 spawn"
        )
        expect(
            coordinator.ensure() == .waitForExistingStart,
            "启动中第二次必须共用"
        )
        expect(
            coordinator.ensure() == .waitForExistingStart,
            "启动中第三次仍必须共用"
        )
        coordinator.didBecomeReady()
        expect(
            coordinator.ensure() == .alreadyReady,
            "ready 后不得再 spawn"
        )
        coordinator.didStop()
        expect(
            coordinator.ensure() == .spawn,
            "停下后下一次必须重新 spawn"
        )

        var aborted = AGYStartCoordinator()
        expect(aborted.ensure() == .spawn, "失败路径第一次 spawn")
        aborted.didStop()
        expect(
            aborted.ensure() == .spawn,
            "启动失败后必须允许再 spawn"
        )
    }

    private static func emptyStdoutWhileRunningIsNotClosed() {
        expect(
            !AGYStdoutEOF.isClosed(
                dataEmpty: true,
                processRunning: true
            ),
            "进程仍在跑时空 stdout 不得当成关闭"
        )
        expect(
            AGYStdoutEOF.isClosed(
                dataEmpty: true,
                processRunning: false
            ),
            "进程已退且 stdout 空才是关闭"
        )
        expect(
            !AGYStdoutEOF.isClosed(
                dataEmpty: false,
                processRunning: false
            ),
            "有数据时不是 EOF"
        )
    }

    // MARK: -

    private static func decodeJSON(_ line: String) -> [String: Any]? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        else { return nil }
        return obj
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        if !condition() { fail(message) }
        passed += 1
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(
            Data("助手 agy 通道失败：\(message)\n".utf8)
        )
        exit(1)
    }
}
