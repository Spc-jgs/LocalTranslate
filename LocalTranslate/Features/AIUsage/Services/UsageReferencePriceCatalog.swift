import Foundation

/// 参考费用的单一出处：Anthropic、OpenAI（Codex）、Google 与 xAI 的官方标准
/// API 单价，以及「这个模型为什么没有费用」的判定。价目分散会让两侧各自漂移，
/// 也会让 UI 只剩下一个无从解释的破折号。
///
/// 每个模型持有一串**按时间排列的单价档**，而不是一个数。官方公布的形式本来
/// 就是「到某日为止 X，之后 Y」；把它压成一个数，要么在涨价当天悄悄算错，
/// 要么在促销结束当天整列变空。全部档位都过期说明官方还没公布后继单价，
/// 那时不猜——这是 AGENTS.md 的「不从 Token 反推」在时间轴上的同一条规则。
nonisolated enum UsageReferencePriceCatalog {
    private struct Price {
        let inputPerMillion: Double
        let cachedInputPerMillion: Double
        let cacheWritePerMillion: Double
        let outputPerMillion: Double
        let longContext: LongContextPrice?
        /// 这一档的截止时刻；`nil` 表示官方没有给它设终点。
        let validBefore: Date?

        init(
            _ inputPerMillion: Double,
            _ cachedInputPerMillion: Double,
            _ cacheWritePerMillion: Double,
            _ outputPerMillion: Double,
            longContext: LongContextPrice? = nil,
            validBefore: Date? = nil
        ) {
            self.inputPerMillion = inputPerMillion
            self.cachedInputPerMillion = cachedInputPerMillion
            self.cacheWritePerMillion = cacheWritePerMillion
            self.outputPerMillion = outputPerMillion
            self.longContext = longContext
            self.validBefore = validBefore
        }
    }

    private struct LongContextPrice {
        let threshold: Int64
        let inputPerMillion: Double
        let cachedInputPerMillion: Double
        let outputPerMillion: Double

        init(
            _ threshold: Int64,
            _ inputPerMillion: Double,
            _ cachedInputPerMillion: Double,
            _ outputPerMillion: Double
        ) {
            self.threshold = threshold
            self.inputPerMillion = inputPerMillion
            self.cachedInputPerMillion = cachedInputPerMillion
            self.outputPerMillion = outputPerMillion
        }
    }

    /// 价目表的修订号。**改动任何单价、新增任何模型都要 +1。**
    ///
    /// 事件的费用在入库时就算好并固化在 SQLite 里，价目表后来变了，已入库的行
    /// 不会自己更新。补了 gpt-6-astra 的单价却忘了动 Codex 的 parserVersion，
    /// 结果就是那 12 条记录一直挂着 NULL，表里显示成一个没有金额的破折号——
    /// 价格明明已经收录了。把这个号并进每个算费用的解析器的 parserVersion，
    /// 加一条单价就自动触发重扫，而不是靠人记得同时改四个数字。
    static let revision = 2

    /// 算费用的解析器用它组合版本号：解析逻辑自身的版本 × 1000 + 价目修订号。
    /// 两者任一变化都让 `unchanged` 判定失配，从而重扫并覆盖旧事件。
    static func pricedParserVersion(_ parserBaseVersion: Int) -> Int {
        parserBaseVersion * 1_000 + revision
    }

    private static func date(_ iso8601UTC: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        // 价目表里的日期都是写死的常量；解析不出来是编码错误，不是运行期条件。
        guard let value = formatter.date(from: iso8601UTC) else {
            preconditionFailure("价目表日期无法解析：\(iso8601UTC)")
        }
        return value
    }

    // MARK: - Anthropic

    // Anthropic standard global API list prices checked on 2026-08-30.
    private static let claudePrices: [String: [Price]] = [
        "claude-opus-5": [Price(5, 0.5, 6.25, 25)],
        "claude-opus-4-8": [Price(5, 0.5, 6.25, 25)],
        "claude-opus-4-7": [Price(5, 0.5, 6.25, 25)],
        "claude-opus-4-6": [Price(5, 0.5, 6.25, 25)],
        "claude-opus-4-5": [Price(5, 0.5, 6.25, 25)],
        "claude-sonnet-5": [Price(2, 0.2, 2.5, 10)],
        "claude-sonnet-4-6": [Price(3, 0.3, 3.75, 15)],
        "claude-sonnet-4-5": [Price(3, 0.3, 3.75, 15)],
        "claude-haiku-4-5": [Price(1, 0.1, 1.25, 5)]
    ]

    // MARK: - xAI

    // xAI standard API list prices checked on 2026-08-30. Grok Build's
    // `-build` suffix is normalized to the matching public API model.
    private static let grokPrices: [String: [Price]] = [
        "grok-4.6": [
            Price(2, 0.5, 2, 6, longContext: LongContextPrice(200_000, 4, 1, 12))
        ],
        "grok-4.5": [
            Price(2, 0.3, 2, 6, longContext: LongContextPrice(200_000, 4, 0.6, 12))
        ]
    ]

    // MARK: - OpenAI (Codex)

    /// Promotional GPT-5.6 prices published by OpenAI and guaranteed through
    /// 2026-11-21. OpenAI has not published the follow-on rate, so the schedule
    /// ends there and the UI says the rate expired rather than inventing one.
    /// Checked on 2026-09-05 against developers.openai.com/api/docs/pricing.
    private static let codexPromotionEnd = date("2026-11-22T00:00:00Z")

    private static let codexPrices: [String: [Price]] = [
        "gpt-5.6": [Price(4, 0.4, 5, 20, validBefore: codexPromotionEnd)],
        "gpt-5.6-sol": [Price(4, 0.4, 5, 20, validBefore: codexPromotionEnd)],
        "gpt-5.6-terra": [Price(2, 0.2, 2.5, 12, validBefore: codexPromotionEnd)],
        "gpt-5.6-luna": [Price(0.2, 0.02, 0.25, 1.2, validBefore: codexPromotionEnd)],
        // GPT-6 family standard API list prices checked on 2026-09-23 against
        // developers.openai.com/api/docs/pricing.
        "gpt-6-astra": [Price(10, 1, 12.5, 50)],
        "gpt-6-sol": [Price(2, 0.2, 2.5, 10)],
        "gpt-6-luna": [Price(0.1, 0.01, 0.125, 0.5)],
        "gpt-6": [Price(2, 0.2, 2.5, 10)]
    ]

    /// OpenAI 的长上下文加价与 Anthropic/xAI 不同：超过阈值后输入与缓存 ×2、
    /// 输出 ×1.5，而不是换一张单价表。gpt-5.6 与 gpt-6 全家族共用这个阈值。
    private static let codexLongContextThreshold: Int64 = 272_000

    // MARK: - Google (Gemini)

    /// Gemini 3.x Flash 的促销单价到 2026-12-31 为止，之后官方已经公布了翻倍后
    /// 的价格，所以这里是两档而不是一个终点。Checked on 2026-09-05 against
    /// ai.google.dev/gemini-api/docs/pricing.
    private static let geminiPromotionEnd = date("2027-01-01T00:00:00Z")

    /// Gemini 的上下文缓存不按写入 Token 计费，而是按存储小时收费，本机日志里
    /// 也没有缓存写入 Token。没有可换算的量就记 0，不用别的费率顶替。
    private static let geminiPrices: [String: [Price]] = [
        "gemini-3.8-flash": [
            Price(0.75, 0.075, 0, 3.75, validBefore: geminiPromotionEnd),
            Price(1.5, 0.15, 0, 7.5)
        ],
        "gemini-3.7-flash": [
            Price(0.75, 0.075, 0, 3.75, validBefore: geminiPromotionEnd),
            Price(1.5, 0.15, 0, 7.5)
        ],
        "gemini-3.6-flash": [
            Price(0.75, 0.075, 0, 3.75, validBefore: geminiPromotionEnd),
            Price(1.5, 0.15, 0, 7.5)
        ],
        "gemini-3.5-flash": [Price(1.5, 0.15, 0, 9)]
    ]

    // MARK: - Estimates

    static func estimateClaude(
        modelID: String,
        usage: TokenBreakdown,
        oneHourCacheCreationTokens: Int64 = 0,
        now: Date = Date()
    ) -> Double? {
        estimate(
            price: currentPrice(modelID, in: claudePrices, now: now),
            usage: usage,
            oneHourCacheCreationTokens: oneHourCacheCreationTokens
        )
    }

    static func estimateGrok(
        modelID: String,
        usage: TokenBreakdown,
        now: Date = Date()
    ) -> Double? {
        estimate(
            price: currentPrice(strippedGrokSuffix(modelID), in: grokPrices, now: now),
            usage: usage
        )
    }

    static func estimateGemini(
        modelID: String,
        usage: TokenBreakdown,
        now: Date = Date()
    ) -> Double? {
        estimate(
            price: currentPrice(modelID, in: geminiPrices, now: now),
            usage: usage
        )
    }

    static func estimateCodex(
        modelID: String,
        usage: TokenBreakdown,
        now: Date = Date()
    ) -> Double? {
        guard let price = currentPrice(modelID, in: codexPrices, now: now) else {
            return nil
        }
        let isLongContext = usage.inputTokens > codexLongContextThreshold
        let inputMultiplier = isLongContext ? 2.0 : 1.0
        let outputMultiplier = isLongContext ? 1.5 : 1.0
        let million = 1_000_000.0
        return Double(usage.freshInputTokens) / million
            * price.inputPerMillion * inputMultiplier
            + Double(usage.cachedReadTokens) / million
            * price.cachedInputPerMillion * inputMultiplier
            + Double(usage.cacheCreationTokens) / million
            * price.cacheWritePerMillion * inputMultiplier
            + Double(usage.outputTokens) / million
            * price.outputPerMillion * outputMultiplier
    }

    // MARK: - Availability

    /// 一行没有金额时，说明是哪一种「没有」。三种情况在账面上完全不同：
    /// 来源按额度计费、价目表没收录这个模型、收录过但所有单价档都已过期。
    /// 统一写成「无费用」会被读成「这行不花钱」。
    static func availability(
        modelID: String,
        provider: ProviderKind,
        now: Date = Date()
    ) -> UsageCostAvailability {
        if isUnidentifiedModel(modelID) { return .unknownModel }
        if quotaBilledProviders.contains(provider) { return .quotaBilled }
        guard let schedule = schedule(modelID: modelID, provider: provider) else {
            return .unlistedModel
        }
        return current(in: schedule, now: now) == nil ? .expiredRate : .priced
    }

    /// 解析器拿不到模型身份时发出的占位 ID。这不是「价目表缺了一条」，而是
    /// 不知道该查哪一条；写成「未收录单价」会让人以为补个价格就能修好。
    private static func isUnidentifiedModel(_ modelID: String) -> Bool {
        modelID.hasSuffix("-unknown") || modelID == "agy-activity-estimate"
    }

    /// 百炼只暴露 Credits 与额度，没有可换算的官方 Token 单价；不从 Token
    /// 反推是 AGENTS.md 的既定约束。
    private static let quotaBilledProviders: Set<ProviderKind> = [.alibaba]

    private static func schedule(
        modelID: String,
        provider: ProviderKind
    ) -> [Price]? {
        switch provider {
        case .anthropic:
            return matched(modelID, in: claudePrices)
        case .xAI:
            return matched(strippedGrokSuffix(modelID), in: grokPrices)
        case .openAI:
            return matched(modelID, in: codexPrices)
        case .google:
            return matched(modelID, in: geminiPrices)
        case .alibaba:
            return nil
        }
    }

    // MARK: - Lookup

    private static func strippedGrokSuffix(_ modelID: String) -> String {
        modelID.hasSuffix("-build")
            ? String(modelID.dropLast("-build".count))
            : modelID
    }

    /// 会话日志里的模型名常带档位或变体后缀（`gpt-5.6-sol-high`、
    /// `gemini-3.8-flash-tiered`），精确匹配会让它们静默无价。取最长前缀，
    /// 免得 `gpt-5.6` 抢走 `gpt-5.6-luna` 的单价。
    private static func matched(
        _ modelID: String,
        in table: [String: [Price]]
    ) -> [Price]? {
        var best: (key: String, schedule: [Price])?
        for (known, schedule) in table where modelID.hasPrefix(known) {
            if best == nil || known.count > (best?.key.count ?? 0) {
                best = (known, schedule)
            }
        }
        return best?.schedule
    }

    private static func currentPrice(
        _ modelID: String,
        in table: [String: [Price]],
        now: Date
    ) -> Price? {
        guard let schedule = matched(modelID, in: table) else { return nil }
        return current(in: schedule, now: now)
    }

    /// 命中第一个尚未过期的档。档位按时间先后写在表里，所以线性扫描即可。
    private static func current(in schedule: [Price], now: Date) -> Price? {
        schedule.first { price in
            guard let validBefore = price.validBefore else { return true }
            return now < validBefore
        }
    }

    private static func estimate(
        price: Price?,
        usage: TokenBreakdown,
        oneHourCacheCreationTokens: Int64 = 0
    ) -> Double? {
        guard let price else { return nil }
        let selected: (
            input: Double,
            cached: Double,
            cacheWrite: Double,
            output: Double
        )
        if let long = price.longContext, usage.inputTokens >= long.threshold {
            selected = (
                long.inputPerMillion,
                long.cachedInputPerMillion,
                price.cacheWritePerMillion * long.inputPerMillion / price.inputPerMillion,
                long.outputPerMillion
            )
        } else {
            selected = (
                price.inputPerMillion,
                price.cachedInputPerMillion,
                price.cacheWritePerMillion,
                price.outputPerMillion
            )
        }

        let million = 1_000_000.0
        let oneHourWrite = min(
            usage.cacheCreationTokens,
            max(0, oneHourCacheCreationTokens)
        )
        let fiveMinuteWrite = usage.cacheCreationTokens - oneHourWrite
        return Double(usage.freshInputTokens) / million * selected.input
            + Double(usage.cachedReadTokens) / million * selected.cached
            + Double(fiveMinuteWrite) / million * selected.cacheWrite
            + Double(oneHourWrite) / million * selected.input * 2
            + Double(usage.outputTokens) / million * selected.output
    }
}

/// 一行为什么显示不出费用。金额本身是 `nil` 时才有意义。
nonisolated enum UsageCostAvailability: String, Sendable {
    case priced
    case quotaBilled
    case unlistedModel
    case unknownModel
    case expiredRate

    var localizedCaption: String {
        switch self {
        case .priced: return ""
        case .quotaBilled: return "按额度计费"
        case .unlistedModel: return "未收录单价"
        case .unknownModel: return "模型未知"
        case .expiredRate: return "单价已过期"
        }
    }
}
