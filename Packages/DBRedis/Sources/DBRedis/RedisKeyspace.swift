import DBCore
import Foundation

/// A Redis key type, as `TYPE` names it.
public enum RedisKeyType: Sendable, Hashable, CaseIterable {
    case string, hash, list, set, zset, stream, json
    /// Anything else a module adds: TimeSeries, Bloom, vector sets… shown, not edited.
    case other(String)

    public static let allCases: [RedisKeyType] = [.string, .hash, .list, .set, .zset, .stream, .json]

    public init(typeName: String) {
        switch typeName.lowercased() {
        case "string": self = .string
        case "hash": self = .hash
        case "list": self = .list
        case "set": self = .set
        case "zset": self = .zset
        case "stream": self = .stream
        case "rejson-rl", "json": self = .json
        default: self = .other(typeName)
        }
    }

    /// What `SCAN … TYPE` expects.
    public var scanName: String {
        switch self {
        case .string: "string"
        case .hash: "hash"
        case .list: "list"
        case .set: "set"
        case .zset: "zset"
        case .stream: "stream"
        case .json: "ReJSON-RL"
        case let .other(name): name
        }
    }

    public var displayName: String {
        switch self {
        case .string: "String"
        case .hash: "Hash"
        case .list: "List"
        case .set: "Set"
        case .zset: "Sorted Set"
        case .stream: "Stream"
        case .json: "JSON"
        case let .other(name): name
        }
    }

    /// The command that says how many elements the key holds.
    var lengthCommand: String? {
        switch self {
        case .string: "STRLEN"
        case .hash: "HLEN"
        case .list: "LLEN"
        case .set: "SCARD"
        case .zset: "ZCARD"
        case .stream: "XLEN"
        case .json, .other: nil
        }
    }
}

/// A key name. Redis keys are bytes; most are UTF-8, and the rest are shown escaped the
/// way `redis-cli` shows them, so every key can be displayed, typed back and matched.
public struct RedisKey: Sendable, Hashable, Comparable, Identifiable {
    public let bytes: Data

    public init(_ bytes: Data) { self.bytes = bytes }
    public init(_ text: String) { bytes = Data(text.utf8) }

    public var id: Data { bytes }
    public var display: String { RedisText.display(bytes) }
    public var argument: RedisArgument { RedisArgument(bytes) }

    public static func < (lhs: RedisKey, rhs: RedisKey) -> Bool {
        lhs.bytes.lexicographicallyPrecedes(rhs.bytes)
    }
}

/// One row of the key list.
public struct RedisKeyInfo: Sendable, Hashable, Identifiable {
    public let key: RedisKey
    public var type: RedisKeyType
    /// Milliseconds to live; nil when the key does not expire.
    public var ttlMilliseconds: Int64?
    /// Elements, or bytes for a string; nil when the type has no length command.
    public var length: Int64?
    /// `MEMORY USAGE`, when the server allows it.
    public var memoryBytes: Int64?

    public var id: Data { key.bytes }
}

/// A page of `SCAN`.
public struct RedisScanPage: Sendable, Hashable {
    public var cursor: String
    public var keys: [RedisKey]
    /// True when the cursor came back to 0: the whole keyspace has been walked.
    public var isComplete: Bool { cursor == "0" }
}

/// One logical database and what `INFO keyspace` says about it.
public struct RedisDatabaseInfo: Sendable, Hashable, Identifiable {
    public let index: Int
    public var keys: Int64
    public var expires: Int64
    public var id: Int { index }
}

/// Reading and changing the keyspace. Every call takes the connection it runs on, so the
/// browser, the console and a transfer can each use their own.
public enum RedisKeyspace {
    /// Every logical database with its key count; empty ones included, so db 5 can be
    /// opened before anything is written to it.
    public static func databases(_ connection: RedisConnection, count: Int) async throws -> [RedisDatabaseInfo] {
        let info = RedisInfo.parse(try await connection.send(["INFO", "keyspace"]).string ?? "")
        var result = (0 ..< count).map { RedisDatabaseInfo(index: $0, keys: 0, expires: 0) }
        for (key, value) in info.values {
            guard key.hasPrefix("db"), let index = Int(key.dropFirst(2)), index >= 0 else { continue }
            var fields: [String: Int64] = [:]
            for part in value.split(separator: ",") {
                let pair = part.split(separator: "=", maxSplits: 1)
                if pair.count == 2 { fields[String(pair[0])] = Int64(pair[1]) }
            }
            let entry = RedisDatabaseInfo(index: index, keys: fields["keys"] ?? 0, expires: fields["expires"] ?? 0)
            if index < result.count { result[index] = entry } else { result.append(entry) }
        }
        return result
    }

    /// One step of `SCAN`. `count` is a hint to the server, not a limit: a step may
    /// return more or fewer keys, and several empty steps in a row are normal.
    public static func scan(
        _ connection: RedisConnection, cursor: String = "0", match: String? = nil, type: RedisKeyType? = nil,
        count: Int = 500
    ) async throws -> RedisScanPage {
        var arguments: [RedisArgument] = ["SCAN", RedisArgument(cursor)]
        if let match, !match.isEmpty, match != "*" { arguments += ["MATCH", RedisArgument(match)] }
        arguments += ["COUNT", RedisArgument(count)]
        if let type { arguments += ["TYPE", RedisArgument(type.scanName)] }
        let reply = try await connection.send(arguments)
        guard let parts = reply.array, parts.count == 2, let next = parts[0].string else {
            throw DBError.protocolError("SCAN returned \(reply)")
        }
        return RedisScanPage(cursor: next, keys: (parts[1].array ?? []).compactMap { $0.data.map(RedisKey.init) })
    }

    /// Scans until at least `limit` keys were found or the keyspace ends. Returns the
    /// keys and the cursor to continue from.
    public static func scan(
        _ connection: RedisConnection, from cursor: String = "0", match: String?, type: RedisKeyType?, limit: Int
    ) async throws -> RedisScanPage {
        var keys: [RedisKey] = []
        var seen: Set<RedisKey> = []
        var position = cursor
        repeat {
            try Task.checkCancellation()
            let page = try await scan(connection, cursor: position, match: match, type: type, count: max(100, limit))
            // SCAN may return a key more than once; a list shows it once.
            for key in page.keys where seen.insert(key).inserted { keys.append(key) }
            position = page.cursor
        } while position != "0" && keys.count < limit
        return RedisScanPage(cursor: position, keys: keys)
    }

    /// Type, time to live, length and memory of each key, in two pipelined round trips.
    /// A key that vanished between the scan and this call is left out.
    public static func describe(_ connection: RedisConnection, _ keys: [RedisKey], memory: Bool = true) async throws
        -> [RedisKeyInfo]
    {
        guard !keys.isEmpty else { return [] }
        var first: [[RedisArgument]] = []
        for key in keys {
            first.append(["TYPE", key.argument])
            first.append(["PTTL", key.argument])
        }
        let replies = try await connection.pipeline(first)
        var infos: [RedisKeyInfo] = []
        var second: [[RedisArgument]] = []
        for (index, key) in keys.enumerated() {
            let typeName = replies[index * 2].string ?? "none"
            guard typeName != "none" else { continue }
            let type = RedisKeyType(typeName: typeName)
            let ttl = replies[index * 2 + 1].integer ?? -1
            infos.append(RedisKeyInfo(key: key, type: type, ttlMilliseconds: ttl >= 0 ? ttl : nil))
            if let command = type.lengthCommand {
                second.append([RedisArgument(command), key.argument])
            } else if type == .json {
                second.append(["JSON.DEBUG", "MEMORY", key.argument])
            } else {
                second.append(["EXISTS", key.argument])
            }
            if memory { second.append(["MEMORY", "USAGE", key.argument]) }
        }
        let details = try await connection.pipeline(second)
        let stride = memory ? 2 : 1
        for index in infos.indices {
            if infos[index].type.lengthCommand != nil { infos[index].length = details[index * stride].integer }
            if memory { infos[index].memoryBytes = details[index * stride + 1].integer }
        }
        return infos
    }

    public static func exists(_ connection: RedisConnection, _ key: RedisKey) async throws -> Bool {
        (try await connection.send(["EXISTS", key.argument]).integer ?? 0) > 0
    }

    /// `UNLINK`s keys (freed in the background), falling back to `DEL` on servers before 4.0.
    @discardableResult
    public static func delete(_ connection: RedisConnection, _ keys: [RedisKey]) async throws -> Int64 {
        guard !keys.isEmpty else { return 0 }
        var removed: Int64 = 0
        for chunk in stride(from: 0, to: keys.count, by: 500).map({ Array(keys[$0 ..< min($0 + 500, keys.count)]) }) {
            let arguments = chunk.map(\.argument)
            do {
                removed += try await connection.send(["UNLINK"] + arguments).integer ?? 0
            } catch let DBError.server(error) where error.message.localizedCaseInsensitiveContains("unknown command") {
                removed += try await connection.send(["DEL"] + arguments).integer ?? 0
            }
        }
        return removed
    }

    /// Renames a key, refusing to overwrite unless asked.
    public static func rename(
        _ connection: RedisConnection, _ key: RedisKey, to newKey: RedisKey, overwrite: Bool = false
    ) async throws {
        if overwrite {
            try await connection.send(["RENAME", key.argument, newKey.argument])
        } else {
            let done = try await connection.send(["RENAMENX", key.argument, newKey.argument]).integer ?? 0
            if done == 0 {
                throw DBError.server(ServerError(message: "A key named \(newKey.display) already exists."))
            }
        }
    }

    /// Sets or clears the time to live. Nil makes the key persistent.
    public static func setTTL(_ connection: RedisConnection, _ key: RedisKey, milliseconds: Int64?) async throws {
        if let milliseconds {
            try await connection.send(["PEXPIRE", key.argument, RedisArgument(milliseconds)])
        } else {
            try await connection.send(["PERSIST", key.argument])
        }
    }

    /// Copies a key within the server (`COPY`, Redis 6.2+).
    public static func duplicate(
        _ connection: RedisConnection, _ key: RedisKey, to newKey: RedisKey, database: Int? = nil,
        replace: Bool = false
    ) async throws {
        var arguments: [RedisArgument] = ["COPY", key.argument, newKey.argument]
        if let database { arguments += ["DB", RedisArgument(database)] }
        if replace { arguments.append("REPLACE") }
        let copied = try await connection.send(arguments).integer ?? 0
        if copied == 0 { throw DBError.server(ServerError(message: "A key named \(newKey.display) already exists.")) }
    }
}

/// How bytes are shown and read back.
public enum RedisText {
    /// UTF-8 text as is; other bytes, and control characters, as `\xNN` escapes — the
    /// same spelling `redis-cli` uses, and ``parse(_:)`` reads back.
    public static func display(_ data: Data) -> String {
        if let text = String(data: data, encoding: .utf8),
            !text.unicodeScalars.contains(where: { $0.value < 0x20 && $0 != "\n" && $0 != "\t" && $0 != "\r" }),
            !text.contains("\\")
        {
            return text
        }
        var result = ""
        var index = data.startIndex
        while index < data.endIndex {
            let byte = data[index]
            // Keep valid multi-byte UTF-8 sequences readable.
            if byte >= 0x80, let length = utf8Length(byte), index + length <= data.endIndex,
                let text = String(data: data[index ..< index + length], encoding: .utf8)
            {
                result += text
                index += length
                continue
            }
            switch byte {
            case 0x5C: result += "\\\\"
            case 0x20 ... 0x7E: result.append(Character(Unicode.Scalar(byte)))
            default: result += String(format: "\\x%02x", byte)
            }
            index += 1
        }
        return result
    }

    /// The bytes a displayed key stands for: `\xNN` and `\\` escapes are decoded when the
    /// text holds them; otherwise it is plain UTF-8.
    public static func parse(_ text: String) -> Data {
        guard text.contains("\\") else { return Data(text.utf8) }
        var result = Data()
        var scalars = Array(text.utf8)[...]
        while let byte = scalars.first {
            scalars = scalars.dropFirst()
            guard byte == UInt8(ascii: "\\"), let next = scalars.first else {
                result.append(byte)
                continue
            }
            if next == UInt8(ascii: "\\") {
                result.append(next)
                scalars = scalars.dropFirst()
            } else if next == UInt8(ascii: "x"), scalars.count >= 3,
                let value = UInt8(String(decoding: scalars.dropFirst().prefix(2), as: UTF8.self), radix: 16)
            {
                result.append(value)
                scalars = scalars.dropFirst(3)
            } else {
                result.append(byte)
            }
        }
        return result
    }

    /// True when the bytes are text a person can edit without losing anything.
    public static func isText(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else { return false }
        return !text.unicodeScalars.contains { $0.value < 0x20 && $0 != "\n" && $0 != "\t" && $0 != "\r" }
    }

    private static func utf8Length(_ byte: UInt8) -> Int? {
        switch byte {
        case 0xC2 ... 0xDF: 2
        case 0xE0 ... 0xEF: 3
        case 0xF0 ... 0xF4: 4
        default: nil
        }
    }

    /// Escapes the glob characters of a literal key prefix for `MATCH`.
    public static func globEscape(_ text: String) -> String {
        var result = ""
        for character in text {
            if "*?[]\\".contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }
}
