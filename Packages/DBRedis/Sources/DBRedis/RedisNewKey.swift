import DBCore
import Foundation

/// What a new key can be: every data type Redis documents that can be started from a
/// few typed lines. A HyperLogLog, a bitmap and a geospatial index are listed beside
/// the types they are stored as, because that is how they are made and used.
public enum RedisNewKeyKind: String, Sendable, Hashable, CaseIterable, Identifiable {
    case string, hash, list, set, sortedSet, stream, json
    case hyperLogLog, bitmap, geospatial
    case vectorSet, timeSeries, bloomFilter, cuckooFilter, countMinSketch, tDigest, topK

    public var id: String { rawValue }

    /// The name Redis's documentation gives the type.
    public var displayName: String {
        switch self {
        case .hyperLogLog: "HyperLogLog"
        case .bitmap: "Bitmap"
        case .geospatial: "Geospatial"
        default: keyType.displayName
        }
    }

    /// What `TYPE` will say of the key once it exists.
    public var keyType: RedisKeyType {
        switch self {
        case .string, .hyperLogLog, .bitmap: .string
        case .hash: .hash
        case .list: .list
        case .set: .set
        case .sortedSet, .geospatial: .zset
        case .stream: .stream
        case .json: .json
        case .vectorSet: .vectorSet
        case .timeSeries: .timeSeries
        case .bloomFilter: .bloomFilter
        case .cuckooFilter: .cuckooFilter
        case .countMinSketch: .countMinSketch
        case .tDigest: .tDigest
        case .topK: .topK
        }
    }

    /// The kind that makes a plain key of a type; nil for a type Tinker cannot create.
    public init?(_ type: RedisKeyType) {
        switch type {
        case .string: self = .string
        case .hash: self = .hash
        case .list: self = .list
        case .set: self = .set
        case .zset: self = .sortedSet
        case .stream: self = .stream
        case .json: self = .json
        case .vectorSet: self = .vectorSet
        case .timeSeries: self = .timeSeries
        case .bloomFilter: self = .bloomFilter
        case .cuckooFilter: self = .cuckooFilter
        case .countMinSketch: self = .countMinSketch
        case .tDigest: self = .tDigest
        case .topK: self = .topK
        case .other: return nil
        }
    }

    /// The commands creating one takes; a server without them is not offered the kind.
    public var commands: [String] {
        switch self {
        case .string, .hash, .list, .set, .sortedSet, .stream, .bitmap: []
        case .json: ["json.set"]
        case .hyperLogLog: ["pfadd"]
        case .geospatial: ["geoadd"]
        case .vectorSet: ["vadd"]
        case .timeSeries: ["ts.create", "ts.add"]
        case .bloomFilter: ["bf.reserve", "bf.add"]
        case .cuckooFilter: ["cf.reserve", "cf.add"]
        case .countMinSketch: ["cms.initbydim", "cms.incrby"]
        case .tDigest: ["tdigest.create", "tdigest.add"]
        case .topK: ["topk.reserve", "topk.add"]
        }
    }

    /// The kinds a server can create, in the documentation's order.
    public static func available(on server: RedisServerInfo?) -> [RedisNewKeyKind] {
        allCases.filter { kind in kind.commands.allSatisfy { server?.supports($0) ?? false } }
    }

    /// What the value field asks for.
    public var prompt: String {
        switch self {
        case .string: "The value"
        case .json: #"A JSON document, e.g. {"name": "Ada"}"#
        case .hash: "One field=value per line"
        case .list, .set: "One element per line"
        case .sortedSet: "One \"score member\" per line, e.g. 1.5 ada"
        case .stream: "The first entry: one field=value per line"
        case .hyperLogLog: "One element per line; only how many distinct ones there are is kept"
        case .bitmap: "The offsets of the bits to set, one per line, e.g. 7"
        case .geospatial: "One \"longitude latitude member\" per line, e.g. 116.1 -8.58 mataram"
        case .vectorSet: "One \"element v1 v2 v3…\" per line; every vector has the same length"
        case .timeSeries: "One \"timestamp value\" per line; * is now. May be left empty"
        case .bloomFilter, .cuckooFilter, .topK: "One item per line. May be left empty"
        case .countMinSketch: "One item per line, each counted once. May be left empty"
        case .tDigest: "One number per line. May be left empty"
        }
    }

    /// The settings the kind is created with, as `(label, placeholder)`; the placeholder
    /// is what the server uses when the field is left empty.
    public var settings: [RedisNewKeySetting] {
        switch self {
        case .timeSeries:
            [
                RedisNewKeySetting(.retention, "Retention (ms)", "0 — keep for ever"),
                RedisNewKeySetting(.labels, "Labels", "name=value name=value"),
            ]
        case .bloomFilter:
            [
                RedisNewKeySetting(.errorRate, "Error rate", "0.01"),
                RedisNewKeySetting(.capacity, "Capacity", "100"),
            ]
        case .cuckooFilter: [RedisNewKeySetting(.capacity, "Capacity", "1024")]
        case .topK: [RedisNewKeySetting(.topK, "K", "10")]
        case .countMinSketch:
            [RedisNewKeySetting(.width, "Width", "2000"), RedisNewKeySetting(.depth, "Depth", "5")]
        case .tDigest: [RedisNewKeySetting(.compression, "Compression", "100")]
        default: []
        }
    }

    /// Reads the value field. Throws a sentence that says which line is wrong.
    public func initialValue(from text: String) throws -> RedisInitialValue {
        switch self {
        case .string, .json:
            return .text(text)
        case .hash, .stream:
            return .pairs(RedisNewKeyText.pairs(text))
        case .list, .set, .hyperLogLog, .bloomFilter, .cuckooFilter, .topK, .countMinSketch:
            return .items(RedisNewKeyText.items(text))
        case .tDigest:
            let values = RedisNewKeyText.lines(text)
            if let wrong = values.first(where: { Double($0) == nil }) {
                throw RedisNewKeyProblem("“\(wrong)” is not a number.")
            }
            return .items(values.map { Data($0.utf8) })
        case .bitmap:
            let offsets = RedisNewKeyText.lines(text)
            // SETBIT takes offsets below 2^32.
            if let wrong = offsets.first(where: { UInt32($0) == nil }) {
                throw RedisNewKeyProblem("“\(wrong)” is not a bit offset (0 to 4294967295).")
            }
            return .items(offsets.map { Data($0.utf8) })
        case .sortedSet:
            guard let scored = RedisNewKeyText.scored(text) else {
                throw RedisNewKeyProblem("Each line is a number, a space, then the member.")
            }
            return .scored(scored)
        case .geospatial:
            return .positions(try RedisNewKeyText.positions(text))
        case .vectorSet:
            return .vectors(try RedisNewKeyText.vectors(text))
        case .timeSeries:
            return .samples(try RedisNewKeyText.samples(text))
        }
    }
}

/// One setting of a new key.
public struct RedisNewKeySetting: Sendable, Hashable, Identifiable {
    public enum Name: String, Sendable, Hashable {
        case retention, labels, errorRate, capacity, topK, width, depth, compression
    }

    public let name: Name
    public let label: String
    public let placeholder: String
    public var id: Name { name }

    init(_ name: Name, _ label: String, _ placeholder: String) {
        self.name = name
        self.label = label
        self.placeholder = placeholder
    }
}

/// What was wrong with a new key's form, as a sentence for the person who typed it.
public struct RedisNewKeyProblem: Error, Hashable, Sendable, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// A sample for a new time series; `*` as the timestamp is the server's clock.
public struct RedisNewSample: Sendable, Hashable {
    public var timestamp: String
    public var value: String

    public init(timestamp: String, value: String) {
        self.timestamp = timestamp
        self.value = value
    }
}

/// An element for a new vector set, its components as typed.
public struct RedisNewVector: Sendable, Hashable {
    public var element: Data
    public var values: [String]

    public init(element: Data, values: [String]) {
        self.element = element
        self.values = values
    }
}

/// Reading the multi-line value field of a new key.
public enum RedisNewKeyText {
    /// The lines that hold something, trimmed.
    public static func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// `field=value` per line; a line without `=` is a field with an empty value.
    public static func pairs(_ text: String) -> [RedisPair] {
        lines(text).map { line in
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            return RedisPair(
                field: RedisText.parse(String(parts[0]).trimmingCharacters(in: .whitespaces)),
                value: RedisText.parse(parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""))
        }
    }

    /// One element per line, as typed: spaces inside a line belong to the element.
    public static func items(_ text: String) -> [Data] {
        text.split(whereSeparator: \.isNewline).map { RedisText.parse(String($0)) }.filter { !$0.isEmpty }
    }

    /// `score member` per line. Nil when a score does not parse.
    public static func scored(_ text: String) -> [RedisScoredMember]? {
        var result: [RedisScoredMember] = []
        for line in lines(text) {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            let score = String(parts[0])
            guard Double(score) != nil || ["inf", "+inf", "-inf"].contains(score.lowercased()) else { return nil }
            result.append(RedisScoredMember(member: RedisText.parse(String(parts[1])), score: score))
        }
        return result
    }

    /// `longitude latitude member` per line, within the limits `GEOADD` documents.
    public static func positions(_ text: String) throws -> [RedisGeoMember] {
        try lines(text).map { line in
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let longitude = Double(parts[0]), let latitude = Double(parts[1]) else {
                throw RedisNewKeyProblem("“\(line)” is not “longitude latitude member”.")
            }
            guard (-180 ... 180).contains(longitude), (-85.05112878 ... 85.05112878).contains(latitude) else {
                throw RedisNewKeyProblem(
                    "“\(line)”: longitude is -180 to 180 and latitude -85.05112878 to 85.05112878.")
            }
            return RedisGeoMember(
                member: RedisText.parse(String(parts[2])), longitude: String(parts[0]), latitude: String(parts[1]),
                score: "")
        }
    }

    /// `element v1 v2 …` per line; every vector must have the first one's length.
    public static func vectors(_ text: String) throws -> [RedisNewVector] {
        var result: [RedisNewVector] = []
        for line in lines(text) {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 2, parts.dropFirst().allSatisfy({ Double($0) != nil }) else {
                throw RedisNewKeyProblem("“\(line)” is not an element followed by its numbers.")
            }
            if let first = result.first, first.values.count != parts.count - 1 {
                throw RedisNewKeyProblem(
                    "“\(parts[0])” has \(parts.count - 1) numbers; the first element has \(first.values.count).")
            }
            result.append(RedisNewVector(element: RedisText.parse(parts[0]), values: Array(parts.dropFirst())))
        }
        return result
    }

    /// `timestamp value` per line; the timestamp is milliseconds or `*`.
    public static func samples(_ text: String) throws -> [RedisNewSample] {
        try lines(text).map { line in
            let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard parts.count == 2, parts[0] == "*" || (Int64(parts[0]) ?? -1) >= 0, Double(parts[1]) != nil else {
                throw RedisNewKeyProblem("“\(line)” is not “timestamp value”; the timestamp is milliseconds or *.")
            }
            return RedisNewSample(timestamp: parts[0], value: parts[1])
        }
    }

    /// `name=value name=value` on one line, for a time series' labels.
    public static func labels(_ text: String) -> [RedisField] {
        text.split(whereSeparator: { $0 == " " || $0.isNewline }).compactMap { part in
            let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2, !pair[0].isEmpty else { return nil }
            return RedisField(name: String(pair[0]), value: String(pair[1]))
        }
    }
}

extension RedisValues {
    /// A new key of any documented kind, with its first value. Refuses when the key
    /// already exists, so creating never overwrites. `settings` are the kind's own
    /// (``RedisNewKeyKind/settings``), as typed; an empty one is the server's default.
    /// Everything the key takes — reserving, filling, expiry — runs in one transaction.
    public static func create(
        _ connection: RedisConnection, _ key: RedisKey, kind: RedisNewKeyKind, initial: RedisInitialValue,
        settings: [RedisNewKeySetting.Name: String] = [:], ttlSeconds: Int64? = nil
    ) async throws {
        if try await RedisKeyspace.exists(connection, key) {
            throw DBError.server(ServerError(message: "A key named \(key.display) already exists."))
        }
        var commands = try creation(key, kind: kind, initial: initial, settings: settings)
        if let ttlSeconds, ttlSeconds > 0 { commands.append(["EXPIRE", key.argument, RedisArgument(ttlSeconds)]) }
        if commands.count == 1 {
            try await connection.send(commands[0])
        } else {
            try check(try await connection.pipeline([["MULTI"]] + commands + [["EXEC"]]))
        }
    }

    /// The commands that make the key, in order.
    static func creation(
        _ key: RedisKey, kind: RedisNewKeyKind, initial: RedisInitialValue, settings: [RedisNewKeySetting.Name: String]
    ) throws -> [[RedisArgument]] {
        func setting(_ name: RedisNewKeySetting.Name) -> String? {
            let value = settings[name]?.trimmingCharacters(in: .whitespaces) ?? ""
            return value.isEmpty ? nil : value
        }
        func filled(_ items: [Data]) throws -> [Data] {
            // Redis has no empty hashes, lists, sets or streams: removing the last element
            // removes the key. A new one needs something in it.
            guard !items.isEmpty else {
                throw DBError.protocolError(
                    "A \(kind.displayName.lowercased()) needs at least one element; Redis does not keep empty ones.")
            }
            return items
        }
        let name = key.argument
        switch (kind, initial) {
        case let (.string, .text(value)):
            return [["SET", name, RedisArgument(value), "NX"]]
        case let (.json, .text(value)):
            return [["JSON.SET", name, "$", RedisArgument(value), "NX"]]
        case let (.hash, .pairs(pairs)):
            _ = try filled(pairs.map(\.field))
            return [["HSET", name] + pairs.flatMap { [RedisArgument($0.field), RedisArgument($0.value)] }]
        case let (.stream, .pairs(pairs)):
            _ = try filled(pairs.map(\.field))
            return [["XADD", name, "*"] + pairs.flatMap { [RedisArgument($0.field), RedisArgument($0.value)] }]
        case let (.list, .items(items)):
            return try [["RPUSH", name] + filled(items).map(RedisArgument.init)]
        case let (.set, .items(items)):
            return try [["SADD", name] + filled(items).map(RedisArgument.init)]
        case let (.sortedSet, .scored(members)):
            _ = try filled(members.map(\.member))
            return [["ZADD", name] + members.flatMap { [RedisArgument($0.score), RedisArgument($0.member)] }]
        case let (.hyperLogLog, .items(items)):
            // PFADD with no element makes an empty HyperLogLog, which is a key like any other.
            return [["PFADD", name] + items.map(RedisArgument.init)]
        case let (.bitmap, .items(offsets)):
            return try filled(offsets).map { ["SETBIT", name, RedisArgument($0), 1] }
        case let (.geospatial, .positions(members)):
            _ = try filled(members.map(\.member))
            return [
                ["GEOADD", name]
                    + members.flatMap {
                        [RedisArgument($0.longitude), RedisArgument($0.latitude), RedisArgument($0.member)]
                    }
            ]
        case let (.vectorSet, .vectors(vectors)):
            _ = try filled(vectors.map(\.element))
            return vectors.map { vector in
                ["VADD", name, "VALUES", RedisArgument(vector.values.count)]
                    + vector.values.map { RedisArgument($0) } + [RedisArgument(vector.element)]
            }
        case let (.timeSeries, .samples(samples)):
            var create: [RedisArgument] = ["TS.CREATE", name]
            if let retention = setting(.retention) { create += ["RETENTION", RedisArgument(retention)] }
            let labels = RedisNewKeyText.labels(setting(.labels) ?? "")
            if !labels.isEmpty {
                create += ["LABELS"] + labels.flatMap { [RedisArgument($0.name), RedisArgument($0.value)] }
            }
            return [create]
                + samples.map { ["TS.ADD", name, RedisArgument($0.timestamp), RedisArgument($0.value)] }
        case let (.bloomFilter, .items(items)):
            var commands: [[RedisArgument]] = [
                [
                    "BF.RESERVE", name, RedisArgument(setting(.errorRate) ?? "0.01"),
                    RedisArgument(setting(.capacity) ?? "100"),
                ]
            ]
            if !items.isEmpty { commands.append(["BF.MADD", name] + items.map(RedisArgument.init)) }
            return commands
        case let (.cuckooFilter, .items(items)):
            return [["CF.RESERVE", name, RedisArgument(setting(.capacity) ?? "1024")]]
                + items.map { ["CF.ADD", name, RedisArgument($0)] }
        case let (.topK, .items(items)):
            var commands: [[RedisArgument]] = [["TOPK.RESERVE", name, RedisArgument(setting(.topK) ?? "10")]]
            if !items.isEmpty { commands.append(["TOPK.ADD", name] + items.map(RedisArgument.init)) }
            return commands
        case let (.countMinSketch, .items(items)):
            var commands: [[RedisArgument]] = [
                [
                    "CMS.INITBYDIM", name, RedisArgument(setting(.width) ?? "2000"),
                    RedisArgument(setting(.depth) ?? "5"),
                ]
            ]
            if !items.isEmpty {
                commands.append(["CMS.INCRBY", name] + items.flatMap { [RedisArgument($0), 1] })
            }
            return commands
        case let (.tDigest, .items(values)):
            var create: [RedisArgument] = ["TDIGEST.CREATE", name]
            if let compression = setting(.compression) { create += ["COMPRESSION", RedisArgument(compression)] }
            var commands = [create]
            if !values.isEmpty { commands.append(["TDIGEST.ADD", name] + values.map(RedisArgument.init)) }
            return commands
        default:
            throw DBError.protocolError("\(kind.displayName) keys cannot be created with that value.")
        }
    }
}
