import AppKit
import Foundation

/// 用 TextKit 实测一段文本在给定宽度下的排版高度。
///
/// 这里替换的是原先按「字符数 ÷ 每行字数」估算行数的做法。那个启发式对
/// 中文与拉丁文的字宽差异（约 2:1）无能为力，也无法感知翻译方向：中→英
/// 时按中文字宽估算会把窗口撑到实际需要的两倍，英→中时又会不够。
@MainActor
enum TextHeightMeasurer {

    private struct CacheKey: Hashable {
        let text: String
        let width: CGFloat
        let fontSize: CGFloat
        let fontWeightRaw: CGFloat
        let lineSpacing: CGFloat
    }

    private static var cache: [CacheKey: CGFloat] = [:]
    private static var insertionOrder: [CacheKey] = []
    private static let cacheLimit = 128

    /// 文本实际占用的高度；空文本返回单行高度。
    static func height(
        for text: String,
        width: CGFloat,
        fontSize: CGFloat,
        fontWeight: NSFont.Weight = .regular,
        lineSpacing: CGFloat = 0
    ) -> CGFloat {

        guard width > 0 else { return 0 }

        let key = CacheKey(
            text: text,
            width: width,
            fontSize: fontSize,
            fontWeightRaw: fontWeight.rawValue,
            lineSpacing: lineSpacing
        )

        if let cached = cache[key] {
            return cached
        }

        let height = measure(
            text: text,
            width: width,
            fontSize: fontSize,
            fontWeight: fontWeight,
            lineSpacing: lineSpacing
        )

        store(height, for: key)
        return height
    }

    private static func measure(
        text: String,
        width: CGFloat,
        fontSize: CGFloat,
        fontWeight: NSFont.Weight,
        lineSpacing: CGFloat
    ) -> CGFloat {

        let font = NSFont.systemFont(
            ofSize: fontSize,
            weight: fontWeight
        )

        // 空文本仍然要占一行，否则容器会在首次输入时跳变。
        let measured = text.isEmpty ? " " : text

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = lineSpacing

        let storage = NSTextStorage(
            string: measured,
            attributes: [
                .font: font,
                .paragraphStyle: paragraphStyle
            ]
        )

        let container = NSTextContainer(
            size: NSSize(
                width: width,
                height: .greatestFiniteMagnitude
            )
        )
        container.lineFragmentPadding = 0

        let layoutManager = NSLayoutManager()
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)

        layoutManager.ensureLayout(for: container)

        return ceil(
            layoutManager.usedRect(for: container).height
        )
    }

    private static func store(_ height: CGFloat, for key: CacheKey) {
        cache[key] = height
        insertionOrder.append(key)

        guard insertionOrder.count > cacheLimit else { return }

        // 流式翻译每秒会产生多个不同的中间文本，缓存必须有上界。
        let evicted = insertionOrder.removeFirst()
        cache.removeValue(forKey: evicted)
    }
}
