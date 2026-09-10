import XCTest

@testable import DBCore

final class FuzzyMatchTests: XCTestCase {
    /// The request: `kel`, `asekel` and `ak` all find `aset_kelompok`.
    func testLettersInOrderFindTheName() {
        XCTAssertEqual(FuzzyMatch.match("kel", in: "aset_kelompok")?.tier, .wordStart)
        XCTAssertEqual(FuzzyMatch.match("kel", in: "aset_kelompok")?.positions, [5, 6, 7])
        XCTAssertEqual(FuzzyMatch.match("asekel", in: "aset_kelompok")?.tier, .subsequence)
        XCTAssertEqual(FuzzyMatch.match("asekel", in: "aset_kelompok")?.positions, [0, 1, 2, 5, 6, 7])
        XCTAssertEqual(FuzzyMatch.match("ak", in: "aset_kelompok")?.tier, .subsequence)
        XCTAssertEqual(FuzzyMatch.match("ak", in: "aset_kelompok")?.positions, [0, 5])
        XCTAssertNil(FuzzyMatch.match("kela", in: "aset_kelompok"))
        XCTAssertNil(FuzzyMatch.match("xyz", in: "aset_kelompok"))
    }

    func testTiersFromBestToWorst() {
        XCTAssertEqual(FuzzyMatch.match("From", in: "FROM")?.tier, .exact)
        XCTAssertEqual(FuzzyMatch.match("fro", in: "FROM_DAYS")?.tier, .prefix)
        XCTAssertEqual(FuzzyMatch.match("days", in: "FROM_DAYS")?.tier, .wordStart)
        XCTAssertEqual(FuzzyMatch.match("ays", in: "FROM_DAYS")?.tier, .substring)
        XCTAssertEqual(FuzzyMatch.match("fds", in: "FROM_DAYS")?.tier, .subsequence)
        let ordered: [FuzzyMatch.Tier] = [.exact, .prefix, .wordStart, .substring, .subsequence]
        XCTAssertEqual(ordered, ordered.sorted())
    }

    func testCamelCaseAndSeparatorsStartWords() {
        XCTAssertEqual(FuzzyMatch.match("count", in: "rowCount")?.tier, .wordStart)
        XCTAssertEqual(FuzzyMatch.match("id", in: "user.id")?.tier, .wordStart)
        XCTAssertEqual(FuzzyMatch.match("kota", in: "Jakarta Kota")?.tier, .wordStart)
    }

    /// Word starts are preferred when letters scatter: `sk` lands on the `s` of `sub` and
    /// the `k` of `kelompok`, not on the `s` inside `aset`.
    func testScatteredLettersPreferWordStarts() {
        XCTAssertEqual(FuzzyMatch.match("sk", in: "aset_sub_kelompok")?.positions, [5, 9])
        // A run inside a word still beats scattered word starts.
        XCTAssertEqual(FuzzyMatch.match("ak", in: "aset_paket_kelompok")?.tier, .substring)
        XCTAssertEqual(FuzzyMatch.match("ak", in: "aset_paket_kelompok")?.positions, [6, 7])
        // When no word start carries the letter, the nearest one is taken.
        XCTAssertEqual(FuzzyMatch.match("akt", in: "aset_paket")?.positions, [0, 7, 9])
    }

    func testMultiWordQueryNeedsEveryWord() {
        XCTAssertNotNil(FuzzyMatch.match("open tab", in: "Open Table in New Tab"))
        XCTAssertNil(FuzzyMatch.match("open zzz", in: "Open Table in New Tab"))
        XCTAssertEqual(FuzzyMatch.match("new tab", in: "Open Table in New Tab")?.tier, .wordStart)
    }

    func testFilterOrdersBestFirstAndKeepsTiesStable() {
        let names = ["user_sessions", "usr_log", "users", "measures", "sessions_users", "USR"]
        // `measures` has no `r` after its `us`; equally scattered letters rank the shorter name first.
        XCTAssertEqual(
            FuzzyMatch.filter(names, query: "usr", text: { $0 }),
            ["USR", "usr_log", "users", "user_sessions", "sessions_users"]
        )
        XCTAssertEqual(FuzzyMatch.filter(names, query: "", text: { $0 }), names)
        XCTAssertEqual(FuzzyMatch.filter(names, query: "   ", text: { $0 }), names)
    }

    func testShorterPrefixMatchRanksFirst() {
        let names = ["FROM_UNIXTIME", "FROM_DAYS", "FROM"]
        XCTAssertEqual(FuzzyMatch.filter(names, query: "fro", text: { $0 }), ["FROM", "FROM_DAYS", "FROM_UNIXTIME"])
    }

    func testEmptyAndOverlongQueries() {
        XCTAssertEqual(FuzzyMatch.match("", in: "anything")?.tier, .prefix)
        XCTAssertNil(FuzzyMatch.match("toolong", in: "top"))
        XCTAssertNil(FuzzyMatch.match("a", in: ""))
    }
}
