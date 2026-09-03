import DBCore
import XCTest
@testable import DBSQL

final class QuickSearchAndSnippetTests: XCTestCase {
    func testAnyContainsBindsThePatternOncePerColumn() {
        let rule = FilterRule.search("bob", in: ["name", "email"])
        let pg = FilterCompiler.compile([rule], dialect: .postgresql)
        XCTAssertEqual(
            pg.whereClause,
            #"("name"::text ILIKE $1 ESCAPE '!' OR "email"::text ILIKE $2 ESCAPE '!')"#
        )
        XCTAssertEqual(pg.parameters, [.string("%bob%"), .string("%bob%")])

        let my = FilterCompiler.compile([rule], dialect: .mysql)
        XCTAssertEqual(
            my.whereClause,
            #"(CAST(`name` AS CHAR) LIKE ? ESCAPE '!' OR CAST(`email` AS CHAR) LIKE ? ESCAPE '!')"#
        )
        XCTAssertEqual(my.parameters.count, 2)
    }

    func testAnyContainsEscapesWildcardsAndSkipsEmptyInput() {
        let rule = FilterRule.search("50%_off", in: ["label"])
        let compiled = FilterCompiler.compile([rule], dialect: .postgresql)
        XCTAssertEqual(compiled.parameters, [.string("%50!%!_off%")])

        let empty = FilterCompiler.compile([FilterRule.search("   ", in: ["a"])], dialect: .postgresql)
        XCTAssertNotNil(empty.whereClause, "whitespace is a search like any other; the caller trims")
        let blank = FilterCompiler.compile([FilterRule.search("", in: ["a"])], dialect: .postgresql)
        XCTAssertNil(blank.whereClause)
        let noColumns = FilterCompiler.compile([FilterRule.search("x", in: [])], dialect: .postgresql)
        XCTAssertNil(noColumns.whereClause)
    }

    func testAnyContainsCombinesWithOrdinaryRulesUsingAnd() {
        let rules = [
            FilterRule(column: "id", op: .greaterThan, values: [.int(10)]),
            FilterRule.search("x", in: ["a", "b"]),
        ]
        let compiled = FilterCompiler.compile(rules, dialect: .postgresql)
        XCTAssertEqual(
            compiled.whereClause,
            #""id" > $1 AND ("a"::text ILIKE $2 ESCAPE '!' OR "b"::text ILIKE $3 ESCAPE '!')"#
        )
        XCTAssertEqual(compiled.parameters.count, 3)
    }

    func testSnippetExpansionSelectsTheFirstPlaceholder() {
        let expansion = SnippetTemplate.expand("SELECT * FROM ${1:table} WHERE ${2:id} = $3;$0")
        XCTAssertEqual(expansion.text, "SELECT * FROM table WHERE id = ;")
        XCTAssertEqual(expansion.selection, 14 ..< 19)
    }

    func testSnippetWithoutPlaceholdersIsUnchanged() {
        let expansion = SnippetTemplate.expand("SELECT now();")
        XCTAssertEqual(expansion.text, "SELECT now();")
        XCTAssertNil(expansion.selection)
    }

    func testSnippetKeepsDollarQuotedBodiesAndBareDollars() {
        // `$$` and `$body$` are PostgreSQL, not placeholders, and must survive.
        let source = "CREATE FUNCTION f() RETURNS int AS $$ SELECT 1 $$ LANGUAGE sql; -- costs $"
        XCTAssertEqual(SnippetTemplate.expand(source).text, source)
        let unterminated = SnippetTemplate.expand("x ${1:abc")
        XCTAssertEqual(unterminated.text, "x ${1:abc")
    }

    func testFinalCaretWinsWhenThereIsNoDefaultText() {
        let expansion = SnippetTemplate.expand("BEGIN;\n$0\nCOMMIT;")
        XCTAssertEqual(expansion.text, "BEGIN;\n\nCOMMIT;")
        XCTAssertEqual(expansion.selection, 7 ..< 7)
    }
}
