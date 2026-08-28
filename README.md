# LocalTranslate · 本机 AI 小工具箱

<p align="center">
  <b>极轻量 · 零干扰 · 强隔离 · 本地隐私安全</b>
  <br>
  专为 macOS 打造的极简状态栏小工具集合：本地大模型即时划词翻译 + 多账号 AI 用量监控看板。
</p>

---

## 🌟 核心特性

### 1. 本地 AI 快捷翻译 (Local Translate)
- **本地 Ollama 驱动**：数据完全留存在本地，零外部网络 API 泄露风险；支持任何 Ollama 兼容模型（如 `qwen3.5:4b`、`deepseek-r1` 等）。
- **全局无感划词 (⌥⇧T)**：在任何 App 中选中文字后按 `⌥⇧T` 即可就近弹出翻译；支持 Accessibility API 智能读取，无权限时自动降级模拟复制并还原剪贴板。
- **技术场景深度优化**：内置面向开发者与技术文档的 Prompt 保护规则，精准保留变量名、API 标识符、代码块、JSON Key 与 CLI 标志，绝不盲目汉化。
- **多种翻译风格**：内置“默认”、“自然”、“简洁”、“正式”、“直译”及“自定义 Prompt”风格，灵活应对日常阅读、代码注释或商务邮件。
- **智能交互浮窗**：自动贴靠鼠标坐标与屏幕边界，流式生成平滑展示，支持置顶钉住 (`Pin`)、`Esc` 退出与一键复制反馈。

### 2. AI 用量监控看板 (AI Usage Hub)
- **全方位 Provider 汇聚**：
  - **Codex Plus A** (`~/.codex`)
  - **Codex Plus B** (`~/.codex_account2`)
  - **Antigravity (AGY)** (`~/.gemini/antigravity` 本地 SQLite 交互轨迹)
  - **SuperGrok** (`~/.grok`)
- **额度与重置周期**：实时读取官方 API 与会话限额，直观展示 5h 窗口、周度/月度额度使用百分比及下次重置时间点。
- **极速增量扫描引擎**：
  - 基于原始 UTF-8 字节匹配跳过 99.5% 无效 chunk，毫秒级读取 500MB+ 日志。
  - 配合磁盘增量缓存（`GrokCacheStore` 与 SQLite 本地查询），实现 **< 5ms 毫秒级秒开**。
- **交互式趋势图表**：
  - 基于 Swift Charts 展示 7 天 / 30 天每日 Token 消耗趋势（Codex + AGY + Grok 汇总）。
  - **鼠标悬停交互**：鼠标移动到任意柱/点上，实时浮现当天的确切 Token 数量、交互轮次与虚线定位标尺。

---

## 🏗️ 架构与资源隔离设计

本项目秉承 **“每个功能互不影响，单工具启动极低开销”** 的微工具哲学：

```
LocalTranslate/
├── App/                                # 应用入口与生命周期装配
│   └── LocalTranslateApp.swift         # MenuBarExtra 常驻、AppDelegate、浮窗定位
│
├── Core/                               # 共享基础底座（无业务状态）
│   ├── Config/AppSettings.swift        # UserDefaults 统一配置管理
│   └── System/ShellResolver.swift      # CLI 路径解析（带内存并发缓存）
│
├── Features/                           # 业务微工具特性模块（完全解耦）
│   ├── Translate/                      # 翻译工具
│   │   ├── Models/                     # 翻译风格定义
│   │   ├── Services/                   # Ollama 客户端、全局快捷键、划词读取
│   │   ├── ViewModels/                 # 翻译状态机
│   │   └── Views/                      # 悬浮面板、主界面、无滚动条流式文本框
│   │
│   └── AIUsage/                        # AI 用量看板
│       ├── Models/                     # 统一领域模型 (AccountSnapshot, TokenBreakdown)
│       ├── Services/                   # Codex Runner、AGY SQLite 扫描器、Grok 扫描器、磁盘缓存
│       ├── ViewModels/                 # 并发调度中心 (UsageStore)
│       └── Views/                      # 用量趋势图表与各账号卡片
│
├── Settings/                           # 个人工具箱集中设置 (780x640 统一原生窗口)
│   └── SettingsView.swift              # 多分页懒加载导航
│
├── AGENTS.md                           # AI Agent 与开发者协作规范
└── README.md                           # 本说明文档
```

### 资源优化亮点：
1. **按需懒加载 (Lazy Loading)**：打开设置面板配置翻译时，AI 用量组件完全不被初始化，后台不启动轮询，不产生额外内存和 CPU 消耗。
2. **非阻塞后台调度 (Background QoS)**：Codex 进程拉起、Grok 日志解析均在 `.utility` 后台线程并行处理，主线程保持 120 FPS 流畅无卡顿。
3. **预计算渲染优化**：图表和卡片统计数据在数据层计算完成，避免在 SwiftUI `body` 渲染周期内反复遍历数组。
4. **统一窗口尺寸**：设置窗口锁定为 780 × 640，页面切换平滑淡入，彻底消除拉伸撕裂。

---

## 🚀 快速上手

### 环境要求
- macOS 14.0+ (Sonoma / Sequoia)
- [Xcode 16.0+](https://developer.apple.com/xcode/)
- [Ollama](https://ollama.com/)（翻译功能必需，推荐拉取 `qwen3.5:4b` 或 `qwen2.5:7b`）
  ```bash
  ollama run qwen3.5:4b
  ```
- *(可选)* 已登录的 `codex` / `grok` / `agy` CLI 工具（AI 用量看板所需）。

### 编译与运行

1. 克隆或打开本仓库：
   ```bash
   open LocalTranslate.xcodeproj
   ```
2. 在 Xcode 中选择 `LocalTranslate` Scheme，直接按下 `⌘R` 运行。
3. 状态栏将出现书籍图标 `character.book.closed`。
4. 使用快捷键 `⌥⇧T` 唤起翻译浮窗，或在菜单栏点击 **“设置…”** 打开工具箱。

---

## ⚙️ 快捷键速查

| 快捷键 | 功能说明 | 触发场景 |
| :--- | :--- | :--- |
| `⌥ ⇧ T` | **智能取词翻译 / 呼出浮窗** | 全局任何应用程序中 |
| `⌘ ↩` | **立即翻译 / 重新翻译** | 翻译浮窗激活时 |
| `Esc` | **隐藏浮窗** | 浮窗激活时 |
| `⌘ ,` | **打开个人工具设置** | 任意界面 |

---

## 🤝 开发者与协作规范

若需对本项目进行扩展或提交代码，请参阅 [AGENTS.md](file:///Users/shaopc/playground/LocalTranslate-macos/LocalTranslate/AGENTS.md) 了解详细的架构约束、性能红线与测试要求。
