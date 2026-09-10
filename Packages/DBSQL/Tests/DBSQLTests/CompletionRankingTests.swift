import XCTest

@testable import DBSQL

final class CompletionRankingTests: XCTestCase {
    private struct Candidate: Equatable {
        let text: String
        let isKeyword: Bool
    }

    private func order(_ items: [Candidate], prefix: String) -> [String] {
        SQLCompletionRanking.order(items, prefix: prefix, text: \.text, isKeyword: \.isKeyword).map(\.text)
    }

    /// The reported case: `fro` on MySQL offered three functions above FROM.
    func testExactKeywordBeatsFunctionsSharingThePrefix() {
        let items = [
            Candidate(text: "FROM_BASE64", isKeyword: false),
            Candidate(text: "FROM_DAYS", isKeyword: false),
            Candidate(text: "FROM_UNIXTIME", isKeyword: false),
            Candidate(text: "FROM", isKeyword: true),
        ]
        XCTAssertEqual(order(items, prefix: "fro"), ["FROM", "FROM_BASE64", "FROM_DAYS", "FROM_UNIXTIME"])
        XCTAssertEqual(order(items, prefix: "FROM"), ["FROM", "FROM_BASE64", "FROM_DAYS", "FROM_UNIXTIME"])
    }

    func testCommonKeywordsComeBeforeRareOnesInTheirUsualOrder() {
        let items = [
            Candidate(text: "OFFSET", isKeyword: true),
            Candidate(text: "ON", isKeyword: true),
            Candidate(text: "ONLY", isKeyword: true),
            Candidate(text: "OR", isKeyword: true),
            Candidate(text: "ORDER", isKeyword: true),
            Candidate(text: "OUTER", isKeyword: true),
            Candidate(text: "OVER", isKeyword: true),
        ]
        XCTAssertEqual(order(items, prefix: "o"), ["ORDER", "ON", "OR", "OFFSET", "ONLY", "OUTER", "OVER"])
        XCTAssertEqual(order(items, prefix: "or"), ["OR", "ORDER", "OVER", "OUTER"])
    }

    func testExactMatchWinsOverACommonKeyword() {
        let items = [
            Candidate(text: "SELECT", isKeyword: true),
            Candidate(text: "SET", isKeyword: true),
        ]
        XCTAssertEqual(order(items, prefix: "set"), ["SET", "SELECT"])
    }

    /// A function or column that happens to be named like a common keyword does not
    /// get the keyword tier; the context's own order stands.
    func testOnlyKeywordsGetTheCommonTier() {
        let items = [
            Candidate(text: "order_id", isKeyword: false),
            Candidate(text: "ORDER", isKeyword: true),
            Candidate(text: "OR", isKeyword: true),
        ]
        XCTAssertEqual(order(items, prefix: "or"), ["OR", "ORDER", "order_id"])
        XCTAssertEqual(order(items, prefix: "ord"), ["ORDER", "order_id"])
        // A function named like a keyword stays where the context put it.
        let functions = [
            Candidate(text: "date_trunc", isKeyword: false),
            Candidate(text: "DATE", isKeyword: false),
        ]
        XCTAssertEqual(order(functions, prefix: "dat"), ["date_trunc", "DATE"])
        XCTAssertEqual(order(functions, prefix: "date"), ["DATE", "date_trunc"])
    }

    func testOrderIsStableAndEmptyPrefixIsUntouched() {
        let items = [
            Candidate(text: "b_col", isKeyword: false),
            Candidate(text: "a_col", isKeyword: false),
            Candidate(text: "BY", isKeyword: true),
        ]
        XCTAssertEqual(order(items, prefix: ""), ["b_col", "a_col", "BY"])
        XCTAssertEqual(order(items, prefix: "x"), [])
        XCTAssertEqual(order(items, prefix: "col"), ["b_col", "a_col"])
    }

    /// The request: `kel`, `asekel` and `ak` all offer `aset_kelompok`, and a table
    /// starting with the letters still comes first.
    func testLettersInsideANameStillOfferIt() {
        let items = [
            Candidate(text: "aset_bidang", isKeyword: false),
            Candidate(text: "aset_kelompok", isKeyword: false),
            Candidate(text: "kelurahan", isKeyword: false),
        ]
        XCTAssertEqual(order(items, prefix: "kel"), ["kelurahan", "aset_kelompok"])
        XCTAssertEqual(order(items, prefix: "asekel"), ["aset_kelompok"])
        XCTAssertEqual(order(items, prefix: "ak"), ["aset_kelompok"])
        XCTAssertEqual(order(items, prefix: "ab"), ["aset_bidang"])
    }

    /// A common keyword only jumps the queue when the letters start it; `ord` is ORDER,
    /// but `rd` merely contains it.
    func testCommonKeywordNeedsAPrefixMatch() {
        let items = [
            Candidate(text: "rd_code", isKeyword: false),
            Candidate(text: "ORDER", isKeyword: true),
        ]
        XCTAssertEqual(order(items, prefix: "rd"), ["rd_code", "ORDER"])
        XCTAssertEqual(order(items, prefix: "ord"), ["ORDER"])
    }

    func testEveryCommonKeywordIsAKnownKeyword() {
        for keyword in SQLCompletionRanking.commonKeywords {
            XCTAssertTrue(SQLTokenizer.keywords.contains(keyword), keyword)
        }
        XCTAssertEqual(SQLCompletionRanking.commonKeywordRank("from"), 1)
        XCTAssertNil(SQLCompletionRanking.commonKeywordRank("LATERAL"))
    }
}
