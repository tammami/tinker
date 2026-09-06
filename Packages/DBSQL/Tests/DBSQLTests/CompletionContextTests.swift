import DBCore
import XCTest

@testable import DBSQL

final class CompletionContextTests: XCTestCase {
    private func context(_ sql: String, dialect: SQLDialect = .postgresql) -> SQLCompletionContext {
        // A `|` marks the caret; without one the caret is at the end.
        let caret = sql.firstIndex(of: "|").map { sql.utf16.distance(from: sql.startIndex, to: $0) }
        let text = sql.replacingOccurrences(of: "|", with: "")
        return SQLCompletionContext.detect(statement: text, caretOffset: caret ?? text.utf16.count, dialect: dialect)
    }

    func testAfterFromExpectsTablesEvenWithNothingTyped() {
        let empty = context("SELECT id, name FROM ")
        XCTAssertEqual(empty.expecting, .tables)
        XCTAssertEqual(empty.prefix, "")
        let typed = context("SELECT * FROM cus")
        XCTAssertEqual(typed.expecting, .tables)
        XCTAssertEqual(typed.prefix, "cus")
    }

    func testJoinIntoUpdateAndDeleteFromExpectTables() {
        XCTAssertEqual(context("SELECT * FROM a JOIN ").expecting, .tables)
        XCTAssertEqual(context("INSERT INTO ").expecting, .tables)
        XCTAssertEqual(context("UPDATE ").expecting, .tables)
        XCTAssertEqual(context("DELETE FROM ").expecting, .tables)
        XCTAssertEqual(context("SELECT * FROM a, ").expecting, .tables)
    }

    func testSelectListAndConditionsExpectColumnsOfTheMentionedTable() {
        let select = context("SELECT | FROM customers")
        XCTAssertEqual(select.expecting, .columns)
        XCTAssertEqual(select.tables, [SQLTableMention(name: "customers")])
        XCTAssertEqual(context("SELECT id, | FROM customers").expecting, .columns)
        XCTAssertEqual(context("SELECT * FROM customers WHERE ").expecting, .columns)
        XCTAssertEqual(context("SELECT * FROM customers WHERE id = 1 AND ").expecting, .columns)
        XCTAssertEqual(context("SELECT * FROM customers WHERE id = ").expecting, .columns)
        XCTAssertEqual(context("SELECT * FROM customers ORDER BY ").expecting, .columns)
        XCTAssertEqual(context("SELECT * FROM customers ORDER BY id, ").expecting, .columns)
        XCTAssertEqual(context("UPDATE customers SET ").expecting, .columns)
        XCTAssertEqual(context("UPDATE customers SET name = 'x', ").expecting, .columns)
        XCTAssertEqual(context("INSERT INTO customers (").expecting, .columns)
        XCTAssertEqual(context("INSERT INTO customers (id, ").expecting, .columns)
        XCTAssertEqual(context("SELECT * FROM a JOIN b ON ").expecting, .columns)
    }

    func testQualifierResolvesThroughAliasesAndSchemas() {
        let aliased = context("SELECT c.na| FROM customers c")
        XCTAssertEqual(aliased.expecting, .qualified("c"))
        XCTAssertEqual(aliased.prefix, "na")
        XCTAssertEqual(aliased.table(for: "c"), SQLTableMention(name: "customers", alias: "c"))

        let asAlias = context("SELECT * FROM customers AS cu WHERE cu.")
        XCTAssertEqual(asAlias.expecting, .qualified("cu"))
        XCTAssertEqual(asAlias.table(for: "cu")?.name, "customers")

        let byName = context("SELECT customers.| FROM customers")
        XCTAssertEqual(byName.table(for: "customers")?.name, "customers")

        let schema = context("SELECT * FROM public.")
        XCTAssertEqual(schema.expecting, .qualified("public"))
        XCTAssertNil(schema.table(for: "public"))

        let qualifiedTable = context("SELECT s.| FROM shop.sales s")
        XCTAssertEqual(qualifiedTable.table(for: "s"), SQLTableMention(schema: "shop", name: "sales", alias: "s"))
    }

    func testMentionsCoverJoinsCommaListsAndQuotedNames() {
        let joined = context("SELECT * FROM customers c LEFT JOIN orders o ON o.customer_id = c.id, \"Audit\" a")
        XCTAssertEqual(
            joined.tables,
            [
                SQLTableMention(name: "customers", alias: "c"),
                SQLTableMention(name: "orders", alias: "o"),
            ])
        let list = context("SELECT * FROM customers c, orders o WHERE ")
        XCTAssertEqual(list.tables.map(\.name), ["customers", "orders"])
        XCTAssertEqual(list.tables.map(\.alias), ["c", "o"])
        let quoted = context("SELECT * FROM `my table` t WHERE ", dialect: .mysql)
        XCTAssertEqual(quoted.tables, [SQLTableMention(name: "my table", alias: "t")])
    }

    func testKeywordsAreNeverTakenForAliases() {
        let whereClause = context("SELECT * FROM customers WHERE ")
        XCTAssertEqual(whereClause.tables, [SQLTableMention(name: "customers")])
        let limit = context("SELECT * FROM customers LIMIT ")
        XCTAssertNil(limit.tables.first?.alias)
    }

    func testElsewhereIsUnconstrained() {
        XCTAssertEqual(context("sel").expecting, .any)
        XCTAssertEqual(context("sel").prefix, "sel")
        XCTAssertEqual(context("SELECT * FROM customers c ").expecting, .any)
        XCTAssertEqual(context("SELECT * FROM customers LIMIT ").expecting, .any)
    }

    func testCaretInsideAStatementUsesOnlyWhatIsBeforeIt() {
        let inside = context("SELECT | FROM customers WHERE id = 1")
        XCTAssertEqual(inside.expecting, .columns)
        XCTAssertEqual(inside.prefix, "")
        let midWord = context("SELECT na|me FROM customers")
        XCTAssertEqual(midWord.prefix, "na")
    }
}
