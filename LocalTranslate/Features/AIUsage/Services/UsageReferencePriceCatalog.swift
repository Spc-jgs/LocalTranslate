import Foundation

/// 参考费用的单一出处：Anthropic、OpenAI（Codex）与 xAI 的官方标准 API 单价，
/// 以及「这个模型为什么没有费用」的判定。价目分散会让两侧各自漂移，
/// 也会让 UI 只剩下一个无从解释的破折号。
nonisolated enum UsageReferencePriceCatalog {
    private struct Price {
        let inputPerMillion: Double
        let cachedInputPerMillion: Double
        let cacheWritePerMillion: Double
        let outputPerMillion: Double
        let longContext: LongContextPrice?
        /// 促销价这类有时效的单价到期后不再换算，也不静默沿用。
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

    // Anthropic standard global API list prices checked on 2026-08-30.
    private static let claudePrices: [String: Price] = [
        "claude-opus-5": Price(5, 0.5, 6.25, 25),
        "claude-opus-4-8": Price(5, 0.5, 6.25, 25),
        "claude-opus-4-7": Price(5, 0.5, 6.25, 25),
        "claude-opus-4-6": Price(5, 0.5, 6.25, 25),
        "claude-opus-4-5": Price(5, 0.5, 6.25, 25),
        "claude-sonnet-5": Price(2, 0.2, 2.5, 10),
        "claude-sonnet-4-6": Price(3, 0.3, 3.75, 15),
        "claude-sonnet-4-5": Price(3, 0.3, 3.75, 15),
        "claude-haiku-4-5": Price(1, 0.1, 1.25, 5)
    ]

    // xAI standard API list prices checked on 2026-08-30. Grok Build's
    // `-build` suffix is normalized to the matching public API model.
    private static let grokPrices: [String: Price] = [
        "grok-4.6": Price(
            2,
            0.5,
            2,
            6,
            longContext: LongContextPrice(200_000, 4, 1, 12)
        ),
        "grok-4.5": Price(
            2,
            0.3,
            2,
            6,
            longContext: LongContextPrice(200_000, 4, 0.6, 12)
        )
    ]

    /// Promotional GPT-5.6 prices published by OpenAI and guaranteed through
    /// 2026-11-21. After that the entry stays listed so the UI can say the rate
    /// expired instead of pretending the model was never priced.
    private static let codexPromotionEnd = Date(timeIntervalSince1970: 1_795_305_600)

    private static let codexPrices: [String: Price] = [
        "gpt-5.6": Price(4, 0.4, 5, 20, validBefore: codexPromotionEnd),
        "gpt-5.6-sol": Price(4, 0.4, 5, 20, validBefore: codexPromotionEnd),
        "gpt-5.6-terra": Price(2, 0.2, 2.5, 12, validBefore: codexPromotionEnd),
        "gpt-5.6-luna": Price(0.2, 0.02, 0.25, 1.2, validBefore: codexPromotionEnd)
    ]

    /// OpenAI 的长上下文加价与 Anthropic/xAI 不同：超过阈值后输入 ×2、输出 ×1.5，
    /// 而不是换一张单价表。
    private static let codexLongContextThreshold: Int64 = 272_000

    static func estimateClaude(
        modelID: String,
        usage: TokenBreakdown,
        oneHourCacheCreationTokens: Int64 = 0,
        now: Date = Date()
    ) -> Double? {
        estimate(
            price: claudePrices[normalizedClaudeModelID(modelID)],
            usage: usage,
            oneHourCacheCreationTokens: oneHourCacheCreationTokens,
            now: now
        )
    }

    static func estimateGrok(
        modelID: String,
        usage: TokenBreakdown,
        now: Date = Date()
    ) -> Double? {
        estimate(
            price: grokPrices[normalizedGrokModelID(modelID)],
            usage: usage,
            now: now
        )
    }

    static func estimateCodex(
        modelID: String,
        usage: TokenBreakdown,
        now: Date = Date()
    ) -> Double? {
        guard let price = codexPrices[normalizedCodexModelID(modelID)] else {
            return nil
        }
        if let validBefore = price.validBefore, now >= validBefore { return nil }

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

    /// 一行没有费用时，说明是哪一种「没有」。三种情况在账面上完全不同：
    /// 来源按额度计费、单价没收录、收录过但已过期。UI 把它们都写成
    /// 「无费用」会读成「这行不花钱」，而 Gemini 与 gpt-6-astra 都在花钱。
    static func availability(
        modelID: String,
        provider: ProviderKind,
        now: Date = Date()
    ) -> UsageCostAvailability {
        guard let price = price(modelID: modelID, provider: provider) else {
            return quotaBilledProviders.contains(provider)
                ? .quotaBilled
                : .unlistedModel
        }
        if let validBefore = price.validBefore, now >= validBefore {
            return .expiredRate
        }
        return .priced
    }

    /// 这些来源在本机只暴露订阅额度或 Credits，没有可换算的官方 Token 单价；
    /// 不从 Token 反推是 AGENTS.md 的既定约束。
    private static let quotaBilledProviders: Set<ProviderKind> = [
        .google, .alibaba
    ]

    private static func price(
        modelID: String,
        provider: ProviderKind
    ) -> Price? {
        switch provider {
        case .anthropic:
            return claudePrices[normalizedClaudeModelID(modelID)]
        case .xAI:
            return grokPrices[normalizedGrokModelID(modelID)]
        case .openAI:
            return codexPrices[normalizedCodexModelID(modelID)]
        case .google, .alibaba:
            return nil
        }
    }

    private static func normalizedClaudeModelID(_ modelID: String) -> String {
        longestPrefixMatch(modelID, in: claudePrices) ?? modelID
    }

    private static func normalizedGrokModelID(_ modelID: String) -> String {
        let stripped = modelID.hasSuffix("-build")
            ? String(modelID.dropLast("-build".count))
            : modelID
        return longestPrefixMatch(stripped, in: grokPrices) ?? stripped
    }

    /// Codex 会话里的模型名带推理档位等后缀（`gpt-5.6-sol-high`），
    /// 精确匹配会让它们静默无价。取最长前缀，避免 `gpt-5.6` 抢走
    /// `gpt-5.6-luna` 的单价。
    private static func normalizedCodexModelID(_ modelID: String) -> String {
        longestPrefixMatch(modelID, in: codexPrices) ?? modelID
    }

    private static func longestPrefixMatch(
        _ modelID: String,
        in table: [String: Price]
    ) -> String? {
        var best: String?
        for known in table.keys where modelID.hasPrefix(known) {
            if best == nil || known.count > (best?.count ?? 0) { best = known }
        }
        return best
    }

    private static func estimate(
        price: Price?,
        usage: TokenBreakdown,
        oneHourCacheCreationTokens: Int64 = 0,
        now: Date = Date()
    ) -> Double? {
        guard let price else { return nil }
        if let validBefore = price.validBefore, now >= validBefore { return nil }
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
    case expiredRate

    var localizedCaption: String {
        switch self {
        case .priced: return ""
        case .quotaBilled: return "按额度计费"
        case .unlistedModel: return "未收录单价"
        case .expiredRate: return "单价已过期"
        }
    }
}
