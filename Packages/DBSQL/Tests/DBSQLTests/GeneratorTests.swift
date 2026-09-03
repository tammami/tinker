import DBCore
import XCTest
@testable import DBSQL

final class DMLGeneratorTests: XCTestCase {
    let users = TableRef(database: "app", schema: "public", name: "users")

    func testUpdateListsOnlyChangedColumnsAndKeysOnOriginalValues() throws {
        let generator = DMLGenerator(dialect: .postgresql, table: users, identityColumns: ["id"])
        let statement = try generator.update(
            changes: ["name": .string("new"), "age": .int(31)],
            originalIdentity: ["id": .int(7)]
        )
        XCTAssertEqual(
            statement.sql,
            "UPDATE \"public\".\"users\" SET \"age\" = $1, \"name\" = $2 WHERE \"id\" = $3"
        )
        XCTAssertEqual(statement.parameters, [.int(31), .string("new"), .int(7)])
        XCTAssertTrue(statement.expectsSingleRow)
    }

    func testUpdateWithCompositeKey() throws {
        let generator = DMLGenerator(
            dialect: .mysql,
            table: TableRef(database: "app", schema: "app", name: "memberships"),
            identityColumns: ["org_id", "user_id"]
        )
        let statement = try generator.update(
            changes: ["role": .string("admin")],
            originalIdentity: ["org_id": .int(1), "user_id": .int(2)]
        )
        XCTAssertEqual(
            statement.sql,
            "UPDATE `app`.`memberships` SET `role` = ? WHERE `org_id` = ? AND `user_id` = ?"
        )
        XCTAssertEqual(statement.parameters, [.string("admin"), .int(1), .int(2)])
    }

    func testUpdateWithUUIDKey() throws {
        let id = UUID(uuidString: "1EA1F2B3-0000-4000-8000-000000000001")
        let uuid = try XCTUnwrap(id)
        let generator = DMLGenerator(dialect: .postgresql, table: users, identityColumns: ["uid"])
        let statement = try generator.update(changes: ["name": .string("x")], originalIdentity: ["uid": .uuid(uuid)])
        XCTAssertEqual(statement.parameters.last, .uuid(uuid))
        XCTAssertTrue(statement.sql.hasSuffix("WHERE \"uid\" = $2"))
    }

    func testDeleteUsesIdentityOnly() throws {
        let generator = DMLGenerator(dialect: .postgresql, table: users, identityColumns: ["id"])
        let statement = try generator.delete(originalIdentity: ["id": .int(3)])
        XCTAssertEqual(statement.sql, "DELETE FROM \"public\".\"users\" WHERE \"id\" = $1")
        XCTAssertEqual(statement.parameters, [.int(3)])
    }

    func testInsertOmitsUnsetColumnsAndReturnsTheRowOnPostgres() throws {
        let generator = DMLGenerator(dialect: .postgresql, table: users, identityColumns: ["id"])
        let statement = try generator.insert(values: ["name": .string("a"), "email": .null])
        XCTAssertEqual(
            statement.sql,
            "INSERT INTO \"public\".\"users\" (\"email\", \"name\") VALUES ($1, $2) RETURNING *"
        )
        XCTAssertEqual(statement.parameters, [.null, .string("a")])
    }

    func testInsertOfAnAllDefaultsRow() throws {
        let pg = DMLGenerator(dialect: .postgresql, table: users, identityColumns: ["id"])
        XCTAssertEqual(try pg.insert(values: [:]).sql, "INSERT INTO \"public\".\"users\" DEFAULT VALUES RETURNING *")
        let mysql = DMLGenerator(dialect: .mysql, table: users, identityColumns: ["id"])
        XCTAssertEqual(try mysql.insert(values: [:]).sql, "INSERT INTO `app`.`users` () VALUES ()")
    }

    func testNullIdentityUsesIsNull() throws {
        let generator = DMLGenerator(dialect: .postgresql, table: users, identityColumns: ["id"])
        let statement = try generator.delete(originalIdentity: ["id": .null])
        XCTAssertEqual(statement.sql, "DELETE FROM \"public\".\"users\" WHERE \"id\" IS NULL")
        XCTAssertTrue(statement.parameters.isEmpty)
    }

    func testMissingIdentityValueThrows() {
        let generator = DMLGenerator(dialect: .postgresql, table: users, identityColumns: ["id"])
        XCTAssertThrowsError(try generator.update(changes: ["a": .int(1)], originalIdentity: [:])) { error in
            XCTAssertEqual(error as? DMLGeneratorError, .missingIdentityValue(column: "id"))
        }
    }

    func testTableWithoutIdentityThrows() {
        let generator = DMLGenerator(dialect: .postgresql, table: users, identityColumns: [])
        XCTAssertThrowsError(try generator.delete(originalIdentity: [:])) { error in
            XCTAssertEqual(error as? DMLGeneratorError, .noRowIdentity(self.users))
        }
    }

    func testEmptyChangeSetThrows() {
        let generator = DMLGenerator(dialect: .postgresql, table: users, identityColumns: ["id"])
        XCTAssertThrowsError(try generator.update(changes: [:], originalIdentity: ["id": .int(1)])) { error in
            XCTAssertEqual(error as? DMLGeneratorError, .noColumnsToWrite)
        }
    }

    /// SPEC §12.6: three cells across two rows commit as exactly two UPDATE statements.
    func testThreeCellsInTwoRowsProduceTwoUpdates() throws {
        let generator = DMLGenerator(dialect: .postgresql, table: users, identityColumns: ["id"])
        let statements = [
            try generator.update(changes: ["name": .string("a"), "age": .int(1)], originalIdentity: ["id": .int(1)]),
            try generator.update(changes: ["name": .string("b")], originalIdentity: ["id": .int(2)]),
        ]
        XCTAssertEqual(statements.count, 2)
        XCTAssertEqual(statements.filter { $0.kind == .update }.count, 2)
        XCTAssertTrue(statements.allSatisfy(\.expectsSingleRow))
        XCTAssertEqual(statements[0].parameters.count, 3)
        XCTAssertEqual(statements[1].parameters.count, 2)
    }

    func testDisplaySQLIsReadableButNeverExecuted() throws {
        let generator = DMLGenerator(dialect: .postgresql, table: users, identityColumns: ["id"])
        let statement = try generator.update(changes: ["name": .string("O'Brien")], originalIdentity: ["id": .int(4)])
        XCTAssertEqual(
            statement.displaySQL(dialect: .postgresql),
            "UPDATE \"public\".\"users\" SET \"name\" = 'O''Brien' WHERE \"id\" = 4"
        )
        // The executed form still carries placeholders, never the value.
        XCTAssertFalse(statement.sql.contains("O'Brien"))
    }
}

final class FilterCompilerTests: XCTestCase {
    func testComparisonOperators() {
        let rules = [
            FilterRule(column: "a", op: .equal, values: [.int(1)]),
            FilterRule(column: "b", op: .greaterOrEqual, values: [.decimal("2.5")]),
        ]
        let compiled = FilterCompiler.compile(rules, dialect: .postgresql)
        XCTAssertEqual(compiled.whereClause, "\"a\" = $1 AND \"b\" >= $2")
        XCTAssertEqual(compiled.parameters, [.int(1), .decimal("2.5")])
    }

    func testNullOperatorsBindNothing() {
        let compiled = FilterCompiler.compile(
            [FilterRule(column: "a", op: .isNull), FilterRule(column: "b", op: .isNotNull)],
            dialect: .mysql
        )
        XCTAssertEqual(compiled.whereClause, "`a` IS NULL AND `b` IS NOT NULL")
        XCTAssertTrue(compiled.parameters.isEmpty)
    }

    func testLikeOperatorsEscapeUserWildcards() {
        let compiled = FilterCompiler.compile(
            [FilterRule(column: "name", op: .contains, values: [.string("50%_off")])],
            dialect: .postgresql
        )
        XCTAssertEqual(compiled.whereClause, "\"name\"::text LIKE $1 ESCAPE '\\'")
        XCTAssertEqual(compiled.parameters, [.string("%50\\%\\_off%")])
    }

    func testStartsWithAndEndsWith() {
        let starts = FilterCompiler.compile(
            [FilterRule(column: "n", op: .startsWith, values: [.string("ab")])], dialect: .mysql
        )
        XCTAssertEqual(starts.parameters, [.string("ab%")])
        XCTAssertEqual(starts.whereClause, "CAST(`n` AS CHAR) LIKE ? ESCAPE '\\'")
        let ends = FilterCompiler.compile(
            [FilterRule(column: "n", op: .endsWith, values: [.string("ab")])], dialect: .mysql
        )
        XCTAssertEqual(ends.parameters, [.string("%ab")])
    }

    func testInListAndBetween() {
        let compiled = FilterCompiler.compile(
            [
                FilterRule(column: "a", op: .inList, values: [.int(1), .int(2), .int(3)]),
                FilterRule(column: "b", op: .between, values: [.int(10), .int(20)]),
            ],
            dialect: .postgresql
        )
        XCTAssertEqual(compiled.whereClause, "\"a\" IN ($1, $2, $3) AND \"b\" BETWEEN $4 AND $5")
        XCTAssertEqual(compiled.parameters.count, 5)
    }

    func testPlaceholderNumberingCanBeOffset() {
        let compiled = FilterCompiler.compile(
            [FilterRule(column: "a", op: .equal, values: [.int(1)])],
            dialect: .postgresql, startingParameterIndex: 4
        )
        XCTAssertEqual(compiled.whereClause, "\"a\" = $4")
    }

    func testEmptyRulesProduceNoClause() {
        XCTAssertNil(FilterCompiler.compile([], dialect: .postgresql).whereClause)
        // An operator with too few operands is skipped rather than producing broken SQL.
        XCTAssertNil(FilterCompiler.compile(
            [FilterRule(column: "a", op: .between, values: [.int(1)])], dialect: .postgresql
        ).whereClause)
    }

    func testFilterRuleRoundTripsThroughCoding() throws {
        let rules = [
            FilterRule(column: "a", op: .inList, values: [.int(1), .string("x"), .null]),
            FilterRule(column: "b", op: .isNull),
        ]
        let data = try JSONEncoder().encode(rules)
        let decoded = try JSONDecoder().decode([FilterRule].self, from: data)
        XCTAssertEqual(decoded.map(\.column), ["a", "b"])
        XCTAssertEqual(decoded[0].values, [.int(1), .string("x"), .null])
    }
}

final class PagePlannerTests: XCTestCase {
    let planner = PagePlanner(dialect: .postgresql, table: TableRef(database: "app", schema: "public", name: "big"))

    func testShallowPagesUseOffset() {
        let strategy = planner.strategy(page: 3, userSort: [], identityColumns: ["id"], identityKind: .int)
        XCTAssertEqual(strategy, .offset)
    }

    func testDeepPagesUseKeysetWhenTheKeyAllowsIt() {
        let strategy = planner.strategy(page: 51, userSort: [], identityColumns: ["id"], identityKind: .int)
        XCTAssertEqual(strategy, .keyset(column: "id"))
    }

    func testUserSortForcesOffset() {
        let strategy = planner.strategy(
            page: 100,
            userSort: [PagePlanner.SortTerm(column: "name", ascending: true)],
            identityColumns: ["id"], identityKind: .int
        )
        XCTAssertEqual(strategy, .offset)
    }

    func testCompositeOrNonIntegerKeysForceOffset() {
        XCTAssertEqual(
            planner.strategy(page: 100, userSort: [], identityColumns: ["a", "b"], identityKind: .int),
            .offset
        )
        XCTAssertEqual(
            planner.strategy(page: 100, userSort: [], identityColumns: ["id"], identityKind: .uuid),
            .offset
        )
        XCTAssertEqual(
            planner.strategy(page: 100, userSort: [], identityColumns: [], identityKind: nil),
            .offset
        )
    }

    func testOffsetPageQuery() {
        let query = planner.pageQuery(strategy: .offset, page: 2)
        XCTAssertEqual(query.sql, "SELECT * FROM \"public\".\"big\" LIMIT 1000 OFFSET 2000")
        XCTAssertTrue(query.parameters.isEmpty)
    }

    func testKeysetPageQueryOrdersByTheKeyAndBindsTheAnchor() {
        let query = planner.pageQuery(strategy: .keyset(column: "id"), page: 51, keysetAnchor: .int(51_000))
        XCTAssertEqual(
            query.sql,
            "SELECT * FROM \"public\".\"big\" WHERE \"id\" > $1 ORDER BY \"id\" ASC LIMIT 1000"
        )
        XCTAssertEqual(query.parameters, [.int(51_000)])
    }

    func testFilterAndSortAreComposedIntoThePageQuery() {
        let filter = FilterCompiler.compile(
            [FilterRule(column: "status", op: .equal, values: [.string("on")])], dialect: .postgresql
        )
        let query = planner.pageQuery(
            columns: ["id", "name"],
            filter: filter,
            sort: [PagePlanner.SortTerm(column: "name", ascending: false)],
            strategy: .offset,
            page: 1
        )
        XCTAssertEqual(
            query.sql,
            "SELECT \"id\", \"name\" FROM \"public\".\"big\" WHERE \"status\" = $1 "
            + "ORDER BY \"name\" DESC LIMIT 1000 OFFSET 1000"
        )
        XCTAssertEqual(query.parameters, [.string("on")])
    }

    func testCountQuery() {
        let filter = FilterCompiler.compile(
            [FilterRule(column: "a", op: .isNull)], dialect: .postgresql
        )
        XCTAssertEqual(
            planner.countQuery(filter: filter).sql,
            "SELECT COUNT(*) FROM \"public\".\"big\" WHERE \"a\" IS NULL"
        )
    }
}

final class SQLFormatterTests: XCTestCase {
    func testKeywordsAreUppercasedAndClausesGetTheirOwnLine() {
        let formatted = SQLFormatter.format("select a, b from t where a = 1 order by b", dialect: .postgresql)
        XCTAssertEqual(formatted, "SELECT a, b\nFROM t\nWHERE a = 1\nORDER BY b")
    }

    func testSubSelectsAreIndented() {
        let formatted = SQLFormatter.format(
            "select * from t where id in (select id from u where x = 1)", dialect: .postgresql
        )
        XCTAssertTrue(formatted.contains("(\n    SELECT id"), formatted)
        XCTAssertTrue(formatted.contains("    WHERE x = 1"), formatted)
    }

    func testStringsAndCommentsSurviveUntouched() {
        let sql = "select 'Select FROM keep' -- keep this comment\nfrom t"
        let formatted = SQLFormatter.format(sql, dialect: .postgresql)
        XCTAssertTrue(formatted.contains("'Select FROM keep'"))
        XCTAssertTrue(formatted.contains("-- keep this comment"))
    }

    func testQuotedIdentifiersKeepTheirCase() {
        let formatted = SQLFormatter.format("select \"MixedCase\" from \"T\"", dialect: .postgresql)
        XCTAssertTrue(formatted.contains("\"MixedCase\""))
        XCTAssertTrue(formatted.contains("\"T\""))
    }

    func testMultipleStatementsKeepTheirTerminators() {
        let formatted = SQLFormatter.format("select 1; select 2;", dialect: .postgresql)
        XCTAssertEqual(formatted, "SELECT 1;\n\nSELECT 2;")
    }

    func testFormattingIsIdempotent() {
        let sql = "select a, b from t join u on t.id = u.id where a = 1 group by a order by b"
        let once = SQLFormatter.format(sql, dialect: .postgresql)
        XCTAssertEqual(SQLFormatter.format(once, dialect: .postgresql), once)
    }
}

final class SQLTokenizerTests: XCTestCase {
    func testTokenKinds() {
        let tokens = SQLTokenizer.tokenize("SELECT 'a', 1.5, \"c\", $1 -- x", dialect: .postgresql)
            .filter { $0.kind != .whitespace }
        XCTAssertEqual(tokens.map(\.kind), [
            .keyword, .string, .punctuation, .number, .punctuation, .quotedIdentifier, .punctuation,
            .parameter, .comment,
        ])
    }

    func testRangesAddressTheOriginalText() {
        let sql = "SELECT 'π', x"
        let utf16 = Array(sql.utf16)
        for token in SQLTokenizer.tokenize(sql, dialect: .postgresql) {
            XCTAssertEqual(String(decoding: utf16[token.utf16Range], as: UTF16.self), token.text)
        }
    }
}
