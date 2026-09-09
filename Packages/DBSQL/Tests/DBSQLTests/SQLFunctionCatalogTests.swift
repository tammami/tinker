import DBCore
import XCTest

@testable import DBSQL

/// The function lists behind the editor's completion: every engine has one, the names are
/// unique within it, and the date functions a person reaches for are there.
final class SQLFunctionCatalogTests: XCTestCase {
    func testEveryEngineHasACatalogWithUniqueNames() {
        for dialect in SQLDialect.allCases {
            let functions = SQLFunctionCatalog.functions(for: dialect)
            XCTAssertGreaterThan(functions.count, 100, "\(dialect) has too few functions")
            let ids = functions.map(\.id)
            XCTAssertEqual(ids.count, Set(ids).count, "\(dialect) lists a function twice")
            XCTAssertTrue(functions.allSatisfy { !$0.summary.isEmpty && !$0.name.isEmpty }, dialect.rawValue)
        }
    }

    func testDateFunctionsAreOfferedForDA() {
        let mysql = SQLFunctionCatalog.matching(prefix: "da", dialect: .mysql).map(\.name)
        XCTAssertTrue(mysql.contains("DATE"), mysql.joined(separator: ","))
        XCTAssertTrue(mysql.contains("DATE_FORMAT"))
        XCTAssertTrue(mysql.contains("DAY"))
        XCTAssertTrue(mysql.contains("DAYNAME"))
        XCTAssertTrue(mysql.contains("DATABASE"))
        XCTAssertFalse(mysql.contains("MONTH"), "a prefix match, not a category match")

        let postgres = SQLFunctionCatalog.matching(prefix: "date_", dialect: .postgresql).map(\.name)
        XCTAssertEqual(postgres, ["date_bin", "date_part", "date_trunc"])

        let sqlite = SQLFunctionCatalog.matching(prefix: "DATE", dialect: .sqlite).map(\.name)
        XCTAssertEqual(sqlite, ["date", "datetime"], "case does not matter")
    }

    func testSignaturesAndInsertionsFollowTheParentheses() {
        let date = SQLFunctionCatalog.functions(for: .mysql).first { $0.name == "DATE" }!
        XCTAssertEqual(date.signature, "DATE(expr)")
        XCTAssertEqual(date.insertion, "DATE()")
        XCTAssertFalse(date.takesNoParentheses)
        XCTAssertEqual(date.category, .dateTime)

        let now = SQLFunctionCatalog.functions(for: .mysql).first { $0.name == "CURRENT_TIMESTAMP" }!
        XCTAssertEqual(now.signature, "CURRENT_TIMESTAMP")
        XCTAssertEqual(now.insertion, "CURRENT_TIMESTAMP")
        XCTAssertTrue(now.takesNoParentheses)

        let extract = SQLFunctionCatalog.functions(for: .postgresql).first { $0.name == "extract" }!
        XCTAssertEqual(extract.signature, "extract(field FROM source)")
    }

    func testEveryCategoryIsUsedSomewhere() {
        let used = Set(SQLDialect.allCases.flatMap { SQLFunctionCatalog.functions(for: $0).map(\.category) })
        for category in SQLFunctionCategory.allCases {
            XCTAssertTrue(used.contains(category), "\(category.rawValue) has no functions in any engine")
        }
    }

    func testNamesForTheHighlighterAreLowerCased() {
        let names = SQLFunctionCatalog.names(for: .mysql)
        XCTAssertTrue(names.contains("date_format"))
        XCTAssertFalse(names.contains("DATE_FORMAT"))
    }
}
