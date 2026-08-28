# LocalTranslate · 本机 AI 小工具箱

<p align="center">
  <b>极轻量 · 零干扰 · 强隔离 · 本地隐私安全</b>
  <br>
  专为 macOS 打造的极简状态栏小工具集合：本地大模型即时划词/截图翻译 + 电影实时音视频同传中文字幕 + 多账号 AI 用量监控看板。
</p>

---

## 🌟 核心特性

### 1. 本地 AI 快捷翻译 (Local Translate)
- **本地 Ollama 驱动**：数据完全留存在本地，零外部网络 API 泄露风险；支持任何 Ollama 兼容模型（如 `qwen3.5:4b`、`deepseek-r1` 等）。
- **全局无感划词 (⌥⇧T)**：在任何 App 中选中文字后按 `⌥⇧T` 即可就近弹出翻译；支持 Accessibility API 智能读取，无权限时自动降级模拟复制并还原剪贴板。
- **秒级截图翻译 (⌥⇧S)**：
  - 硬件加速 Apple **Vision Framework (`VNRecognizeTextRequest`)** 离线 OCR，毫秒级精准提取文字。
  - 内置**智能段落重组算法 (Smart Paragraph Merging)**，自动连贯断句，消除大模型机械直译硬伤。
  - 零权限弹窗门槛，完全不污染系统剪贴板。
- **技术场景深度优化**：内置面向开发者与技术文档的 Prompt 保护规则，精准保留变量名、API 标识符、代码块、JSON Key 与 CLI 标志，绝不盲目汉化。
- **多种翻译风格**：内置“默认”、“自然”、“简洁”、“正式”、“直译”及“自定义 Prompt”风格，灵活应对日常阅读、代码注释或商务邮件。
- **智能交互浮窗**：自动贴靠鼠标坐标与屏幕边界，流式生成平滑展示，支持置顶钉住 (`Pin`)、`Esc` 退出与一键复制反馈。

### 2. 电影/音视频实时同传中文字幕 (Live Subtitles)
- **免装虚拟声卡**：基于 macOS 原生 **`ScreenCaptureKit`** 系统音频内录，无需安装任何 BlackHole / Soundflower 虚拟声卡驱动，即开即用。
- **端侧离线语音识别**：基于 Apple 原生 **`SFSpeechRecognizer`**（硬件加速），支持日语、韩语、英语、普通话、粤语等多语种实时流式转录。
- **电影级流式翻译 (⌥⇧C)**：复用本地大模型以“电影字幕”精炼口语风格毫秒级流式生成中文译文。
- **极简电影悬浮字幕条**：
  - 屏幕底部半透明深色磨砂胶囊底色；
  - 高对比度纯白主译文字体（带抗背景反光柔和阴影）+ 原文对照；
  - 悬停浮现控制栏：源语言切换、字号微调、动态音浪感知、鼠标穿透。

### 3. AI 用量监控看板 (AI Usage Hub)
- **全方位 Provider 汇聚**：
  - **Codex Plus A** (`~/.codex`)
  - **Codex Plus B** (`~/.codex_account2`)
  - **Antigravity (AGY)** (`~/.gemini/antigravity` 本地 SQLite 交互轨迹，底层 Protobuf 步进解析)
  - **SuperGrok** (`~/.grok`)
- **全景模型归一化看板**：按模型全局合并聚合 30 天 Token 消耗，支持 Fresh Input / Cache Read / Output / Reasoning 四维细分。
- **额度与重置周期**：实时读取官方 API 与会话限额，直观展示 5h 窗口、周度/月度额度使用百分比及下次重置时间点。
- **极速增量缓存引擎**：
  - 配合双层磁盘与内存增量缓存（`AGYCacheStore` 与 `GrokCacheStore`），实现 **< 0.05ms** 极速加载。
  - 切页零开销，120 FPS 丝滑切换。
- **交互式趋势图表**：
  - 基于 Swift Charts 展示 7 天 / 30 天每日 Token 消耗趋势（Codex + AGY + Grok 汇总）。
  - **鼠标悬停交互**：鼠标移动到任意柱/点上，实时浮现当天的确切 Token 数量、交互轮次与虚线定位标尺。

---

## 🏗️ 架构与资源隔离设计

本项目秉承 **“每个功能互不影响，单工具启动极低开销”** 的微工具哲学：

```
LocalTranslate/
├── App/                                # 应用入口与生命周期装配
│   ├── LocalTranslateApp.swift         # MenuBarExtra 常驻、AppDelegate、浮窗调度
│   └── Assets.xcassets                 # 全套 macOS AppIcon 与配色资源
│
├── Core/                               # 跨模块共享基础层（极轻量、无业务依赖）
│   ├── Config/AppSettings.swift        # UserDefaults 统一配置管理
│   └── System/ShellResolver.swift      # CLI 路径解析（带内存并发缓存）
│
├── Features/                           # 业务微工具特性模块（完全解耦）
│   ├── Translate/                      # 翻译工具
│   │   ├── Models/                     # 翻译风格定义
│   │   ├── Services/                   # Ollama 客户端、全局快捷键、划词读取、Vision 截图 OCR
│   │   ├── ViewModels/                 # 翻译状态机
│   │   └── Views/                      # 悬浮面板、主界面、无滚动条流式文本框
│   │
│   ├── LiveSubtitles/                  # 实时音视频同传中文字幕
│   │   ├── Models/                     # 字幕模型 (SubtitleItem)
│   │   ├── Services/                   # ScreenCaptureKit 内录、Apple ASR 识别、流式字幕翻译
│   │   ├── ViewModels/                 # 同传状态机与音频电平 (LiveSubtitlesViewModel)
│   │   └── Views/                      # 电影级半透明磨砂字幕浮窗 (LiveSubtitlesView)
│   │
│   └── AIUsage/                        # AI 用量看板
│       ├── Models/                     # 统一领域模型 (AccountSnapshot, TokenBreakdown)
│       ├── Services/                   # Codex 容错 Runner、AGY Protobuf 扫描器、Grok 扫描器、增量缓存
│       ├── ViewModels/                 # 并发调度中心 (UsageStore)
│       └── Views/                      # 全景模型分布、趋势图表与各账号卡片
│
├── Settings/                           # 个人工具箱集中设置 (780x640 统一原生窗口)
│   └── SettingsView.swift              # 多分页懒加载导航
│
├── AGENTS.md                           # AI Agent 与开发者协作规范
└── README.md                           # 本说明文档
```

---

## ⚙️ 快捷键速查

| 快捷键 | 功能说明 | 触发场景 |
| :--- | :--- | :--- |
| `⌥ ⇧ T` | **智能取词翻译 / 呼出浮窗** | 全局任何应用程序中 |
| `⌥ ⇧ S` | **交互式截图翻译** | 全局任何应用程序中 |
| `⌥ ⇧ C` | **开启/暂停/隐藏实时音视频中文字幕条** | 看电影/视频/YouTube/Netflix 时 |
| `⌘ ↩` | **立即翻译 / 重新翻译** | 翻译浮窗激活时 |
| `Esc` | **隐藏浮窗 / 取消截图** | 浮窗激活或截图框选时 |
| `⌘ ,` | **打开个人工具设置** | 任意界面 |

---

## 🤝 开发者与协作规范

若需对本项目进行扩展或提交代码，请参阅 [AGENTS.md](file:///Users/shaopc/playground/LocalTranslate-macos/LocalTranslate/AGENTS.md) 了解详细的架构约束、性能红线与测试要求。
