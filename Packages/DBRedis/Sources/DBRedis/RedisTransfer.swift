import DBCore
import Foundation

/// One side of a Redis transfer: a session and one of its logical databases.
public struct RedisEndpoint: Sendable {
    public let session: RedisSession
    public let database: Int

    public init(session: RedisSession, database: Int) {
        self.session = session
        self.database = database
    }
}

extension RedisEndpoint {
    /// A connection of its own on each side. When the second cannot be opened the first
    /// is closed, rather than left open until the app quits.
    static func pair(_ source: RedisEndpoint, _ target: RedisEndpoint) async throws -> (RedisConnection, RedisConnection) {
        let first = try await source.session.dedicatedConnection(database: source.database)
        do {
            return (first, try await target.session.dedicatedConnection(database: target.database))
        } catch {
            await first.close()
            throw error
        }
    }
}

/// Which keys a transfer or a sync touches, and how.
public struct RedisTransferOptions: Sendable, Hashable {
    /// A `MATCH` pattern; `*` is every key.
    public var pattern: String
    /// Only these types; empty is every type.
    public var types: Set<RedisKeyType>
    /// What happens to a key the target already has.
    public var existing: ExistingKeys
    /// Copy each key's remaining time to live; off makes the copies persistent.
    public var keepTTL: Bool
    /// Keys per round trip.
    public var batchSize: Int

    public enum ExistingKeys: String, Sendable, Hashable, CaseIterable {
        case replace
        case skip
    }

    public init(
        pattern: String = "*", types: Set<RedisKeyType> = [], existing: ExistingKeys = .replace, keepTTL: Bool = true,
        batchSize: Int = 500
    ) {
        self.pattern = pattern
        self.types = types
        self.existing = existing
        self.keepTTL = keepTTL
        self.batchSize = max(1, min(batchSize, 5_000))
    }
}

/// How far a transfer or an apply has got.
public struct RedisTransferProgress: Sendable, Hashable {
    public var scanned = 0
    public var copied = 0
    public var skipped = 0
    public var deleted = 0
    /// Keys the target refused, with the server's reason. The first hundred are kept.
    public var failures: [RedisKeyFailure] = []
    public var failed = 0

    public init() {}

    mutating func fail(_ key: RedisKey, _ message: String) {
        failed += 1
        if failures.count < 100 { failures.append(RedisKeyFailure(key: key, message: message)) }
    }
}

public struct RedisKeyFailure: Sendable, Hashable, Identifiable {
    public let key: RedisKey
    public let message: String
    public var id: Data { key.bytes }
}

/// Copying keys from one Redis database to another — on the same server or another.
///
/// Keys go across as `DUMP` payloads restored with `RESTORE`, so every type, encoding
/// and module value arrives exactly, in batches that cost one round trip each way.
/// When the servers disagree on the payload format (different major versions), that
/// key is copied element by element instead.
///
/// Only Redis to Redis: the key–value model has no faithful mapping to tables, and the
/// transfer tools keep Redis connections to themselves.
public enum RedisTransfer {
    /// Copies every matching key. Runs on connections of its own, so the browser stays usable.
    @discardableResult
    public static func copy(
        from source: RedisEndpoint, to target: RedisEndpoint, options: RedisTransferOptions,
        progress: (@Sendable (RedisTransferProgress) -> Void)? = nil
    ) async throws -> RedisTransferProgress {
        let (reader, writer) = try await RedisEndpoint.pair(source, target)
        defer {
            Task {
                await reader.close()
                await writer.close()
            }
        }
        var state = RedisTransferProgress()
        var cursor = "0"
        repeat {
            try Task.checkCancellation()
            let page = try await RedisKeyspace.scan(
                reader, cursor: cursor, match: options.pattern, type: options.types.count == 1 ? options.types.first : nil,
                count: options.batchSize)
            cursor = page.cursor
            state.scanned += page.keys.count
            let keys = try await filter(page.keys, on: reader, types: options.types)
            try await copyBatch(keys, reader: reader, writer: writer, options: options, state: &state)
            progress?(state)
        } while cursor != "0"
        return state
    }

    /// Copies the given keys (a sync's plan uses this), replacing what the target has.
    static func copyKeys(
        _ keys: [RedisKey], reader: RedisConnection, writer: RedisConnection, keepTTL: Bool,
        state: inout RedisTransferProgress
    ) async throws {
        let options = RedisTransferOptions(existing: .replace, keepTTL: keepTTL)
        for start in stride(from: 0, to: keys.count, by: 500) {
            try Task.checkCancellation()
            try await copyBatch(
                Array(keys[start ..< min(start + 500, keys.count)]), reader: reader, writer: writer, options: options,
                state: &state)
        }
    }

    private static func filter(_ keys: [RedisKey], on connection: RedisConnection, types: Set<RedisKeyType>)
        async throws -> [RedisKey]
    {
        guard types.count > 1 else { return keys }
        let replies = try await connection.pipeline(keys.map { ["TYPE", $0.argument] })
        return zip(keys, replies).compactMap { key, reply in
            types.contains(RedisKeyType(typeName: reply.string ?? "none")) ? key : nil
        }
    }

    private static func copyBatch(
        _ keys: [RedisKey], reader: RedisConnection, writer: RedisConnection, options: RedisTransferOptions,
        state: inout RedisTransferProgress
    ) async throws {
        guard !keys.isEmpty else { return }
        var candidates = keys
        if options.existing == .skip {
            let present = try await writer.pipeline(keys.map { ["EXISTS", $0.argument] })
            candidates = zip(keys, present).compactMap { key, reply in (reply.integer ?? 0) > 0 ? nil : key }
            state.skipped += keys.count - candidates.count
        }
        guard !candidates.isEmpty else { return }
        var reads: [[RedisArgument]] = []
        for key in candidates {
            reads.append(["DUMP", key.argument])
            reads.append(["PTTL", key.argument])
        }
        let dumped = try await reader.pipeline(reads)
        var restores: [[RedisArgument]] = []
        var restoring: [RedisKey] = []
        for (index, key) in candidates.enumerated() {
            let payload = dumped[index * 2]
            let ttl = dumped[index * 2 + 1].integer ?? -1
            // Gone since the scan: nothing to copy.
            if payload.isNull || ttl == -2 { continue }
            guard let bytes = payload.data else {
                // DUMP refused (an ACL without it, a module type that cannot be dumped):
                // copy the value itself, and say so when that fails too.
                do {
                    try await RedisValueCopy.copy(key, from: reader, to: writer, keepTTL: options.keepTTL)
                    state.copied += 1
                } catch {
                    let reason = (error as? DBError)?.errorDescription ?? String(describing: error)
                    if case let .error(message) = payload { state.fail(key, "\(message) — \(reason)") } else {
                        state.fail(key, reason)
                    }
                }
                continue
            }
            var command: [RedisArgument] = [
                "RESTORE", key.argument, RedisArgument(options.keepTTL && ttl > 0 ? ttl : 0), RedisArgument(bytes),
            ]
            if options.existing == .replace { command.append("REPLACE") }
            restores.append(command)
            restoring.append(key)
        }
        let results = try await writer.pipeline(restores)
        for (key, result) in zip(restoring, results) {
            guard case let .error(message) = result else {
                state.copied += 1
                continue
            }
            if message.hasPrefix("BUSYKEY") {
                state.skipped += 1
            } else if message.localizedCaseInsensitiveContains("payload version")
                || message.localizedCaseInsensitiveContains("checksum")
            {
                // Another major version: copy the value itself.
                do {
                    try await RedisValueCopy.copy(key, from: reader, to: writer, keepTTL: options.keepTTL)
                    state.copied += 1
                } catch {
                    state.fail(key, (error as? DBError)?.errorDescription ?? String(describing: error))
                }
            } else {
                state.fail(key, message)
            }
        }
    }
}

// MARK: - Data synchronization

/// What synchronizing a target with a source would change.
public struct RedisSyncPlan: Sendable, Hashable {
    /// In the source only: copied over.
    public var added: [RedisKey] = []
    /// In both, with different contents or a different type: replaced.
    public var changed: [RedisKey] = []
    /// In the target only: deleted when the sync is asked to remove extras.
    public var removed: [RedisKey] = []
    public var unchanged = 0

    public var isEmpty: Bool { added.isEmpty && changed.isEmpty && removed.isEmpty }
    public init() {}
}

/// Compares two Redis databases key by key and makes the target match the source.
public enum RedisDataSync {
    /// Walks both sides. Contents are compared, not their encoding: a hash stored as a
    /// listpack on one server and a hashtable on the other is still the same hash.
    public static func compare(
        source: RedisEndpoint, target: RedisEndpoint, options: RedisTransferOptions,
        progress: (@Sendable (Int) -> Void)? = nil
    ) async throws -> RedisSyncPlan {
        let (reader, other) = try await RedisEndpoint.pair(source, target)
        defer {
            Task {
                await reader.close()
                await other.close()
            }
        }
        var plan = RedisSyncPlan()
        var compared = 0
        var cursor = "0"
        repeat {
            try Task.checkCancellation()
            let page = try await RedisKeyspace.scan(reader, cursor: cursor, match: options.pattern, count: options.batchSize)
            cursor = page.cursor
            let keys = try await typed(page.keys, on: reader, types: options.types)
            guard !keys.isEmpty else { continue }
            let mine = try await reader.pipeline(keys.flatMap { [["TYPE", $0.argument], ["DUMP", $0.argument]] })
            let theirs = try await other.pipeline(keys.flatMap { [["TYPE", $0.argument], ["DUMP", $0.argument]] })
            for (index, key) in keys.enumerated() {
                let sourceType = mine[index * 2].string ?? "none"
                let targetType = theirs[index * 2].string ?? "none"
                if sourceType == "none" { continue }
                if targetType == "none" {
                    plan.added.append(key)
                } else if sourceType != targetType {
                    plan.changed.append(key)
                } else if let a = mine[index * 2 + 1].data, let b = theirs[index * 2 + 1].data, a == b {
                    plan.unchanged += 1
                } else if try await RedisValueCopy.sameContents(
                    key, type: RedisKeyType(typeName: sourceType), left: reader, right: other)
                {
                    plan.unchanged += 1
                } else {
                    plan.changed.append(key)
                }
            }
            compared += keys.count
            progress?(compared)
        } while cursor != "0"

        // The target's own keys that the source does not have.
        cursor = "0"
        repeat {
            try Task.checkCancellation()
            let page = try await RedisKeyspace.scan(other, cursor: cursor, match: options.pattern, count: options.batchSize)
            cursor = page.cursor
            let keys = try await typed(page.keys, on: other, types: options.types)
            guard !keys.isEmpty else { continue }
            let present = try await reader.pipeline(keys.map { ["EXISTS", $0.argument] })
            for (key, reply) in zip(keys, present) where (reply.integer ?? 0) == 0 { plan.removed.append(key) }
        } while cursor != "0"
        return plan
    }

    /// Carries out a plan: adds and replaces keys, and deletes the extras when asked.
    @discardableResult
    public static func apply(
        _ plan: RedisSyncPlan, source: RedisEndpoint, target: RedisEndpoint, deleteExtras: Bool, keepTTL: Bool = true,
        progress: (@Sendable (RedisTransferProgress) -> Void)? = nil
    ) async throws -> RedisTransferProgress {
        let (reader, writer) = try await RedisEndpoint.pair(source, target)
        defer {
            Task {
                await reader.close()
                await writer.close()
            }
        }
        var state = RedisTransferProgress()
        let keys = plan.added + plan.changed
        for start in stride(from: 0, to: keys.count, by: 500) {
            try await RedisTransfer.copyKeys(
                Array(keys[start ..< min(start + 500, keys.count)]), reader: reader, writer: writer, keepTTL: keepTTL,
                state: &state)
            progress?(state)
        }
        if deleteExtras, !plan.removed.isEmpty {
            state.deleted = Int(try await RedisKeyspace.delete(writer, plan.removed))
            progress?(state)
        }
        return state
    }

    private static func typed(_ keys: [RedisKey], on connection: RedisConnection, types: Set<RedisKeyType>)
        async throws -> [RedisKey]
    {
        guard !types.isEmpty else { return keys }
        let replies = try await connection.pipeline(keys.map { ["TYPE", $0.argument] })
        return zip(keys, replies).compactMap { key, reply in
            types.contains(RedisKeyType(typeName: reply.string ?? "none")) ? key : nil
        }
    }
}

// MARK: - Element-by-element copy and comparison

/// A key's whole contents in a form that compares by meaning.
enum RedisFullValue: Hashable {
    case string(Data)
    case hash([Data: Data])
    case list([Data])
    case set(Set<Data>)
    case zset([Data: String])
    /// Entries, the last id the stream handed out, and its consumer groups with the id
    /// each has read to: DUMP carries all of it, so a copy made without DUMP must too.
    case stream(entries: [RedisStreamEntry], lastID: String, groups: [String: String])
    case json(String)
}

enum RedisValueCopy {
    static func read(_ key: RedisKey, type: RedisKeyType, on connection: RedisConnection) async throws -> RedisFullValue? {
        switch type {
        case .string:
            return .string(try await connection.send(["GET", key.argument]).data ?? Data())
        case .hash:
            var result: [Data: Data] = [:]
            var cursor = "0"
            repeat {
                let reply = try await connection.send(["HSCAN", key.argument, RedisArgument(cursor), "COUNT", 1_000])
                let parts = reply.array ?? []
                cursor = parts.first?.string ?? "0"
                let items = parts.count > 1 ? (parts[1].array ?? []) : []
                for index in stride(from: 0, to: items.count - 1, by: 2) {
                    result[items[index].data ?? Data()] = items[index + 1].data ?? Data()
                }
            } while cursor != "0"
            return .hash(result)
        case .list:
            let reply = try await connection.send(["LRANGE", key.argument, 0, -1])
            return .list((reply.array ?? []).map { $0.data ?? Data() })
        case .set:
            var result: Set<Data> = []
            var cursor = "0"
            repeat {
                let reply = try await connection.send(["SSCAN", key.argument, RedisArgument(cursor), "COUNT", 1_000])
                let parts = reply.array ?? []
                cursor = parts.first?.string ?? "0"
                for item in parts.count > 1 ? (parts[1].array ?? []) : [] { result.insert(item.data ?? Data()) }
            } while cursor != "0"
            return .set(result)
        case .zset:
            let reply = try await connection.send(["ZRANGE", key.argument, 0, -1, "WITHSCORES"])
            let items = reply.array ?? []
            var result: [Data: String] = [:]
            for index in stride(from: 0, to: items.count - 1, by: 2) {
                result[items[index].data ?? Data()] = items[index + 1].string ?? ""
            }
            return .zset(result)
        case .stream:
            let replies = try await connection.pipeline([
                ["XRANGE", key.argument, "-", "+"], ["XINFO", "STREAM", key.argument], ["XINFO", "GROUPS", key.argument],
            ])
            var lastID = "0-0"
            for (name, value) in replies[1].pairs where name.string == "last-generated-id" { lastID = value.string ?? lastID }
            var groups: [String: String] = [:]
            for group in replies[2].array ?? [] {
                var fields: [String: String] = [:]
                for (name, value) in group.pairs { if let name = name.string { fields[name] = value.string } }
                if let name = fields["name"] { groups[name] = fields["last-delivered-id"] ?? "0-0" }
            }
            return .stream(
                entries: (replies[0].array ?? []).compactMap(RedisValues.streamEntry), lastID: lastID, groups: groups)
        case .json:
            let text = try await connection.send(["JSON.GET", key.argument]).string ?? "null"
            return .json(canonicalJSON(text))
        case .timeSeries, .bloomFilter, .cuckooFilter, .topK, .countMinSketch, .tDigest, .vectorSet, .other:
            // What a sketch or an index holds cannot be read back out of it element by
            // element; these travel as DUMP payloads or not at all.
            return nil
        }
    }

    static func sameContents(_ key: RedisKey, type: RedisKeyType, left: RedisConnection, right: RedisConnection)
        async throws -> Bool
    {
        guard let a = try await read(key, type: type, on: left) else { return false }
        return a == (try await read(key, type: type, on: right))
    }

    /// Writes a key's contents into the other server, replacing it, in one transaction.
    static func copy(_ key: RedisKey, from reader: RedisConnection, to writer: RedisConnection, keepTTL: Bool)
        async throws
    {
        let replies = try await reader.pipeline([["TYPE", key.argument], ["PTTL", key.argument]])
        let type = RedisKeyType(typeName: replies[0].string ?? "none")
        let ttl = replies[1].integer ?? -1
        guard let value = try await read(key, type: type, on: reader) else {
            throw DBError.protocolError("\(type.displayName) keys can only be copied between servers of the same version.")
        }
        var commands: [[RedisArgument]] = [["MULTI"], ["DEL", key.argument]]
        switch value {
        case let .string(data):
            commands.append(["SET", key.argument, RedisArgument(data)])
        case let .hash(fields):
            if !fields.isEmpty {
                commands.append(["HSET", key.argument] + fields.flatMap { [RedisArgument($0.key), RedisArgument($0.value)] })
            }
        case let .list(items):
            if !items.isEmpty { commands.append(["RPUSH", key.argument] + items.map { RedisArgument($0) }) }
        case let .set(members):
            if !members.isEmpty { commands.append(["SADD", key.argument] + members.map { RedisArgument($0) }) }
        case let .zset(members):
            if !members.isEmpty {
                commands.append(["ZADD", key.argument] + members.flatMap { [RedisArgument($0.value), RedisArgument($0.key)] })
            }
        case let .stream(entries, lastID, groups):
            if entries.isEmpty {
                // An empty stream still exists; a throwaway group creates it without an entry.
                commands.append(["XGROUP", "CREATE", key.argument, "__tinker_create__", "$", "MKSTREAM"])
                commands.append(["XGROUP", "DESTROY", key.argument, "__tinker_create__"])
            }
            for entry in entries {
                commands.append(
                    ["XADD", key.argument, RedisArgument(entry.id)]
                        + entry.fields.flatMap { [RedisArgument($0.field), RedisArgument($0.value)] })
            }
            if RedisStreamID(lastID) > RedisStreamID(entries.last?.id ?? "0-0") {
                commands.append(["XSETID", key.argument, RedisArgument(lastID)])
            }
            for (name, delivered) in groups.sorted(by: { $0.key < $1.key }) {
                commands.append(["XGROUP", "CREATE", key.argument, RedisArgument(name), RedisArgument(delivered)])
            }
        case let .json(text):
            commands.append(["JSON.SET", key.argument, "$", RedisArgument(text)])
        }
        if keepTTL, ttl > 0 { commands.append(["PEXPIRE", key.argument, RedisArgument(ttl)]) }
        commands.append(["EXEC"])
        let results = try await writer.pipeline(commands)
        for result in results + (results.last?.array ?? []) {
            if case let .error(message) = result { throw DBError.server(ServerError(message: message)) }
        }
    }

    static func canonicalJSON(_ text: String) -> String {
        guard let data = text.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
            let canonical = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed])
        else { return text }
        return String(decoding: canonical, as: UTF8.self)
    }
}

/// A stream entry id, `milliseconds-sequence`, compared as numbers.
struct RedisStreamID: Comparable {
    let milliseconds: UInt64
    let sequence: UInt64

    init(_ text: String) {
        let parts = text.split(separator: "-")
        milliseconds = parts.first.flatMap { UInt64($0) } ?? 0
        sequence = parts.count > 1 ? UInt64(parts[1]) ?? 0 : 0
    }

    static func < (lhs: RedisStreamID, rhs: RedisStreamID) -> Bool {
        (lhs.milliseconds, lhs.sequence) < (rhs.milliseconds, rhs.sequence)
    }
}
