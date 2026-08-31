# LocalTranslate

LocalTranslate 是一个面向 macOS 的本机轻量工具箱，把划词翻译、截图 OCR 翻译、系统音频实时字幕和 AI 用量看板放在同一个菜单栏 App 中。翻译与语音内容默认只发送到本机 Ollama。

当前已发布版本：[v1.5.0](https://github.com/Spc-jgs/LocalTranslate/releases/tag/v1.5.0)

## 功能

### 本机翻译

- `⌥⇧T`：读取当前选中文本并打开完整翻译面板；支持编辑、翻译风格、复制和置顶。
- `⌥⇧D`：在鼠标附近显示轻量翻译气泡。
- `⌥⇧S`：调用 macOS 交互式框选，使用 Apple Vision 在本机 OCR，再交给 Ollama 翻译。
- 默认 Ollama 地址是 `http://127.0.0.1:11434`，默认模型是 `qwen3.5:4b`；地址、模型、keep-alive 和翻译风格可在设置中修改。

### 实时字幕

- `⌥⇧C`：打开、暂停或恢复实时字幕。
- 源语言、字幕呈现与字号可在字幕条工具栏或设置的「实时字幕」页调整。
- 使用 Core Audio private process tap 捕获系统输出，不安装虚拟声卡，也不创建屏幕共享流。
- 使用 Apple `SpeechAnalyzer` / `SpeechTranscriber` 做端侧增量 ASR，再使用本地 Ollama 翻译。
- 支持英语、日语、韩语、普通话、粤语、法语、德语、西班牙语和俄语；可切换双语、仅译文或仅原文。
- 当前译文保持高亮，已确认历史字幕不因后续识别 revision 被改写。

实时链路不是“每次 partial 全文重翻”，而是两个并行状态：

```text
system audio -> ASR -> committed transcript + volatile partial
                    -> semantic segmentation
                    -> committed translation + preview translation
                    -> immutable history + highlighted current caption
```

audio range 用于消除 rolling overlap；`sessionID / segmentID / revision` 用于拦截旧 Ollama 响应。第一条当前译文可以 append-only 流式出现，后续 revision 原子更新，减少闪烁和语义跳变。

### AI 用量看板

- 汇总本机 Codex、Claude、Antigravity、Grok 与百炼 Token Plan 数据源。
- 账号来源可配置：Codex 账号可增删改（每个对应一个 `CODEX_HOME` 目录），
  其余固定路径来源可单独启停。入口在用量页右上角「账号来源」。
- 模型用量按 `modelID` 全局归一，账号卡片聚焦配额窗口和时间汇总。
- Antigravity 运行时优先从其本机 language server 读取 Gemini 与 Claude/GPT 的
  5 小时、每周额度；本机会话库提供可验证时间时统计模型 Token，尚无事件时间时
  只保留零 Token 模型证据并标明等待落盘。
- 使用内存与磁盘增量缓存；单个 Provider 失败时保留其他可用数据。

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
| `⌥⇧S` | 截图 OCR 翻译 |
| `⌥⇧C` | 实时字幕 |
| `⌘↩` | 在翻译面板中立即翻译 |
| `Esc` | 隐藏浮窗或取消截图 |
| `⌘,` | 打开设置 |

快捷键当前不可自定义。若某个组合已被其他 App 占用，设置页的「全局快捷键」会标记为「已被占用」。

## 隐私与资源

- 文本、截图 OCR 结果和语音转录默认只发送到 `127.0.0.1` 的 Ollama；如果修改 Ollama Base URL，数据边界随该配置变化。
- 截图在临时目录中生成，读取后删除。
- 实时字幕暂停或关闭时会结束识别输入，并销毁 IOProc、aggregate device 和 process tap，同时取消翻译任务并请求卸载模型。
- AI 用量模块读取本机客户端数据；Antigravity 额度请求只连接 `127.0.0.1`
  上已运行的 language server，相关客户端自身仍可能访问网络刷新官方额度。

## 已知限制

- v1.2.0 已优先解决 partial/final 混合、源转录重复、stale response 覆盖和字幕全文闪烁。
- v1.5.0 修复 AGY 用量的事件时间来源：Token 此前因时间戳解析落空而无法归入当日，
  现按会话库 `steps` 表的事件时间归日。
- 快速访谈与长句场景仍可能感知约 2 秒端到端时差，后续优化记录在 [Issue #3](https://github.com/Spc-jgs/LocalTranslate/issues/3)。优化不会以恢复全文跳变或修改 committed 字幕为代价。
- Release 产物尚未做 Developer ID 签名与 Apple notarization。

## 开发

状态测试（实时字幕增量契约与 AI 用量增量索引）：

```bash
./Scripts/run-state-tests.sh
```

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
