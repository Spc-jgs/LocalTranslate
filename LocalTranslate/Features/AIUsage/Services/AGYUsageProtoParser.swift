import Foundation

nonisolated struct AGYRecordedUsage: Sendable, Equatable {
    let occurredAt: Date?
    let modelID: String?
    let modelLabel: String?
    let responseID: String?
    let usage: TokenBreakdown
}

/// 只解码 AGY `gen_metadata.data` 中已确认的模型与生成用量字段。
/// 未知字段全部跳过；时间缺失时只返回模型证据，调用方不得把 Token 猜到某一天。
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
        var seconds: UInt64?
        var nanos: UInt64 = 0
        var modelID: String?
        var modelLabel: String?
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
            let occurredAt = try timestamp(seconds: turn.seconds, nanos: turn.nanos)
            guard input > 0 || output > 0 || turn.modelID != nil || turn.modelLabel != nil else {
                return nil
            }
            return AGYRecordedUsage(
                occurredAt: occurredAt,
                modelID: turn.modelID,
                modelLabel: turn.modelLabel,
                responseID: rawUsage.responseID,
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
            case 9:
                try parseGeneration(field.message(), into: &turn)
            case 19:
                turn.modelID = try field.string()
            case 21:
                turn.modelLabel = try field.string()
            default:
                break
            }
        }
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

    private static func parseGeneration(
        _ bytes: ArraySlice<UInt8>,
        into turn: inout ParsedTurn
    ) throws {
        try visit(bytes) { generationField in
            guard generationField.number == 4 else { return }
            try visit(generationField.message()) { timestampField in
                switch timestampField.number {
                case 1:
                    turn.seconds = try timestampField.unsignedInteger()
                case 2:
                    turn.nanos = try timestampField.unsignedInteger()
                default:
                    break
                }
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

    private static func timestamp(seconds: UInt64?, nanos: UInt64) throws -> Date? {
        guard let seconds else { return nil }
        guard seconds > 0, seconds <= 253_402_300_799,
              nanos <= 999_999_999,
              let exactSeconds = Int64(exactly: seconds),
              let exactNanos = Int64(exactly: nanos) else {
            throw ParseError.malformed
        }
        let milliseconds = exactSeconds * 1_000 + exactNanos / 1_000_000
        return Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000)
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
