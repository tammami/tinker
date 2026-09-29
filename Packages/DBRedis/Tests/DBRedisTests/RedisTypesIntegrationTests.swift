import DBCore
import DBTestKit
import Foundation
import XCTest

@testable import DBRedis

/// Every data type Redis documents, made and read on the developer's local server
/// (`TINKER_TEST_REDIS_URL`, logical database 15, keys under `tinker:test:types:`).
///
/// A type the server does not have is skipped, and a skip is a gap to report: the type
/// was not proved there.
final class RedisTypesIntegrationTests: XCTestCase {
    private var sessions: [RedisSession] = []

    private struct Server {
        let connection: RedisConnection
        let info: RedisServerInfo
    }

    private func server() async throws -> Server {
        let test = try await RedisIntegrationTests.server()
        let session = RedisSession(config: test.config, secrets: test.secrets)
        sessions.append(session)
        let info = try await session.connect()
        return Server(connection: try await session.connection(database: test.main), info: info)
    }

    /// Skips unless the server has every command of the kind.
    private func require(_ kind: RedisNewKeyKind, on server: Server) throws {
        let missing = kind.commands.filter { !server.info.supports($0) }
        if !missing.isEmpty || !server.info.supports(kind.keyType) {
            throw XCTSkip(
                "\(server.info.product) \(server.info.version) has no \(kind.displayName) (\(missing.joined(separator: ", ")))"
            )
        }
    }

    private func key(_ name: String) -> RedisKey { RedisKey("tinker:test:types:\(name)") }

    private func create(
        _ kind: RedisNewKeyKind, _ key: RedisKey, _ text: String, settings: [RedisNewKeySetting.Name: String] = [:],
        ttl: Int64? = nil, on server: Server
    ) async throws {
        try await RedisValues.create(
            server.connection, key, kind: kind, initial: kind.initialValue(from: text), settings: settings,
            ttlSeconds: ttl)
    }

    private func type(of key: RedisKey, on server: Server) async throws -> RedisKeyType {
        RedisKeyType(typeName: try await server.connection.send(["TYPE", key.argument]).string ?? "none")
    }

    override func tearDown() async throws {
        for session in sessions {
            if let connection = try? await session.connection(database: 15) {
                let keys =
                    (try? await RedisKeyspace.scan(connection, match: "tinker:test:types:*", type: nil, limit: 100_000))?
                    .keys ?? []
                _ = try? await RedisKeyspace.delete(connection, keys)
            }
            await session.disconnect()
        }
        sessions = []
    }

    // MARK: - The server

    func testTheServerSaysWhichTypesAndCommandsItHas() async throws {
        let server = try await server()
        TestLog.note(
            "redis types: \(server.info.product) \(server.info.version), modules \(server.info.modules.sorted()), "
                + "types \(server.info.keyTypes.map(\.displayName)), field expiry \(server.info.hasHashFieldExpiry)")
        // Every server has the classic types and the commands of the types inside them.
        XCTAssertTrue(server.info.keyTypes.starts(with: [.string, .hash, .list, .set, .zset, .stream]))
        for command in ["pfcount", "geopos", "bitcount", "object"] {
            XCTAssertTrue(server.info.supports(command), command)
        }
        XCTAssertFalse(server.info.supports("no.such.command"))
        let kinds = RedisNewKeyKind.available(on: server.info)
        XCTAssertTrue(kinds.starts(with: [.string, .hash, .list, .set, .sortedSet, .stream]))
        XCTAssertTrue(kinds.contains(.hyperLogLog))
        XCTAssertTrue(kinds.contains(.geospatial))
    }

    // MARK: - Types inside a string

    func testAHyperLogLogIsRecognisedAndCounted() async throws {
        let server = try await server()
        try require(.hyperLogLog, on: server)
        let key = key("hll")
        try await create(.hyperLogLog, key, "a\nb\nc\na", on: server)
        let type = try await type(of: key, on: server)
        XCTAssertEqual(type, .string)
        guard case let .string(data) = try await RedisValues.read(server.connection, key, type: .string) else {
            return XCTFail("not read as a string")
        }
        XCTAssertTrue(RedisFacets.isHyperLogLog(data))
        let count = try await RedisFacets.hyperLogLogCount(server.connection, key)
        XCTAssertEqual(count, 3)
        try await RedisFacets.addToHyperLogLog(server.connection, key, [Data("d".utf8)])
        let after = try await RedisFacets.hyperLogLogCount(server.connection, key)
        XCTAssertEqual(after, 4)
        // An ordinary string is not taken for one, and the server says so verbatim when asked.
        let plain = self.key("plain")
        try await create(.string, plain, "HYLL is how this text happens to start", on: server)
        do {
            _ = try await RedisFacets.hyperLogLogCount(server.connection, plain)
            XCTFail("PFCOUNT counted a plain string")
        } catch let DBError.server(error) {
            XCTAssertTrue(error.message.hasPrefix("WRONGTYPE"), error.message)
        }
    }

    func testABitmapIsReadBitByBit() async throws {
        let server = try await server()
        let key = key("bitmap")
        try await create(.bitmap, key, "7\n8\n10", on: server)
        var bitmap = try await RedisFacets.bitmap(server.connection, key)
        XCTAssertEqual(bitmap.bytes, 2)
        XCTAssertEqual(bitmap.setBits, 3)
        XCTAssertEqual(bitmap.headBits, "0000000110100000")
        XCTAssertEqual(bitmap.headOffsets, [7, 8, 10])
        try await RedisFacets.setBit(server.connection, key, offset: 7, on: false)
        try await RedisFacets.setBit(server.connection, key, offset: 1_000, on: true)
        bitmap = try await RedisFacets.bitmap(server.connection, key)
        XCTAssertEqual(bitmap.setBits, 3)
        XCTAssertEqual(bitmap.bytes, 126)
        // Only the head is read, however long the string.
        XCTAssertEqual(bitmap.head.count, RedisBitmap.headLength)
        XCTAssertEqual(bitmap.headOffsets, [8, 10])
    }

    // MARK: - Geospatial

    func testAGeospatialIndexIsASortedSetWithPlaces() async throws {
        let server = try await server()
        try require(.geospatial, on: server)
        let key = key("geo")
        try await create(.geospatial, key, "116.1 -8.58 mataram\n106.8 -6.2 jakarta", on: server)
        let type = try await type(of: key, on: server)
        XCTAssertEqual(type, .zset)
        guard case let .zset(members, _) = try await RedisValues.read(server.connection, key, type: .zset) else {
            return XCTFail("not read as a sorted set")
        }
        XCTAssertEqual(members.count, 2)
        XCTAssertTrue(RedisFacets.looksGeospatial(members))
        let positions = try await RedisFacets.positions(server.connection, key, of: members)
        XCTAssertEqual(positions.map { String(decoding: $0.member, as: UTF8.self) }.sorted(), ["jakarta", "mataram"])
        let mataram = try XCTUnwrap(positions.first { $0.member == Data("mataram".utf8) })
        // The server's own digits, within the centimetres a 52-bit geohash keeps.
        XCTAssertEqual(try XCTUnwrap(Double(mataram.longitude)), 116.1, accuracy: 0.000_01)
        XCTAssertEqual(try XCTUnwrap(Double(mataram.latitude)), -8.58, accuracy: 0.000_01)
        XCTAssertTrue(mataram.longitude.count > 8, mataram.longitude)

        try await RedisFacets.addPosition(
            server.connection, key, member: Data("mataram".utf8), longitude: "116.2", latitude: "-8.6")
        guard case let .zset(moved, _) = try await RedisValues.read(server.connection, key, type: .zset) else {
            return XCTFail("not read as a sorted set")
        }
        let again = try await RedisFacets.positions(server.connection, key, of: moved)
        let movedPlace = try XCTUnwrap(again.first { $0.member == Data("mataram".utf8) })
        XCTAssertEqual(try XCTUnwrap(Double(movedPlace.longitude)), 116.2, accuracy: 0.000_01)

        // A sorted set of ordinary scores is not offered as places.
        let plain = self.key("zset")
        try await create(.sortedSet, plain, "1.5 a\n3 b", on: server)
        guard case let .zset(scored, _) = try await RedisValues.read(server.connection, plain, type: .zset) else {
            return XCTFail("not read as a sorted set")
        }
        XCTAssertFalse(RedisFacets.looksGeospatial(scored))
    }

    // MARK: - Metadata

    func testTheServerSaysHowItHoldsAKey() async throws {
        let server = try await server()
        let key = key("meta")
        try await create(.hash, key, "a=1\nb=2", ttl: 300, on: server)
        let metadata = try await RedisFacets.metadata(server.connection, key)
        let encoding = try XCTUnwrap(metadata.encoding)
        XCTAssertTrue(["listpack", "ziplist", "hashtable", "listpackex"].contains(encoding), encoding)
        // One of the two is kept, depending on the eviction policy; never both.
        XCTAssertTrue((metadata.idleSeconds != nil) != (metadata.frequency != nil), "\(metadata)")
        let infos = try await RedisKeyspace.describe(server.connection, [key])
        let info = try XCTUnwrap(infos.first)
        XCTAssertEqual(info.length, 2)
        XCTAssertGreaterThan(try XCTUnwrap(info.memoryBytes), 0)
        let ttl = try XCTUnwrap(info.ttlMilliseconds)
        XCTAssertTrue((1 ... 300_000).contains(ttl), "\(ttl)")
        // A key that is not there has nothing to say, and that is not an error.
        let missing = try await RedisFacets.metadata(server.connection, self.key("absent"))
        XCTAssertEqual(missing, RedisKeyMetadata())
    }

    // MARK: - Hash field expiry

    func testASingleHashFieldExpiresAndAnEditKeepsItsTime() async throws {
        let server = try await server()
        guard server.info.hasHashFieldExpiry else {
            throw XCTSkip("\(server.info.product) \(server.info.version) has no hash field expiry (HPEXPIRE)")
        }
        let key = key("hash-ttl")
        try await create(.hash, key, "a=1\nb=2", on: server)
        let a = Data("a".utf8)
        try await RedisFacets.setFieldExpiry(server.connection, key, field: a, milliseconds: 100_000)

        func fields() async throws -> [String: Int64?] {
            guard
                case let .hash(fields, _) = try await RedisValues.read(
                    server.connection, key, type: .hash, server: server.info)
            else {
                XCTFail("not read as a hash")
                return [:]
            }
            return Dictionary(
                uniqueKeysWithValues: fields.map { (String(decoding: $0.field, as: UTF8.self), $0.ttlMilliseconds) })
        }
        var read = try await fields()
        let first = try XCTUnwrap(read["a"] ?? nil)
        XCTAssertTrue((1 ... 100_000).contains(first), "\(first)")
        XCTAssertEqual(read["b"], .some(nil))

        // HSET alone would drop the field's expiry; the edit puts it back.
        try await RedisValues.setHashField(server.connection, key, field: a, value: Data("9".utf8), keepingTTL: first)
        read = try await fields()
        let kept = try XCTUnwrap(read["a"] ?? nil)
        XCTAssertTrue((1 ... first).contains(kept), "\(kept)")
        let value = try await server.connection.send(["HGET", key.argument, "a"]).string
        XCTAssertEqual(value, "9")

        // A rename hands the time over to the new field.
        try await RedisValues.renameHashField(
            server.connection, key, from: a, to: Data("c".utf8), value: Data("9".utf8), keepingTTL: kept)
        read = try await fields()
        XCTAssertFalse(read.keys.contains("a"))
        XCTAssertNotNil(read["c"] ?? nil)

        try await RedisFacets.setFieldExpiry(server.connection, key, field: Data("c".utf8), milliseconds: nil)
        read = try await fields()
        XCTAssertEqual(read["c"], .some(nil))

        do {
            try await RedisFacets.setFieldExpiry(server.connection, key, field: Data("nope".utf8), milliseconds: 1_000)
            XCTFail("a field that does not exist was given an expiry")
        } catch DBError.protocolError {}

        // Without the server's word, the hash reads as before: no expiry asked for.
        guard case let .hash(plain, _) = try await RedisValues.read(server.connection, key, type: .hash) else {
            return XCTFail("not read as a hash")
        }
        XCTAssertTrue(plain.allSatisfy { $0.ttlMilliseconds == nil })
    }

    // MARK: - Time series

    func testATimeSeriesIsReadAPageAtATime() async throws {
        let server = try await server()
        try require(.timeSeries, on: server)
        let key = key("series")
        try await create(
            .timeSeries, key, "1000 1.5\n2000 2.25", settings: [.retention: "0", .labels: "sensor=a unit=c"], ttl: 600,
            on: server)
        let type = try await type(of: key, on: server)
        XCTAssertEqual(type, .timeSeries)

        guard
            case let .timeSeries(info, samples, next) = try await RedisValues.read(
                server.connection, key, type: .timeSeries, server: server.info)
        else { return XCTFail("not read as a time series") }
        XCTAssertEqual(info.totalSamples, 2)
        XCTAssertEqual(info.firstTimestamp, 1_000)
        XCTAssertEqual(info.lastTimestamp, 2_000)
        XCTAssertEqual(info.labels, [RedisField(name: "sensor", value: "a"), RedisField(name: "unit", value: "c")])
        XCTAssertEqual(
            samples, [RedisSample(timestamp: 1_000, value: "1.5"), RedisSample(timestamp: 2_000, value: "2.25")])
        XCTAssertNil(next)
        let ttl = try await server.connection.send(["TTL", key.argument]).integer ?? -1
        XCTAssertTrue((1 ... 600).contains(ttl), "\(ttl)")

        // More samples than a page holds: two pages, no sample twice, none left out.
        let total = RedisValues.pageSize + 120
        var command: [RedisArgument] = ["TS.MADD"]
        for index in 0 ..< total - 2 {
            command += [key.argument, RedisArgument(3_000 + index * 10), RedisArgument(index)]
        }
        try await server.connection.send(command)
        let first = try await RedisValues.read(server.connection, key, type: .timeSeries)
        guard case let .timeSeries(_, firstPage, firstNext) = first else { return XCTFail("no first page") }
        XCTAssertEqual(firstPage.count, RedisValues.pageSize)
        XCTAssertNotNil(firstNext)
        let second = try await RedisValues.read(server.connection, key, type: .timeSeries, continuing: first)
        guard case let .timeSeries(_, secondPage, secondNext) = second else { return XCTFail("no second page") }
        XCTAssertEqual(secondPage.count, total - RedisValues.pageSize)
        XCTAssertNil(secondNext)
        let all = (firstPage + secondPage).map(\.timestamp)
        XCTAssertEqual(Set(all).count, total)
        XCTAssertEqual(all, all.sorted())

        try await RedisModuleValues.addSample(server.connection, key, timestamp: "*", value: "42.5")
        try await RedisModuleValues.deleteSamples(server.connection, key, timestamps: [1_000, 2_000])
        guard
            case let .timeSeries(after, remaining, _) = try await RedisValues.read(
                server.connection, key, type: .timeSeries)
        else { return XCTFail("not read again") }
        XCTAssertEqual(after.totalSamples, Int64(total - 2 + 1))
        XCTAssertEqual(remaining.first?.timestamp, 3_000)

        // The server's refusal comes back in its own words.
        do {
            try await RedisModuleValues.addSample(server.connection, key, timestamp: "1", value: "not a number")
            XCTFail("a sample that is not a number was taken")
        } catch let DBError.server(error) {
            XCTAssertTrue(error.message.contains("TSDB"), error.message)
        }
    }

    // MARK: - Probabilistic types

    func testABloomFilterReportsItselfAndAnswersForOneItem() async throws {
        let server = try await server()
        try require(.bloomFilter, on: server)
        let key = key("bloom")
        try await create(
            .bloomFilter, key, "ada\ngrace", settings: [.errorRate: "0.001", .capacity: "5000"], on: server)
        let type = try await type(of: key, on: server)
        XCTAssertEqual(type, .bloomFilter)
        guard case let .summary(summary) = try await RedisValues.read(server.connection, key, type: .bloomFilter) else {
            return XCTFail("not read as a summary")
        }
        XCTAssertEqual(summary.fields.first { $0.name == "Capacity" }?.value, "5000")
        XCTAssertEqual(summary.fields.first { $0.name == "Number of items inserted" }?.value, "2")
        XCTAssertTrue(summary.rows.isEmpty)
        let yes = try await RedisModuleValues.ask(server.connection, key, type: .bloomFilter, item: "ada")
        XCTAssertTrue(yes.contains("may be in the filter"), yes)
        let no = try await RedisModuleValues.ask(server.connection, key, type: .bloomFilter, item: "nobody")
        XCTAssertTrue(no.contains("is not in the filter"), no)
        try await RedisModuleValues.add(server.connection, key, type: .bloomFilter, items: [Data("nobody".utf8)])
        let now = try await RedisModuleValues.ask(server.connection, key, type: .bloomFilter, item: "nobody")
        XCTAssertTrue(now.contains("may be in the filter"), now)

        // Creating never overwrites, whatever the type.
        do {
            try await create(.bloomFilter, key, "", on: server)
            XCTFail("an existing key was created again")
        } catch let DBError.server(error) {
            XCTAssertTrue(error.message.contains("already exists"), error.message)
        }
    }

    func testACuckooFilterCanForgetAnItem() async throws {
        let server = try await server()
        try require(.cuckooFilter, on: server)
        let key = key("cuckoo")
        try await create(.cuckooFilter, key, "ada", settings: [.capacity: "2000"], on: server)
        let type = try await type(of: key, on: server)
        XCTAssertEqual(type, .cuckooFilter)
        guard case let .summary(summary) = try await RedisValues.read(server.connection, key, type: .cuckooFilter)
        else {
            return XCTFail("not read as a summary")
        }
        XCTAssertEqual(summary.fields.first { $0.name == "Number of items inserted" }?.value, "1")
        let yes = try await RedisModuleValues.ask(server.connection, key, type: .cuckooFilter, item: "ada")
        XCTAssertTrue(yes.contains("may be in the filter"), yes)
        try await RedisModuleValues.removeFromCuckoo(server.connection, key, item: Data("ada".utf8))
        let no = try await RedisModuleValues.ask(server.connection, key, type: .cuckooFilter, item: "ada")
        XCTAssertTrue(no.contains("is not in the filter"), no)
        do {
            try await RedisModuleValues.removeFromCuckoo(server.connection, key, item: Data("ada".utf8))
            XCTFail("an item that is not there was removed")
        } catch DBError.protocolError {}
    }

    func testATopKListsItsHeavyHitters() async throws {
        let server = try await server()
        try require(.topK, on: server)
        let key = key("topk")
        try await create(.topK, key, "a\na\na\nb\nb\nc", settings: [.topK: "2"], on: server)
        let type = try await type(of: key, on: server)
        XCTAssertEqual(type, .topK)
        guard case let .summary(summary) = try await RedisValues.read(server.connection, key, type: .topK) else {
            return XCTFail("not read as a summary")
        }
        XCTAssertEqual(summary.fields.first { $0.name == "k" }?.value, "2")
        XCTAssertEqual(summary.columns, ["Item", "Count"])
        XCTAssertEqual(summary.rows, [["a", "3"], ["b", "2"]])
        let answer = try await RedisModuleValues.ask(server.connection, key, type: .topK, item: "a")
        XCTAssertTrue(answer.hasPrefix("a is among the top items"), answer)
        let other = try await RedisModuleValues.ask(server.connection, key, type: .topK, item: "zzz")
        XCTAssertTrue(other.hasPrefix("zzz is not among the top items"), other)
    }

    func testACountMinSketchCountsAnItem() async throws {
        let server = try await server()
        try require(.countMinSketch, on: server)
        let key = key("cms")
        try await create(.countMinSketch, key, "a\na\nb", settings: [.width: "100", .depth: "4"], on: server)
        let type = try await type(of: key, on: server)
        XCTAssertEqual(type, .countMinSketch)
        guard case let .summary(summary) = try await RedisValues.read(server.connection, key, type: .countMinSketch)
        else { return XCTFail("not read as a summary") }
        XCTAssertEqual(summary.fields.map { "\($0.name)=\($0.value)" }, ["width=100", "depth=4", "count=3"])
        let answer = try await RedisModuleValues.ask(server.connection, key, type: .countMinSketch, item: "a")
        XCTAssertEqual(answer, "a was counted at most 2 times.")
        try await RedisModuleValues.add(server.connection, key, type: .countMinSketch, items: [Data("b".utf8)])
        let more = try await RedisModuleValues.ask(server.connection, key, type: .countMinSketch, item: "b")
        XCTAssertEqual(more, "b was counted at most 2 times.")
    }

    func testATDigestGivesItsQuantiles() async throws {
        let server = try await server()
        try require(.tDigest, on: server)
        let key = key("tdigest")
        try await create(.tDigest, key, "1\n2\n3\n4\n5", settings: [.compression: "200"], on: server)
        let type = try await type(of: key, on: server)
        XCTAssertEqual(type, .tDigest)
        guard case let .summary(summary) = try await RedisValues.read(server.connection, key, type: .tDigest) else {
            return XCTFail("not read as a summary")
        }
        XCTAssertEqual(summary.fields.first { $0.name == "Compression" }?.value, "200")
        XCTAssertEqual(summary.fields.first { $0.name == "Observations" }?.value, "5")
        XCTAssertEqual(summary.columns, ["Quantile", "Value"])
        XCTAssertEqual(summary.rows.first, ["min", "1"])
        XCTAssertEqual(summary.rows.last, ["max", "5"])
        XCTAssertEqual(summary.rows.first { $0[0] == "0.5" }, ["0.5", "3"])
        XCTAssertEqual(summary.rows.count, RedisModuleValues.quantiles.count + 2)
        try await RedisModuleValues.addObservations(server.connection, key, values: ["100"])
        let answer = try await RedisModuleValues.ask(server.connection, key, type: .tDigest, item: "1")
        XCTAssertEqual(answer, "Quantile 1 is 100.")

        // An empty digest answers nan, and is still read.
        let empty = self.key("tdigest-empty")
        try await create(.tDigest, empty, "", on: server)
        guard case let .summary(nothing) = try await RedisValues.read(server.connection, empty, type: .tDigest) else {
            return XCTFail("not read as a summary")
        }
        XCTAssertEqual(nothing.rows.first { $0[0] == "0.5" }, ["0.5", "nan"])
    }

    // MARK: - Vector set

    func testAVectorSetIsPagedInOrderAndAnElementShowsItsNeighbours() async throws {
        let server = try await server()
        try require(.vectorSet, on: server)
        let key = key("vectors")
        try await create(.vectorSet, key, "alpha 1.0 0.5 0.25\nbeta 0.1 0.2 0.3\ngamma 0.9 0.2 0.3", on: server)
        let type = try await type(of: key, on: server)
        XCTAssertEqual(type, .vectorSet)
        let infos = try await RedisKeyspace.describe(server.connection, [key])
        let described = try XCTUnwrap(infos.first)
        XCTAssertEqual(described.type, .vectorSet)
        XCTAssertEqual(described.length, 3)

        guard
            case let .vectorSet(info, elements, next, isSample) = try await RedisValues.read(
                server.connection, key, type: .vectorSet, server: server.info)
        else { return XCTFail("not read as a vector set") }
        XCTAssertEqual(info.first { $0.name == "vector-dim" }?.value, "3")
        XCTAssertEqual(info.first { $0.name == "size" }?.value, "3")
        XCTAssertNil(next)
        let names = elements.map { String(decoding: $0, as: UTF8.self) }
        if server.info.supports("vrange") {
            XCTAssertFalse(isSample)
            XCTAssertEqual(names, ["alpha", "beta", "gamma"])
        } else {
            XCTAssertTrue(isSample)
            XCTAssertEqual(names.sorted(), ["alpha", "beta", "gamma"])
        }

        // A server without VRANGE still shows elements, as a sample.
        guard
            case let .vectorSet(_, sampled, sampleNext, sampleFlag) = try await RedisModuleValues.vectorSet(
                server.connection, key, after: nil, ranged: false)
        else { return XCTFail("no sample") }
        XCTAssertTrue(sampleFlag)
        XCTAssertNil(sampleNext)
        XCTAssertEqual(sampled.map { String(decoding: $0, as: UTF8.self) }.sorted(), ["alpha", "beta", "gamma"])

        try await server.connection.send(["VSETATTR", key.argument, "beta", #"{"year":2020}"#])
        let beta = try await RedisModuleValues.vectorElement(server.connection, key, element: Data("beta".utf8))
        XCTAssertEqual(beta.vector.count, 3)
        XCTAssertTrue(beta.vector.allSatisfy { Double($0) != nil }, "\(beta.vector)")
        XCTAssertEqual(beta.attributes, #"{"year":2020}"#)
        let alpha = try await RedisModuleValues.vectorElement(server.connection, key, element: Data("alpha".utf8))
        XCTAssertNil(alpha.attributes)

        let matches = try await RedisModuleValues.similar(server.connection, key, to: Data("alpha".utf8), count: 3)
        XCTAssertEqual(matches.first?.element, Data("alpha".utf8))
        XCTAssertEqual(matches.map { String(decoding: $0.element, as: UTF8.self) }, ["alpha", "gamma", "beta"])
        XCTAssertTrue(matches.allSatisfy { Double($0.score) != nil })

        try await RedisModuleValues.removeVectorElements(server.connection, key, [Data("beta".utf8)])
        let count = try await server.connection.send(["VCARD", key.argument]).integer
        XCTAssertEqual(count, 2)
    }

    func testAVectorSetLargerThanAPageContinuesWhereItStopped() async throws {
        let server = try await server()
        try require(.vectorSet, on: server)
        guard server.info.supports("vrange") else {
            throw XCTSkip("\(server.info.product) \(server.info.version) has no VRANGE; vector sets are sampled")
        }
        let key = key("vectors-many")
        let total = RedisValues.pageSize + 30
        var commands: [[RedisArgument]] = []
        for index in 0 ..< total {
            commands.append([
                "VADD", key.argument, "VALUES", 2, RedisArgument(index), 1,
                RedisArgument(String(format: "e%04d", index)),
            ])
        }
        try RedisModuleValues.throwFirstError(try await server.connection.pipeline(commands))
        let first = try await RedisValues.read(server.connection, key, type: .vectorSet, server: server.info)
        guard case let .vectorSet(_, firstPage, firstNext, _) = first else { return XCTFail("no first page") }
        XCTAssertEqual(firstPage.count, RedisValues.pageSize)
        XCTAssertEqual(firstNext, firstPage.last)
        let second = try await RedisValues.read(
            server.connection, key, type: .vectorSet, continuing: first, server: server.info)
        guard case let .vectorSet(_, secondPage, secondNext, _) = second else { return XCTFail("no second page") }
        XCTAssertEqual(secondPage.count, total - RedisValues.pageSize)
        XCTAssertNil(secondNext)
        XCTAssertEqual(Set(firstPage + secondPage).count, total)
    }

    // MARK: - The rest

    func testTheKeyListNamesEveryTypeTheServerHas() async throws {
        let server = try await server()
        var made: [RedisKey: RedisKeyType] = [:]
        let samples: [(RedisNewKeyKind, String)] = [
            (.string, "v"), (.hash, "a=1"), (.list, "a"), (.set, "a"), (.sortedSet, "1 a"), (.stream, "a=1"),
            (.json, #"{"a":1}"#), (.timeSeries, "1 1"), (.bloomFilter, "a"), (.cuckooFilter, "a"), (.topK, "a"),
            (.countMinSketch, "a"), (.tDigest, "1"), (.vectorSet, "a 1 2"),
        ]
        var missing: [String] = []
        for (kind, text) in samples {
            guard RedisNewKeyKind.available(on: server.info).contains(kind) else {
                missing.append(kind.displayName)
                continue
            }
            let key = key("list:\(kind.rawValue)")
            try await create(kind, key, text, on: server)
            made[key] = kind.keyType
        }
        let infos = try await RedisKeyspace.describe(server.connection, made.keys.sorted())
        XCTAssertEqual(infos.count, made.count)
        for info in infos { XCTAssertEqual(info.type, made[info.key], info.key.display) }

        // SCAN … TYPE finds a module type by the name TYPE gave it.
        for type in server.info.keyTypes where type.probeCommand != nil {
            let page = try await RedisKeyspace.scan(
                server.connection, match: "tinker:test:types:list:*", type: type, limit: 100)
            XCTAssertEqual(page.keys.count, 1, type.displayName)
        }
        if !missing.isEmpty { throw XCTSkip("not proved on this server: \(missing.joined(separator: ", "))") }
    }

    func testATypeOfAnUnknownModuleIsShownWithWhatTheServerSays() async throws {
        let server = try await server()
        let key = key("unknown")
        try await create(.list, key, "a", on: server)
        // A list read as a type Tinker does not know stands in for a foreign module's key.
        guard
            case let .unsupported(name, info) = try await RedisValues.read(
                server.connection, key, type: .other("SomeModule"))
        else { return XCTFail("not shown as unsupported") }
        XCTAssertEqual(name, "SomeModule")
        XCTAssertTrue(info.contains { $0.hasPrefix("encoding: ") }, "\(info)")
        XCTAssertTrue(info.contains { $0.hasPrefix("memory: ") }, "\(info)")
    }
}
