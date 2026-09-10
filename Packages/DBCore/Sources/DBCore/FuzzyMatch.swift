import Foundation

/// How well a typed query fits a name, the way every search field in the app matches.
///
/// The query is matched as a subsequence: its letters must appear in the name in order,
/// not necessarily next to each other. So `kel`, `asekel` and `ak` all find
/// `aset_kelompok`. Matches are graded so the obvious one comes first: the whole word,
/// then a prefix, then a run starting at a word boundary (`kel` at the `k` of
/// `kelompok`), then a run anywhere, then scattered letters — the fewer letters skipped,
/// the better.
///
/// A query of several words (`open tab`) matches when every word does; its grade is the
/// worst word's.
public struct FuzzyMatch: Sendable, Hashable, Comparable {
    /// Grades from best to worst.
    public enum Tier: Int, Sendable, Comparable {
        /// The name is the query.
        case exact = 0
        /// The name starts with the query.
        case prefix
        /// The query is a run inside the name starting at a word boundary.
        case wordStart
        /// The query is a run inside the name.
        case substring
        /// The query's letters are spread through the name.
        case subsequence

        public static func < (lhs: Tier, rhs: Tier) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public let tier: Tier
    /// Lower is better within a tier: letters skipped before and between the matched ones.
    public let penalty: Int
    /// Character offsets in the name the query letters landed on, for highlighting.
    public let positions: [Int]

    public init(tier: Tier, penalty: Int, positions: [Int]) {
        self.tier = tier
        self.penalty = penalty
        self.positions = positions
    }

    public static func < (lhs: FuzzyMatch, rhs: FuzzyMatch) -> Bool {
        (lhs.tier.rawValue, lhs.penalty) < (rhs.tier.rawValue, rhs.penalty)
    }

    /// The match of `query` against `name`, or nil when the letters are not there in
    /// order. Case-insensitive. An empty query matches everything as a prefix.
    public static func match(_ query: String, in name: String) -> FuzzyMatch? {
        let words = query.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return FuzzyMatch(tier: .prefix, penalty: 0, positions: []) }
        let target = Target(name)
        if words.count == 1 { return matchWord(Array(words[0].lowercased()), in: target) }
        var tier = Tier.exact
        var penalty = 0
        var positions: Set<Int> = []
        for word in words {
            guard let found = matchWord(Array(word.lowercased()), in: target) else { return nil }
            tier = max(tier, found.tier)
            penalty += found.penalty
            positions.formUnion(found.positions)
        }
        return FuzzyMatch(tier: tier, penalty: penalty, positions: positions.sorted())
    }

    private struct Scored<T> {
        let index: Int
        let match: FuzzyMatch
        let length: Int
        let item: T

        var key: (Int, Int, Int, Int) { (match.tier.rawValue, match.penalty, length, index) }
    }

    /// `items` that match `query`, best first: by grade, then by letters skipped, then
    /// the shorter name (`usr` puts `users` before `user_sessions`), then their order.
    /// An empty query returns `items` untouched.
    public static func filter<T>(_ items: [T], query: String, text: (T) -> String) -> [T] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return items }
        var scored: [Scored<T>] = []
        for (index, item) in items.enumerated() {
            let name = text(item)
            guard let found = match(query, in: name) else { continue }
            scored.append(Scored(index: index, match: found, length: name.count, item: item))
        }
        scored.sort { $0.key < $1.key }
        return scored.map(\.item)
    }

    /// Whether `name` matches `query` at all.
    public static func matches(_ query: String, in name: String) -> Bool {
        match(query, in: name) != nil
    }

    // MARK: - Matching one word

    private struct Target {
        let lower: [Character]
        /// Whether each offset starts a word: the first letter, the letter after a
        /// separator, or a capital after a lower-case letter (`rowCount`).
        let isWordStart: [Bool]

        init(_ name: String) {
            let original = Array(name)
            let lower = Array(name.lowercased())
            self.lower = lower
            // Lower-casing can change a string's length (`İ`); then only separators count.
            let sameLength = original.count == lower.count
            var starts = [Bool](repeating: false, count: lower.count)
            for index in lower.indices {
                if index == 0 {
                    starts[index] = true
                } else if Self.separators.contains(lower[index - 1]) {
                    starts[index] = true
                } else if sameLength, original[index].isUppercase, original[index - 1].isLowercase {
                    starts[index] = true
                }
            }
            isWordStart = starts
        }

        private static let separators: Set<Character> = ["_", " ", ".", "-", "/", ":"]
    }

    private static func matchWord(_ query: [Character], in target: Target) -> FuzzyMatch? {
        let name = target.lower
        guard !query.isEmpty else { return FuzzyMatch(tier: .prefix, penalty: 0, positions: []) }
        guard query.count <= name.count else { return nil }
        if query == name { return FuzzyMatch(tier: .exact, penalty: 0, positions: Array(name.indices)) }
        if name.starts(with: query) {
            return FuzzyMatch(tier: .prefix, penalty: name.count - query.count, positions: Array(0 ..< query.count))
        }
        // A run inside the name: the first one at a word boundary, else the first at all.
        var firstRun: Int?
        for start in stride(from: 1, through: name.count - query.count, by: 1) where name[start] == query[0] {
            guard name[start ..< start + query.count].elementsEqual(query) else { continue }
            if target.isWordStart[start] {
                return FuzzyMatch(
                    tier: .wordStart, penalty: start, positions: Array(start ..< start + query.count))
            }
            if firstRun == nil { firstRun = start }
        }
        if let start = firstRun {
            return FuzzyMatch(tier: .substring, penalty: start, positions: Array(start ..< start + query.count))
        }
        // Scattered letters: try to land each on a word start first (`ak` on the `a` and
        // the `k` of `aset_kelompok`), and fall back to the nearest letter when that runs
        // out of name.
        if let positions = subsequence(query, in: name, preferringWordStarts: target.isWordStart) {
            return FuzzyMatch(tier: .subsequence, penalty: penalty(of: positions), positions: positions)
        }
        if let positions = subsequence(query, in: name, preferringWordStarts: nil) {
            return FuzzyMatch(tier: .subsequence, penalty: penalty(of: positions), positions: positions)
        }
        return nil
    }

    private static func subsequence(
        _ query: [Character], in name: [Character], preferringWordStarts wordStarts: [Bool]?
    ) -> [Int]? {
        var positions: [Int] = []
        positions.reserveCapacity(query.count)
        var from = 0
        for letter in query {
            var found: Int?
            if let wordStarts {
                var index = from
                while index < name.count {
                    if name[index] == letter, wordStarts[index] {
                        found = index
                        break
                    }
                    index += 1
                }
            }
            if found == nil {
                var index = from
                while index < name.count {
                    if name[index] == letter {
                        found = index
                        break
                    }
                    index += 1
                }
            }
            guard let found else { return nil }
            positions.append(found)
            from = found + 1
        }
        return positions
    }

    /// Letters skipped before the first hit and between hits.
    private static func penalty(of positions: [Int]) -> Int {
        guard let first = positions.first, let last = positions.last else { return 0 }
        return last - first + 1 - positions.count + first
    }
}
