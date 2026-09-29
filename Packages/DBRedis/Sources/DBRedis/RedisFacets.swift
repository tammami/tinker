import DBCore
import Foundation

/// What a key is besides its `TYPE`. Redis documents bitmaps, bitfields and
/// HyperLogLogs as data types, yet stores them as strings, and a geospatial index as a
/// sorted set; `TYPE` cannot tell them apart, the contents can.
public enum RedisFacet: Sendable, Hashable {
    /// A string that starts with the `HYLL` header: `PFCOUNT` says how many distinct
    /// elements were added, within 0.81%.
    case hyperLogLog(count: Int64)
    /// A sorted set whose scores are 52-bit geohashes, as `GEOADD` writes them.
    case geospatial

    /// The name Redis's documentation gives the type.
    public var displayName: String {
        switch self {
        case .hyperLogLog: "HyperLogLog"
        case .geospatial: "Geospatial"
        }
    }
}

/// How the server holds a key: what `OBJECT` says about it.
public struct RedisKeyMetadata: Sendable, Hashable {
    /// `OBJECT ENCODING`: `listpack`, `hashtable`, `skiplist`, `embstr`, `int`…
    public var encoding: String?
    /// `OBJECT IDLETIME`: seconds since the key was last read or written. The server
    /// keeps it only under an LRU (or no) eviction policy.
    public var idleSeconds: Int64?
    /// `OBJECT FREQ`: the logarithmic access counter, kept only under an LFU policy.
    public var frequency: Int64?

    public init(encoding: String? = nil, idleSeconds: Int64? = nil, frequency: Int64? = nil) {
        self.encoding = encoding
        self.idleSeconds = idleSeconds
        self.frequency = frequency
    }
}

/// A string read as a bitmap.
public struct RedisBitmap: Sendable, Hashable {
    /// The string's length in bytes; it holds eight times as many bits.
    public var bytes: Int64
    /// `BITCOUNT`: how many bits are set.
    public var setBits: Int64
    /// The first bytes, for showing the first bits.
    public var head: Data

    /// How many of the first bytes are read.
    public static let headLength = 64

    /// The first bits as `0` and `1`, most significant first — bit 0 is the first
    /// character, as `SETBIT` and `GETBIT` count them.
    public var headBits: String {
        var text = ""
        text.reserveCapacity(head.count * 8)
        for byte in head {
            for shift in stride(from: 7, through: 0, by: -1) {
                text.append((byte >> UInt8(shift)) & 1 == 1 ? "1" : "0")
            }
        }
        return text
    }

    /// The offsets of the set bits among the first ones read.
    public var headOffsets: [Int] {
        var offsets: [Int] = []
        for (index, byte) in head.enumerated() {
            for bit in 0 ..< 8 where (byte >> UInt8(7 - bit)) & 1 == 1 { offsets.append(index * 8 + bit) }
        }
        return offsets
    }
}

/// A member of a geospatial index with where it is. The coordinates are the server's
/// own text: a position is never rounded through a `Double`.
public struct RedisGeoMember: Sendable, Hashable, Identifiable {
    public var member: Data
    public var longitude: String
    public var latitude: String
    /// The 52-bit geohash the sorted set stores as the member's score.
    public var score: String
    public var id: Data { member }

    public init(member: Data, longitude: String, latitude: String, score: String) {
        self.member = member
        self.longitude = longitude
        self.latitude = latitude
        self.score = score
    }
}

/// The types that live inside other types, and what the server knows about any key.
public enum RedisFacets {
    /// The header every HyperLogLog starts with.
    static let hyperLogLogMagic = Data("HYLL".utf8)

    /// Whether a string's first bytes are a HyperLogLog's.
    public static func isHyperLogLog(_ value: Data) -> Bool {
        value.count >= 16 && value.prefix(4) == hyperLogLogMagic
    }

    /// Whether every score could be a geohash `GEOADD` wrote: a whole number below 2⁵².
    /// Other sorted sets can pass — one scored by timestamps does — so this decides
    /// whether the geospatial view is offered, never whether it is shown.
    public static func looksGeospatial(_ members: [RedisScoredMember]) -> Bool {
        guard !members.isEmpty else { return false }
        return members.allSatisfy { member in
            guard let score = UInt64(member.score) else { return false }
            return score > 0 && score < (1 << 52)
        }
    }

    /// Encoding, idle time and access frequency, in one round trip. Whatever the server
    /// does not keep, or refuses to say, stays nil.
    public static func metadata(_ connection: RedisConnection, _ key: RedisKey) async throws -> RedisKeyMetadata {
        let replies = try await connection.pipeline([
            ["OBJECT", "ENCODING", key.argument], ["OBJECT", "IDLETIME", key.argument],
            ["OBJECT", "FREQ", key.argument],
        ])
        return metadata(replies)
    }

    static func metadata(_ replies: [RESPValue]) -> RedisKeyMetadata {
        guard replies.count == 3 else { return RedisKeyMetadata() }
        return RedisKeyMetadata(
            encoding: replies[0].string, idleSeconds: replies[1].integer, frequency: replies[2].integer)
    }

    /// `PFCOUNT`: the approximate number of distinct elements.
    public static func hyperLogLogCount(_ connection: RedisConnection, _ key: RedisKey) async throws -> Int64 {
        try await connection.send(["PFCOUNT", key.argument]).integer ?? 0
    }

    /// Adds elements to a HyperLogLog.
    public static func addToHyperLogLog(
        _ connection: RedisConnection, _ key: RedisKey, _ elements: [Data]
    )
        async throws
    {
        guard !elements.isEmpty else { return }
        try await connection.send(["PFADD", key.argument] + elements.map(RedisArgument.init))
    }

    /// A string as a bitmap: its size, its set bits and its first bytes.
    public static func bitmap(_ connection: RedisConnection, _ key: RedisKey) async throws -> RedisBitmap {
        let replies = try await connection.pipeline([
            ["STRLEN", key.argument], ["BITCOUNT", key.argument],
            ["GETRANGE", key.argument, 0, RedisArgument(RedisBitmap.headLength - 1)],
        ])
        try RedisModuleValues.throwFirstError(replies)
        return RedisBitmap(
            bytes: replies[0].integer ?? 0, setBits: replies[1].integer ?? 0, head: replies[2].data ?? Data())
    }

    /// Sets or clears one bit.
    public static func setBit(_ connection: RedisConnection, _ key: RedisKey, offset: Int64, on: Bool) async throws {
        try await connection.send(["SETBIT", key.argument, RedisArgument(offset), on ? 1 : 0])
    }

    /// Where the members of a page are (`GEOPOS`), in the page's order. A member whose
    /// score is not a position is left out.
    public static func positions(
        _ connection: RedisConnection, _ key: RedisKey, of members: [RedisScoredMember]
    )
        async throws -> [RedisGeoMember]
    {
        guard !members.isEmpty else { return [] }
        let reply = try await connection.send(["GEOPOS", key.argument] + members.map { RedisArgument($0.member) })
        return positions(members, reply)
    }

    static func positions(_ members: [RedisScoredMember], _ reply: RESPValue) -> [RedisGeoMember] {
        zip(members, reply.array ?? []).compactMap { member, position in
            guard let parts = position.array, parts.count == 2, let longitude = parts[0].string,
                let latitude = parts[1].string
            else { return nil }
            return RedisGeoMember(
                member: member.member, longitude: longitude, latitude: latitude, score: member.score)
        }
    }

    /// Adds or moves a member of a geospatial index.
    public static func addPosition(
        _ connection: RedisConnection, _ key: RedisKey, member: Data, longitude: String, latitude: String
    ) async throws {
        try await connection.send([
            "GEOADD", key.argument, RedisArgument(longitude), RedisArgument(latitude), RedisArgument(member),
        ])
    }

    // MARK: - Hash field expiry

    /// The time each field has left, in milliseconds (`HPTTL`); nil for a field that
    /// does not expire.
    public static func fieldExpiry(
        _ connection: RedisConnection, _ key: RedisKey, fields: [Data]
    ) async throws
        -> [Int64?]
    {
        guard !fields.isEmpty else { return [] }
        let reply = try await connection.send(
            ["HPTTL", key.argument, "FIELDS", RedisArgument(fields.count)] + fields.map(RedisArgument.init))
        return fieldExpiry(reply, count: fields.count)
    }

    static func fieldExpiry(_ reply: RESPValue, count: Int) -> [Int64?] {
        let values = reply.array ?? []
        return (0 ..< count).map { index in
            guard index < values.count, let ttl = values[index].integer, ttl >= 0 else { return nil }
            return ttl
        }
    }

    /// Gives one field a time to live, or with nil takes it away.
    public static func setFieldExpiry(
        _ connection: RedisConnection, _ key: RedisKey, field: Data, milliseconds: Int64?
    ) async throws {
        let reply: RESPValue
        if let milliseconds {
            reply = try await connection.send([
                "HPEXPIRE", key.argument, RedisArgument(milliseconds), "FIELDS", 1, RedisArgument(field),
            ])
        } else {
            reply = try await connection.send(["HPERSIST", key.argument, "FIELDS", 1, RedisArgument(field)])
        }
        // -2: the server found no such field.
        if reply.array?.first?.integer == -2 {
            throw DBError.protocolError("The field no longer exists. Reload the hash and try again.")
        }
    }
}
