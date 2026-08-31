# AGENTS.md · LocalTranslate 开发契约

本文件约束 LocalTranslate 的代码修改、验证与发布。目标是保持它作为 macOS 本机轻量工具箱的特性隔离、低空闲开销和可解释的实时体验。

## 1. 开始与完成

修改前依次完成：

1. 运行 `git status --short --branch`，确认当前分支、用户改动和远端关系；用户改动原样保留。
2. 只读取本任务涉及的 Feature、共享层和工作流。目录与快捷键以源码为准，不在本文缓存完整文件树。
3. 涉及 SDK、API、CLI 或 GitHub Actions 时，先用 Context7 查询当前官方文档。
4. 涉及实时字幕时，先定位链路中的故障阶段，再决定实现；Prompt 和 Ollama 模型不是源转录、revision 或 UI 状态错误的替代修复。

交付前分别报告以下证据，不把其中一项代替另一项：

- **Source**：实现和不变量是否存在；
- **Test**：`./Scripts/run-state-tests.sh` 是否全绿；
- **Build**：本机或 CI 是否完成 Xcode Release 构建；
- **Runtime**：权限、资源释放和真实音频链路是否运行验证；
- **Experience**：快速访谈、长句和字幕视觉是否由用户验收；
- **External**：GitHub Issue、标签、Release 和产物是否真实存在。

没有证据的层级标记为 `UNKNOWN`。用户明确负责体验验收时，不代替用户启动 App 或播放测试媒体，只做其授权范围内的构建、测试、CI 和静态核对。

## 2. 架构边界

### 特性隔离

`Features/Translate`、`Features/LiveSubtitles` 与 `Features/AIUsage` 是独立微工具。Feature 之间不直接持有彼此的状态机或重型服务。

- 未激活 Feature 不启动采集、识别、模型、子进程或目录扫描。
  「激活」的判据是这些资源是否真的开始工作，而不是某个类型是否被构造：
  `LiveSubtitlesViewModel` 的 `SpeechAnalyzer` 与 `SpeechTranscriber` 在 `start()`
  才创建，因此设置界面读取它的语言与字号不算激活。
- 文件枚举、日志解析、子进程和网络 I/O 在后台执行，不阻塞 `MainActor`。
- UI 首帧优先读取内存或磁盘快照；刷新动作与已有内容解耦。
- 暂停或关闭功能时，以资源实际释放作为完成条件，而不是仅隐藏窗口。

### 共享层

`Core/` 只放**不含 Feature 状态机**的东西。传输、配置与尺寸计算属于共享层；
会话、模型生命周期与业务状态留在各自 Feature。

- `Core/Config/AppSettings.swift` 是**全部** UserDefaults key 与默认值的唯一出处。
  任何 Feature 都不内联裸字符串 key：key 一旦分散，读与写就会各自漂移。
- `Core/Ollama/OllamaEndpoint.swift` 是 Ollama 地址解析的唯一出处，
  含 `localhost -> 127.0.0.1` 规避（URLSession 会优先解析 `::1`，而 Ollama
  默认只监听 IPv4）。`OllamaClient` 与 `LiveTranslationService` 都调用它，
  两者仍各自持有自己的请求协调器。
- `Core/UI/TextHeightMeasurer.swift` 用 TextKit 实测文本高度，带上界缓存。
  **禁止**用「字符数 ÷ 每行字数」估算行数：该启发式对中西文字宽差异
  （约 2:1）无能为力，也不感知翻译方向。
- `Core/UI/TranslatePanelLayout.swift` / `MiniHUDLayout` 是窗口高度与内容高度的
  唯一出处。窗口高度按定义等于「基础高度 + 内容相对空态的增量」，
  SwiftUI 视图与 `AppDelegate` 调用同一组函数。

### 单一真值

以下几何量各自只有一个出处，新增调用方必须复用而不是复制：

| 量 | 出处 |
| --- | --- |
| 翻译浮窗宽高与内容高度 | `TranslatePanelLayout` |
| 划词气泡宽高与内容高度 | `MiniHUDLayout` |
| 字幕条宽度、折叠/展开高度、圆角 | `LiveSubtitlesOverlayLayout`，宽度由 `LiveSubtitlesOverlayPanel` 持有 |
| 全局快捷键键码、修饰键、防抖与展示名 | `HotKeyAction` |

字幕条宽度依赖屏幕，必须响应 `NSApplication.didChangeScreenParametersNotification`；
只在单例初始化时按 `NSScreen.main` 算一次是错误的。

### 快捷键

- 快捷键定义集中在 `HotKeyAction`，新增一个键只加一个 case。
- `RegisterEventHotKey` 的返回值必须检查。注册失败写入 `HotKeyRegistry`
  并在设置页显示为「已被占用」；静默失败会让用户以为是功能坏了。

### AI 用量

- 账号来源由 `UsageProviderSettings` 持久化，**不得**硬编码在 `UsageStore` 里。
  Codex 账号可增删改（每个对应一个 `CODEX_HOME` 目录），其余固定路径来源可启停。
  首次运行按本机实际存在的目录推断，不假设某种固定布局。
- 删除账号后同时清理其快照与错误，避免看板上留下无来源的卡片。
- 模型按 `modelID` 全局归一；账号卡片只展示账号配额与时间汇总，不复制模型明细。
- 单个 Provider 失败走软失败：保留已成功数据，并回退到 `UsageDiskCache` 或本地日志；错误不使整页失效。
- 本机 Provider 日志是用量事实源；`UsageIndex` SQLite 只保存可重建的数字事件、文件游标和刷新状态，不保存 prompt、回复或工具正文。
- 扫描前比较文件 `inode`、大小与 `mtime`，命中增量索引时跳过内容解析；索引写入走单一后台执行器和文件级事务，损坏库隔离后重建。
- 上游日志只提供模型身份而尚无 Token 时，保留零 Token 的模型证据并标明等待落盘；没有官方真值的额度、Credits 或费用保持不可用，不从 Token 反推。
- 外部 SQLite（如 AGY 会话库）始终只读；存在 WAL sidecar 时按正常只读连接读取，缺少 sidecar 的 WAL 快照才使用 immutable URI。
- 切到 AI 用量页的首帧不创建子进程或执行全量扫描。
- 仪表盘聚合（`UsageDashboardSnapshot`）由 `UsageStore` 按 `accounts + range`
  计算一次并持有。**不得**写成 View 的计算属性：那会让这段多趟遍历跟着每一次
  body 求值重跑。同理，不保留没有任何视图读取的预计算指标。

## 3. 实时字幕稳定增量契约

实时字幕的数据流固定为：

```text
Core Audio process tap
  -> SpeechAnalyzer / SpeechTranscriber
  -> audio-range transcript ledger
  -> committed transcript + volatile partial
  -> semantic window planner
  -> Ollama request coordinator
  -> committed translation + preview translation
  -> current-highlighted overlay + immutable history
```

### 音频与 ASR

- 实时字幕只用 Core Audio private process tap 捕获系统输出，不创建 display-level `SCStream`。截图 OCR 的屏幕采集是独立、显式触发的功能。
- PCM buffer 按时间顺序送入一个识别会话；rolling input 如有重叠，使用 audio range 对账。
- volatile partial 是同一时间范围的**可替换快照**，不是追加日志。新结果替换相交的 volatile span。
- finalized span 是 committed transcript。相同 audio range 只 commit 一次，commit 后不被后续 partial 覆盖或重复追加。
- 源转录出现重复或错序时，先检查 rolling overlap、span range、finalization frontier 和 ledger merge，再检查模型翻译。

### 分段与翻译

- preview 面向当前讲话，允许从安全的短前缀启动；短语动词、连词或明显未闭合尾词继续等待最小上下文。
- committed window 依据标点、时长、词数与安全尾词形成语义块；长句允许在从句边界切开，不等待完整自然句。
- finalized transcript 进入历史窗口；volatile transcript 只驱动当前 preview。两者保留独立身份。
- live preview 优先占用 Ollama worker；active speech 期间 archive 不与当前字幕竞争，静音或停止后再补历史翻译。
- 首条 preview 可以 append-only 流式展示；后续 revision 原子更新，避免逐 token 全文重写。

### 身份与 UI

- 每个请求携带 `sessionID + segmentID + revision + kind + audioRange`。响应发布前必须仍匹配当前会话和 revision；stale response 只记录并丢弃。
- committed translation 只写入一次。后续 ASR、preview 或 Ollama 响应不得回写已 commit 字幕。
- UI 将正在说的译文作为最高视觉层级；历史字幕降权。切换历史项使用淡入淡出或小幅纵向过渡，不使用横向滑出。
- UI 分开呈现 preview 与 committed 状态；unstable translation 不伪装成 final，也不触发历史列表全量刷新。

### 延迟预算

延迟优化以 monotonic timing 拆分：

```text
audio ingress -> ASR volatile -> segment ready
-> Ollama request -> first byte -> first visible translation -> commit
```

分别观察首屏、持续追赶和句尾 commit。降低某一阶段延迟时，以下稳定性不变量必须保持为绿：无源转录重复/错序、无 stale 覆盖、无 committed 回写、无全文闪烁。当前快速访谈约 2 秒时差记录在 GitHub Issue #3，属于后续性能项，不通过放宽这些不变量换取数字。

**调整 planner 参数（`minimumWords` / `maximumWords` / `targetDuration` /
`lookaheadWords`）必须同时运行 `./Scripts/run-state-tests.sh`。** 历史教训：
commit 9c61419 为降低延迟把 `maximumWords` 从 16 降到 12、`lookaheadWords`
从 2 降到 1，两个用例随即变红并在多个版本里无人发现——因为当时没有任何
自动化在运行它们。断言应表达不变量（窗口有界、不消费前瞻、不以未闭合尾词
收尾），而不是写死某个具体词数。

## 4. 权限与生命周期

- 实时字幕声明 `NSAudioCaptureUsageDescription` 与 `NSSpeechRecognitionUsageDescription`，不声明麦克风权限。
- 截图 OCR 在用户触发时单独请求 Screen Recording 权限；实时字幕链路不复用该权限。
- 截图临时文件在成功与失败路径上都必须删除，与 README 的隐私承诺一致。
- 划词优先使用 Accessibility API，失败时才走复制/剪贴板恢复兜底。
- 启动顺序允许 ASR 资源准备与 Ollama 预热并行；模型和识别 ready 后才开始采集，避免首请求承担冷启动。
- 停止必须覆盖：取消 UI/翻译任务、调用 `speechRecognizer.stop()`、调用 `audioCaptureService.stopCapture()`，以及请求 Ollama 卸载模型；音频资源内部按 IOProc -> aggregate device -> process tap 的顺序销毁。
- 会话切换、语言切换、暂停和窗口关闭都生成新的生命周期身份，旧异步回调不得复活已停止状态。
- 不引入会让窗口整体停止接收鼠标事件的开关。曾经加过字幕条「点击穿透」：
  开启后字幕条无法拖动、暂停与关闭按钮全部失效，而恢复入口在菜单栏，
  且状态被持久化，重启也不恢复——等于永久锁死。这类开关如果确有需要，
  必须同时满足：图标与文案自解释、hover 时临时恢复交互、不持久化。
  在满足之前不提供入口，也不保留无入口的实现。

## 5. 测试

```bash
./Scripts/run-state-tests.sh
```

- `Tests/` 下每个文件是独立的 `@main` 可执行程序，各自有入口，因此**分别编译**，
  不能合并进同一个 target。新增测试时在脚本里加一个 `run_suite`，
  并显式列出它依赖的源文件。
- `AIUsageRealCorpusSmoke` 读取真实的 `~/.codex` 等目录，只在本机有意义，
  不进 CI。
- CI 在 Release 构建**之前**运行该脚本。测试只写在设计文档里而不接入自动化，
  等同于没有测试。

## 6. 构建、CI 与发布

项目当前最低系统与 SDK 边界是 macOS 26 / Xcode 26，因为 `SpeechAnalyzer` 与 `SpeechTranscriber` 直接参与编译。

```bash
xcodebuild -project LocalTranslate.xcodeproj \
  -scheme LocalTranslate \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  build \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO

git diff --check
git status --short --branch
```

- Xcode 项目使用 `PBXFileSystemSynchronizedRootGroup`：`LocalTranslate/` 下新增的
  `.swift` 文件自动进入构建，不需要改 `project.pbxproj`。
- 项目仍是 `SWIFT_VERSION = 5.0`。新代码不应引入新的 Swift 6 并发警告；
  纯配置与纯计算类型标 `nonisolated`，避免被默认 actor 推断卷入 `MainActor`。
- CI 显式选择 Xcode 26.x；步骤名称、实际 Xcode 和 SDK 版本必须一致。
- App 使用显式 `LocalTranslate/App/Info.plist`。新增权限后既检查 build settings，也检查最终 `.app/Contents/Info.plist`。
- 自动发布产物当前未签名、未公证；Release 构建成功不等于 Gatekeeper、权限或体验验证成功。
- 发布顺序：版本号提交 -> `main` CI 成功 -> annotated tag -> Release workflow 成功 -> 核对 DMG/ZIP 的名称、状态、大小与 digest。
- README 的「当前已发布版本」必须与实际存在的 tag 一致；`MARKETING_VERSION`
  领先于 tag 时要写明尚未发布。
- Release workflow 使用 GitHub CLI 创建或覆盖产物，保持 tag 重跑幂等。

提交信息使用 `<type>(<scope>): <中文描述>`。提交和推送仅在用户授权后执行；标签与 Release 创建必须有明确发布授权。
