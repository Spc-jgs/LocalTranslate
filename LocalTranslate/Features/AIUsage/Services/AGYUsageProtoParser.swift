import Foundation

nonisolated struct AGYRecordedUsage: Sendable, Equatable {
    let modelID: String?
    let modelLabel: String?
    let responseID: String?
    /// 这次生成在 `steps` 表里的行号；事件时间只能从这一行取。
    let lastStepIndex: Int64?
    let usage: TokenBreakdown
}

/// 只解码 AGY 本机会话库中已确认的字段，未知字段全部跳过。
///
/// 职责边界：这里只负责「一段 blob 里有什么」。事件时间不在 `gen_metadata`
/// 里——实测 1451 行样本中该表没有任何精度的事件时间戳；时间由 `steps.metadata`
/// 提供，而两表的 `idx` **各自独立递增**：`gen_metadata` 每次模型生成加一，
/// `steps` 连用户消息与工具调用一起加一。跨表关联只能走本记录里的
/// `last_step_index`，关联由 indexer 完成。
nonisolated enum AGYUsageProtoParser {
    private enum ParseError: Error {
        case malformed
    }

    private struct ParsedUsage {
        var systemPrompt: Int64 = 0
        var newInput: Int64 = 0
        var cacheRead: Int64 = 0
        var textOutput: Int64 = 0
        var reasoningOutput: Int64 = 0
        var responseID: String?
    }

    private struct ParsedTurn {
        var usage: ParsedUsage?
        var modelID: String?
        var modelLabel: String?
        var lastStepIndex: Int64?
    }

    private struct Field {
        let number: Int
        let wireType: Int
        let bytes: ArraySlice<UInt8>?
        let integer: UInt64?

        func message() throws -> ArraySlice<UInt8> {
            guard wireType == 2, let bytes else { throw ParseError.malformed }
            return bytes
        }

        func unsignedInteger() throws -> UInt64 {
            guard wireType == 0, let integer else { throw ParseError.malformed }
            return integer
        }

        func counter() throws -> Int64 {
            guard let value = Int64(exactly: try unsignedInteger()) else {
                throw ParseError.malformed
            }
            return value
        }

        func string() throws -> String? {
            guard let value = String(bytes: try message(), encoding: .utf8) else {
                throw ParseError.malformed
            }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    private struct Reader {
        let bytes: ArraySlice<UInt8>
        var offset: Int
        var malformed = false

        init(_ bytes: ArraySlice<UInt8>) {
            self.bytes = bytes
            self.offset = bytes.startIndex
        }

        mutating func nextField() -> Field? {
            guard offset < bytes.endIndex else { return nil }
            guard let tag = readVarint(), tag >> 3 > 0, tag >> 3 <= 536_870_911 else {
                malformed = true
                return nil
            }
            let number = Int(tag >> 3)
            let wireType = Int(tag & 7)
            if wireType == 0 {
                guard let value = readVarint() else { return nil }
                return Field(number: number, wireType: wireType, bytes: nil, integer: value)
            }

            let length: Int?
            switch wireType {
            case 1:
                length = 8
            case 2:
                length = readVarint().flatMap(Int.init(exactly:))
            case 5:
                length = 4
            default:
                length = nil
            }
            guard let length, length <= bytes.endIndex - offset else {
                malformed = true
                return nil
            }
            let end = offset + length
            let payload = bytes[offset..<end]
            offset = end
            return Field(number: number, wireType: wireType, bytes: payload, integer: nil)
        }

        private mutating func readVarint() -> UInt64? {
            var result: UInt64 = 0
            for index in 0..<10 {
                guard offset < bytes.endIndex else { break }
                let byte = bytes[offset]
                offset += 1
                if index == 9, byte > 1 { break }
                result |= UInt64(byte & 0x7F) << (index * 7)
                if byte & 0x80 == 0 { return result }
            }
            malformed = true
            return nil
        }
    }

    static func parse(_ data: Data) -> AGYRecordedUsage? {
        do {
            let rawBytes = [UInt8](data)
            var turn = ParsedTurn()
            var foundChat = false
            try visit(rawBytes[...]) { field in
                guard field.number == 1 else { return }
                foundChat = true
                try parseChat(field.message(), into: &turn)
            }
            guard foundChat else { return nil }
            let rawUsage = turn.usage ?? ParsedUsage()
            guard let input = checkedSum([
                rawUsage.systemPrompt,
                rawUsage.newInput,
                rawUsage.cacheRead
            ]),
            let output = checkedSum([
                rawUsage.textOutput,
                rawUsage.reasoningOutput
            ]) else {
                return nil
            }
            guard input > 0 || output > 0 || turn.modelID != nil || turn.modelLabel != nil else {
                return nil
            }
            return AGYRecordedUsage(
                modelID: turn.modelID,
                modelLabel: turn.modelLabel,
                responseID: rawUsage.responseID,
                lastStepIndex: turn.lastStepIndex,
                usage: TokenBreakdown(
                    inputTokens: input,
                    outputTokens: output,
                    cachedReadTokens: rawUsage.cacheRead,
                    reasoningTokens: rawUsage.reasoningOutput
                )
            )
        } catch {
            return nil
        }
    }

    private static func parseChat(
        _ bytes: ArraySlice<UInt8>,
        into turn: inout ParsedTurn
    ) throws {
        try visit(bytes) { field in
            switch field.number {
            case 4:
                var usage = turn.usage ?? ParsedUsage()
                try parseUsage(field.message(), into: &usage)
                turn.usage = usage
            case 19:
                turn.modelID = try field.string()
            case 20:
                if let index = try parseStepIndex(field.message()) {
                    turn.lastStepIndex = index
                }
            case 21:
                turn.modelLabel = try field.string()
            default:
                break
            }
        }
    }

    /// `chat.20` 是一组 key/value 字符串对，其中 `last_step_index` 指出这次生成
    /// 落在 `steps` 表的哪一行。没有它就无法给这条用量定时间——`gen_metadata.idx`
    /// 与 `steps.idx` 不同步，直接相等会把 Token 记到别的日子。
    private static func parseStepIndex(_ bytes: ArraySlice<UInt8>) throws -> Int64? {
        var key: String?
        var value: String?
        try visit(bytes) { field in
            switch field.number {
            case 1: key = try field.string()
            case 2: value = try field.string()
            default: break
            }
        }
        guard key == "last_step_index", let value else { return nil }
        return Int64(value)
    }

    private static func parseUsage(
        _ bytes: ArraySlice<UInt8>,
        into usage: inout ParsedUsage
    ) throws {
        try visit(bytes) { field in
            switch field.number {
            case 1: usage.systemPrompt = try field.counter()
            case 2: usage.newInput = try field.counter()
            case 5: usage.cacheRead = try field.counter()
            case 9: usage.textOutput = try field.counter()
            case 10: usage.reasoningOutput = try field.counter()
            case 11: usage.responseID = try field.string()
            default: break
            }
        }
    }

    private static func visit(
        _ bytes: ArraySlice<UInt8>,
        _ body: (Field) throws -> Void
    ) throws {
        var reader = Reader(bytes)
        while reader.offset < reader.bytes.endIndex {
            guard let field = reader.nextField() else { break }
            try body(field)
        }
        if reader.malformed { throw ParseError.malformed }
    }

    /// 解析 `steps.metadata` 的事件时间（protobuf 路径 1.1，Unix 秒）。
    ///
    /// 只需要 blob 开头的几十字节：实测 1451 行样本中前 32 字节即可 100% 解出，
    /// 因此调用方用 `substr(metadata, 1, 64)` 读取，不必载入整个 blob。
    static func stepTimestamp(_ data: Data) -> Date? {
        var seconds: UInt64?

        // 只读前缀必然在中途截断，`visit` 会因此抛 malformed；那是预期结果，
        // 不能连同已经读到的时间一起丢弃。
        try? visit([UInt8](data)[...]) { field in
            guard seconds == nil, field.number == 1, field.wireType == 2 else {
                return
            }
            try? visit(field.message()) { inner in
                guard inner.number == 1, inner.wireType == 0 else { return }
                seconds = try? inner.unsignedInteger()
            }
        }

        guard let seconds,
              seconds > 1_600_000_000,
              seconds < 4_102_444_800 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    private static func checkedSum(_ values: [Int64]) -> Int64? {
        var result: Int64 = 0
        for value in values {
            let (next, overflow) = result.addingReportingOverflow(value)
            guard !overflow else { return nil }
            result = next
        }
        return result
    }
}
