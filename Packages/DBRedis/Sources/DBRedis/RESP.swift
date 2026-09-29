import Foundation
import NIOCore

/// A value in the Redis serialization protocol.
///
/// Tinker speaks RESP2, which every Redis-compatible server understands (Redis, Valkey,
/// KeyDB, Dragonfly, managed services). The RESP3 types are decoded too, so a server or
/// proxy that answers in RESP3 anyway is still understood. Bulk strings are bytes:
/// a Redis value is binary-safe and is only turned into text when shown.
public indirect enum RESPValue: Sendable, Hashable {
    case simpleString(String)
    /// The server's error line, verbatim — `ERR …`, `WRONGTYPE …`, `NOAUTH …`.
    case error(String)
    case integer(Int64)
    case bulkString(Data)
    case null
    case array([RESPValue])
    /// RESP3 double, kept as the server wrote it.
    case double(String)
    case boolean(Bool)
    /// RESP3 map, as alternating keys and values.
    case map([RESPValue])
    case set([RESPValue])
    case bigNumber(String)
    case verbatim(String)
    case push([RESPValue])

    /// The value as text: bulk strings decoded as UTF-8 (lossily), numbers as written.
    public var string: String? {
        switch self {
        // An error is not a value: a `TYPE` refused by an ACL must not read as a type named
        // "NOPERM …". Errors are read through their own case.
        case let .simpleString(text), let .double(text), let .bigNumber(text), let .verbatim(text):
            return text
        case let .bulkString(data):
            return String(decoding: data, as: UTF8.self)
        case let .integer(value):
            return String(value)
        case let .boolean(flag):
            return flag ? "1" : "0"
        default:
            return nil
        }
    }

    /// The raw bytes of a string reply.
    public var data: Data? {
        switch self {
        case let .bulkString(data): data
        case let .simpleString(text), let .verbatim(text): Data(text.utf8)
        default: nil
        }
    }

    public var integer: Int64? {
        switch self {
        case let .integer(value): value
        case let .bulkString(data): Int64(String(decoding: data, as: UTF8.self))
        case let .simpleString(text): Int64(text)
        case let .boolean(flag): flag ? 1 : 0
        default: nil
        }
    }

    /// Elements of an array, set, push or map reply; nil for anything else.
    public var array: [RESPValue]? {
        switch self {
        case let .array(items), let .set(items), let .push(items), let .map(items): items
        default: nil
        }
    }

    public var isNull: Bool { self == .null }

    /// A flat `field value field value …` reply (HGETALL, CONFIG GET, a RESP3 map) as pairs.
    public var pairs: [(RESPValue, RESPValue)] {
        guard let items = array else { return [] }
        return stride(from: 0, to: items.count - 1, by: 2).map { (items[$0], items[$0 + 1]) }
    }
}

/// One argument of a command. Arguments go over the wire as bulk strings, so a value
/// with spaces, quotes, newlines or arbitrary bytes needs no escaping.
public struct RedisArgument: Sendable, Hashable, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral {
    public let bytes: Data

    public init(_ bytes: Data) { self.bytes = bytes }
    public init(_ text: String) { bytes = Data(text.utf8) }
    public init(_ value: Int) { bytes = Data(String(value).utf8) }
    public init(_ value: Int64) { bytes = Data(String(value).utf8) }
    public init(stringLiteral value: String) { self.init(value) }
    public init(integerLiteral value: Int) { self.init(value) }
}

/// Encodes commands and decodes replies.
public enum RESPCodec {
    /// A command as an array of bulk strings.
    public static func encode(_ arguments: [RedisArgument], into buffer: inout ByteBuffer) {
        buffer.writeString("*\(arguments.count)\r\n")
        for argument in arguments {
            buffer.writeString("$\(argument.bytes.count)\r\n")
            buffer.writeBytes(argument.bytes)
            buffer.writeString("\r\n")
        }
    }

    /// Nesting deeper than this is not a reply any server sends; it is refused rather
    /// than followed down the stack.
    static let maximumDepth = 64
    /// Redis's own `proto-max-bulk-len` default: no string is longer.
    public static let maximumBulkLength = 512 * 1_024 * 1_024
    /// No aggregate reply holds more elements than this; a larger count is damage.
    static let maximumElements = 1 << 28

    /// Decodes one complete value from the front of `buffer`, advancing past it. Returns
    /// nil, leaving the buffer as it was, when the value has not fully arrived yet.
    public static func decode(_ buffer: inout ByteBuffer) throws -> RESPValue? {
        var copy = buffer
        guard let value = try decodeValue(&copy, depth: 0) else { return nil }
        buffer = copy
        return value
    }

    private static func line(_ buffer: inout ByteBuffer) -> String? {
        let view = buffer.readableBytesView
        guard let cr = view.firstIndex(of: UInt8(ascii: "\r")), cr + 1 < view.endIndex,
            view[cr + 1] == UInt8(ascii: "\n")
        else { return nil }
        let length = cr - view.startIndex
        let text = buffer.readString(length: length)
        buffer.moveReaderIndex(forwardBy: 2)
        return text
    }

    private static func decodeValue(_ buffer: inout ByteBuffer, depth: Int) throws -> RESPValue? {
        guard depth < maximumDepth else { throw RESPError("reply nested more than \(maximumDepth) deep") }
        guard let type = buffer.readInteger(as: UInt8.self) else { return nil }
        switch type {
        case UInt8(ascii: "+"):
            return line(&buffer).map(RESPValue.simpleString)
        case UInt8(ascii: "-"):
            return line(&buffer).map(RESPValue.error)
        case UInt8(ascii: ":"):
            guard let text = line(&buffer) else { return nil }
            guard let value = Int64(text) else { throw RESPError("bad integer \(text)") }
            return .integer(value)
        case UInt8(ascii: "$"), UInt8(ascii: "="), UInt8(ascii: "!"):
            guard let text = line(&buffer) else { return nil }
            guard let length = Int(text), length >= -1, length <= maximumBulkLength else {
                throw RESPError("bad length \(text)")
            }
            if length < 0 { return .null }
            guard buffer.readableBytes >= length + 2, let bytes = buffer.readBytes(length: length) else { return nil }
            buffer.moveReaderIndex(forwardBy: 2)
            let data = Data(bytes)
            if type == UInt8(ascii: "!") { return .error(String(decoding: data, as: UTF8.self)) }
            if type == UInt8(ascii: "=") {
                // `txt:` or `mkd:` then the text.
                let text = String(decoding: data, as: UTF8.self)
                return .verbatim(text.count > 4 ? String(text.dropFirst(4)) : text)
            }
            return .bulkString(data)
        case UInt8(ascii: "*"), UInt8(ascii: "~"), UInt8(ascii: ">"), UInt8(ascii: "%"), UInt8(ascii: "|"):
            guard let text = line(&buffer) else { return nil }
            guard let declared = Int(text), declared >= -1, declared <= maximumElements else {
                throw RESPError("bad count \(text)")
            }
            if declared < 0 { return .null }
            let isMap = type == UInt8(ascii: "%") || type == UInt8(ascii: "|")
            let count = isMap ? declared * 2 : declared
            var items: [RESPValue] = []
            items.reserveCapacity(min(count, 4_096))
            for _ in 0 ..< count {
                guard let item = try decodeValue(&buffer, depth: depth + 1) else { return nil }
                items.append(item)
            }
            // RESP3 attributes (`|`) describe the reply that follows; the reply is what matters.
            if type == UInt8(ascii: "|") { return try decodeValue(&buffer, depth: depth + 1) }
            switch type {
            case UInt8(ascii: "~"): return .set(items)
            case UInt8(ascii: ">"): return .push(items)
            case UInt8(ascii: "%"): return .map(items)
            default: return .array(items)
            }
        case UInt8(ascii: "_"):
            return line(&buffer).map { _ in .null }
        case UInt8(ascii: ","):
            return line(&buffer).map(RESPValue.double)
        case UInt8(ascii: "#"):
            return line(&buffer).map { .boolean($0 == "t") }
        case UInt8(ascii: "("):
            return line(&buffer).map(RESPValue.bigNumber)
        default:
            throw RESPError("unexpected reply type byte \(type)")
        }
    }
}

/// Finds where a complete reply ends without building it, and remembers how far it got
/// between network reads: a reply of a million elements arriving in 64 KiB pieces is
/// walked once, not once per piece, and only built when all of it is there.
struct RESPFrameScanner {
    /// Bytes from the frame's start that are known to be complete elements or headers.
    private var offset = 0
    /// For each open aggregate: the elements still expected, and whether it is an
    /// attribute (which is followed by the reply it describes rather than counting as one).
    private var open: [(remaining: Int, isAttribute: Bool)] = []

    /// The frame's length when it is complete, nil while it is not. Throws on bytes that
    /// cannot be a reply.
    mutating func scan(_ buffer: ByteBuffer) throws -> Int? {
        let view = buffer.readableBytesView
        let base = view.startIndex
        while true {
            let start = base + offset
            guard start < view.endIndex else { return nil }
            guard let cr = view[start...].firstIndex(of: UInt8(ascii: "\r")), cr + 1 < view.endIndex else { return nil }
            guard view[cr + 1] == UInt8(ascii: "\n") else { throw RESPError("header without CRLF") }
            let type = view[start]
            let header = String(decoding: view[(start + 1) ..< cr], as: UTF8.self)
            var consumed = cr + 2 - start
            var opens: (Int, Bool)?
            switch type {
            case UInt8(ascii: "$"), UInt8(ascii: "="), UInt8(ascii: "!"):
                guard let length = Int(header), length >= -1, length <= RESPCodec.maximumBulkLength else {
                    throw RESPError("bad length \(header)")
                }
                if length >= 0 {
                    guard view.endIndex - (cr + 2) >= length + 2 else { return nil }
                    consumed += length + 2
                }
            case UInt8(ascii: "*"), UInt8(ascii: "~"), UInt8(ascii: ">"), UInt8(ascii: "%"), UInt8(ascii: "|"):
                guard let count = Int(header), count >= -1, count <= RESPCodec.maximumElements else {
                    throw RESPError("bad count \(header)")
                }
                let isMap = type == UInt8(ascii: "%") || type == UInt8(ascii: "|")
                if count > 0 {
                    opens = (isMap ? count * 2 : count, type == UInt8(ascii: "|"))
                } else if type == UInt8(ascii: "|") {
                    // An empty attribute: the reply it annotates is still to come.
                    offset += consumed
                    continue
                }
            case UInt8(ascii: "+"), UInt8(ascii: "-"), UInt8(ascii: ":"), UInt8(ascii: "_"), UInt8(ascii: ","),
                UInt8(ascii: "#"), UInt8(ascii: "("):
                break
            default:
                throw RESPError("unexpected reply type byte \(type)")
            }
            offset += consumed
            guard open.count < RESPCodec.maximumDepth else { throw RESPError("reply nested too deep") }
            if let (count, isAttribute) = opens {
                open.append((count, isAttribute))
                continue
            }
            // An element finished: count it against the aggregates it closes.
            var closedAttribute = false
            while let last = open.last {
                open[open.count - 1].remaining -= 1
                guard open[open.count - 1].remaining == 0 else { break }
                open.removeLast()
                // An attribute is followed by the reply it annotates, which is the element.
                if last.isAttribute {
                    closedAttribute = true
                    break
                }
            }
            if open.isEmpty, !closedAttribute {
                let length = offset
                offset = 0
                return length
            }
        }
    }
}

/// A reply that does not follow the protocol: the connection cannot be trusted after it.
public struct RESPError: Error, CustomStringConvertible, Sendable, Hashable {
    public let description: String
    init(_ description: String) { self.description = "Redis protocol error: \(description)" }
}
