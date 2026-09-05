# LocalTranslate

LocalTranslate 是一个面向 macOS 的本机轻量工具箱，把划词翻译、截图 OCR 翻译、系统音频实时字幕和 AI 用量看板放在同一个菜单栏 App 中。翻译与语音内容默认只发送到本机 Ollama。

当前已发布版本：[v1.7.0](https://github.com/Spc-jgs/LocalTranslate/releases/tag/v1.7.0)

## 功能

### 本机翻译

- `⌥⇧T`：读取当前选中文本并打开完整翻译面板；支持编辑、翻译风格、复制和置顶。
- `⌥⇧D`：在鼠标附近显示轻量翻译气泡。
- `⌥⇧S`：调用 macOS 交互式框选，使用 Apple Vision 在本机 OCR，再交给 Ollama 翻译。
- 源语言由原文自动识别，无需选择；目标语言可在设置中选择（简体中文、繁體中文、
  英、日、韩、法、德、西、俄）。原文本身已是目标语言时，中文与英文互译，
  其余语言译为简体中文。
- 原文与译文各有一个朗读按钮，使用系统语音在本机合成，不联网。译文的语音语言即目标
  语言；原文按字形与识别结果判定，单个拉丁词识别不可靠时按英文朗读。
- 默认 Ollama 地址是 `http://127.0.0.1:11434`，默认模型是 `qwen3.5:4b`；地址、模型、keep-alive 和翻译风格可在设置中修改。

### 词义分诊

- `⌥⇧E`：读取选词及两侧有限上下文，用本地模型在三句内判断“解释已够用”或
  “建议核对”。它是阅读分诊器，不承担百科问答、联网事实核验或连续追问。
- commit、CVE、年份/版本、当前状态、高风险结论与提示词注入由确定性规则直接
  升级，不让小模型用自报置信度放行。
- 需要核对时，可预览并复制有长度上限的交接内容，再打开 ChatGPT；网页不会
  自动粘贴或发送，App 也不保存选词、上下文或解释。

### 实时字幕

- `⌥⇧C`：打开、暂停或恢复实时字幕。
- 源语言、字幕呈现与字号可在字幕条工具栏或设置的「实时字幕」页调整。
- 使用 Core Audio private process tap 捕获系统输出，不安装虚拟声卡，也不创建屏幕共享流。
- 使用 Apple `SpeechAnalyzer` / `SpeechTranscriber` 做端侧增量 ASR，再使用本地 Ollama 翻译。
- 支持英语、日语、韩语、普通话、粤语、法语、德语、西班牙语和俄语；可切换双语、仅译文或仅原文。
- 字幕条是固定的三行：上一句译文降权在最上，当前译文居中高亮，当前原文在最下。
  三行的位置和高度全程不变，不会因为有没有译文而跳动。
- 当前译文以续写方式增长——已经显示出来的字不会被改写。整句定稿是唯一一次可以
  推翻先前措辞的机会，它定稿后进入上一行，主行随之翻到下一句。
- 已确认的历史字幕不因后续识别 revision 被改写。

实时链路不是“每次 partial 全文重翻”，而是两个并行状态：

```text
system audio -> ASR -> committed transcript + volatile partial
                          ├─ semantic window planner (翻译单元) -> 整句定稿
                          └─ caption pager           (显示单元) -> preview
                    -> committed translation + preview translation
                    -> immutable history + highlighted current caption
```

翻译单元和显示单元是分开的：planner 按标点、时长和词数切出送去翻译的窗口，
主行显示到哪由字幕自己攒页决定。两者共用边界时，planner 每切走一段主行就会
凭空缩水。

audio range 用于消除 rolling overlap；`sessionID / segmentID / revision` 用于拦截旧 Ollama 响应。preview 请求把已显示的译文作为末尾 assistant 消息送出，模型只能往后写，因此屏幕上的字不会被改写。

调整字幕节奏时可以在设置的「实时字幕」页打开「节奏诊断日志」，会话总表写到
`~/.localtranslate/live-subtitles/`，记录每句在屏幕上变了几次、被擦掉重写多少字
以及字幕落后语音多少秒。默认关闭——不写盘是实时字幕的资源基线。

### AI 用量看板

- 汇总本机 Codex、Claude、Antigravity、Grok 与百炼 Token Plan 数据源。
- 账号来源可配置：Codex 账号可增删改（每个对应一个 `CODEX_HOME` 目录），
  其余固定路径来源可单独启停。入口在用量页右上角「账号来源」。
- 模型用量按 `modelID` 全局归一，账号卡片聚焦配额窗口和时间汇总。
- Antigravity 运行时优先从其本机 language server 读取 Gemini 与 Claude/GPT 的
  5 小时、每周额度；本机会话库提供可验证时间时统计模型 Token，尚无事件时间时
  只保留零 Token 模型证据并标明等待落盘。
- 使用内存与磁盘增量缓存；单个 Provider 失败时保留其他可用数据。
- 首次索引大量历史日志时分片进行，卡片上显示「已索引 x/y 个文件」并标明当前
  数字尚不完整，补齐完成后自动消失。

## 环境要求

- macOS 26 或更高版本；
- Xcode 26.x（从源码构建时）；
- 已安装并运行 [Ollama](https://ollama.com/)；
- 至少一个本地翻译模型。

首次使用可以准备默认模型：

```bash
ollama pull qwen3.5:4b
ollama serve
```

如果 Ollama 已由桌面 App 启动，不需要重复执行 `ollama serve`。

## 安装与运行

从 [Releases](https://github.com/Spc-jgs/LocalTranslate/releases) 下载 DMG 或 ZIP。当前自动发布产物未签名、未公证，首次打开可能被 Gatekeeper 阻止；可在 Finder 中按住 Control 点击 App，选择“打开”，并确认来源。

也可以在 Xcode 26 中打开 `LocalTranslate.xcodeproj`，选择 `LocalTranslate` scheme 后运行。

## 权限边界

| 权限 | 触发功能 | 用途 |
| --- | --- | --- |
| 辅助功能 | 划词翻译 | 读取当前选中文本；必要时模拟复制并恢复剪贴板 |
| 屏幕与系统音频录制 | 截图 OCR | 仅在用户按 `⌥⇧S` 框选屏幕时请求 |
| 系统音频录制 | 实时字幕 | 通过 Core Audio process tap 读取系统输出 |
| 语音识别 | 实时字幕 | 将系统音频转换为增量源文本 |

实时字幕不使用麦克风，也不使用 ScreenCaptureKit display stream。截图 OCR 的屏幕权限与实时字幕链路相互独立。

## 快捷键

| 快捷键 | 功能 |
| --- | --- |
| `⌥⇧T` | 划词翻译 / 完整面板 |
| `⌥⇧D` | 划词翻译气泡 |
| `⌥⇧E` | 本地词义分诊；需要时复制上下文并打开 ChatGPT |
| `⌥⇧S` | 截图 OCR 翻译 |
| `⌥⇧C` | 实时字幕 |
| `⌘↩` | 在翻译面板中立即翻译 |
| `Esc` | 隐藏浮窗或取消截图 |
| `⌘,` | 打开设置 |

快捷键当前不可自定义。若某个组合已被其他 App 占用，设置页的「全局快捷键」会标记为「已被占用」。

## 隐私与资源

- 文本、截图 OCR 结果和语音转录默认只发送到 `127.0.0.1` 的 Ollama；如果修改 Ollama Base URL，数据边界随该配置变化。
- 词义分诊不自动向外部服务发送内容；只有用户点击交接按钮时，才把选词、周围上下文和本地解释复制到剪贴板并打开 ChatGPT。网页不会自动粘贴或提交。
- 截图在临时目录中生成，读取后删除。
- 实时字幕暂停或关闭时会结束识别输入，并销毁 IOProc、aggregate device 和 process tap，同时取消翻译任务并请求卸载模型。
- AI 用量活动读取本机客户端数据；刷新额度时，Codex 可能通过本机 app-server
  使用现有登录态，Grok 会访问其官方额度服务。Antigravity 额度请求只连接
  `127.0.0.1` 上已运行的 language server。LocalTranslate 不代用户登录账号。

## 已知限制

- v1.2.0 已优先解决 partial/final 混合、源转录重复、stale response 覆盖和字幕全文闪烁。
- v1.5.0 修复 AGY 用量的事件时间来源：Token 此前因时间戳解析落空而无法归入当日，
  现按会话库 `steps` 表的事件时间归日。
- 快速访谈与长句场景仍可能感知约 2 秒端到端时差，后续优化记录在 [Issue #3](https://github.com/Spc-jgs/LocalTranslate/issues/3)。优化不会以恢复全文跳变或修改 committed 字幕为代价。
- Release 产物尚未做 Developer ID 签名与 Apple notarization。

## 开发

状态测试（实时字幕增量契约、AI 用量与分诊安全规则）：

```bash
./Scripts/run-state-tests.sh
```

分诊模型的 20 例 V0 门禁（需要本机 Ollama，默认 `qwen3.5:4b`）：

```bash
./Scripts/run-triage-eval.sh
```

脚本直接提取 App 使用的 prompt，输出 TSV 对照表；`expected=escalate` 却被模型
判为 `enough` 的 false-safe 超过 2 例时失败。解释的事实正确性仍需按 reference
人工复核。

Release 构建：

```bash
xcodebuild -project LocalTranslate.xcodeproj \
  -scheme LocalTranslate \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  build \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO
```

GitHub Actions 在 `macos-15` runner 上显式选择 Xcode 26.x，先跑状态测试再执行 Release 构建。推送到 `main` 会执行 CI；推送 `v*` 标签会生成 DMG 和 ZIP，并创建 GitHub Release。

架构不变量、实时字幕增量契约、权限检查和发布流程见 [AGENTS.md](AGENTS.md)。
