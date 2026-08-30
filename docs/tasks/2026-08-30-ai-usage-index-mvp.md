# AI 用量增量索引与轻量刷新设计

状态：DESIGN FROZEN / MVP IMPLEMENTED / EXPERIENCE PENDING

日期：2026-08-30

## 1. 决策摘要

AI 用量页不再把“刷新”理解为同时重新扫描所有 Provider 的全部本地历史。
本设计将刷新拆成两个相互独立的数据面：

1. **订阅额度面**：Codex 5 小时、每周额度等轻量网络或 CLI 查询；
2. **本地活动面**：模型、Token、次数与参考费用的增量索引。

本地活动使用 macOS 系统自带的 SQLite3 建立可重建索引。UI 首帧只读取已有
`AccountSnapshot` 和 SQLite 聚合结果；本地日志解析进入一个全局串行扫描器，按
文件游标增量执行。单个账号完成一段刷新后立即发布，不等待其他账号或 Provider。

SQLite 是索引结果和游标的存储，不是扫描性能的替代品。MVP 必须同时实现串行
调度、分片预算、协作取消和逐账号发布，否则不能视为完成。

## 2. 背景与现场证据

### 2.1 用户目标

AI 用量页的优先级固定为：

1. 今天使用了哪些模型；
2. 每个模型的输入、缓存、输出与总 Token；
3. 可验证或可估算的大概费用；
4. 每个订阅账号的 5 小时与每周额度放在同一张账号卡片；
5. 每个订阅有独立刷新按钮；
6. 页面进入时先显示缓存，长时间未刷新才自动刷新；
7. 一个账号完成就更新一个账号，不等待容易失败的 AGY；
8. 单个 Provider 失败不清空其他 Provider 或上次成功数据。

### 2.2 当前运行证据

一次 AI 用量刷新期间观察到：

- CPU 约 138%；
- App 内存约 843 MB；
- 进程物理内存峰值约 1.1 GB；
- 刷新结束后 CPU 回到 0%，物理占用约 94 MB；
- `MALLOC_SMALL` 留下约 1 GB 的高水位虚拟区域。

本机被扫描的数据规模约为：

| 来源 | 规模 | 备注 |
| --- | ---: | --- |
| Codex 主账号 | 约 941 MB | sessions + archived_sessions |
| Codex 第二账号 | 约 392 MB | sessions |
| Grok | 约 557 MB | 约 3425 个 session 文件 |
| AGY | 约 139 MB | 约 81 个 SQLite 会话库 |

单个文件也不可假定很小：当前最大 Codex JSONL 约 99 MB，最大 Grok
`updates.jsonl` 约 21 MB，最大 AGY 数据库约 50 MB。

这说明主要问题是刷新阶段的全量 I/O、并发解析、临时对象和缓存形态，而不是
SwiftUI 空闲常驻本身。

## 3. 当前实现诊断

### 3.1 Provider 同时启动重型工作

`UsageStore` 在全量刷新或缓存 schema 失效时，会为两个 Codex 账号、AGY 和
Grok 分别创建刷新任务。各 Provider 又使用 `Task.detached` 执行本地扫描，因此
多个大数据源会同时竞争 CPU、文件缓存和分配器。

### 3.2 Codex 每次重扫 90 天

现有 `CodexTranscriptScanner` 每次枚举两个根目录，重新读取 90 天内所有 JSONL，
逐行构造 `String`、`Data` 和 `[String: Any]`。它没有持久化文件身份、mtime、
size、解析 offset 或解析状态。

两个 Codex 账号独立运行，刷新一次可重复读取约 1.3 GB。

### 3.3 Grok 缓存保留对象级 turn

Grok 已比较 size 和 mtime，也能从旧 size 继续解析，但缓存结构仍然保存
`turnsByPromptID`。生成页面快照时又构造全部 turn、今天、7 天和 30 天数组；缓存
落盘还会复制并重新 JSON 编码完整字典。

`Data(contentsOf: options: [.alwaysMapped, .uncached])` 即使只处理新增尾部，也会
建立整个文件的映射。这不符合轻量索引目标。

### 3.4 AGY 无增量文件索引

AGY 每次打开所有会话数据库，并遍历 `steps` 全表。当前只按行读取，内存不会一次
装入完整数据库，但没有文件级命中、时间预算、行数预算或 SQLite progress handler。

### 3.5 取消语义不完整

页面离开时取消的是外层任务。已经开始的 `Task.detached`、同步文件读取和 SQLite
遍历不会可靠停止。功能隐藏不等于资源释放。

## 4. 外部实现参考与取舍

### 4.1 T3 Code

T3 Code 将扫描放在本地 Server，UI 只消费结果；Provider 依次处理；解析结果按
文件 `(size, mtime)` 持久化。未变化文件不重新解析。其 30 天约 1.4 GB 的说明数据
中，冷扫约数秒、热缓存加载约十毫秒。

参考：

- https://github.com/pingdotgg/t3code/blob/main/apps/server/src/usage/UsageService.ts
- https://github.com/pingdotgg/t3code/blob/main/apps/server/src/usage/usageScanCache.ts

可采用：UI 与扫描解耦、文件级缓存、Provider 不并发全扫。

不直接复制：其变更文件仍可能整文件重读，且序列化缓存仍是单个 JSON 文档；本项目
需要追加 offset 和 SQLite 行级持久化。

### 4.2 CodexBar

CodexBar 使用独立的串行 utility queue 执行本地 corpus 扫描，避免阻塞 Swift
协作线程池并避免 Provider 扫描重叠。Codex 文件状态包含 inode、mtime、size、
parsed bytes、校验 anchor、resume state，并设置每次读取的字节与时间预算。

CodexBar 已将 Codex cost-usage 持久化从单个 JSON artifact 迁移到 SQLite；其公开
决策明确指出，整体 JSON decode/encode 是内存增长和二次复杂度问题的根因。

参考：

- https://github.com/steipete/CodexBar/blob/main/Sources/CodexBarCore/CostUsageScanExecutor.swift
- https://github.com/steipete/CodexBar/blob/main/Sources/CodexBarCore/Vendored/CostUsage/CostUsageStoreModels.swift
- https://github.com/steipete/CodexBar/issues/2760

本设计以 CodexBar 的扫描执行器、文件游标和 SQLite 持久化为主要工程参考。

### 4.3 OpenCode

OpenCode 在会话写入时把 cost 与不同 Token 类型投影到 SQLite session 行，统计无需
重读原始会话。LocalTranslate 不拥有外部 Agent 的写入链路，因此不能照搬写时统计，
但可以用本地增量索引模拟相同结果。

参考：

- https://github.com/anomalyco/opencode/blob/dev/packages/core/src/session/sql.ts
- https://github.com/anomalyco/opencode/blob/dev/packages/core/src/session/projector.ts

### 4.4 CodexRouter / CodeRouter

Router 能在请求经过网关时直接记录模型与用量，但无法覆盖没有经过它的 Codex、Grok
和 AGY 历史。LocalTranslate 继续保持只读观察者，不要求用户把模型请求改接到代理。

## 5. 目标与非目标

### 5.1 MVP 目标

- AI 用量页首帧不启动子进程或本地全量扫描；
- 缓存未超过 30 分钟时，进入页面不自动刷新；
- 长时间未刷新时按账号安排刷新，账号之间不互相等待；
- 额度查询和本地活动索引分别成功、分别合并；
- 所有本地重型扫描共用一个串行执行器；
- Codex JSONL 记录增量 offset，未变化文件零内容读取；
- Grok 从对象级 JSON cache 迁移为 SQLite 数值事件索引；
- AGY 按数据库 size + mtime 复用上次聚合，变化数据库才重新查询；
- UI 优先展示今天的模型、Token 和参考费用；
- 单 Provider 失败保留旧数据并发布可解释状态；
- 页面离开后，扫描在下一个 64 KiB chunk 或 SQLite progress callback 停止；
- 不引入第三方 SQLite wrapper，继续使用系统 `SQLite3`。

### 5.2 MVP 非目标

- 不实现文件系统常驻 watcher；
- 不引入 XPC/helper 进程；
- 不接管或代理 Codex、Grok、AGY 请求；
- 不保证订阅扣费与 API 估价相同；
- 不为 AGY 虚构模型级 Token 或订阅额度；
- 不保存 prompt、回复正文、工具参数或 AGY metadata BLOB；
- 不追求第一次建立 90 天索引瞬间完成；
- 不更改翻译和实时字幕 Feature；
- 不提交、推送或发布。

## 6. 数据真值与展示语义

### 6.1 订阅额度

Codex 5 小时、每周窗口来自账号对应的 app-server/API 返回。它们属于额度面，必须
成组展示在同一账号卡片，不与模型使用量混合。

### 6.2 本地活动

本地活动来自各 Agent 会话文件：

- Codex：`token_count.last_token_usage`；
- Grok：`turn_completed.usage`；
- AGY：无可靠 Token 字段时只提供现有字节估算，并维持低置信度。

模型按 `modelID` 全局归一。账号卡片只展示账号额度与时间，不复制模型明细。今天
模型表可以按 Provider 和账号过滤，但默认按全局 modelID 聚合。

### 6.3 费用

费用行必须带来源：

- `recorded`：会话明确记录的费用；
- `estimated`：按版本化价格表估算；
- `unpriced`：没有可靠价格，显示 `—`，不得按零费用处理。

只要某一模型存在 unpriced 事件，该模型总费用不宣称完整；可以显示已知费用下限，
但必须带“不完整”状态。订阅 Plus 实际扣款、工具调用附加费和 API 等价估价不是同一
口径，UI 保留现有免责声明。

## 7. 总体架构

```text
AIUsageView
    |
    v
UsageStore (@MainActor)
    |-- 首帧读取 UsageDiskCache，立即渲染
    |-- 逐账号合并 quota lane / activity lane
    |
    v
UsageRefreshCoordinator
    |-- 轻量额度任务：账号间允许并发，带独立超时
    |-- 本地扫描任务：只提交给一个 UsageScanExecutor
    |
    v
UsageScanExecutor (single serial utility queue)
    |-- cooperative cancellation
    |-- byte/time slice budget
    |
    +--> CodexUsageSource
    +--> GrokUsageSource
    +--> AGYUsageSource
             |
             v
        UsageIndex.sqlite
        - source_file
        - usage_event
        - refresh_state
             |
             v
        小型聚合查询
        - today model usage
        - daily activity
        - 7/30 day totals
```

## 8. 组件职责

### 8.1 UsageStore

`UsageStore` 只负责页面状态和合并，不做文件、SQLite、网络或子进程 I/O。

要求：

- 初始化只读取内存/磁盘快照；
- 每个账号维护额度与活动两个 lane 的刷新状态；
- 任一 lane 成功后立即合并到旧账号快照并发布；
- 任一 lane 失败只更新该 lane 的错误，不删除旧值；
- 账号 A 发布不等待账号 B 或 AGY；
- `stop()` 取消 coordinator，并等待扫描器确认停止后清除 spinner。

### 8.2 UsageRefreshCoordinator

Coordinator 负责去重、优先级和 stale 规则。

同一账号同一 lane 同时最多一个任务。刷新来源分为：

1. `pageStale`：页面进入且上次成功超过 30 分钟；
2. `accountManual`：账号卡片独立刷新；
3. `allManual`：顶部刷新，等价于为每个账号分别排队；
4. `catchUp`：索引未完成时的后续分片。

优先级：`accountManual > allManual > pageStale > catchUp`。手动刷新可以合并已排队的
低优先级同账号任务，不重复扫描。

### 8.3 UsageScanExecutor

所有本地 corpus 扫描共用一个串行 utility queue，不能使用彼此独立的
`Task.detached`。

执行器向扫描函数提供：

```swift
typealias CancellationCheck = @Sendable () throws -> Void

struct ScanBudget {
    let maximumBytes: Int64
    let deadline: ContinuousClock.Instant
}
```

扫描器必须在以下位置检查取消与预算：

- 每个目录；
- 每个文件；
- 每个 64 KiB chunk；
- 每 256 条已解析记录；
- AGY SQLite 每 1000 个 VM opcode 的 progress handler。

### 8.4 UsageIndex

`UsageIndex` 是单 writer actor/串行拥有者。UI 不持有 sqlite handle。Provider 只通过
类型化接口提交文件状态、数值事件和查询范围。

数据库是可重建的本机派生索引。参考 T3 Code 与 Claude Code Router 的本机状态目录
风格，MVP 不使用 macOS `Caches` 或 `Application Support`，统一放在 LocalTranslate
专属隐藏目录：

```text
~/.localtranslate/
└── ai-usage/
    ├── usage-index.sqlite
    ├── usage-index.sqlite-wal
    └── usage-index.sqlite-shm
```

主数据库的冻结路径为：

```text
~/.localtranslate/ai-usage/usage-index.sqlite
```

约束：

- `~` 使用 `FileManager.default.homeDirectoryForCurrentUser` 解析，不依赖 shell 的
  `HOME`，也不把展开后的绝对用户目录写入配置；
- `~/.localtranslate` 是 LocalTranslate 的持久本机状态根目录，`ai-usage` 只属于
  AI 用量 Feature；
- 目录权限目标为仅当前用户可访问，数据库及 WAL/SHM companion 文件不得对其他
  本机用户开放；
- 目录内只保存游标、文件身份、数值事件和聚合索引，不复制 Provider 原始会话；
- 索引可重建但重建代价较高，因此不依赖系统缓存清理；同时将 `ai-usage` 目录标记为
  不参与备份，避免把派生索引带入 Time Machine；
- 清理操作必须同时关闭连接并处理主数据库、`-wal`、`-shm` 和已确认的损坏备份，
  不允许扩大到整个 `~/.localtranslate` 根目录。

现有 `UsageDiskCache` 暂时继续保存最终 `AccountSnapshot`，保证首帧兼容。SQLite
只负责本地活动索引，MVP 不同时迁移所有页面缓存。

## 9. SQLite 配置

MVP 使用系统 `SQLite3` C API，不增加 Swift Package。

连接初始化：

```sql
PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;
PRAGMA foreign_keys = ON;
PRAGMA busy_timeout = 1000;
PRAGMA cache_size = -4096;
PRAGMA mmap_size = 0;
```

取舍：

- WAL 允许页面读取旧聚合时扫描器提交新数据；
- 索引可重建，因此 `synchronous=NORMAL` 的掉电丢失最后事务风险可接受；
- 页缓存以约 4 MiB 为初始上限；
- MVP 显式关闭 SQLite mmap，避免重新制造大映射高水位；
- 所有批量事件在显式事务中写入；
- WAL checkpoint 由自动阈值处理，页面关闭或 App 退出不强制同步大 checkpoint。

## 10. Schema

### 10.1 schema_metadata

```sql
CREATE TABLE schema_metadata (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
) WITHOUT ROWID;
```

至少保存：

- `schema_version`；
- 各 Provider `parser_version`；
- `pricing_version`。

### 10.2 source_file

```sql
CREATE TABLE source_file (
    id                 INTEGER PRIMARY KEY,
    provider_id        TEXT NOT NULL,
    account_id         TEXT NOT NULL,
    path               TEXT NOT NULL,
    inode              INTEGER,
    mtime_ms           INTEGER NOT NULL,
    file_size          INTEGER NOT NULL,
    parsed_offset      INTEGER NOT NULL DEFAULT 0,
    parser_version     INTEGER NOT NULL,
    cursor_state       BLOB,
    anchor_offset      INTEGER,
    anchor_sha256      BLOB,
    scan_status        TEXT NOT NULL,
    updated_at_ms      INTEGER NOT NULL,
    UNIQUE(provider_id, account_id, path)
);
```

`scan_status` 只能是：

- `complete`；
- `partial`；
- `retryable_failure`。

`cursor_state` 只保存恢复解析所需的小型状态，不保存原始内容。例如 Codex 保存当前
model、上一个 usage signature、fork suppression 状态和未完成行字节。

### 10.3 usage_event

```sql
CREATE TABLE usage_event (
    source_file_id       INTEGER NOT NULL
                         REFERENCES source_file(id) ON DELETE CASCADE,
    event_key            TEXT NOT NULL,
    occurred_at_ms       INTEGER NOT NULL,
    local_day            TEXT NOT NULL,
    model_id             TEXT NOT NULL,
    input_tokens         INTEGER NOT NULL,
    output_tokens        INTEGER NOT NULL,
    cached_read_tokens   INTEGER NOT NULL,
    cache_write_tokens   INTEGER NOT NULL,
    reasoning_tokens     INTEGER NOT NULL,
    turn_count           INTEGER NOT NULL,
    cost_microusd        INTEGER,
    cost_kind            TEXT,
    PRIMARY KEY(source_file_id, event_key)
) WITHOUT ROWID;

CREATE INDEX usage_event_day_model_idx
ON usage_event(local_day, model_id);

CREATE INDEX usage_event_time_idx
ON usage_event(occurred_at_ms);
```

`event_key`：

- Codex：JSONL 完整行结束 offset；
- Grok：稳定 prompt ID，缺失时使用文件 offset；
- AGY：数据库内稳定 step row ID；若 schema 无稳定 ID，则整库变化时删除该文件事件并
  全量替换。

只保存统计数字。单条 numeric event 允许 Grok 后续同 prompt ID 更新时执行 UPSERT，
也允许文件截断时按 `source_file_id` 原子删除并重建。

### 10.4 refresh_state

```sql
CREATE TABLE refresh_state (
    provider_id          TEXT NOT NULL,
    account_id           TEXT NOT NULL,
    last_attempt_ms      INTEGER,
    last_success_ms      INTEGER,
    coverage_start_day   TEXT,
    coverage_end_day     TEXT,
    catch_up_pending     INTEGER NOT NULL DEFAULT 0,
    last_error           TEXT,
    PRIMARY KEY(provider_id, account_id)
) WITHOUT ROWID;
```

`last_error` 只保存短错误类别和摘要，不保存路径中的用户名、token 或原始 payload。

## 11. 增量算法

### 11.1 文件发现

每个 Provider 先枚举候选文件并读取轻量 stat。候选优先级：

1. 今天修改且未完成；
2. 今天修改且 size/mtime 变化；
3. 最近修改的历史文件；
4. 首次索引的历史文件，按新到旧；
5. 校验可能已删除的旧索引记录。

文件未变化且 parser version 相同：

- 不打开文件；
- 不读取 payload；
- 直接复用 SQLite 事件。

### 11.2 追加验证

允许从 `parsed_offset` 继续的条件：

- inode 未变化；
- 新 size 不小于旧 parsed offset；
- parser version 未变化；
- offset 前最多 4096 字节的 SHA-256 anchor 仍匹配。

任一条件不满足，视为替换或截断：

1. 开始事务；
2. 删除该 source file 的旧 usage_event；
3. cursor 归零；
4. 从头重建；
5. 提交新 cursor 与事件。

### 11.3 分片和未完成行

默认读取块为 64 KiB。只把最后一个完整换行符之前的字节计入 `parsed_offset`。末尾
未完成 JSON 行保存在受限 cursor state，或留到下一次从安全 offset 重读；不能把
半行当成稳定事件。

每个分片最多：

- 新读取 32 MiB；或
- 1 秒 wall-clock；

以先到者为准。达到预算时，在一个事务中提交已完成事件、anchor、cursor 和
`scan_status=partial`，然后把账号标为 `catch_up_pending`。

### 11.4 Codex

Codex parser 必须保留当前去重和 fork-copy suppression 语义，并将恢复状态随 cursor
持久化。读取顺序按文件内 offset，不跨文件复用 parser state。

90 天以前的文件默认不建立活动索引；lifetime 优先使用 app-server 的官方 summary，
不得用 90 天局部数据冒充 lifetime。

### 11.5 Grok

Grok 不再持久化 `CachedTurn` 或 `turnsByPromptID` JSON。每个 `turn_completed` 转换为
一条或多条数值事件：

- 有 `modelUsage` 时按模型写入；
- 只有 top-level usage 时写入明确的 unknown model bucket；
- 相同 prompt ID 再次出现使用 UPSERT 替换，而不是重复累计。

迁移成功后删除旧 Grok JSON cache；删除必须发生在 SQLite 事务和校验成功之后，且
该缓存可重建。

### 11.6 AGY

AGY 继续以只读方式打开外部数据库。每个数据库先比较 inode、size、mtime：

- 未变化：零 SQL 查询；
- 变化：只重建该数据库对应的 usage_event；
- 查询设置 SQLite progress handler，支持取消、5 万总行、1 万行/库、128 MiB
  尝试读取和 5 秒总时长上限；
- `length(BLOB)` 优先在 SQLite 内计算，metadata 只在解析时间戳确实需要时按行复制；
- 无模型/Token 真值时保持 `model_id=agy-activity-estimate` 和低置信度。

AGY 失败不得阻塞 Codex 或 Grok 发布。

## 12. 刷新时序

### 12.1 页面进入

```text
AIUsageView appear
  -> UsageStore.start()
  -> 读取已有 AccountSnapshot（同步首帧）
  -> 检查各账号 last_success
     -> < 30 分钟：不刷新
     -> >= 30 分钟或缺失：各账号独立排队
  -> 页面继续可交互
```

### 12.2 单账号刷新

```text
点击 Codex Plus A 刷新
  -> 立即显示该账号 spinner
  -> quota lane 与 activity lane 分开启动
     -> quota 成功：立即更新 5 小时/每周
     -> activity 进入全局串行扫描队列
        -> 每个分片事务提交
        -> 查询今天/7天/30天聚合
        -> 立即更新该账号活动
  -> 其他账号不显示 spinner，也不被刷新
```

### 12.3 全部刷新

顶部刷新只创建多个独立账号请求。额度 lane 可以小规模并发；本地活动 lane 仍严格
串行。任一账号成功立即发布，不设置“等待全部完成后统一替换”的 barrier。

### 12.4 catch-up

- 页面自动 stale 刷新：每账号只执行一个分片，不递归占用 CPU；
- 账号手动刷新：最多连续执行 4 个分片，分片间至少 yield 500 ms；
- 仍未完成时展示“正在补齐历史”，后续手动或 stale 刷新继续；
- 页面离开后不再安排 catch-up，当前 chunk 完成或取消后释放资源。

今天修改的文件优先，因此用户关心的当天模型通常先可用。覆盖不完整时 UI 必须显示
索引状态，不能把部分数据伪装成完整统计。

## 13. 查询与快照生成

### 13.1 当天模型

```sql
SELECT model_id,
       SUM(input_tokens),
       SUM(output_tokens),
       SUM(cached_read_tokens),
       SUM(cache_write_tokens),
       SUM(reasoning_tokens),
       SUM(turn_count),
       SUM(cost_microusd),
       SUM(CASE WHEN cost_microusd IS NULL THEN 1 ELSE 0 END)
FROM usage_event
WHERE local_day = ?
GROUP BY model_id;
```

账号过滤通过 join `source_file.account_id` 完成。默认全局聚合时，同一 modelID 跨账号
合并，符合“模型按 modelID 全局归一”的约束。

### 13.2 日期汇总

按 `local_day` 聚合生成 `DailyActivity`，再从最多 90 行的结果计算 7/30 天。SwiftUI
不接触 event 行，也不对全部 turn 执行 filter/map。

### 13.3 时区

`local_day` 按扫描时系统时区生成。数据库 metadata 保存 time zone identifier。时区
变化时，不能继续复用 day bucket；MVP 通过清空并重建活动索引处理，旧
`AccountSnapshot` 可继续显示并注明待更新。

## 14. 错误、损坏与软失败

### 14.1 外部文件读取失败

- 不将读取失败缓存为零使用量；
- 不推进 cursor；
- 保留旧事件；
- 记录 retryable failure，下一次继续。

### 14.2 SQLite 损坏

发现 `SQLITE_CORRUPT` 或 quick check 失败时：

1. 关闭连接；
2. 将索引重命名为带时间戳的 `.corrupt` 文件；
3. 创建空索引；
4. 保留 `UsageDiskCache` 的上次页面快照；
5. 后续按分片重建。

不删除任何 Codex、Grok 或 AGY 原始文件。

### 14.3 并发写入中的源变化

扫描文件前后各读取一次 stat。如果 size 或 mtime 在扫描期间变化，只提交已确认完整
换行之前的安全 offset，并保留 `partial`；不假定扫描开始时的 EOF 仍有效。

## 15. 资源预算与性能目标

以下为 Release 构建的 MVP 验收目标，不是当前已验证结果：

| 场景 | 目标 |
| --- | --- |
| AI 用量页空闲 | CPU 接近 0%，无目录扫描、子进程或 timer 高频工作 |
| 首帧 | 100 ms 内显示已有快照 |
| 未变化账号热刷新 | 不读取日志 payload；每账号 300 ms 内完成本地索引检查 |
| 本地扫描并发 | 全局最多 1 个重型扫描任务 |
| 扫描 CPU | 不超过一个逻辑核的持续占用 |
| 扫描峰值物理内存 | 目标低于 200 MB |
| 取消 | 页面离开后 500 ms 内停止继续读取新 chunk |
| Provider 隔离 | AGY 超时不延迟 Codex/Grok 已完成结果发布 |

若首次索引无法达到时间目标，优先延长 catch-up 周期，不放宽内存和取消不变量。

## 16. 隐私与安全

- SQLite 只保存在本机 `~/.localtranslate/ai-usage/` 目录，并排除备份；
- 不保存 prompt、completion、工具输入、账号 token 或 Cookie；
- path 可用于文件身份，但错误与 UI 不暴露完整用户目录；
- SQL 全部使用 prepared statement 和参数绑定；
- 外部数据库始终以 `SQLITE_OPEN_READONLY` 打开；
- 索引删除只针对 `ai-usage` 下明确列出的 SQLite 主文件、companion 文件和损坏备份；
- 数据库可以清理和重建，不影响外部 Agent 会话。

## 17. 可观测性

每次账号活动刷新记录以下本地诊断指标，不记录内容：

- provider/account ID；
- 枚举文件数；
- cache hit 文件数；
- 重建、追加、删除文件数；
- 新读取字节数；
- 解析事件数；
- 扫描和 SQLite 提交耗时；
- 是否因 bytes、deadline 或 cancellation 停止；
- 当前 coverage 与 catch-up 状态；
- 峰值指标由 Instruments/`vmmap` 外部验证，不在 App 内持续轮询。

## 18. 测试设计

### 18.1 纯状态测试

- 未变化 `(inode, size, mtime, parserVersion)` 必须为 cache hit；
- append 且 anchor 匹配，从旧 offset 继续；
- truncate、inode 变化、anchor 不匹配触发单文件重建；
- 半行不推进安全 offset；
- parser version 变化不复用旧 cursor；
- 同 Grok prompt ID UPSERT 不重复计数；
- 同 Codex event offset 不重复计数；
- recorded / estimated / unpriced 聚合语义正确；
- 时区变化触发活动索引重建。

### 18.2 SQLite 集成测试

使用临时目录和小型 fixture：

- 文件 cursor 与事件在同一事务提交；
- 模拟 commit 前失败后旧状态保持；
- source file 删除触发 cascade；
- 并发读旧快照和单 writer 提交；
- WAL 重开后结果一致；
- 损坏索引走重建，不影响 fixture 原文件。

### 18.3 Provider fixture

- Codex 普通、重复 token_count、fork、model 切换、追加和截断；
- Grok modelUsage、top-level usage、重复 prompt ID、缺失 prompt ID；
- AGY 空库、锁定库、超大 BLOB、无时间戳和查询取消。

### 18.4 性能验证

使用当前真实规模的只读副本或原目录只读扫描，分别记录：

1. 冷索引首个分片；
2. 冷索引完整 catch-up；
3. 无变化热刷新；
4. 单个活跃文件追加；
5. 页面离开取消；
6. AGY 失败时 Codex/Grok 发布。

不得用小 fixture 的通过代替真实规模性能证据。

## 19. 迁移与回滚

### 19.1 首次启用

1. 保留现有 `UsageDiskCache`，立即显示旧页面数据；
2. 创建 `~/.localtranslate/ai-usage/` 及空 SQLite 索引；
3. 优先建立当天活动；
4. 每个账号分片完成后发布 coverage 状态；
5. 后续刷新逐步补齐 90 天。

先前文档草案中的 `~/Library/Caches/LocalTranslate/AIUsage/` 从未进入实现，不作为
迁移来源，也不在 MVP 中探测或创建。

### 19.2 Grok 旧缓存

SQLite 至少完成一次 Grok 提交并能生成等价快照后，才删除
`grok_sessions_cache.json`。删除仅限该明确文件；失败时允许保留，不影响运行。

### 19.3 回滚

实现应保留一个开发期开关，可以禁用 SQLite 活动索引并回退到上次
`UsageDiskCache`。不回退到四 Provider 并发全量扫描；旧 scanner 只允许作为诊断
工具显式运行。

## 20. 实施顺序

本设计按以下顺序实现，每一步单独验证：

1. `UsageScanExecutor`、取消与预算测试；
2. `UsageIndex` schema、事务、查询和损坏恢复测试；
3. Codex 单账号 fixture 增量 parser；
4. 两个 Codex 账号接入并验证不并发扫描；
5. Grok 从对象 JSON cache 迁移到 SQLite numeric events；
6. AGY 文件级复用与查询预算；
7. quota/activity lane 分离和逐账号发布；
8. UI coverage、lane error 和 spinner 状态；
9. Debug/Release 构建、standalone tests、真实目录性能验证；
10. 用户体验验收后再删除开发期开关。

## 21. 验收证据分层

### Source

- Schema、游标、anchor、事务、串行执行器和取消不变量存在；
- UI 不直接读取源文件；
- Provider 失败保留旧数据；
- 无对象级 turn 全量 cache。

### Build

- Xcode 26 Debug 和 Release 无签名构建成功；
- `git diff --check` 通过；
- focused standalone tests 真实执行，`Tests run: 0` 不算通过。

### Runtime

- Instruments、`sample` 或 `vmmap` 验证峰值与取消；
- 无变化热刷新证明 payload bytes 为 0；
- 两个 Codex、Grok、AGY 不发生重型扫描重叠。

### Experience

- 用户验收今天模型、Token、费用是否符合关注顺序；
- 账号 5 小时/每周是否成组清晰；
- 单账号刷新和逐账号更新是否符合预期。

### External

- 本设计不创建 Issue、Release、远端标签或产物；
- 没有明确授权前不提交或推送。

## 22. 当前状态

截至 2026-08-30 MVP 实现完成：

- 设计：FROZEN；
- Source：统一 `UsageScanExecutor`、SQLite `UsageIndex`、Codex/Grok JSONL
  文件游标、AGY 数据库游标、事务提交、WAL、损坏隔离、时区重建、软失败保留和
  逐账号刷新均已接入；旧 Grok/AGY 对象 JSON cache store 与未使用的全量 scanner
  已从源码移除；
- Tests：`AIUsageIndexTests` 6 项、`AIUsageProviderFixtureTests` 7 项真实执行通过，
  覆盖事务、UPSERT、cascade、WAL 重开、串行、取消、Codex append/truncate/半行、
  Grok prompt 与多模型去重、AGY 文件命中/变化和损坏索引重建；
- Build：Xcode 26 Debug 与 Release 无签名构建成功；Release 仍有一个既存的
  `ScreenshotOCRService` Swift 6 Sendable warning，与 AIUsage 无关；
- Runtime：在当前真实 Codex 双账号、Grok、AGY 目录上运行单进程首批分片 smoke，
  最终一次四个来源串行完成约 2.36 秒，最大常驻内存约 69 MiB，SQLite
  `quick_check=ok`；
  索引仍按预算逐次补齐，尚未用 App + Instruments 验证完整 90 天 catch-up；
- Storage：数据库实际创建于
  `~/.localtranslate/ai-usage/usage-index.sqlite`，目录权限 `0700`、主文件权限
  `0600`，旧 `grok_sessions_cache.json` 在新索引成功后已删除；
- Experience：今日模型、费用、账号额度组合、单账号刷新和逐账号更新仍待用户验收；
- External：未提交、未推送、未创建 Issue、标签、Release 或远端产物。
