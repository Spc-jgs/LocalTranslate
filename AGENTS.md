# AGENTS.md · LocalTranslate 开发契约

本文件约束 LocalTranslate 的代码修改、验证与发布。目标是保持它作为 macOS 本机轻量工具箱的特性隔离、低空闲开销和可解释的实时体验。

## 1. 开始与完成

修改前依次完成：

1. 运行 `git status --short --branch`，确认当前分支、用户改动和远端关系；用户改动原样保留。
2. 只读取本任务涉及的 Feature、共享配置和工作流。目录与快捷键以源码为准，不在本文缓存完整文件树。
3. 涉及 SDK、API、CLI 或 GitHub Actions 时，先用 Context7 查询当前官方文档。
4. 涉及实时字幕时，先定位链路中的故障阶段，再决定实现；Prompt 和 Ollama 模型不是源转录、revision 或 UI 状态错误的替代修复。

交付前分别报告以下证据，不把其中一项代替另一项：

- **Source**：实现和不变量是否存在；
- **Build**：本机或 CI 是否完成 Xcode Release 构建；
- **Runtime**：权限、资源释放和真实音频链路是否运行验证；
- **Experience**：快速访谈、长句和字幕视觉是否由用户验收；
- **External**：GitHub Issue、标签、Release 和产物是否真实存在。

没有证据的层级标记为 `UNKNOWN`。用户明确负责体验验收时，不代替用户启动 App 或播放测试媒体，只做其授权范围内的构建、CI 和静态核对。

## 2. 架构边界

### 特性隔离

`Features/Translate`、`Features/LiveSubtitles` 与 `Features/AIUsage` 是独立微工具。共享层保持轻量，Feature 之间不直接持有彼此的状态机或重型服务。

- 未激活 Feature 不启动采集、识别、模型、子进程或目录扫描。
- 文件枚举、日志解析、子进程和网络 I/O 在后台执行，不阻塞 `MainActor`。
- UI 首帧优先读取内存或磁盘快照；刷新动作与已有内容解耦。
- 暂停或关闭功能时，以资源实际释放作为完成条件，而不是仅隐藏窗口。

### AI 用量

- 模型按 `modelID` 全局归一；账号卡片只展示账号配额与时间汇总，不复制模型明细。
- 单个 Provider 失败走软失败：保留已成功数据，并回退到 `UsageDiskCache` 或本地日志；错误不使整页失效。
- 扫描 AGY/Grok 会话前比较文件大小与 `mtime`，命中增量缓存时跳过内容解析。
- 切到 AI 用量页的首帧不创建子进程或执行全量扫描。

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

## 4. 权限与生命周期

- 实时字幕声明 `NSAudioCaptureUsageDescription` 与 `NSSpeechRecognitionUsageDescription`，不声明麦克风权限。
- 截图 OCR 在用户触发时单独请求 Screen Recording 权限；实时字幕链路不复用该权限。
- 划词优先使用 Accessibility API，失败时才走复制/剪贴板恢复兜底。
- 启动顺序允许 ASR 资源准备与 Ollama 预热并行；模型和识别 ready 后才开始采集，避免首请求承担冷启动。
- 停止必须覆盖：取消 UI/翻译任务、调用 `speechRecognizer.stop()`、调用 `audioCaptureService.stopCapture()`，以及请求 Ollama 卸载模型；音频资源内部按 IOProc -> aggregate device -> process tap 的顺序销毁。
- 会话切换、语言切换、暂停和窗口关闭都生成新的生命周期身份，旧异步回调不得复活已停止状态。

## 5. 构建、CI 与发布

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

- CI 显式选择 Xcode 26.x；步骤名称、实际 Xcode 和 SDK 版本必须一致。
- App 使用显式 `LocalTranslate/App/Info.plist`。新增权限后既检查 build settings，也检查最终 `.app/Contents/Info.plist`。
- 自动发布产物当前未签名、未公证；Release 构建成功不等于 Gatekeeper、权限或体验验证成功。
- 发布顺序：版本号提交 -> `main` CI 成功 -> annotated tag -> Release workflow 成功 -> 核对 DMG/ZIP 的名称、状态、大小与 digest。
- Release workflow 使用 GitHub CLI 创建或覆盖产物，保持 tag 重跑幂等。

提交信息使用 `<type>(<scope>): <中文描述>`。提交和推送仅在用户授权后执行；标签与 Release 创建必须有明确发布授权。
