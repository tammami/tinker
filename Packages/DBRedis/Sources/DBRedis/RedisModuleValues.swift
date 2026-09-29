import DBCore
import Foundation

/// One `name value` line of what a type reports about a key (`TS.INFO`, `BF.INFO`, `VINFO`…).
/// Both are the server's own words.
public struct RedisField: Sendable, Hashable, Identifiable {
    public var name: String
    public var value: String
    public var id: String { name }

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// One sample of a time series. The value stays as the server wrote it.
public struct RedisSample: Sendable, Hashable, Identifiable {
    /// Milliseconds since the Unix epoch.
    public var timestamp: Int64
    public var value: String
    public var id: Int64 { timestamp }

    public init(timestamp: Int64, value: String) {
        self.timestamp = timestamp
        self.value = value
    }
}

/// What `TS.INFO` says about a time series.
public struct RedisTimeSeriesInfo: Sendable, Hashable {
    public var totalSamples: Int64
    public var firstTimestamp: Int64
    public var lastTimestamp: Int64
    /// How long samples are kept, in milliseconds; 0 keeps them for ever.
    public var retentionMilliseconds: Int64
    public var labels: [RedisField]
    /// Everything the server reported, in its order.
    public var fields: [RedisField]

    public init(
        totalSamples: Int64 = 0, firstTimestamp: Int64 = 0, lastTimestamp: Int64 = 0, retentionMilliseconds: Int64 = 0,
        labels: [RedisField] = [], fields: [RedisField] = []
    ) {
        self.totalSamples = totalSamples
        self.firstTimestamp = firstTimestamp
        self.lastTimestamp = lastTimestamp
        self.retentionMilliseconds = retentionMilliseconds
        self.labels = labels
        self.fields = fields
    }
}

/// A probabilistic key as it can be shown: what it reports about itself and, where the
/// type can list anything, a table — the heavy hitters of a Top-K, the quantiles of a
/// t-digest. A Bloom filter, a Cuckoo filter and a Count-min sketch cannot enumerate
/// what was put into them; they answer questions about one item at a time.
public struct RedisTypeSummary: Sendable, Hashable {
    public var fields: [RedisField]
    public var columns: [String]
    public var rows: [[String]]

    public init(fields: [RedisField], columns: [String] = [], rows: [[String]] = []) {
        self.fields = fields
        self.columns = columns
        self.rows = rows
    }
}

/// One element of a vector set: its vector and the JSON attributes stored with it.
public struct RedisVectorElement: Sendable, Hashable {
    public var element: Data
    /// The components, as the server writes them (`VEMB`).
    public var vector: [String]
    /// The element's attributes (`VGETATTR`), or nil when it has none.
    public var attributes: String?
}

/// An element and how close it is to the one asked about (`VSIM … WITHSCORES`).
public struct RedisVectorMatch: Sendable, Hashable, Identifiable {
    public var element: Data
    public var score: String
    public var id: Data { element }
}

/// Reading and changing the types Redis documents beside the classic ones: time series,
/// Bloom and Cuckoo filters, Top-K, Count-min sketch, t-digest and vector sets.
///
/// Every read is bounded — a page of samples, a page of elements, a fixed list of
/// quantiles — so a key of any size costs the same to open.
public enum RedisModuleValues {
    /// The quantiles a t-digest is asked for when it is opened.
    public static let quantiles = ["0.01", "0.05", "0.25", "0.5", "0.75", "0.9", "0.95", "0.99", "0.999"]

    // MARK: - Reading

    /// A page of samples, oldest first, with the series' own description.
    static func timeSeries(
        _ connection: RedisConnection, _ key: RedisKey, from start: Int64?
    ) async throws
        -> RedisValuePage
    {
        let replies = try await connection.pipeline([
            ["TS.INFO", key.argument],
            [
                "TS.RANGE", key.argument, start.map { RedisArgument($0) } ?? "-", "+", "COUNT",
                RedisArgument(RedisValues.pageSize),
            ],
        ])
        try throwFirstError(replies)
        let found = samples(replies[1])
        var next: Int64?
        // Timestamps are unique in a series, so the page after starts one millisecond on.
        if found.count == RedisValues.pageSize, let last = found.last, last.timestamp < Int64.max {
            next = last.timestamp + 1
        }
        return .timeSeries(info: timeSeriesInfo(replies[0]), samples: found, next: next)
    }

    /// `BF.INFO`, `CF.INFO` or `CMS.INFO`: all these types can say about themselves.
    static func summary(
        _ connection: RedisConnection, _ key: RedisKey, info command: String
    ) async throws
        -> RedisValuePage
    {
        .summary(RedisTypeSummary(fields: fields(try await connection.send([RedisArgument(command), key.argument]))))
    }

    static func topK(_ connection: RedisConnection, _ key: RedisKey) async throws -> RedisValuePage {
        let replies = try await connection.pipeline([
            ["TOPK.INFO", key.argument], ["TOPK.LIST", key.argument, "WITHCOUNT"],
        ])
        try throwFirstError(replies)
        return .summary(
            RedisTypeSummary(fields: fields(replies[0]), columns: ["Item", "Count"], rows: counted(replies[1])))
    }

    static func tDigest(_ connection: RedisConnection, _ key: RedisKey) async throws -> RedisValuePage {
        let replies = try await connection.pipeline([
            ["TDIGEST.INFO", key.argument], ["TDIGEST.MIN", key.argument], ["TDIGEST.MAX", key.argument],
            ["TDIGEST.QUANTILE", key.argument] + quantiles.map { RedisArgument($0) },
        ])
        try throwFirstError(replies)
        var rows = [["min", replies[1].string ?? ""]]
        rows += quantileRows(replies[3])
        rows.append(["max", replies[2].string ?? ""])
        return .summary(RedisTypeSummary(fields: fields(replies[0]), columns: ["Quantile", "Value"], rows: rows))
    }

    /// A page of a vector set's elements in lexicographic order (`VRANGE`), or, on a
    /// server without it, a random sample of them (`VRANDMEMBER`).
    static func vectorSet(
        _ connection: RedisConnection, _ key: RedisKey, after: Data?, ranged: Bool
    ) async throws
        -> RedisValuePage
    {
        let size = RedisArgument(RedisValues.pageSize)
        let list: [RedisArgument] =
            ranged
            ? ["VRANGE", key.argument, after.map { RedisArgument(Data("(".utf8) + $0) } ?? "-", "+", size]
            : ["VRANDMEMBER", key.argument, size]
        let replies = try await connection.pipeline([["VINFO", key.argument], list])
        try throwFirstError(replies)
        let elements = (replies[1].array ?? []).compactMap(\.data)
        var next: Data?
        if ranged, elements.count == RedisValues.pageSize { next = elements.last }
        return .vectorSet(info: fields(replies[0]), elements: elements, next: next, isSample: !ranged)
    }

    /// One element's vector and attributes.
    public static func vectorElement(
        _ connection: RedisConnection, _ key: RedisKey, element: Data
    ) async throws
        -> RedisVectorElement
    {
        let replies = try await connection.pipeline([
            ["VEMB", key.argument, RedisArgument(element)], ["VGETATTR", key.argument, RedisArgument(element)],
        ])
        if case let .error(message) = replies[0] { throw DBError.server(ServerError(message: message)) }
        // A server without VGETATTR still has the vector.
        let attributes = replies[1].isNull ? nil : replies[1].data.map { String(decoding: $0, as: UTF8.self) }
        return RedisVectorElement(
            element: element, vector: (replies[0].array ?? []).compactMap(\.string),
            attributes: attributes.flatMap { $0.isEmpty ? nil : $0 })
    }

    /// The elements nearest to one already in the set, nearest first.
    public static func similar(
        _ connection: RedisConnection, _ key: RedisKey, to element: Data, count: Int = 10
    )
        async throws -> [RedisVectorMatch]
    {
        let reply = try await connection.send([
            "VSIM", key.argument, "ELE", RedisArgument(element), "WITHSCORES", "COUNT", RedisArgument(count),
        ])
        return reply.pairs.compactMap { pair in
            pair.0.data.map { RedisVectorMatch(element: $0, score: pair.1.string ?? "") }
        }
    }

    // MARK: - Parsing

    /// A flat `name value name value` reply as lines. A value that is itself a list
    /// (labels, rules) is written on one line, its parts separated by spaces.
    static func fields(_ reply: RESPValue) -> [RedisField] {
        reply.pairs.compactMap { pair in
            guard let name = pair.0.string else { return nil }
            return RedisField(name: name, value: flat(pair.1))
        }
    }

    static func flat(_ value: RESPValue) -> String {
        if let items = value.array {
            return items.map { item in
                guard let inner = item.array else { return flat(item) }
                // A pair inside a list reads as `name=value`.
                return inner.count == 2 ? "\(flat(inner[0]))=\(flat(inner[1]))" : "[\(flat(item))]"
            }.joined(separator: " ")
        }
        if value.isNull { return "" }
        if case let .error(message) = value { return message }
        return value.string ?? ""
    }

    static func timeSeriesInfo(_ reply: RESPValue) -> RedisTimeSeriesInfo {
        var info = RedisTimeSeriesInfo(fields: fields(reply))
        for (name, value) in reply.pairs {
            switch name.string {
            case "totalSamples": info.totalSamples = value.integer ?? 0
            case "firstTimestamp": info.firstTimestamp = value.integer ?? 0
            case "lastTimestamp": info.lastTimestamp = value.integer ?? 0
            case "retentionTime": info.retentionMilliseconds = value.integer ?? 0
            case "labels":
                info.labels = (value.array ?? []).compactMap { label in
                    guard let parts = label.array, parts.count == 2, let name = parts[0].string else { return nil }
                    return RedisField(name: name, value: parts[1].string ?? "")
                }
            default: break
            }
        }
        return info
    }

    /// `TS.RANGE`: a list of `[timestamp, value]`.
    static func samples(_ reply: RESPValue) -> [RedisSample] {
        (reply.array ?? []).compactMap { sample in
            guard let parts = sample.array, parts.count == 2, let timestamp = parts[0].integer else { return nil }
            return RedisSample(timestamp: timestamp, value: parts[1].string ?? "")
        }
    }

    /// `TOPK.LIST … WITHCOUNT`: `item count item count`.
    static func counted(_ reply: RESPValue) -> [[String]] {
        reply.pairs.compactMap { pair in
            guard let item = pair.0.data else { return nil }
            return [RedisText.display(item), pair.1.string ?? ""]
        }
    }

    /// `TDIGEST.QUANTILE`: one value for each quantile asked, in order.
    static func quantileRows(_ reply: RESPValue) -> [[String]] {
        zip(quantiles, reply.array ?? []).map { [$0, $1.string ?? ""] }
    }

    /// Throws the first server error among the replies, verbatim.
    static func throwFirstError(_ replies: [RESPValue]) throws {
        for reply in replies {
            if case let .error(message) = reply { throw DBError.server(ServerError(message: message)) }
        }
    }

    // MARK: - Writing

    /// Adds a sample. `timestamp` is milliseconds, or `*` for the server's clock.
    public static func addSample(
        _ connection: RedisConnection, _ key: RedisKey, timestamp: String, value: String
    )
        async throws
    {
        try await connection.send(["TS.ADD", key.argument, RedisArgument(timestamp), RedisArgument(value)])
    }

    /// Removes the samples at exactly these timestamps.
    public static func deleteSamples(_ connection: RedisConnection, _ key: RedisKey, timestamps: [Int64]) async throws {
        guard !timestamps.isEmpty else { return }
        let commands: [[RedisArgument]] = timestamps.map {
            ["TS.DEL", key.argument, RedisArgument($0), RedisArgument($0)]
        }
        try RedisValues.check(try await connection.pipeline([["MULTI"]] + commands + [["EXEC"]]))
    }

    /// Adds items to a Bloom filter, a Cuckoo filter or a Top-K.
    public static func add(
        _ connection: RedisConnection, _ key: RedisKey, type: RedisKeyType, items: [Data]
    )
        async throws
    {
        guard !items.isEmpty else { return }
        switch type {
        case .bloomFilter:
            try await connection.send(["BF.MADD", key.argument] + items.map(RedisArgument.init))
        case .cuckooFilter:
            let commands: [[RedisArgument]] = items.map { ["CF.ADD", key.argument, RedisArgument($0)] }
            try RedisValues.check(try await connection.pipeline([["MULTI"]] + commands + [["EXEC"]]))
        case .topK:
            try await connection.send(["TOPK.ADD", key.argument] + items.map(RedisArgument.init))
        case .countMinSketch:
            try await connection.send(["CMS.INCRBY", key.argument] + items.flatMap { [RedisArgument($0), 1] })
        default:
            throw DBError.protocolError("Items cannot be added to a \(type.displayName.lowercased()) this way.")
        }
    }

    /// Adds observations to a t-digest.
    public static func addObservations(_ connection: RedisConnection, _ key: RedisKey, values: [String]) async throws {
        guard !values.isEmpty else { return }
        try await connection.send(["TDIGEST.ADD", key.argument] + values.map { RedisArgument($0) })
    }

    /// Removes one occurrence of an item from a Cuckoo filter — the one probabilistic
    /// filter that can forget.
    public static func removeFromCuckoo(_ connection: RedisConnection, _ key: RedisKey, item: Data) async throws {
        let removed = try await connection.send(["CF.DEL", key.argument, RedisArgument(item)]).integer ?? 0
        if removed == 0 { throw DBError.protocolError("The filter does not hold that item.") }
    }

    /// Removes elements from a vector set.
    public static func removeVectorElements(
        _ connection: RedisConnection, _ key: RedisKey, _ elements: [Data]
    )
        async throws
    {
        guard !elements.isEmpty else { return }
        let commands: [[RedisArgument]] = elements.map { ["VREM", key.argument, RedisArgument($0)] }
        try RedisValues.check(try await connection.pipeline([["MULTI"]] + commands + [["EXEC"]]))
    }

    /// What a probabilistic key answers about one item, in a sentence that says how far
    /// the answer can be trusted: these types trade certainty for size.
    public static func ask(
        _ connection: RedisConnection, _ key: RedisKey, type: RedisKeyType, item: String
    )
        async throws -> String
    {
        let argument = RedisArgument(RedisText.parse(item))
        switch type {
        case .bloomFilter, .cuckooFilter:
            let command: RedisArgument = type == .bloomFilter ? "BF.EXISTS" : "CF.EXISTS"
            let found = try await connection.send([command, key.argument, argument]).integer ?? 0
            return found == 1
                ? "\(item) may be in the filter (a false positive is possible)."
                : "\(item) is not in the filter."
        case .countMinSketch:
            let count = try await connection.send(["CMS.QUERY", key.argument, argument]).array?.first?.integer ?? 0
            return "\(item) was counted at most \(count) time\(count == 1 ? "" : "s")."
        case .topK:
            let replies = try await connection.pipeline([
                ["TOPK.QUERY", key.argument, argument], ["TOPK.COUNT", key.argument, argument],
            ])
            if case let .error(message) = replies[0] { throw DBError.server(ServerError(message: message)) }
            let isTop = replies[0].array?.first?.integer == 1
            // TOPK.COUNT is deprecated on newer servers; the answer stands without it.
            let count = replies[1].array?.first?.integer
            return "\(item) is \(isTop ? "" : "not ")among the top items"
                + (count.map { ", counted about \($0) time\($0 == 1 ? "" : "s")." } ?? ".")
        case .tDigest:
            let reply = try await connection.send(["TDIGEST.QUANTILE", key.argument, RedisArgument(item)])
            return "Quantile \(item) is \(reply.array?.first?.string ?? "nan")."
        default:
            throw DBError.protocolError("A \(type.displayName.lowercased()) has nothing to ask.")
        }
    }
}
