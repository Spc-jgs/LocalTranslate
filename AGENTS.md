# AGENTS.md · LocalTranslate 架构与开发协作规范

本文档面向维护和扩展 **LocalTranslate** 项目的 AI Agent 与人类开发者。在对本项目进行任何修改、重构或新增功能前，请务必遵守以下架构原则与性能基准，严防代码与架构漂移。

---

## 1. 项目定位与核心设计哲学

- **本机轻量级小工具 (Native Micro-Tools Hub)**：项目为 macOS 用户提供无感常驻的个人 AI 工具集。
- **单工具完全解耦 (Strict Feature Isolation)**：每个微工具（如“翻译浮窗”、“实时字幕”、“AI 用量看板”）作为独立特性模块存在，彼此互不依赖，单工具异常不得影响其他工具正常运行。
- **按需加载与零空闲开销 (Lazy Loading & Zero Idle Cost)**：
  - 未激活的工具禁止在后台占用 CPU 或持有高内存对象。
  - 用户仅使用翻译功能时，AI 用量与实时字幕模块不得被加载，内存保持在最低基线（约 20~30MB）。
  - 实时字幕条关闭或暂停时，必须立即销毁 `SCStream` 音频采集进程与语音识别会话，释放麦克风/内录资源。
- **主线程绝对非阻塞 (Never Block MainActor)**：
  - 严禁在主线程执行文件枚举、全量日志解析、子进程创建（如 `codex app-server` / `zsh`）或网络 I/O。
  - 耗时任务一律派发至 `.utility` 或 `.background` QoS 异步后台任务。

---

## 2. 目录组织规范

本项目采用 Xcode 16+ `PBXFileSystemSynchronizedRootGroup` 目录同步机制，所有源代码严格按以下结构分层：

```
LocalTranslate/
├── App/                                # 应用入口与全局生命周期
│   ├── LocalTranslateApp.swift         # MenuBarExtra 常驻、AppDelegate、浮窗调度
│   └── Assets.xcassets                 # 全套 macOS AppIcon 与配色资源
│
├── Core/                               # 跨模块共享基础层（极轻量、无业务依赖）
│   ├── Config/
│   │   └── AppSettings.swift           # UserDefaults 统一配置管理
│   └── System/
│       └── ShellResolver.swift         # CLI 可执行文件寻址（带内存缓存与线程锁）
│
├── Features/                           # 业务微工具模块（每个模块完全自包含）
│   ├── Translate/                      # 翻译工具模块
│   │   ├── Models/
│   │   │   └── TranslationStyle.swift  # 翻译风格枚举与 Prompt 定义
│   │   ├── Services/
│   │   │   ├── OllamaClient.swift      # Ollama /api/chat 流式交互与语言识别
│   │   │   ├── ScreenshotOCRService.swift # Apple Vision 离线 OCR 与智能段落重组
│   │   │   ├── HotKeyManager.swift     # Carbon 全局热键 (⌥⇧T, ⌥⇧S, ⌥⇧C)
│   │   │   └── SelectedTextReader.swift# 屏幕取词 (Accessibility + 剪贴板兜底)
│   │   ├── ViewModels/
│   │   │   └── TranslationViewModel.swift # 翻译状态机与输入管理
│   │   └── Views/
│   │       ├── FloatingPanel.swift     # NSPanel 悬浮窗实现
│   │       ├── ContentView.swift       # 浮窗主交互界面
│   │       └── CleanTextScrollView.swift # 无滚动条流式文本容器
│   │
│   ├── LiveSubtitles/                  # 实时音视频同传中文字幕模块
│   │   ├── Models/
│   │   │   └── SubtitleItem.swift      # 字幕数据模型与源语言枚举
│   │   ├── Services/
│   │   │   ├── SystemAudioCaptureService.swift # ScreenCaptureKit 原生系统音频内录
│   │   │   ├── LiveSpeechRecognizer.swift      # Apple SFSpeechRecognizer 离线端侧 ASR
│   │   │   └── LiveTranslationService.swift    # 极简电影字幕流式翻译管线
│   │   ├── ViewModels/
│   │   │   └── LiveSubtitlesViewModel.swift    # 同传状态机与音频电平
│   │   └── Views/
│   │       ├── LiveSubtitlesOverlayPanel.swift # 底部悬浮置顶电影字幕窗
│   │       └── LiveSubtitlesView.swift         # 电影级磨砂字幕排版与交互控制
│   │
│   └── AIUsage/                        # AI 用量监控模块
│       ├── Models/
│       │   └── UsageModels.swift       # 领域数据模型 (QuotaWindow, TokenBreakdown)
│       ├── Services/
│       │   ├── CodexProvider.swift     # Codex JSON-RPC app-server 提取与优雅容错
│       │   ├── AGYProvider.swift       # AGY 步进 Protobuf 时间戳底层逆向提取
│       │   ├── AGYCacheStore.swift     # AGY 会话增量缓存管理
│       │   ├── GrokProvider.swift      # Grok CLI API 额度与增量日志扫描
│       │   ├── GrokCacheStore.swift    # Grok 磁盘增量缓存管理
│       │   └── UsageDiskCache.swift    # 全局用量快照持久化缓存
│       ├── ViewModels/
│       │   └── UsageStore.swift        # 数据调度中心 (单例常驻、并发聚合、预计算指标)
│       └── Views/
│           └── AIUsageView.swift       # 全模型归一分布、趋势图与账号卡片
│
├── Settings/                           # 统一设置窗口
│   └── SettingsView.swift              # 多分页懒加载装配容器
│
├── AGENTS.md                           # 本开发维护指南
└── README.md                           # 项目公开说明文档
```

---

## 3. 核心架构红线与防漂移守则

### 3.1 跨账号模型全局归一化（防重复漂移）
- **唯一展示原则**：全景模型用量看板中的模型必须按 `modelID` 全局合并归一。
- **禁止在单个账号卡片内重复展示模型列表**：账号卡片仅聚焦展示账号配额窗口（5h / Weekly / Reset）与用量时间汇总（今日 / 7天 / 30天 / 历史），模型明细统一收敛在顶部的“模型 Token 用量（按模型分组）”卡片中。

### 3.2 优雅降级与软失败机制（防 UI 报错漂移）
- **禁止单一子请求失败导致整卡崩溃**：
  - 当某个 Provider（如 OpenAI `codex app-server`）的 `account/usage/read` 接口网络超时或返回 `token usage profile fetch timed out` 时，**严禁抛出致命异常并展示黄色警告条**。
  - 必须保留已成功获取的账号身份与配额窗口，并无缝回退至本地 SQLite 日志或已持久化的磁盘快照（`UsageDiskCache`），将信任度标记为 `.medium`。

### 3.3 切页零开销与即时渲染（防体感卡顿漂移）
- **切页禁发子进程**：切换到“AI 用量”分页时，**禁止在首帧触发任何 `Process()` 子进程或全量磁盘扫描**。
- **快照即时呈现**：直接从内存及 `UsageDiskCache` 渲染已有快照（渲染耗时 < 1ms，120 FPS 丝滑切换）。
- **增量缓存保护**：扫描 `~/.grok/sessions` 与 `~/.gemini/antigravity/conversations` 必须严格核对 `fileSize` 与 `mtime`，命中缓存直接跳过磁盘 I/O（耗时 < 0.05ms）。

### 3.4 实时字幕资源释放与无感同传（防资源泄漏漂移）
- **关闭即销毁**：实时字幕浮窗关闭或用户暂停时，必须立即调用 `stopCapture()` 释放 `SCStream` 资源并停止 `SFSpeechRecognizer`，不得在后台静默录音或空转 CPU。
- **电影级视觉保护**：字幕条默认采用 `.ultraThinMaterial` 半透明黑色胶囊底色与高对比度白色文字（带暗阴影），确保在任意视频明亮背景下均清晰可读。

---

## 4. 构建与验证流程

每次修改后，请在终端执行以下检查确保无构建回归：

```bash
# 1. 编译构建测试
xcodebuild -project LocalTranslate.xcodeproj -scheme LocalTranslate build CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO

# 2. 检查 Git 状态与文件归位
git status
```
