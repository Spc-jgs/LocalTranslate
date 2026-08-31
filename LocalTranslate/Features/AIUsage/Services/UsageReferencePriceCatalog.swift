import Foundation

nonisolated enum UsageReferencePriceCatalog {
    private struct Price {
        let inputPerMillion: Double
        let cachedInputPerMillion: Double
        let cacheWritePerMillion: Double
        let outputPerMillion: Double
        let longContext: LongContextPrice?

        init(
            _ inputPerMillion: Double,
            _ cachedInputPerMillion: Double,
            _ cacheWritePerMillion: Double,
            _ outputPerMillion: Double,
            longContext: LongContextPrice? = nil
        ) {
            self.inputPerMillion = inputPerMillion
            self.cachedInputPerMillion = cachedInputPerMillion
            self.cacheWritePerMillion = cacheWritePerMillion
            self.outputPerMillion = outputPerMillion
            self.longContext = longContext
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

    static func estimateClaude(
        modelID: String,
        usage: TokenBreakdown,
        oneHourCacheCreationTokens: Int64 = 0
    ) -> Double? {
        estimate(
            price: claudePrices[normalizedClaudeModelID(modelID)],
            usage: usage,
            oneHourCacheCreationTokens: oneHourCacheCreationTokens
        )
    }

    static func estimateGrok(modelID: String, usage: TokenBreakdown) -> Double? {
        let normalized = modelID.hasSuffix("-build")
            ? String(modelID.dropLast("-build".count))
            : modelID
        return estimate(price: grokPrices[normalized], usage: usage)
    }

    private static func normalizedClaudeModelID(_ modelID: String) -> String {
        for known in claudePrices.keys where modelID.hasPrefix(known) {
            return known
        }
        return modelID
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
