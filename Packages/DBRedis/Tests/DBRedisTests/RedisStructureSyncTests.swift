import DBCore
import Foundation
import XCTest

@testable import DBRedis

final class RedisStructureSyncTests: XCTestCase {
    private func bulk(_ text: String) -> RESPValue { .bulkString(Data(text.utf8)) }
    private func simple(_ text: String) -> RESPValue { .simpleString(text) }

    /// `FT.INFO` as Redis 8.10 answered it for
    /// `FT.CREATE tinker_probe_idx ON HASH PREFIX 2 tinker:probe: tinker:p2: FILTER "@age>0"
    ///  SCORE 0.5 SCHEMA name AS title TEXT NOSTEM WEIGHT 2 SORTABLE age NUMERIC SORTABLE
    ///  tags TAG SEPARATOR ";" CASESENSITIVE loc GEO vec VECTOR FLAT 6 TYPE FLOAT32 DIM 4
    ///  DISTANCE_METRIC COSINE` (statistics trimmed).
    private var hashIndexInfo: RESPValue {
        .array([
            simple("index_name"), bulk("tinker_probe_idx"),
            simple("index_options"), .array([]),
            simple("index_definition"),
            .array([
                simple("key_type"), simple("HASH"),
                simple("prefixes"), .array([bulk("tinker:probe:"), bulk("tinker:p2:")]),
                simple("filter"), bulk("@age>0"),
                simple("default_score"), bulk("0.5"),
                simple("indexes_all"), simple("false"),
            ]),
            simple("attributes"),
            .array([
                .array([
                    simple("identifier"), bulk("name"), simple("attribute"), bulk("title"), simple("type"), simple("TEXT"),
                    simple("WEIGHT"), bulk("2"), simple("SORTABLE"), simple("NOSTEM"),
                ]),
                .array([
                    simple("identifier"), bulk("age"), simple("attribute"), bulk("age"), simple("type"), simple("NUMERIC"),
                    simple("SORTABLE"), simple("UNF"),
                ]),
                .array([
                    simple("identifier"), bulk("tags"), simple("attribute"), bulk("tags"), simple("type"), simple("TAG"),
                    simple("SEPARATOR"), bulk(";"), simple("CASESENSITIVE"),
                ]),
                .array([simple("identifier"), bulk("loc"), simple("attribute"), bulk("loc"), simple("type"), simple("GEO")]),
                .array([
                    simple("identifier"), bulk("vec"), simple("attribute"), bulk("vec"), simple("type"), simple("VECTOR"),
                    simple("algorithm"), simple("FLAT"), simple("data_type"), simple("FLOAT32"), simple("dim"), .integer(4),
                    simple("distance_metric"), simple("COSINE"),
                ]),
            ]),
            simple("num_docs"), .integer(0),
        ])
    }

    private func text(_ command: [RedisArgument]) -> String {
        command.map { String(decoding: $0.bytes, as: UTF8.self) }.joined(separator: " ")
    }

    func testCreateCommandIsRebuiltFromFTInfo() throws {
        let command = try RedisStructureSync.createCommand(name: "tinker_probe_idx", info: hashIndexInfo)
        XCTAssertEqual(
            text(command),
            "FT.CREATE tinker_probe_idx ON HASH PREFIX 2 tinker:probe: tinker:p2: FILTER @age>0 SCORE 0.5 SCHEMA "
                + "name AS title TEXT NOSTEM WEIGHT 2 SORTABLE age NUMERIC SORTABLE UNF tags TAG SEPARATOR ; "
                + "CASESENSITIVE loc GEO vec VECTOR FLAT 6 TYPE FLOAT32 DIM 4 DISTANCE_METRIC COSINE")
    }

    func testAJSONIndexKeepsItsPathsAndLeavesDefaultsOut() throws {
        let info: RESPValue = .array([
            simple("index_name"), bulk("people"),
            simple("index_options"), .array([simple("NOOFFSETS")]),
            simple("index_definition"),
            .array([
                simple("key_type"), simple("JSON"), simple("prefixes"), .array([bulk("person:")]),
                simple("default_score"), bulk("1"),
            ]),
            simple("attributes"),
            .array([
                .array([
                    simple("identifier"), bulk("$.name"), simple("attribute"), bulk("name"), simple("type"), simple("TEXT"),
                    simple("WEIGHT"), bulk("1"),
                ]),
                .array([simple("identifier"), bulk("$.n"), simple("attribute"), bulk("n"), simple("type"), simple("NUMERIC")]),
            ]),
            simple("stopwords_list"), .array([bulk("a"), bulk("the")]),
        ])
        XCTAssertEqual(
            text(try RedisStructureSync.createCommand(name: "people", info: info)),
            "FT.CREATE people ON JSON PREFIX 1 person: NOOFFSETS STOPWORDS 2 a the SCHEMA $.name AS name TEXT $.n AS n NUMERIC")
    }

    func testAnUnknownAttributeTypeIsRefusedNotGuessed() {
        let info: RESPValue = .array([
            simple("index_definition"), .array([simple("key_type"), simple("HASH")]),
            simple("attributes"),
            .array([.array([simple("identifier"), bulk("x"), simple("attribute"), bulk("x"), simple("type"), simple("FUTURE")])]),
        ])
        XCTAssertThrowsError(try RedisStructureSync.createCommand(name: "i", info: info))
    }

    func testThePreviewQuotesWhatNeedsIt() {
        let change = RedisStructureChange(
            action: .create, object: .searchIndex("i"), summary: "",
            commands: [["FT.CREATE", "i", "FILTER", "@a > 1"]])
        XCTAssertEqual(change.preview, #"FT.CREATE i FILTER "@a > 1""#)
    }

    // MARK: - Against the server

    func testConsumerGroupsAreComparedAndCreated() async throws {
        let server = try await RedisIntegrationTests.server()
        let redis = RedisSession(config: server.config, secrets: server.secrets)
        defer { Task { await redis.disconnect() } }
        let source = try await redis.connection(database: server.main)
        let target = try await redis.connection(database: server.other)
        let cleanup: @Sendable () async -> Void = {
            for connection in [source, target] {
                _ = try? await connection.send(["DEL", "tinker:test:s:orders", "tinker:test:s:new"])
            }
        }
        await cleanup()
        _ = try await source.pipeline([
            ["XADD", "tinker:test:s:orders", "1-1", "k", "v"],
            ["XGROUP", "CREATE", "tinker:test:s:orders", "billing", "0"],
            ["XGROUP", "CREATE", "tinker:test:s:orders", "shipping", "$"],
            ["XADD", "tinker:test:s:new", "1-1", "k", "v"],
            ["XGROUP", "CREATE", "tinker:test:s:new", "audit", "0"],
        ])
        _ = try await target.pipeline([
            ["XADD", "tinker:test:s:orders", "1-1", "k", "v"],
            ["XGROUP", "CREATE", "tinker:test:s:orders", "billing", "$"],
            ["XGROUP", "CREATE", "tinker:test:s:orders", "legacy", "0"],
        ])
        let from = RedisEndpoint(session: redis, database: server.main)
        let to = RedisEndpoint(session: redis, database: server.other)
        let changes = try await RedisStructureSync.compare(
            source: from, target: to, pattern: "tinker:test:s:*", dropExtras: true)
        let groups = changes.compactMap { change -> String? in
            guard case let .consumerGroup(stream, group) = change.object else { return nil }
            return "\(change.action.rawValue) \(stream.display) \(group)"
        }
        XCTAssertEqual(
            Set(groups),
            [
                "create tinker:test:s:orders shipping", "recreate tinker:test:s:orders billing",
                "drop tinker:test:s:orders legacy",
            ],
            "a group read to another id is set back; a stream the target lacks is left to the data tools")
        XCTAssertTrue(
            changes.first { $0.summary.contains("billing") }?.preview.contains("XGROUP SETID") ?? false)

        try await RedisStructureSync.apply(changes, target: to)
        let after = try await RedisStructureSync.compare(
            source: from, target: to, pattern: "tinker:test:s:*", dropExtras: true)
        XCTAssertTrue(
            after.filter { if case .consumerGroup = $0.object { true } else { false } }.isEmpty, "\(after.map(\.summary))")
        await cleanup()
    }
}
