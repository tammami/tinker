import DBCore
import Foundation

/// One entry of a stream.
public struct RedisStreamEntry: Sendable, Hashable, Identifiable {
    public let id: String
    public var fields: [(field: Data, value: Data)]

    public init(id: String, fields: [(field: Data, value: Data)]) {
        self.id = id
        self.fields = fields
    }

    public static func == (lhs: RedisStreamEntry, rhs: RedisStreamEntry) -> Bool {
        lhs.id == rhs.id && lhs.fields.map(\.field) == rhs.fields.map(\.field)
            && lhs.fields.map(\.value) == rhs.fields.map(\.value)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        for (field, value) in fields {
            hasher.combine(field)
            hasher.combine(value)
        }
    }
}

/// A page of a key's contents, as the value editors show it.
public enum RedisValuePage: Sendable, Hashable {
    case string(Data)
    /// `cursor` continues an HSCAN/SSCAN/ZSCAN; "0" means the end was reached.
    case hash(fields: [RedisPair], cursor: String)
    /// `offset` is the index of the first element shown.
    case list(items: [Data], offset: Int)
    case set(members: [Data], cursor: String)
    /// Scores stay as the server writes them (`1.5`, `inf`); they are never rounded.
    case zset(members: [RedisScoredMember], offset: Int)
    /// `next` is the id to read on from, or nil at the end.
    case stream(entries: [RedisStreamEntry], next: String?)
    /// Pretty-printed where it parses.
    case json(String)
    /// A module type Tinker does not edit; `info` is what the module says about it.
    case unsupported(typeName: String, info: [String])
}

public struct RedisPair: Sendable, Hashable {
    public var field: Data
    public var value: Data

    public init(field: Data, value: Data) {
        self.field = field
        self.value = value
    }
}

public struct RedisScoredMember: Sendable, Hashable {
    public var member: Data
    public var score: String

    public init(member: Data, score: String) {
        self.member = member
        self.score = score
    }
}

/// Reading and writing a key's value by type.
public enum RedisValues {
    /// How much of a large key one page shows.
    public static let pageSize = 500
    /// Strings longer than this are read in part; the editor says so and edits nothing.
    public static let stringReadLimit = 4 * 1_024 * 1_024

    /// The first page of a key, or the page after `continuing`.
    public static func read(
        _ connection: RedisConnection, _ key: RedisKey, type: RedisKeyType, continuing: RedisValuePage? = nil,
        match: String? = nil
    ) async throws -> RedisValuePage {
        let size = RedisArgument(pageSize)
        let pattern: [RedisArgument] = match.map { $0.isEmpty ? [] : ["MATCH", RedisArgument($0)] } ?? []
        switch type {
        case .string:
            let length = try await connection.send(["STRLEN", key.argument]).integer ?? 0
            if length > stringReadLimit {
                let part = try await connection.send(["GETRANGE", key.argument, 0, RedisArgument(stringReadLimit - 1)])
                return .string(part.data ?? Data())
            }
            return .string(try await connection.send(["GET", key.argument]).data ?? Data())
        case .hash:
            var cursor = "0"
            if case let .hash(_, previous) = continuing { cursor = previous }
            let reply = try await connection.send(["HSCAN", key.argument, RedisArgument(cursor)] + pattern + ["COUNT", size])
            let (next, items) = try scanReply(reply)
            let fields = stride(from: 0, to: items.count - 1, by: 2).map {
                RedisPair(field: items[$0].data ?? Data(), value: items[$0 + 1].data ?? Data())
            }
            return .hash(fields: fields, cursor: next)
        case .list:
            var offset = 0
            if case let .list(items, previous) = continuing { offset = previous + items.count }
            let reply = try await connection.send([
                "LRANGE", key.argument, RedisArgument(offset), RedisArgument(offset + pageSize - 1),
            ])
            return .list(items: (reply.array ?? []).map { $0.data ?? Data() }, offset: offset)
        case .set:
            var cursor = "0"
            if case let .set(_, previous) = continuing { cursor = previous }
            let reply = try await connection.send(["SSCAN", key.argument, RedisArgument(cursor)] + pattern + ["COUNT", size])
            let (next, items) = try scanReply(reply)
            return .set(members: items.map { $0.data ?? Data() }, cursor: next)
        case .zset:
            var offset = 0
            if case let .zset(members, previous) = continuing { offset = previous + members.count }
            let reply = try await connection.send([
                "ZRANGE", key.argument, RedisArgument(offset), RedisArgument(offset + pageSize - 1), "WITHSCORES",
            ])
            let items = reply.array ?? []
            let members = stride(from: 0, to: items.count - 1, by: 2).map {
                RedisScoredMember(member: items[$0].data ?? Data(), score: items[$0 + 1].string ?? "")
            }
            return .zset(members: members, offset: offset)
        case .stream:
            var start = "-"
            if case let .stream(_, next) = continuing, let next { start = next }
            let reply = try await connection.send(["XRANGE", key.argument, RedisArgument(start), "+", "COUNT", size])
            let entries = (reply.array ?? []).compactMap(streamEntry)
            var next: String?
            if entries.count == pageSize, let last = entries.last { next = "(" + last.id }
            return .stream(entries: entries, next: next)
        case .json:
            let reply = try await connection.send(["JSON.GET", key.argument])
            return .json(prettyJSON(reply.string ?? "null"))
        case let .other(name):
            var info: [String] = []
            for command in ["TS.INFO", "BF.INFO", "CF.INFO", "VINFO", "TOPK.INFO", "CMS.INFO"] {
                let arguments: [RedisArgument] = [RedisArgument(command), key.argument]
                guard let reply = try? await connection.send(arguments) else {
                    continue
                }
                info = RedisReplyFormatter.lines(reply)
                break
            }
            return .unsupported(typeName: name, info: info)
        }
    }

    private static func scanReply(_ reply: RESPValue) throws -> (String, [RESPValue]) {
        guard let parts = reply.array, parts.count == 2, let cursor = parts[0].string else {
            throw DBError.protocolError("unexpected scan reply \(reply)")
        }
        return (cursor, parts[1].array ?? [])
    }

    static func streamEntry(_ value: RESPValue) -> RedisStreamEntry? {
        guard let parts = value.array, parts.count == 2, let id = parts[0].string else { return nil }
        let items = parts[1].array ?? []
        let fields = stride(from: 0, to: items.count - 1, by: 2).map {
            (field: items[$0].data ?? Data(), value: items[$0 + 1].data ?? Data())
        }
        return RedisStreamEntry(id: id, fields: fields)
    }

    public static func prettyJSON(_ text: String) -> String {
        guard let data = text.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
            let pretty = try? JSONSerialization.data(
                withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes])
        else { return text }
        return String(decoding: pretty, as: UTF8.self)
    }

    // MARK: - Writing

    /// A new key with its first value. Refuses when the key already exists, so creating
    /// never overwrites. `ttl` is in seconds.
    public static func create(
        _ connection: RedisConnection, _ key: RedisKey, type: RedisKeyType, initial: RedisInitialValue,
        ttlSeconds: Int64? = nil
    ) async throws {
        if try await RedisKeyspace.exists(connection, key) {
            throw DBError.server(ServerError(message: "A key named \(key.display) already exists."))
        }
        switch (type, initial) {
        case let (.string, .text(value)):
            var arguments: [RedisArgument] = ["SET", key.argument, RedisArgument(value), "NX"]
            if let ttlSeconds, ttlSeconds > 0 { arguments += ["EX", RedisArgument(ttlSeconds)] }
            try await connection.send(arguments)
            return
        case let (.hash, .pairs(pairs)):
            guard !pairs.isEmpty else { throw emptyValue(type) }
            try await connection.send(["HSET", key.argument] + pairs.flatMap { [RedisArgument($0.field), RedisArgument($0.value)] })
        case let (.list, .items(items)):
            guard !items.isEmpty else { throw emptyValue(type) }
            try await connection.send(["RPUSH", key.argument] + items.map(RedisArgument.init))
        case let (.set, .items(items)):
            guard !items.isEmpty else { throw emptyValue(type) }
            try await connection.send(["SADD", key.argument] + items.map(RedisArgument.init))
        case let (.zset, .scored(members)):
            guard !members.isEmpty else { throw emptyValue(type) }
            try await connection.send(
                ["ZADD", key.argument] + members.flatMap { [RedisArgument($0.score), RedisArgument($0.member)] })
        case let (.stream, .pairs(pairs)):
            guard !pairs.isEmpty else { throw emptyValue(type) }
            try await connection.send(
                ["XADD", key.argument, "*"] + pairs.flatMap { [RedisArgument($0.field), RedisArgument($0.value)] })
        case let (.json, .text(value)):
            try await connection.send(["JSON.SET", key.argument, "$", RedisArgument(value), "NX"])
        default:
            throw DBError.protocolError("\(type.displayName) keys cannot be created with that value.")
        }
        if let ttlSeconds, ttlSeconds > 0 {
            try await connection.send(["EXPIRE", key.argument, RedisArgument(ttlSeconds)])
        }
    }

    private static func emptyValue(_ type: RedisKeyType) -> DBError {
        // Redis has no empty hashes, lists, sets or streams: removing the last element
        // removes the key. A new one needs something in it.
        DBError.protocolError("A \(type.displayName.lowercased()) needs at least one element; Redis does not keep empty ones.")
    }

    /// Replaces a string, keeping its time to live.
    public static func setString(_ connection: RedisConnection, _ key: RedisKey, _ value: Data) async throws {
        do {
            try await connection.send(["SET", key.argument, RedisArgument(value), "KEEPTTL"])
        } catch let DBError.server(error) where error.message.localizedCaseInsensitiveContains("syntax") {
            // Before Redis 6, SET had no KEEPTTL: set, then put the old TTL back.
            let ttl = try await connection.send(["PTTL", key.argument]).integer ?? -1
            try await connection.send(["SET", key.argument, RedisArgument(value)])
            if ttl > 0 { try await connection.send(["PEXPIRE", key.argument, RedisArgument(ttl)]) }
        }
    }

    public static func setJSON(_ connection: RedisConnection, _ key: RedisKey, _ text: String) async throws {
        try await connection.send(["JSON.SET", key.argument, "$", RedisArgument(text)])
    }

    public static func setHashField(_ connection: RedisConnection, _ key: RedisKey, field: Data, value: Data) async throws {
        try await connection.send(["HSET", key.argument, RedisArgument(field), RedisArgument(value)])
    }

    /// Renames a hash field: the new one is written before the old one goes, atomically.
    public static func renameHashField(
        _ connection: RedisConnection, _ key: RedisKey, from old: Data, to new: Data, value: Data
    ) async throws {
        let replies = try await connection.pipeline([
            ["MULTI"], ["HSET", key.argument, RedisArgument(new), RedisArgument(value)],
            ["HDEL", key.argument, RedisArgument(old)], ["EXEC"],
        ])
        try check(replies)
    }

    public static func deleteHashFields(_ connection: RedisConnection, _ key: RedisKey, _ fields: [Data]) async throws {
        guard !fields.isEmpty else { return }
        try await connection.send(["HDEL", key.argument] + fields.map(RedisArgument.init))
    }

    public enum ListEnd: Sendable { case head, tail }

    public static func push(_ connection: RedisConnection, _ key: RedisKey, _ items: [Data], at end: ListEnd) async throws {
        guard !items.isEmpty else { return }
        try await connection.send([end == .head ? "LPUSH" : "RPUSH", key.argument] + items.map(RedisArgument.init))
    }

    /// Changes the element at `index`, but only if it still holds `expected` — another
    /// client may have pushed or popped since the page was read.
    public static func setListItem(
        _ connection: RedisConnection, _ key: RedisKey, index: Int, expected: Data, value: Data
    ) async throws {
        // Checked and written in one script, so nothing can move the list in between.
        let done = try await connection.send([
            "EVAL", RedisArgument(setIfUnchanged), 1, key.argument, RedisArgument(index), RedisArgument(expected),
            RedisArgument(value),
        ])
        guard done.integer == 1 else { throw changedMeanwhile() }
    }

    static let setIfUnchanged = """
        if redis.call('LINDEX', KEYS[1], ARGV[1]) == ARGV[2] then
          redis.call('LSET', KEYS[1], ARGV[1], ARGV[3])
          return 1
        end
        return 0
        """

    /// ARGV: the tombstone, then index/expected pairs. Every element is checked first;
    /// only when all still hold what was shown are they marked and removed.
    static let removeIfUnchanged = """
        for i = 2, #ARGV, 2 do
          if redis.call('LINDEX', KEYS[1], ARGV[i]) ~= ARGV[i + 1] then return 0 end
        end
        for i = 2, #ARGV, 2 do redis.call('LSET', KEYS[1], ARGV[i], ARGV[1]) end
        redis.call('LREM', KEYS[1], 0, ARGV[1])
        return 1
        """

    /// Removes the elements at the given indices, checking each still holds what was shown.
    /// Lists have no delete-by-index: each element is marked with a tombstone, then the
    /// tombstones are removed, all in one transaction.
    public static func removeListItems(
        _ connection: RedisConnection, _ key: RedisKey, items: [(index: Int, expected: Data)]
    ) async throws {
        guard !items.isEmpty else { return }
        let marker = RedisArgument("__tinker_removed_\(UUID().uuidString)__")
        var arguments: [RedisArgument] = ["EVAL", RedisArgument(removeIfUnchanged), 1, key.argument, marker]
        for item in items { arguments += [RedisArgument(item.index), RedisArgument(item.expected)] }
        let done = try await connection.send(arguments)
        guard done.integer == 1 else { throw changedMeanwhile() }
    }

    public static func addSetMembers(_ connection: RedisConnection, _ key: RedisKey, _ members: [Data]) async throws {
        guard !members.isEmpty else { return }
        try await connection.send(["SADD", key.argument] + members.map(RedisArgument.init))
    }

    public static func removeSetMembers(_ connection: RedisConnection, _ key: RedisKey, _ members: [Data]) async throws {
        guard !members.isEmpty else { return }
        try await connection.send(["SREM", key.argument] + members.map(RedisArgument.init))
    }

    /// Replaces a set member atomically. The new one is added before the old one goes:
    /// removing the only member first would delete the key, and its TTL with it.
    public static func replaceSetMember(_ connection: RedisConnection, _ key: RedisKey, old: Data, new: Data) async throws {
        guard old != new else { return }
        try check(try await connection.pipeline([
            ["MULTI"], ["SADD", key.argument, RedisArgument(new)], ["SREM", key.argument, RedisArgument(old)], ["EXEC"],
        ]))
    }

    public static func addSortedMembers(
        _ connection: RedisConnection, _ key: RedisKey, _ members: [RedisScoredMember]
    ) async throws {
        guard !members.isEmpty else { return }
        try await connection.send(
            ["ZADD", key.argument] + members.flatMap { [RedisArgument($0.score), RedisArgument($0.member)] })
    }

    public static func removeSortedMembers(_ connection: RedisConnection, _ key: RedisKey, _ members: [Data]) async throws {
        guard !members.isEmpty else { return }
        try await connection.send(["ZREM", key.argument] + members.map(RedisArgument.init))
    }

    /// Changes a member's name or score, atomically.
    public static func replaceSortedMember(
        _ connection: RedisConnection, _ key: RedisKey, old: Data, new: RedisScoredMember
    ) async throws {
        // Added first, for the same reason as a set: never an empty key in between.
        var commands: [[RedisArgument]] = [
            ["MULTI"], ["ZADD", key.argument, RedisArgument(new.score), RedisArgument(new.member)],
        ]
        if old != new.member { commands.append(["ZREM", key.argument, RedisArgument(old)]) }
        commands.append(["EXEC"])
        try check(try await connection.pipeline(commands))
    }

    /// Appends an entry; `id` "*" lets the server choose. Returns the entry's id.
    @discardableResult
    public static func addStreamEntry(
        _ connection: RedisConnection, _ key: RedisKey, id: String = "*", fields: [RedisPair]
    ) async throws -> String {
        guard !fields.isEmpty else { throw emptyValue(.stream) }
        let reply = try await connection.send(
            ["XADD", key.argument, RedisArgument(id)] + fields.flatMap { [RedisArgument($0.field), RedisArgument($0.value)] })
        return reply.string ?? id
    }

    public static func deleteStreamEntries(_ connection: RedisConnection, _ key: RedisKey, ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        let arguments: [RedisArgument] = ["XDEL", key.argument]
        try await connection.send(arguments + ids.map { RedisArgument($0) })
    }

    /// The consumer groups of a stream: name, consumers, pending, last delivered id.
    public static func streamGroups(_ connection: RedisConnection, _ key: RedisKey) async throws -> [RedisStreamGroup] {
        let reply = try await connection.send(["XINFO", "GROUPS", key.argument])
        return (reply.array ?? []).map { group in
            var fields: [String: RESPValue] = [:]
            for (name, value) in group.pairs { if let name = name.string { fields[name] = value } }
            return RedisStreamGroup(
                name: fields["name"]?.string ?? "",
                consumers: fields["consumers"]?.integer ?? 0,
                pending: fields["pending"]?.integer ?? 0,
                lastDeliveredID: fields["last-delivered-id"]?.string ?? "0-0")
        }
    }

    private static func changedMeanwhile() -> DBError {
        DBError.protocolError("The list changed since it was read. Reload it and try again.")
    }

    /// Throws the first error inside a MULTI/EXEC pipeline, verbatim.
    private static func check(_ replies: [RESPValue]) throws {
        for reply in replies {
            if case let .error(message) = reply { throw DBError.server(ServerError(message: message)) }
        }
        if let exec = replies.last {
            if exec.isNull { throw DBError.protocolError("The transaction was aborted.") }
            for inner in exec.array ?? [] {
                if case let .error(message) = inner { throw DBError.server(ServerError(message: message)) }
            }
        }
    }
}

/// A new key's first value, by shape.
public enum RedisInitialValue: Sendable, Hashable {
    case text(String)
    case pairs([RedisPair])
    case items([Data])
    case scored([RedisScoredMember])
}

public struct RedisStreamGroup: Sendable, Hashable, Identifiable {
    public var name: String
    public var consumers: Int64
    public var pending: Int64
    public var lastDeliveredID: String
    public var id: String { name }
}
