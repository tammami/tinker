import DBCore
import DBTestKit
import Foundation
import Logging
import XCTest

@testable import DBRedis

/// The Redis client against the developer's local server (`TINKER_TEST_REDIS_URL`, made
/// by `testenv/prepare.sh`): the ACL user `tinker_test`, logical databases 15 (main) and
/// 14 (a transfer's other side). Every key the tests write starts with `tinker:test:`,
/// and each test deletes its own.
final class RedisIntegrationTests: XCTestCase {
    struct TestRedis {
        let config: ConnectionConfig
        let password: String?
        let secrets: EphemeralSecretStore
        var main: Int { 15 }
        var other: Int { 14 }
    }

    /// The server from the environment, or a skip when there is none. A URL that points
    /// at another database, or at the default user, fails instead: tests never run there.
    static func server() async throws -> TestRedis {
        guard let raw = ProcessInfo.processInfo.environment["TINKER_TEST_REDIS_URL"], !raw.isEmpty else {
            throw XCTSkip("TINKER_TEST_REDIS_URL not set — skipping Redis integration tests")
        }
        guard let url = URL(string: raw), ["redis", "rediss"].contains(url.scheme ?? "") else {
            throw XCTSkip("TINKER_TEST_REDIS_URL is not a redis:// URL")
        }
        let user = url.user ?? ""
        guard !user.isEmpty, user != "default" else {
            XCTFail("TINKER_TEST_REDIS_URL must name the tinker_test ACL user, not the default user")
            throw XCTSkip("refused")
        }
        guard url.path == "/15" else {
            XCTFail("TINKER_TEST_REDIS_URL must use logical database 15 (tests also use 14), got \(url.path)")
            throw XCTSkip("refused")
        }
        var config = ConnectionConfig.redis(name: "redis-test", host: url.host ?? "127.0.0.1", port: url.port ?? 6379)
        config.user = user
        config.database = "15"
        if url.scheme == "rediss" { config.tls = TLSConfig(mode: .require) }
        let secrets = EphemeralSecretStore()
        if let password = url.password {
            let reference = SecretRef.forConnection(config.id, field: "password")
            try await secrets.setSecret(password, for: reference)
            config.passwordRef = reference
        }
        return TestRedis(config: config, password: url.password, secrets: secrets)
    }

    private var sessions: [RedisSession] = []

    private func session(_ server: TestRedis) -> RedisSession {
        let session = RedisSession(config: server.config, secrets: server.secrets)
        sessions.append(session)
        return session
    }

    override func tearDown() async throws {
        for session in sessions {
            for database in [15, 14] {
                if let connection = try? await session.connection(database: database) {
                    let keys = (try? await RedisKeyspace.scan(connection, match: "tinker:test:*", type: nil, limit: 100_000))?.keys ?? []
                    _ = try? await RedisKeyspace.delete(connection, keys)
                }
            }
            await session.disconnect()
        }
        sessions = []
    }

    // MARK: - Connecting

    func testConnectsAuthenticatesAndDescribesTheServer() async throws {
        let server = try await Self.server()
        let redis = session(server)
        let info = try await redis.connect()
        TestLog.note("redis server: \(info.product) \(info.version) \(info.mode), modules \(info.modules.sorted())")
        XCTAssertFalse(info.version.isEmpty)
        XCTAssertGreaterThanOrEqual(info.databaseCount, 16)
        let connection = try await redis.connection(database: 15)
        let selected = await connection.database
        XCTAssertEqual(selected, 15)
        let databases = try await RedisKeyspace.databases(connection, count: info.databaseCount)
        XCTAssertEqual(databases.count, info.databaseCount)
        XCTAssertEqual(databases[15].index, 15)
    }

    func testAWrongPasswordIsReportedAsSuch() async throws {
        var server = try await Self.server()
        var config = server.config
        let reference = SecretRef.forConnection(config.id, field: "password")
        try await server.secrets.setSecret("not-the-password", for: reference)
        config.passwordRef = reference
        server = TestRedis(config: config, password: "x", secrets: server.secrets)
        do {
            _ = try await session(server).connect()
            XCTFail("connected with a wrong password")
        } catch DBError.authenticationFailed(let user) {
            XCTAssertEqual(user, "tinker_test")
        }
    }

    func testServerErrorsComeBackVerbatimAndTheConnectionStaysUsable() async throws {
        let redis = session(try await Self.server())
        let connection = try await redis.connection(database: 15)
        try await connection.send(["SET", "tinker:test:str", "x"])
        do {
            try await connection.send(["LPUSH", "tinker:test:str", "y"])
            XCTFail("WRONGTYPE expected")
        } catch let DBError.server(error) {
            XCTAssertTrue(error.message.hasPrefix("WRONGTYPE"), error.message)
        }
        let denied = try await connection.sendRaw(["FLUSHDB"])
        guard case let .error(message) = denied else { return XCTFail("FLUSHDB ran for the test user") }
        XCTAssertTrue(message.hasPrefix("NOPERM"), message)
        let pong = try await connection.send(["PING"])
        XCTAssertEqual(pong, .simpleString("PONG"))
    }

    func testAPipelineOfAThousandIsOneExchange() async throws {
        let connection = try await session(try await Self.server()).connection(database: 15)
        let writes: [[RedisArgument]] = (0 ..< 1_000).map { ["SET", RedisArgument("tinker:test:p:\($0)"), RedisArgument($0)] }
        let replies = try await connection.pipeline(writes)
        XCTAssertEqual(replies.count, 1_000)
        XCTAssertTrue(replies.allSatisfy { $0 == .simpleString("OK") })
        let reads = try await connection.pipeline((0 ..< 1_000).map { ["GET", RedisArgument("tinker:test:p:\($0)")] })
        XCTAssertEqual(reads.map(\.string), (0 ..< 1_000).map { String($0) })
    }

    /// Callers asking for the same database at once share one connection; a disconnect
    /// in the middle leaves nothing behind; a dead connection is replaced on next use.
    func testConnectionsAreSharedAndReplaced() async throws {
        let redis = session(try await Self.server())
        async let a = redis.connection(database: 15)
        async let b = redis.connection(database: 15)
        let (first, second) = try await (a, b)
        XCTAssertTrue(first === second, "one connect, not two")
        await first.close()
        let pong = try await redis.withConnection(database: 15) { try await $0.send(["PING"]) }
        XCTAssertEqual(pong, .simpleString("PONG"), "a closed connection is reopened when nothing was sent")
        let fresh = try await redis.connection(database: 15)
        XCTAssertFalse(fresh === first)
        await redis.disconnect()
        let isOpen = await fresh.isOpen
        XCTAssertFalse(isOpen, "disconnect closes what the session held")
    }

    // MARK: - Keyspace

    func testScanFindsKeysByPatternAndTypeAndDescribesThem() async throws {
        let connection = try await session(try await Self.server()).connection(database: 15)
        _ = try await connection.pipeline([
            ["SET", "tinker:test:user:1", "Ada"], ["PEXPIRE", "tinker:test:user:1", 600_000],
            ["HSET", "tinker:test:user:2", "name", "Grace", "lang", "COBOL"],
            ["RPUSH", "tinker:test:queue", "a", "b", "c"],
            ["SADD", "tinker:test:tags", "x", "y"],
            ["ZADD", "tinker:test:board", "1.5", "ada", "3", "grace"],
            ["XADD", "tinker:test:events", "*", "kind", "login"],
            ["SET", RedisArgument(Data("tinker:test:bin:\u{0}".utf8) + Data([0xFF])), "binary key"],
        ])
        let all = try await RedisKeyspace.scan(connection, match: "tinker:test:*", type: nil, limit: 1_000)
        XCTAssertTrue(all.isComplete)
        XCTAssertEqual(all.keys.count, 7)
        let users = try await RedisKeyspace.scan(connection, match: "tinker:test:user:*", type: nil, limit: 1_000)
        XCTAssertEqual(Set(users.keys.map(\.display)), ["tinker:test:user:1", "tinker:test:user:2"])
        let hashes = try await RedisKeyspace.scan(connection, match: "tinker:test:*", type: .hash, limit: 1_000)
        XCTAssertEqual(hashes.keys.map(\.display), ["tinker:test:user:2"])

        let infos = try await RedisKeyspace.describe(connection, all.keys.sorted())
        let byName = Dictionary(uniqueKeysWithValues: infos.map { ($0.key.display, $0) })
        XCTAssertEqual(byName["tinker:test:user:1"]?.type, .string)
        XCTAssertEqual(byName["tinker:test:user:1"]?.length, 3)
        XCTAssertGreaterThan(byName["tinker:test:user:1"]?.ttlMilliseconds ?? 0, 500_000)
        XCTAssertEqual(byName["tinker:test:user:2"]?.length, 2)
        XCTAssertNil(byName["tinker:test:user:2"]?.ttlMilliseconds, "no TTL is nil, not -1")
        XCTAssertEqual(byName["tinker:test:queue"]?.length, 3)
        XCTAssertEqual(byName["tinker:test:board"]?.type, .zset)
        XCTAssertEqual(byName["tinker:test:events"]?.type, .stream)
        XCTAssertNotNil(byName["tinker:test:tags"]?.memoryBytes)
        // The binary key shows escaped and reads back to the same bytes.
        let binary = try XCTUnwrap(infos.first { $0.key.display.hasPrefix("tinker:test:bin:") })
        XCTAssertEqual(binary.key.display, #"tinker:test:bin:\x00\xff"#)
        XCTAssertEqual(RedisText.parse(binary.key.display), binary.key.bytes)
    }

    func testRenameTTLDuplicateAndDelete() async throws {
        let connection = try await session(try await Self.server()).connection(database: 15)
        let key = RedisKey("tinker:test:a")
        try await connection.send(["SET", key.argument, "1"])
        try await connection.send(["SET", "tinker:test:taken", "2"])
        try await RedisKeyspace.rename(connection, key, to: RedisKey("tinker:test:b"))
        let awaited1 = try await RedisKeyspace.exists(connection, key)
        XCTAssertFalse(awaited1)
        do {
            try await RedisKeyspace.rename(connection, RedisKey("tinker:test:b"), to: RedisKey("tinker:test:taken"))
            XCTFail("rename must not overwrite")
        } catch DBError.server {}
        try await RedisKeyspace.setTTL(connection, RedisKey("tinker:test:b"), milliseconds: 60_000)
        let awaited2 = try await connection.send(["PTTL", "tinker:test:b"]).integer ?? 0
        XCTAssertGreaterThan(awaited2, 0)
        try await RedisKeyspace.setTTL(connection, RedisKey("tinker:test:b"), milliseconds: nil)
        let awaited3 = try await connection.send(["PTTL", "tinker:test:b"]).integer
        XCTAssertEqual(awaited3, -1)
        try await RedisKeyspace.duplicate(connection, RedisKey("tinker:test:b"), to: RedisKey("tinker:test:c"))
        let awaited4 = try await connection.send(["GET", "tinker:test:c"]).string
        XCTAssertEqual(awaited4, "1")
        let removed = try await RedisKeyspace.delete(connection, [RedisKey("tinker:test:b"), RedisKey("tinker:test:c")])
        XCTAssertEqual(removed, 2)
    }

    // MARK: - Values

    func testEveryTypeIsCreatedReadAndEdited() async throws {
        let redis = session(try await Self.server())
        let info = try await redis.connect()
        let connection = try await redis.connection(database: 15)

        let string = RedisKey("tinker:test:v:string")
        try await RedisValues.create(connection, string, type: .string, initial: .text("héllo"), ttlSeconds: 100)
        guard case let .string(data) = try await RedisValues.read(connection, string, type: .string) else {
            return XCTFail("string")
        }
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "héllo")
        try await RedisValues.setString(connection, string, Data("changed".utf8))
        let awaited5 = try await connection.send(["TTL", string.argument]).integer ?? 0
        XCTAssertGreaterThan(awaited5, 0, "KEEPTTL kept it")
        do {
            try await RedisValues.create(connection, string, type: .string, initial: .text("again"))
            XCTFail("create must not overwrite")
        } catch DBError.server {}

        let hash = RedisKey("tinker:test:v:hash")
        try await RedisValues.create(
            connection, hash, type: .hash,
            initial: .pairs([RedisPair(field: Data("a".utf8), value: Data("1".utf8))]))
        try await RedisValues.setHashField(connection, hash, field: Data("b".utf8), value: Data("2".utf8))
        try await RedisValues.renameHashField(connection, hash, from: Data("a".utf8), to: Data("z".utf8), value: Data("1".utf8))
        guard case let .hash(fields, cursor) = try await RedisValues.read(connection, hash, type: .hash) else {
            return XCTFail("hash")
        }
        XCTAssertEqual(cursor, "0")
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: fields.map { (String(decoding: $0.field, as: UTF8.self), String(decoding: $0.value, as: UTF8.self)) }),
            ["z": "1", "b": "2"])
        do {
            try await RedisValues.create(connection, RedisKey("tinker:test:v:empty"), type: .hash, initial: .pairs([]))
            XCTFail("an empty hash cannot exist")
        } catch DBError.protocolError {}

        let list = RedisKey("tinker:test:v:list")
        try await RedisValues.create(connection, list, type: .list, initial: .items(["a", "b", "c", "b"].map { Data($0.utf8) }))
        try await RedisValues.push(connection, list, [Data("head".utf8)], at: .head)
        try await RedisValues.setListItem(connection, list, index: 1, expected: Data("a".utf8), value: Data("A".utf8))
        do {
            try await RedisValues.setListItem(connection, list, index: 1, expected: Data("a".utf8), value: Data("?".utf8))
            XCTFail("a stale index must be refused")
        } catch DBError.protocolError {}
        // Removes the second "b" only, by index, not every "b".
        try await RedisValues.removeListItems(connection, list, items: [(index: 4, expected: Data("b".utf8))])
        guard case let .list(items, offset) = try await RedisValues.read(connection, list, type: .list) else {
            return XCTFail("list")
        }
        XCTAssertEqual(offset, 0)
        XCTAssertEqual(items.map { String(decoding: $0, as: UTF8.self) }, ["head", "A", "b", "c"])

        let set = RedisKey("tinker:test:v:set")
        try await RedisValues.create(connection, set, type: .set, initial: .items([Data("x".utf8)]))
        try await RedisValues.addSetMembers(connection, set, [Data("y".utf8), Data("z".utf8)])
        try await RedisValues.replaceSetMember(connection, set, old: Data("x".utf8), new: Data("w".utf8))
        try await RedisValues.removeSetMembers(connection, set, [Data("z".utf8)])
        guard case let .set(members, _) = try await RedisValues.read(connection, set, type: .set) else {
            return XCTFail("set")
        }
        XCTAssertEqual(Set(members.map { String(decoding: $0, as: UTF8.self) }), ["w", "y"])

        let zset = RedisKey("tinker:test:v:zset")
        try await RedisValues.create(
            connection, zset, type: .zset, initial: .scored([RedisScoredMember(member: Data("ada".utf8), score: "2.5")]))
        try await RedisValues.addSortedMembers(connection, zset, [RedisScoredMember(member: Data("bob".utf8), score: "1")])
        try await RedisValues.replaceSortedMember(
            connection, zset, old: Data("ada".utf8), new: RedisScoredMember(member: Data("ada".utf8), score: "0.125"))
        guard case let .zset(scored, _) = try await RedisValues.read(connection, zset, type: .zset) else {
            return XCTFail("zset")
        }
        XCTAssertEqual(scored.map { String(decoding: $0.member, as: UTF8.self) }, ["ada", "bob"])
        XCTAssertEqual(scored.map(\.score), ["0.125", "1"], "scores as the server writes them")

        let stream = RedisKey("tinker:test:v:stream")
        try await RedisValues.create(
            connection, stream, type: .stream, initial: .pairs([RedisPair(field: Data("k".utf8), value: Data("v".utf8))]))
        let id = try await RedisValues.addStreamEntry(
            connection, stream, fields: [RedisPair(field: Data("n".utf8), value: Data("2".utf8))])
        try await connection.send(["XGROUP", "CREATE", stream.argument, "workers", "0"])
        guard case let .stream(entries, next) = try await RedisValues.read(connection, stream, type: .stream) else {
            return XCTFail("stream")
        }
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.last?.id, id)
        XCTAssertNil(next)
        let groups = try await RedisValues.streamGroups(connection, stream)
        XCTAssertEqual(groups.map(\.name), ["workers"])
        try await RedisValues.deleteStreamEntries(connection, stream, ids: [id])
        let awaited6 = try await connection.send(["XLEN", stream.argument]).integer
        XCTAssertEqual(awaited6, 1)

        if info.hasJSON {
            let json = RedisKey("tinker:test:v:json")
            try await RedisValues.create(connection, json, type: .json, initial: .text(#"{"b":1,"a":[true,null]}"#))
            guard case let .json(text) = try await RedisValues.read(connection, json, type: .json) else {
                return XCTFail("json")
            }
            XCTAssertTrue(text.contains("\"a\""), text)
            try await RedisValues.setJSON(connection, json, #"{"c":"ç"}"#)
            let infos = try await RedisKeyspace.describe(connection, [json])
            XCTAssertEqual(infos.first?.type, .json)
        } else {
            TestLog.note("the server has no JSON module; JSON editing untested here")
        }
    }

    /// List edits by index check and write in one step; a set's only member is replaced
    /// without the key (and its TTL) disappearing in between.
    func testEditsDoNotRaceOrLoseTheExpiry() async throws {
        let connection = try await session(try await Self.server()).connection(database: 15)
        let list = RedisKey("tinker:test:race:list")
        _ = try await connection.pipeline([["RPUSH", list.argument, "a", "b", "c"]])
        // Another client pops meanwhile: what the page showed is no longer at index 1.
        try await connection.send(["LPOP", list.argument])
        do {
            try await RedisValues.removeListItems(connection, list, items: [(index: 1, expected: Data("b".utf8))])
            XCTFail("a stale index must be refused")
        } catch DBError.protocolError {}
        let left = try await connection.send(["LRANGE", list.argument, 0, -1])
        XCTAssertEqual(left.array?.compactMap(\.string), ["b", "c"], "nothing was removed")

        let set = RedisKey("tinker:test:race:set")
        _ = try await connection.pipeline([["SADD", set.argument, "only"], ["EXPIRE", set.argument, 600]])
        try await RedisValues.replaceSetMember(connection, set, old: Data("only".utf8), new: Data("renamed".utf8))
        let ttl = try await connection.send(["TTL", set.argument]).integer ?? -1
        XCTAssertGreaterThan(ttl, 500, "the key never became empty, so it kept its TTL")
        let zset = RedisKey("tinker:test:race:zset")
        _ = try await connection.pipeline([["ZADD", zset.argument, "1", "only"], ["EXPIRE", zset.argument, 600]])
        try await RedisValues.replaceSortedMember(
            connection, zset, old: Data("only".utf8), new: RedisScoredMember(member: Data("renamed".utf8), score: "2"))
        let zttl = try await connection.send(["TTL", zset.argument]).integer ?? -1
        XCTAssertGreaterThan(zttl, 500)
    }

    /// Without DUMP, a stream still arrives with its groups and its last id — even empty.
    func testTheElementCopyKeepsAStreamsGroupsAndLastID() async throws {
        let server = try await Self.server()
        let redis = session(server)
        let source = try await redis.connection(database: server.main)
        let target = try await redis.connection(database: server.other)
        _ = try await source.pipeline([
            ["XADD", "tinker:test:sx:full", "5-1", "k", "v"], ["XADD", "tinker:test:sx:full", "9-1", "k", "w"],
            ["XDEL", "tinker:test:sx:full", "9-1"],
            ["XGROUP", "CREATE", "tinker:test:sx:full", "billing", "5-1"],
            ["XGROUP", "CREATE", "tinker:test:sx:empty", "audit", "$", "MKSTREAM"],
        ])
        for name in ["full", "empty"] {
            let key = RedisKey("tinker:test:sx:\(name)")
            try await RedisValueCopy.copy(key, from: source, to: target, keepTTL: true)
            let same = try await RedisValueCopy.sameContents(key, type: .stream, left: source, right: target)
            XCTAssertTrue(same, name)
            let type = try await target.send(["TYPE", key.argument]).string
            XCTAssertEqual(type, "stream", "\(name) exists on the target")
        }
        let groups = try await RedisValues.streamGroups(target, RedisKey("tinker:test:sx:full"))
        XCTAssertEqual(groups.map(\.name), ["billing"])
        XCTAssertEqual(groups.first?.lastDeliveredID, "5-1")
    }

    func testLargeKeysArePaged() async throws {
        let connection = try await session(try await Self.server()).connection(database: 15)
        let list = RedisKey("tinker:test:big:list")
        let hash = RedisKey("tinker:test:big:hash")
        for chunk in stride(from: 0, to: 1_200, by: 400) {
            _ = try await connection.pipeline([
                ["RPUSH", list.argument] + (chunk ..< chunk + 400).map { RedisArgument($0) },
                ["HSET", hash.argument] + (chunk ..< chunk + 400).flatMap { [RedisArgument("f\($0)"), RedisArgument($0)] },
            ])
        }
        var page = try await RedisValues.read(connection, list, type: .list)
        guard case let .list(first, _) = page else { return XCTFail() }
        XCTAssertEqual(first.count, RedisValues.pageSize)
        page = try await RedisValues.read(connection, list, type: .list, continuing: page)
        guard case let .list(second, offset) = page else { return XCTFail() }
        XCTAssertEqual(offset, RedisValues.pageSize)
        XCTAssertEqual(String(decoding: second[0], as: UTF8.self), String(RedisValues.pageSize))

        var seen: Set<Data> = []
        var hashPage: RedisValuePage?
        var more = true
        while more {
            hashPage = try await RedisValues.read(connection, hash, type: .hash, continuing: hashPage)
            guard case let .hash(fields, cursor) = hashPage else { return XCTFail() }
            for field in fields { seen.insert(field.field) }
            more = cursor != "0"
        }
        XCTAssertEqual(seen.count, 1_200, "HSCAN may repeat a field but never loses one")
    }

    // MARK: - Transfer and sync

    private func seed(_ connection: RedisConnection) async throws {
        _ = try await connection.pipeline([
            ["SET", "tinker:test:t:s", "text"], ["PEXPIRE", "tinker:test:t:s", 900_000],
            ["HSET", "tinker:test:t:h", "a", "1", "b", "2"],
            ["RPUSH", "tinker:test:t:l", "x", "y"],
            ["SADD", "tinker:test:t:set", "m", "n"],
            ["ZADD", "tinker:test:t:z", "1", "one", "2", "two"],
            ["XADD", "tinker:test:t:x", "1-1", "f", "v"],
            ["SET", "tinker:test:other", "not matched"],
        ])
    }

    func testTransferCopiesEveryTypeWithItsTTL() async throws {
        let server = try await Self.server()
        let redis = session(server)
        let source = try await redis.connection(database: server.main)
        let target = try await redis.connection(database: server.other)
        try await seed(source)
        try await target.send(["SET", "tinker:test:t:h", "stale"])

        let progress = try await RedisTransfer.copy(
            from: RedisEndpoint(session: redis, database: server.main),
            to: RedisEndpoint(session: redis, database: server.other),
            options: RedisTransferOptions(pattern: "tinker:test:t:*", batchSize: 2))
        XCTAssertEqual(progress.copied, 6)
        XCTAssertEqual(progress.failed, 0, "\(progress.failures)")
        let types = try await target.pipeline(
            ["s", "h", "l", "set", "z", "x"].map { ["TYPE", RedisArgument("tinker:test:t:\($0)")] })
        XCTAssertEqual(types.map(\.string), ["string", "hash", "list", "set", "zset", "stream"])
        let awaited7 = try await target.send(["HGET", "tinker:test:t:h", "b"]).string
        XCTAssertEqual(awaited7, "2", "replaced")
        let awaited8 = try await target.send(["PTTL", "tinker:test:t:s"]).integer ?? 0
        XCTAssertGreaterThan(awaited8, 800_000)
        let awaited9 = try await target.send(["EXISTS", "tinker:test:other"]).integer
        XCTAssertEqual(awaited9, 0, "the pattern held")

        // Skip leaves what is there.
        try await target.send(["SET", "tinker:test:t:s", "kept"])
        let skipping = try await RedisTransfer.copy(
            from: RedisEndpoint(session: redis, database: server.main),
            to: RedisEndpoint(session: redis, database: server.other),
            options: RedisTransferOptions(pattern: "tinker:test:t:*", types: [.string], existing: .skip))
        XCTAssertEqual(skipping.copied, 0)
        XCTAssertEqual(skipping.skipped, 1)
        let awaited10 = try await target.send(["GET", "tinker:test:t:s"]).string
        XCTAssertEqual(awaited10, "kept")
    }

    /// Two servers of different major versions reject each other's DUMP payloads; each
    /// type then goes across element by element.
    func testTheElementCopyMatchesTheOriginal() async throws {
        let server = try await Self.server()
        let redis = session(server)
        let source = try await redis.connection(database: server.main)
        let target = try await redis.connection(database: server.other)
        try await seed(source)
        for key in ["s", "h", "l", "set", "z", "x"] {
            try await RedisValueCopy.copy(RedisKey("tinker:test:t:\(key)"), from: source, to: target, keepTTL: true)
            let type = RedisKeyType(typeName: try await source.send(["TYPE", RedisArgument("tinker:test:t:\(key)")]).string ?? "")
            let awaited11 = try await RedisValueCopy.sameContents(RedisKey("tinker:test:t:\(key)"), type: type, left: source, right: target)
            XCTAssertTrue(awaited11,
                key)
        }
    }

    func testDataSyncFindsAddedChangedAndRemovedKeysAndAppliesThem() async throws {
        let server = try await Self.server()
        let redis = session(server)
        let source = try await redis.connection(database: server.main)
        let target = try await redis.connection(database: server.other)
        try await seed(source)
        _ = try await target.pipeline([
            ["HSET", "tinker:test:t:h", "b", "2", "a", "1"],  // same contents, other insertion order
            ["RPUSH", "tinker:test:t:l", "x"],  // different
            ["SET", "tinker:test:t:z", "wrong type"],  // different type
            ["SET", "tinker:test:t:extra", "only here"],  // target only
        ])
        let from = RedisEndpoint(session: redis, database: server.main)
        let to = RedisEndpoint(session: redis, database: server.other)
        let options = RedisTransferOptions(pattern: "tinker:test:t:*")
        let plan = try await RedisDataSync.compare(source: from, target: to, options: options)
        XCTAssertEqual(Set(plan.added.map(\.display)), ["tinker:test:t:s", "tinker:test:t:set", "tinker:test:t:x"])
        XCTAssertEqual(Set(plan.changed.map(\.display)), ["tinker:test:t:l", "tinker:test:t:z"])
        XCTAssertEqual(plan.removed.map(\.display), ["tinker:test:t:extra"])
        XCTAssertEqual(plan.unchanged, 1)

        let applied = try await RedisDataSync.apply(plan, source: from, target: to, deleteExtras: true)
        XCTAssertEqual(applied.copied, 5)
        XCTAssertEqual(applied.deleted, 1)
        let again = try await RedisDataSync.compare(source: from, target: to, options: options)
        XCTAssertTrue(again.isEmpty, "after applying there is nothing left to do: \(again)")
        XCTAssertEqual(again.unchanged, 6)
    }
}
