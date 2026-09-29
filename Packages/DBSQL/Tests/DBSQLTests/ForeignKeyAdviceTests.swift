import DBCore
import XCTest

@testable import DBSQL

final class ForeignKeyAdviceTests: XCTestCase {
    private let orders = TableRef(database: "db", schema: "public", name: "orders")
    private let customers = TableRef(database: "db", schema: "public", name: "customers")

    private func key(
        _ columns: [String], _ referenced: [String], onDelete: ForeignKeyAction = .noAction
    ) -> ForeignKeyDefinition {
        ForeignKeyDefinition(
            name: "k", columns: columns, referencedTable: customers, referencedColumns: referenced,
            onDelete: onDelete)
    }

    private func messages(
        _ key: ForeignKeyDefinition, local: [ForeignKeyAdvice.Column], remote: [ForeignKeyAdvice.Column]?,
        keys: [[String]] = [["id"]], dialect: SQLDialect = .postgresql
    ) -> [ForeignKeyAdvice.Problem] {
        ForeignKeyAdvice.problems(with: key, columns: local, referenced: remote, referencedKeys: keys, dialect: dialect)
    }

    func testEachEngineIsOfferedTheActionsItHas() {
        XCTAssertFalse(ForeignKeyAdvice.actions(for: .mysql).contains(.setDefault))
        XCTAssertEqual(ForeignKeyAdvice.actions(for: .postgresql), ForeignKeyAction.allCases)
        XCTAssertEqual(ForeignKeyAdvice.actions(for: .sqlite), ForeignKeyAction.allCases)
        XCTAssertFalse(ForeignKeyAdvice.supportsDeferral(.mysql))
        XCTAssertTrue(ForeignKeyAdvice.supportsDeferral(.postgresql))
        for dialect in SQLDialect.allCases {
            for action in ForeignKeyAction.allCases {
                XCTAssertFalse(ForeignKeyAdvice.explanation(of: action, onDelete: true, dialect: dialect).isEmpty)
                XCTAssertFalse(ForeignKeyAdvice.explanation(of: action, onDelete: false, dialect: dialect).isEmpty)
            }
        }
    }

    func testNamesFollowTheEngine() {
        XCTAssertEqual(
            ForeignKeyAdvice.suggestedName(table: "orders", columns: ["customer_id"], dialect: .postgresql),
            "orders_customer_id_fkey")
        XCTAssertEqual(
            ForeignKeyAdvice.suggestedName(table: "orders", columns: ["customer_id"], dialect: .mysql),
            "fk_orders_customer_id")
        XCTAssertLessThanOrEqual(
            ForeignKeyAdvice.suggestedName(
                table: String(repeating: "t", count: 60), columns: ["column"], dialect: .postgresql
            ).count, 63)
    }

    func testAKeyThatLinesUpHasNothingSaidAboutIt() {
        let problems = messages(
            key(["customer_id"], ["id"]),
            local: [.init(name: "customer_id", type: "bigint")],
            remote: [.init(name: "id", type: "bigint"), .init(name: "name", type: "text")])
        XCTAssertEqual(problems, [])
    }

    func testAliasesAndSerialsAreTheTypeTheyStandFor() {
        XCTAssertEqual(ForeignKeyAdvice.comparable("int8", dialect: .postgresql), "bigint")
        XCTAssertEqual(ForeignKeyAdvice.comparable("bigserial", dialect: .postgresql), "bigint")
        XCTAssertEqual(ForeignKeyAdvice.comparable("character varying(20)", dialect: .postgresql), "character varying")
        XCTAssertEqual(ForeignKeyAdvice.comparable("varchar(64)", dialect: .mysql), "varchar")
        XCTAssertEqual(ForeignKeyAdvice.comparable("int(11) unsigned", dialect: .mysql), "int unsigned")
        XCTAssertEqual(ForeignKeyAdvice.comparable("timestamptz", dialect: .postgresql), "timestamp with time zone")
        XCTAssertEqual(
            ForeignKeyAdvice.comparable("timestamp(6) with time zone", dialect: .postgresql),
            "timestamp with time zone")
    }

    func testWhatTheServerWouldRefuseIsSaidFirst() {
        // Nothing chosen yet.
        let blank = ForeignKeyDefinition(
            name: "k", columns: [], referencedTable: TableRef(database: "db", schema: "public", name: ""),
            referencedColumns: [])
        XCTAssertEqual(messages(blank, local: [], remote: nil).filter { $0.severity == .error }.count, 2)

        // A column that is not a key of the table pointed at.
        let notUnique = messages(
            key(["customer_id"], ["name"]),
            local: [.init(name: "customer_id", type: "text")],
            remote: [.init(name: "id", type: "bigint"), .init(name: "name", type: "text")])
        XCTAssertEqual(notUnique.first?.severity, .error)
        XCTAssertTrue(notUnique.first?.message.contains("not unique") == true)

        // MySQL refuses a signed column pointing at an unsigned one; PostgreSQL may not.
        let local = [ForeignKeyAdvice.Column(name: "customer_id", type: "int")]
        let remote = [ForeignKeyAdvice.Column(name: "id", type: "int unsigned")]
        XCTAssertEqual(
            messages(key(["customer_id"], ["id"]), local: local, remote: remote, dialect: .mysql).first?.severity,
            .error)
        let loose = messages(
            key(["customer_id"], ["id"]),
            local: [.init(name: "customer_id", type: "integer")], remote: [.init(name: "id", type: "bigint")])
        XCTAssertEqual(loose.map(\.severity), [.warning])

        // SET NULL on a column that cannot be NULL.
        let setNull = messages(
            key(["customer_id"], ["id"], onDelete: .setNull),
            local: [.init(name: "customer_id", type: "bigint", isNullable: false)],
            remote: [.init(name: "id", type: "bigint")])
        XCTAssertTrue(setNull.contains { $0.message.contains("SET NULL") })

        // A composite key needs a column for each of its columns.
        let uneven = messages(
            key(["a", "b"], ["id"]),
            local: [.init(name: "a", type: "bigint"), .init(name: "b", type: "bigint")],
            remote: [.init(name: "id", type: "bigint")])
        XCTAssertTrue(uneven.contains { $0.severity == .error })
    }
}
