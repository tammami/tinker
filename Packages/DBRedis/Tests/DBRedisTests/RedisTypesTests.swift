import DBCore
import Foundation
import XCTest

@testable import DBRedis

/// The data types Redis documents, read from replies written out here: no server.
final class RedisTypesTests: XCTestCase {
    private func bulk(_ text: String) -> RESPValue { .bulkString(Data(text.utf8)) }

    // MARK: - Names

    func testEveryDocumentedTypeIsKnownByTheNameTypeAnswers() {
        let names: [(String, RedisKeyType, String)] = [
            ("string", .string, "String"), ("hash", .hash, "Hash"), ("list", .list, "List"), ("set", .set, "Set"),
            ("zset", .zset, "Sorted set"), ("stream", .stream, "Stream"), ("ReJSON-RL", .json, "JSON"),
            ("TSDB-TYPE", .timeSeries, "Time series"), ("MBbloom--", .bloomFilter, "Bloom filter"),
            ("MBbloomCF", .cuckooFilter, "Cuckoo filter"), ("TopK-TYPE", .topK, "Top-K"),
            ("CMSk-TYPE", .countMinSketch, "Count-min sketch"), ("TDIS-TYPE", .tDigest, "t-digest"),
            ("vectorset", .vectorSet, "Vector set"),
        ]
        for (name, type, documented) in names {
            XCTAssertEqual(RedisKeyType(typeName: name), type, name)
            // What SCAN … TYPE is given must be what TYPE answered, letter for letter.
            XCTAssertEqual(type.scanName, name)
            XCTAssertEqual(type.displayName, documented)
        }
        XCTAssertEqual(Set(RedisKeyType.documented).count, names.count)
        XCTAssertEqual(RedisKeyType(typeName: "GraphData"), .other("GraphData"))
        XCTAssertEqual(RedisKeyType.other("GraphData").displayName, "GraphData")
    }

    // MARK: - What the server can do

    func testCommandInfoSaysWhichTypesTheServerHas() {
        let reply = RESPValue.array([
            .array([bulk("ts.info"), .integer(-2)]), .null, .array([bulk("HPTTL"), .integer(-5)]),
            .array([bulk("hpexpire")]), .array([bulk("hpersist")]), .array([bulk("pfcount")]),
        ])
        let commands = RedisServerInfo.commands(from: reply)
        XCTAssertEqual(commands, ["ts.info", "hpttl", "hpexpire", "hpersist", "pfcount"])
        let server = RedisServerInfo(
            version: "8.0.0", product: "Redis", mode: "standalone", databaseCount: 16, modules: [], role: "master",
            commands: commands)
        XCTAssertTrue(server.supports(.timeSeries))
        XCTAssertTrue(server.supports("TS.INFO"))
        XCTAssertFalse(server.supports(.bloomFilter))
        XCTAssertFalse(server.supports(.vectorSet))
        XCTAssertFalse(server.hasJSON)
        XCTAssertTrue(server.hasHashFieldExpiry)
        XCTAssertEqual(server.keyTypes, [.string, .hash, .list, .set, .zset, .stream, .timeSeries])
    }

    func testAServerThatRefusesCommandIsTakenAtItsVersionsWord() {
        let old = RedisServerInfo.assumedCommands(version: "6.0.9", modules: [])
        XCTAssertTrue(old.contains("pfcount"))
        XCTAssertTrue(old.contains("memory"))
        XCTAssertFalse(old.contains("copy"))
        XCTAssertFalse(old.contains("hpttl"))
        XCTAssertFalse(old.contains("ts.info"))
        let new = RedisServerInfo.assumedCommands(version: "7.4.1", modules: ["timeseries", "bf", "ReJSON"])
        XCTAssertTrue(new.isSuperset(of: ["hpttl", "hpexpire", "hpersist", "copy", "ts.range", "bf.info", "cf.info"]))
        XCTAssertTrue(new.isSuperset(of: ["topk.list", "cms.info", "tdigest.quantile", "json.get"]))
        XCTAssertFalse(new.contains("vcard"))
        XCTAssertTrue(RedisServerInfo.assumedCommands(version: "8.0.0", modules: ["vectorset"]).contains("vrange"))
    }

    func testNewKeyOffersOnlyWhatTheServerCanCreate() {
        var server = RedisServerInfo(
            version: "7.0.0", product: "Redis", mode: "standalone", databaseCount: 16, modules: [], role: "master",
            commands: ["pfadd", "geoadd"])
        XCTAssertEqual(
            RedisNewKeyKind.available(on: server),
            [.string, .hash, .list, .set, .sortedSet, .stream, .hyperLogLog, .bitmap, .geospatial])
        server.commands.formUnion(["ts.create", "ts.add", "bf.reserve", "bf.add", "json.set"])
        let kinds = RedisNewKeyKind.available(on: server)
        XCTAssertTrue(kinds.contains(.timeSeries))
        XCTAssertTrue(kinds.contains(.bloomFilter))
        XCTAssertTrue(kinds.contains(.json))
        XCTAssertFalse(kinds.contains(.cuckooFilter))
        XCTAssertFalse(kinds.contains(.vectorSet))
        // Without a server's answer, only what every server has.
        XCTAssertEqual(RedisNewKeyKind.available(on: nil), [.string, .hash, .list, .set, .sortedSet, .stream, .bitmap])
    }

    // MARK: - Time series

    func testTimeSeriesInfoAndSamplesAreReadAsTheServerWritesThem() {
        let reply = RESPValue.array([
            .simpleString("totalSamples"), .integer(2), .simpleString("memoryUsage"), .integer(5_520),
            .simpleString("firstTimestamp"), .integer(1_000), .simpleString("lastTimestamp"), .integer(2_000),
            .simpleString("retentionTime"), .integer(60_000), .simpleString("chunkType"), .simpleString("compressed"),
            .simpleString("labels"),
            .array([.array([bulk("sensor"), bulk("a")]), .array([bulk("unit"), bulk("c")])]),
            .simpleString("sourceKey"), .null, .simpleString("rules"), .array([]),
        ])
        let info = RedisModuleValues.timeSeriesInfo(reply)
        XCTAssertEqual(info.totalSamples, 2)
        XCTAssertEqual(info.firstTimestamp, 1_000)
        XCTAssertEqual(info.lastTimestamp, 2_000)
        XCTAssertEqual(info.retentionMilliseconds, 60_000)
        XCTAssertEqual(info.labels, [RedisField(name: "sensor", value: "a"), RedisField(name: "unit", value: "c")])
        XCTAssertEqual(info.fields.first { $0.name == "chunkType" }?.value, "compressed")
        XCTAssertEqual(info.fields.first { $0.name == "labels" }?.value, "sensor=a unit=c")
        XCTAssertEqual(info.fields.first { $0.name == "sourceKey" }?.value, "")

        let samples = RedisModuleValues.samples(
            .array([
                .array([.integer(1_000), .simpleString("1.5")]),
                .array([.integer(2_000), bulk("2.2500000000000001")]),
                .array([bulk("broken")]),
            ]))
        // The value keeps every digit the server sent: it is never a Double here.
        XCTAssertEqual(
            samples,
            [RedisSample(timestamp: 1_000, value: "1.5"), RedisSample(timestamp: 2_000, value: "2.2500000000000001")])
    }

    // MARK: - Probabilistic types

    func testInfoRepliesOfTheProbabilisticTypesBecomeFields() {
        let bloom = RESPValue.array([
            bulk("Capacity"), .integer(1_000), bulk("Size"), .integer(1_480), bulk("Number of filters"), .integer(1),
            bulk("Number of items inserted"), .integer(1), bulk("Expansion rate"), .integer(2),
        ])
        XCTAssertEqual(
            RedisModuleValues.fields(bloom).map { "\($0.name)=\($0.value)" },
            [
                "Capacity=1000", "Size=1480", "Number of filters=1", "Number of items inserted=1", "Expansion rate=2",
            ])
        let topK = RESPValue.array([
            bulk("k"), .integer(3), bulk("width"), .integer(8), bulk("depth"), .integer(7), bulk("decay"), bulk("0.9"),
        ])
        XCTAssertEqual(RedisModuleValues.fields(topK).last, RedisField(name: "decay", value: "0.9"))
        // A RESP3 map reads the same as the flat list.
        XCTAssertEqual(
            RedisModuleValues.fields(.map([bulk("width"), .integer(100)])), [RedisField(name: "width", value: "100")])
        XCTAssertEqual(RedisModuleValues.fields(.null), [])
    }

    func testTopKListAndTDigestQuantilesBecomeRows() {
        let list = RESPValue.array([
            bulk("a"), .integer(2), bulk("b"), .integer(1), .bulkString(Data([0xFF])), .integer(1),
        ])
        XCTAssertEqual(RedisModuleValues.counted(list), [["a", "2"], ["b", "1"], ["\\xff", "1"]])
        let quantiles = RESPValue.array(RedisModuleValues.quantiles.map { _ in bulk("3") })
        let rows = RedisModuleValues.quantileRows(quantiles)
        XCTAssertEqual(rows.count, RedisModuleValues.quantiles.count)
        XCTAssertEqual(rows.first, ["0.01", "3"])
        // An empty digest answers nan; it is shown, not hidden.
        XCTAssertEqual(RedisModuleValues.quantileRows(.array([bulk("nan")])), [["0.01", "nan"]])
    }

    func testAnErrorAmongPipelinedRepliesIsThrownVerbatim() {
        let replies: [RESPValue] = [.integer(1), .error("ERR TSDB: the key does not exist")]
        XCTAssertThrowsError(try RedisModuleValues.throwFirstError(replies)) { error in
            guard case let DBError.server(server) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(server.message, "ERR TSDB: the key does not exist")
        }
        XCTAssertNoThrow(try RedisModuleValues.throwFirstError([.integer(1), .null]))
    }

    // MARK: - Types inside other types

    func testAHyperLogLogIsKnownByItsHeader() {
        XCTAssertTrue(RedisFacets.isHyperLogLog(Data("HYLL".utf8) + Data(repeating: 0, count: 12)))
        XCTAssertFalse(RedisFacets.isHyperLogLog(Data("HYLL".utf8)))
        XCTAssertFalse(RedisFacets.isHyperLogLog(Data("HELLO, this is just text".utf8)))
        XCTAssertFalse(RedisFacets.isHyperLogLog(Data()))
    }

    func testGeohashScoresOfferTheGeospatialView() {
        let places = [
            RedisScoredMember(member: Data("jakarta".utf8), score: "3195107319950605"),
            RedisScoredMember(member: Data("mataram".utf8), score: "3220298226941456"),
        ]
        XCTAssertTrue(RedisFacets.looksGeospatial(places))
        XCTAssertFalse(RedisFacets.looksGeospatial([]))
        XCTAssertFalse(RedisFacets.looksGeospatial([RedisScoredMember(member: Data("a".utf8), score: "1.5")]))
        XCTAssertFalse(RedisFacets.looksGeospatial([RedisScoredMember(member: Data("a".utf8), score: "-3")]))
        XCTAssertFalse(RedisFacets.looksGeospatial([RedisScoredMember(member: Data("a".utf8), score: "inf")]))
        // 2^52 and above cannot be a geohash.
        XCTAssertFalse(
            RedisFacets.looksGeospatial([RedisScoredMember(member: Data("a".utf8), score: "4503599627370496")]))
        XCTAssertFalse(RedisFacets.looksGeospatial(places + [RedisScoredMember(member: Data("b".utf8), score: "0.5")]))
    }

    func testPositionsKeepTheServersDigitsAndSkipMembersWithoutOne() {
        let members = [
            RedisScoredMember(member: Data("mataram".utf8), score: "3220298226941456"),
            RedisScoredMember(member: Data("missing".utf8), score: "1"),
            RedisScoredMember(member: Data("jakarta".utf8), score: "3195107319950605"),
        ]
        let reply = RESPValue.array([
            .array([bulk("116.09999924898148"), bulk("-8.579999440347859")]), .null,
            .array([bulk("106.79999738931656"), bulk("-6.2000001952961155")]),
        ])
        let positions = RedisFacets.positions(members, reply)
        XCTAssertEqual(positions.map { String(decoding: $0.member, as: UTF8.self) }, ["mataram", "jakarta"])
        XCTAssertEqual(positions[0].longitude, "116.09999924898148")
        XCTAssertEqual(positions[1].latitude, "-6.2000001952961155")
        XCTAssertEqual(positions[1].score, "3195107319950605")
    }

    func testABitmapShowsItsBitsFromTheFirst() {
        let bitmap = RedisBitmap(bytes: 2, setBits: 3, head: Data([0b0000_0001, 0b1010_0000]))
        XCTAssertEqual(bitmap.headBits, "0000000110100000")
        // SETBIT counts from the most significant bit of the first byte.
        XCTAssertEqual(bitmap.headOffsets, [7, 8, 10])
        XCTAssertEqual(RedisBitmap(bytes: 0, setBits: 0, head: Data()).headBits, "")
    }

    func testMetadataKeepsWhatTheServerAnsweredAndLeavesOutWhatItRefused() {
        let lru = RedisFacets.metadata([
            bulk("listpack"), .integer(12), .error("ERR An LFU maxmemory policy is not selected"),
        ])
        XCTAssertEqual(lru, RedisKeyMetadata(encoding: "listpack", idleSeconds: 12, frequency: nil))
        let lfu = RedisFacets.metadata([
            bulk("skiplist"), .error("ERR An LFU maxmemory policy is selected"), .integer(5),
        ])
        XCTAssertEqual(lfu, RedisKeyMetadata(encoding: "skiplist", idleSeconds: nil, frequency: 5))
        XCTAssertEqual(
            RedisFacets.metadata([.error("NOPERM"), .error("NOPERM"), .error("NOPERM")]), RedisKeyMetadata())
        XCTAssertEqual(RedisFacets.metadata([]), RedisKeyMetadata())
    }

    func testHashFieldExpiryReadsNoExpiryAndNoFieldAsNone() {
        let reply = RESPValue.array([.integer(99_994), .integer(-1), .integer(-2)])
        XCTAssertEqual(RedisFacets.fieldExpiry(reply, count: 3), [99_994, nil, nil])
        // A reply shorter than the fields asked for leaves the rest without one.
        XCTAssertEqual(RedisFacets.fieldExpiry(.array([.integer(5)]), count: 2), [5, nil])
        XCTAssertEqual(RedisFacets.fieldExpiry(.null, count: 1), [nil])
    }

    // MARK: - The new-key form

    func testTheFormsLinesAreReadPerKind() throws {
        XCTAssertEqual(
            try RedisNewKeyKind.geospatial.initialValue(from: "116.1 -8.58 mataram\n\n 106.8 -6.2 kota tua "),
            .positions([
                RedisGeoMember(member: Data("mataram".utf8), longitude: "116.1", latitude: "-8.58", score: ""),
                RedisGeoMember(member: Data("kota tua".utf8), longitude: "106.8", latitude: "-6.2", score: ""),
            ]))
        XCTAssertEqual(
            try RedisNewKeyKind.timeSeries.initialValue(from: "1000 1.5\n* 2"),
            .samples([RedisNewSample(timestamp: "1000", value: "1.5"), RedisNewSample(timestamp: "*", value: "2")]))
        XCTAssertEqual(try RedisNewKeyKind.timeSeries.initialValue(from: ""), .samples([]))
        XCTAssertEqual(
            try RedisNewKeyKind.vectorSet.initialValue(from: "alpha 1.0 0.5\nbeta 0.1 0.2"),
            .vectors([
                RedisNewVector(element: Data("alpha".utf8), values: ["1.0", "0.5"]),
                RedisNewVector(element: Data("beta".utf8), values: ["0.1", "0.2"]),
            ]))
        XCTAssertEqual(
            try RedisNewKeyKind.bitmap.initialValue(from: "7\n8"), .items([Data("7".utf8), Data("8".utf8)]))
        XCTAssertEqual(
            try RedisNewKeyKind.hyperLogLog.initialValue(from: "a b\nc"), .items([Data("a b".utf8), Data("c".utf8)]))
        XCTAssertEqual(
            RedisNewKeyText.labels("sensor=a unit=c junk =x"),
            [
                RedisField(name: "sensor", value: "a"), RedisField(name: "unit", value: "c"),
            ])
    }

    func testAWrongLineIsNamedInsteadOfSent() {
        func problem(_ kind: RedisNewKeyKind, _ text: String) -> String? {
            do {
                _ = try kind.initialValue(from: text)
                return nil
            } catch {
                return (error as? RedisNewKeyProblem)?.description
            }
        }
        XCTAssertEqual(
            problem(.geospatial, "200 0 far"),
            "“200 0 far”: longitude is -180 to 180 and latitude -85.05112878 to 85.05112878.")
        XCTAssertEqual(problem(.geospatial, "116.1 mataram"), "“116.1 mataram” is not “longitude latitude member”.")
        XCTAssertEqual(problem(.vectorSet, "alpha 1 2\nbeta 1"), "“beta” has 1 numbers; the first element has 2.")
        XCTAssertEqual(problem(.vectorSet, "alpha"), "“alpha” is not an element followed by its numbers.")
        XCTAssertEqual(
            problem(.timeSeries, "yesterday 3"),
            "“yesterday 3” is not “timestamp value”; the timestamp is milliseconds or *.")
        XCTAssertEqual(problem(.tDigest, "1\ntwo"), "“two” is not a number.")
        XCTAssertEqual(problem(.bitmap, "-1"), "“-1” is not a bit offset (0 to 4294967295).")
        XCTAssertEqual(problem(.bitmap, "4294967296"), "“4294967296” is not a bit offset (0 to 4294967295).")
        XCTAssertNil(problem(.bitmap, "4294967295"))
        XCTAssertEqual(problem(.sortedSet, "abc member"), "Each line is a number, a space, then the member.")
    }

    func testEachKindIsCreatedWithItsOwnCommands() throws {
        let key = RedisKey("k")
        func commands(
            _ kind: RedisNewKeyKind, _ text: String, _ settings: [RedisNewKeySetting.Name: String] = [:]
        ) throws -> [String] {
            try RedisValues.creation(key, kind: kind, initial: kind.initialValue(from: text), settings: settings)
                .map { $0.map { String(decoding: $0.bytes, as: UTF8.self) }.joined(separator: " ") }
        }
        XCTAssertEqual(try commands(.string, "v"), ["SET k v NX"])
        XCTAssertEqual(try commands(.hyperLogLog, "a\nb"), ["PFADD k a b"])
        XCTAssertEqual(try commands(.hyperLogLog, ""), ["PFADD k"])
        XCTAssertEqual(try commands(.bitmap, "7\n9"), ["SETBIT k 7 1", "SETBIT k 9 1"])
        XCTAssertEqual(try commands(.geospatial, "116.1 -8.58 mataram"), ["GEOADD k 116.1 -8.58 mataram"])
        XCTAssertEqual(
            try commands(.vectorSet, "alpha 1.0 0.5 0.25"), ["VADD k VALUES 3 1.0 0.5 0.25 alpha"])
        XCTAssertEqual(
            try commands(.timeSeries, "1000 1.5", [.retention: " 60000 ", .labels: "sensor=a unit=c"]),
            ["TS.CREATE k RETENTION 60000 LABELS sensor a unit c", "TS.ADD k 1000 1.5"])
        XCTAssertEqual(try commands(.timeSeries, ""), ["TS.CREATE k"])
        XCTAssertEqual(
            try commands(.bloomFilter, "a\nb", [.errorRate: "0.001", .capacity: "5000"]),
            ["BF.RESERVE k 0.001 5000", "BF.MADD k a b"])
        XCTAssertEqual(try commands(.bloomFilter, ""), ["BF.RESERVE k 0.01 100"])
        XCTAssertEqual(try commands(.cuckooFilter, "a"), ["CF.RESERVE k 1024", "CF.ADD k a"])
        XCTAssertEqual(try commands(.topK, "a\na", [.topK: "3"]), ["TOPK.RESERVE k 3", "TOPK.ADD k a a"])
        XCTAssertEqual(
            try commands(.countMinSketch, "a", [.width: "100", .depth: "4"]),
            ["CMS.INITBYDIM k 100 4", "CMS.INCRBY k a 1"])
        XCTAssertEqual(
            try commands(.tDigest, "1\n2.5", [.compression: "200"]),
            ["TDIGEST.CREATE k COMPRESSION 200", "TDIGEST.ADD k 1 2.5"])
        // Redis keeps no empty list, set, hash, sorted set or stream.
        for kind in [RedisNewKeyKind.list, .set, .hash, .sortedSet, .stream, .geospatial, .vectorSet, .bitmap] {
            XCTAssertThrowsError(try commands(kind, ""), "\(kind)")
        }
        // A value of another kind's shape is refused rather than guessed at.
        XCTAssertThrowsError(try RedisValues.creation(key, kind: .timeSeries, initial: .text("x"), settings: [:]))
    }

    func testEveryKindHasAPromptAndMapsToTheTypeItBecomes() {
        for kind in RedisNewKeyKind.allCases {
            XCTAssertFalse(kind.prompt.isEmpty, "\(kind)")
            XCTAssertFalse(kind.displayName.isEmpty, "\(kind)")
        }
        XCTAssertEqual(RedisNewKeyKind.hyperLogLog.keyType, .string)
        XCTAssertEqual(RedisNewKeyKind.bitmap.keyType, .string)
        XCTAssertEqual(RedisNewKeyKind.geospatial.keyType, .zset)
        for type in RedisKeyType.documented { XCTAssertEqual(RedisNewKeyKind(type)?.keyType, type) }
        XCTAssertNil(RedisNewKeyKind(.other("GraphData")))
    }
}
