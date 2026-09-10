import DBCore
import Foundation

/// Puts the suggestion a person most likely wants at the top of the completion list.
///
/// Candidates are matched fuzzily (`FuzzyMatch`: `kel` finds `aset_kelompok`) and then
/// ordered so the obvious answer is first:
///
/// 1. what was typed in full (`from` → `FROM`, `date` → `DATE`),
/// 2. the keywords every statement is made of (`FROM`, `WHERE`, `ORDER`, `JOIN`…) when
///    the typed letters start them, in the order they are usually reached for — so
///    `fro` gives `FROM` before MySQL's `FROM_BASE64`,
/// 3. everything else by how well it matches: prefix, word start, run, scattered letters.
///
/// The sort is stable, so within a grade the caller's order (columns before functions
/// before other keywords, each alphabetical) is kept.
public enum SQLCompletionRanking {
    /// The clause and operator keywords people type most, most common first. Anything
    /// not here is an ordinary keyword and stays behind the context's own candidates.
    public static let commonKeywords: [String] = [
        "SELECT", "FROM", "WHERE", "ORDER", "BY", "GROUP", "JOIN", "LEFT", "INNER", "ON", "AND", "OR",
        "LIMIT", "OFFSET", "HAVING", "AS", "DISTINCT", "INSERT", "INTO", "VALUES", "UPDATE", "SET",
        "DELETE", "NOT", "NULL", "IN", "IS", "LIKE", "BETWEEN", "ASC", "DESC", "UNION", "CASE",
        "WHEN", "THEN", "ELSE", "END", "EXISTS", "WITH", "CREATE", "TABLE", "ALTER", "DROP",
    ]

    private static let commonRank: [String: Int] = {
        var rank: [String: Int] = [:]
        for (index, keyword) in commonKeywords.enumerated() { rank[keyword] = index }
        return rank
    }()

    /// The position of `keyword` among the common keywords, or nil for any other word.
    public static func commonKeywordRank(_ keyword: String) -> Int? {
        commonRank[keyword.uppercased()]
    }

    private struct Ranked<T> {
        let index: Int
        let item: T
        let grade: Int
        let rank: Int
        let penalty: Int

        var key: (Int, Int, Int, Int) { (grade, rank, penalty, index) }
    }

    /// The items of `items` that match `prefix`, best first. `text` is a candidate's
    /// name and `isKeyword` says whether it is a keyword (only keywords get the common
    /// tier). With nothing typed every item is kept in its order.
    public static func order<T>(
        _ items: [T], prefix: String, text: (T) -> String, isKeyword: (T) -> Bool
    ) -> [T] {
        guard !prefix.isEmpty else { return items }
        var ranked: [Ranked<T>] = []
        ranked.reserveCapacity(items.count)
        for (index, item) in items.enumerated() {
            let name = text(item)
            guard let match = FuzzyMatch.match(prefix, in: name) else { continue }
            if match.tier == .exact {
                ranked.append(Ranked(index: index, item: item, grade: 0, rank: 0, penalty: 0))
            } else if isKeyword(item), match.tier == .prefix, let rank = commonRank[name.uppercased()] {
                ranked.append(Ranked(index: index, item: item, grade: 1, rank: rank, penalty: 0))
            } else {
                // Among prefix matches the caller's (alphabetical) order stands; once the
                // letters sit inside the name, the fewer skipped the better.
                let penalty = match.tier >= .substring ? match.penalty : 0
                ranked.append(Ranked(index: index, item: item, grade: 2, rank: match.tier.rawValue, penalty: penalty))
            }
        }
        ranked.sort { $0.key < $1.key }
        return ranked.map(\.item)
    }
}
