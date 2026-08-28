# AGENTS.md · LocalTranslate 架构与开发协作规范

本文档面向维护和扩展 **LocalTranslate** 项目的 AI Agent 与人类开发者。在对本项目进行任何修改、重构或新增功能前，请务必遵守以下架构原则与性能基准。

---

## 1. 项目定位与核心设计哲学

- **本机轻量级小工具 (Native Micro-Tools Hub)**：项目为 macOS 用户提供无感常驻的个人 AI 工具集。
- **单工具完全解耦 (Strict Feature Isolation)**：每个工具（如“翻译浮窗”、“AI 用量看板”）作为独立特性模块存在，彼此互不依赖，单工具异常不得影响其他工具正常运行。
- **按需加载与零空闲开销 (Lazy Loading & Zero Idle Cost)**：
  - 未激活的工具禁止在后台占用 CPU 或持有高内存对象。
  - 用户仅使用翻译功能时，AI 用量模块不得被加载，内存保持在最低基线（约 20~30MB）。
  - 设置页面切出或窗口关闭时，必须挂起或销毁后台定时刷新任务。
- **主线程非阻塞 (Never Block MainActor)**：
  - 严禁在主线程执行文件枚举、全量日志解析、子进程创建（如 `codex app-server` / `zsh`）或网络 I/O。
  - 耗时任务一律派发至 `.utility` 或 `.background` QoS 后台任务。

---

## 2. 目录组织规范

本项目采用 Xcode 16+ `PBXFileSystemSynchronizedRootGroup` 目录同步机制，所有源代码严格按以下结构分层：

```
LocalTranslate/
├── App/                                # 应用入口与全局生命周期
│   ├── LocalTranslateApp.swift         # MenuBarExtra 常驻、AppDelegate、浮窗调度
│   └── Assets.xcassets                 # 图标与配色资源
│
├── Core/                               # 跨模块共享基础层（极轻量、无业务依赖）
│   ├── Config/
│   │   └── AppSettings.swift           # UserDefaults 统一配置管理
│   └── System/
│       └── ShellResolver.swift         # CLI 可执行文件寻址（带内存缓存）
│
├── Features/                           # 业务微工具模块（每个模块完全自包含）
│   ├── Translate/                      # 翻译工具模块
│   │   ├── Models/
│   │   │   └── TranslationStyle.swift  # 翻译风格枚举与 Prompt 定义
│   │   ├── Services/
│   │   │   ├── OllamaClient.swift      # Ollama /api/chat 流式交互与语言识别
│   │   │   ├── HotKeyManager.swift     # Carbon 全局热键 (⌥⇧T)
│   │   │   └── SelectedTextReader.swift# 屏幕取词 (Accessibility + 剪贴板兜底)
│   │   ├── ViewModels/
│   │   │   └── TranslationViewModel.swift # 翻译状态机与输入管理
│   │   └── Views/
│   │       ├── FloatingPanel.swift     # NSPanel 悬浮窗实现
│   │       ├── ContentView.swift       # 浮窗主交互界面
│   │       └── CleanTextScrollView.swift # 无滚动条流式文本容器
│   │
│   └── AIUsage/                        # AI 用量监控模块
│       ├── Models/
│       │   └── UsageModels.swift       # 领域数据模型 (QuotaWindow, TokenBreakdown)
│       ├── Services/
│       │   ├── CodexProvider.swift     # Codex JSON-RPC app-server 提取
│       │   ├── GrokProvider.swift      # Grok CLI API 额度与日志扫描
│       │   └── GrokCacheStore.swift    # Grok 磁盘增量缓存管理
│       ├── ViewModels/
│       │   └── UsageStore.swift        # 数据调度中心 (并发聚合、预计算指标)
│       └── Views/
│           └── AIUsageView.swift       # 用量趋势图表与各账号卡片
│
├── Settings/                           # 统一设置窗口
│   └── SettingsView.swift              # 多分页懒加载装配容器
│
├── AGENTS.md                           # 本开发维护指南
└── README.md                           # 项目公开说明文档
```

---

## 3. 性能红线与开发规范

### 3.1 AI 用量模块 (Features/AIUsage)
1. **大文件快速预过滤**：
   - 扫描 `~/.grok/sessions` 等日志目录时，禁止全量反序列化 JSON。
   - 必须通过 `line.contains("turn_completed")` 等轻量字符预过滤跳过 99% 的流式 chunk。
2. **磁盘增量缓存 (GrokCacheStore)**：
   - 每次扫描记录文件的 `fileSize` 与 `contentModificationDate`。
   - 未修改的文件直接命中缓存，严禁产生磁盘 I/O。
   - 缓存写入在 `.background` 优先级异步落盘（`~/Library/Caches/LocalTranslate/grok_sessions_cache.json`）。
3. **并发调度 (UsageStore)**：
   - 使用 `withTaskGroup` 并行请求多个 Provider。
   - 图表统计指标（如 7 天 / 30 天聚合）由 ViewModel 预计算生成，禁止在 SwiftUI `body` 内做高频循环或排序。
4. **生命周期绑定**：
   - 在 `SettingsView` 中使用懒加载（`@State private var usageStore: UsageStore?`）。
   - 离开用量页面或关闭窗口时调用 `store.stop()` 暂停轮询。

### 3.2 翻译模块 (Features/Translate)
1. **代码与技术标识符保护**：
   - `OllamaClient.swift` 中的 `systemPrompt` 严格约束代码、变量名、API 路径、JSON Key 不被意料外汉化。
2. **浮窗伸缩与频闪控制**：
   - 流式输出中保持固定高度预估，避免 token 追加导致窗口剧烈跳动。
   - 屏幕边界与鼠标吸附计算必须防止窗口在小屏幕或副屏上越界。
3. **剪贴板保护**：
   - `SelectedTextReader` 使用剪贴板兜底方案后，必须立即恢复用户原本的剪贴板历史数据。

---

## 4. 构建与验证流程

每次修改后，请在终端执行以下检查确保无构建回归：

```bash
# 1. 编译构建测试
xcodebuild -project LocalTranslate.xcodeproj -scheme LocalTranslate build CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO

# 2. 检查 Git 状态与文件归位
git status
```
