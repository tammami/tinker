import DBCore
import Foundation

/// Turns a view's definition back into a query-builder canvas, for the subset of SQL the
/// builder can draw.
///
/// A view made elsewhere has no remembered canvas (`ViewBuilderSidecar`), so its text is
/// read instead: `SELECT` items, `FROM` with joins, `WHERE`, `GROUP BY`, `HAVING`,
/// `ORDER BY`, `LIMIT`/`OFFSET`. Whatever the canvas has no shape for — a subquery, an
/// expression, nested condition groups, a join on more than one column — stops the import
/// with a reason the user reads, rather than a canvas that silently means something else.
/// The text is what the server hands back, so PostgreSQL's reformatting (`sum(o.total) AS
/// total`, casts like `'ok'::mood`) and MySQL's (`CREATE ALGORITHM… VIEW … AS select …`,
/// every column aliased, parentheses around joins) are both expected.
public enum QueryBuilderImporter {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case noSelect
        case unknownTable(String)
        case unknownColumnOwner(String)
        case unsupported(String)

        public var description: String {
            switch self {
            case .noSelect: "no SELECT statement was found"
            case let .unknownTable(name): "the table \(name) is not in this schema"
            case let .unknownColumnOwner(column): "the column \(column) does not say which table it belongs to"
            case let .unsupported(what): "the canvas cannot show \(what)"
            }
        }
    }

    /// Reads `sql` into a canvas. `resolveTable` maps a table name, with the schema or
    /// database prefix the text gave it (if any), to a table the schema holds.
    public static func model(
        from sql: String,
        dialect: SQLDialect,
        resolveTable: @escaping (_ name: String, _ qualifier: String?) -> TableRef?
    ) throws -> QueryBuilderModel {
        var parser = Parser(tokens: Lexer.tokens(sql, dialect: dialect), resolveTable: resolveTable)
        return try parser.parse()
    }

    // MARK: - Lexing

    /// A token with quotes stripped and two-character operators joined.
    struct Word: Equatable {
        enum Kind { case word, quoted, string, number, symbol }
        let kind: Kind
        let text: String

        var upper: String { text.uppercased() }
        /// Whether this is the bare or quoted name `name`, case-insensitively for bare ones.
        func isWord(_ keyword: String) -> Bool { kind == .word && upper == keyword }
        func isSymbol(_ symbol: String) -> Bool { kind == .symbol && text == symbol }
        var isName: Bool { kind == .word || kind == .quoted }
    }

    enum Lexer {
        static func tokens(_ sql: String, dialect: SQLDialect) -> [Word] {
            var words: [Word] = []
            for token in SQLTokenizer.tokenize(sql, dialect: dialect) {
                switch token.kind {
                case .whitespace, .comment:
                    continue
                case .keyword, .identifier:
                    words.append(Word(kind: .word, text: token.text))
                case .quotedIdentifier:
                    words.append(Word(kind: .quoted, text: unquote(token.text)))
                case .string:
                    words.append(Word(kind: .string, text: unquoteString(token.text)))
                case .number:
                    words.append(Word(kind: .number, text: token.text))
                case .parameter:
                    words.append(Word(kind: .symbol, text: token.text))
                case .punctuation:
                    // The tokenizer may hand back one character at a time; `<>`, `<=`,
                    // `>=`, `!=` and `::` are one operator each.
                    if let last = words.last, last.kind == .symbol,
                        ["<>", "<=", ">=", "!=", "::"].contains(last.text + token.text)
                    {
                        words[words.count - 1] = Word(kind: .symbol, text: last.text + token.text)
                    } else if token.text.count > 1 {
                        for character in token.text { words.append(Word(kind: .symbol, text: String(character))) }
                        // Re-join pairs split by the loop above.
                        var index = words.count - token.text.count
                        while index + 1 < words.count {
                            let pair = words[index].text + words[index + 1].text
                            if ["<>", "<=", ">=", "!=", "::"].contains(pair) {
                                words.replaceSubrange(index ... index + 1, with: [Word(kind: .symbol, text: pair)])
                            } else {
                                index += 1
                            }
                        }
                    } else {
                        words.append(Word(kind: .symbol, text: token.text))
                    }
                }
            }
            return words
        }

        static func unquote(_ text: String) -> String {
            guard text.count >= 2, let first = text.first, let last = text.last,
                (first == "\"" && last == "\"") || (first == "`" && last == "`") || (first == "[" && last == "]")
            else { return text }
            let inner = String(text.dropFirst().dropLast())
            return first == "\""
                ? inner.replacingOccurrences(of: "\"\"", with: "\"") : inner.replacingOccurrences(of: "``", with: "`")
        }

        static func unquoteString(_ text: String) -> String {
            var body = text
            if body.hasPrefix("E'") || body.hasPrefix("e'") { body.removeFirst() }
            guard body.count >= 2, body.hasPrefix("'"), body.hasSuffix("'") else { return text }
            return String(body.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
    }

    // MARK: - Parsing

    /// A column reference as written: an optional owner (alias or table name) and the name.
    struct ColumnRef: Equatable {
        var owner: String?
        var column: String
        var display: String { owner.map { "\($0).\(column)" } ?? column }
    }

    struct SelectItem {
        var ref: ColumnRef?  // nil with star == true means `*`
        var star = false
        var aggregate: QueryBuilderModel.Aggregate = .none
        var alias: String?
    }

    struct ConditionItem {
        var ref: ColumnRef
        var op: FilterOperator
        var values: [DBValue]
        var conjunction: QueryBuilderModel.Condition.Conjunction
    }

    struct Parser {
        var tokens: [Word]
        let resolveTable: (String, String?) -> TableRef?
        var position = 0

        init(tokens: [Word], resolveTable: @escaping (String, String?) -> TableRef?) {
            self.tokens = tokens
            self.resolveTable = resolveTable
        }

        static let clauseStarters = [
            "FROM", "WHERE", "GROUP", "HAVING", "ORDER", "LIMIT", "OFFSET", "UNION", "EXCEPT", "INTERSECT",
        ]
        static let joinWords = ["JOIN", "LEFT", "RIGHT", "FULL", "INNER", "CROSS", "NATURAL", "OUTER", "ON", "USING"]

        var current: Word? { position < tokens.count ? tokens[position] : nil }
        func peek(_ offset: Int = 1) -> Word? { position + offset < tokens.count ? tokens[position + offset] : nil }
        mutating func advance() { position += 1 }

        mutating func take(word: String) -> Bool {
            guard current?.isWord(word) == true else { return false }
            advance()
            return true
        }

        mutating func take(symbol: String) -> Bool {
            guard current?.isSymbol(symbol) == true else { return false }
            advance()
            return true
        }

        mutating func skip(symbol: String) -> Int {
            var count = 0
            while take(symbol: symbol) { count += 1 }
            return count
        }

        func atClauseStart() -> Bool {
            guard let current else { return true }
            if current.isSymbol(";") { return true }
            return Self.clauseStarters.contains(current.upper) && current.kind == .word
        }

        // MARK: Statement

        mutating func parse() throws -> QueryBuilderModel {
            // `CREATE … VIEW name AS SELECT …` or a bare SELECT: start at the SELECT.
            guard let start = tokens.firstIndex(where: { $0.isWord("SELECT") }) else { throw Failure.noSelect }
            position = start + 1
            var model = QueryBuilderModel()
            model.isDistinct = take(word: "DISTINCT")
            _ = take(word: "ALL")

            let items = try selectList()
            guard take(word: "FROM") else { throw Failure.unsupported("a SELECT without FROM") }
            var tables: [(ref: TableRef, alias: String)] = []
            var joins: [(kind: QueryBuilderModel.JoinKind, left: ColumnRef, right: ColumnRef)] = []
            try fromClause(into: &tables, joins: &joins)

            var conditions: [ConditionItem] = []
            if take(word: "WHERE") { conditions = try conditionList() }
            var groups: [ColumnRef] = []
            if take(word: "GROUP") {
                guard take(word: "BY") else { throw Failure.unsupported("GROUP without BY") }
                groups = try columnList()
            }
            var having: [ConditionItem] = []
            if take(word: "HAVING") { having = try conditionList() }
            var orderings: [(ColumnRef, Bool)] = []
            if take(word: "ORDER") {
                guard take(word: "BY") else { throw Failure.unsupported("ORDER without BY") }
                repeat {
                    let ref = try columnRef()
                    var ascending = true
                    if take(word: "DESC") { ascending = false } else { _ = take(word: "ASC") }
                    _ = take(word: "NULLS") && (take(word: "FIRST") || take(word: "LAST"))
                    orderings.append((ref, ascending))
                } while take(symbol: ",")
            }
            if take(word: "LIMIT") {
                guard let first = current, first.kind == .number, let n = Int(first.text) else {
                    throw Failure.unsupported("a LIMIT that is not a number")
                }
                advance()
                if take(symbol: ",") {
                    // MySQL: LIMIT offset, count
                    guard let second = current, second.kind == .number, let count = Int(second.text) else {
                        throw Failure.unsupported("a LIMIT that is not a number")
                    }
                    advance()
                    model.offset = n
                    model.limit = count
                } else {
                    model.limit = n
                }
            }
            if take(word: "OFFSET") {
                guard let word = current, word.kind == .number, let n = Int(word.text) else {
                    throw Failure.unsupported("an OFFSET that is not a number")
                }
                advance()
                model.offset = n
                _ = take(word: "ROWS") || take(word: "ROW")
            }
            _ = skip(symbol: ";")
            if let leftover = current {
                throw Failure.unsupported(leftover.isWord("UNION") ? "UNION" : "\"\(leftover.text)\" here")
            }

            // Resolve names against the placed tables.
            for (index, table) in tables.enumerated() {
                model.tables.append(
                    QueryBuilderModel.Table(ref: table.ref, alias: table.alias, x: 40 + Double(index) * 300, y: 60))
            }
            func owner(of ref: ColumnRef) throws -> UUID {
                if let owner = ref.owner {
                    if let match = model.tables.first(where: { $0.alias == owner }) { return match.id }
                    if let match = model.tables.first(where: { $0.ref.name == owner }) { return match.id }
                    throw Failure.unknownTable(owner)
                }
                guard model.tables.count == 1, let only = model.tables.first else {
                    throw Failure.unknownColumnOwner(ref.column)
                }
                return only.id
            }
            for join in joins {
                model.joins.append(
                    QueryBuilderModel.Join(
                        kind: join.kind,
                        leftTable: try owner(of: join.left), leftColumn: join.left.column,
                        rightTable: try owner(of: join.right), rightColumn: join.right.column))
            }
            for item in items {
                if item.star, item.ref == nil {
                    // `*`: every table's star, which the builder renders per table.
                    for table in model.tables { model.fields.append(.init(table: table.id, column: "*")) }
                } else if let ref = item.ref {
                    let table = try owner(of: ref)
                    // MySQL writes `c.id AS id` for every column: an alias that only repeats
                    // the name is none. An aggregate's alias is its name, and stays.
                    var alias = item.alias
                    if item.aggregate == .none, alias == ref.column { alias = nil }
                    model.fields.append(
                        .init(table: table, column: ref.column, aggregate: item.aggregate, alias: alias))
                }
            }
            model.conditions = try conditions.map {
                QueryBuilderModel.Condition(
                    table: try owner(of: $0.ref), column: $0.ref.column, op: $0.op, values: $0.values,
                    conjunction: $0.conjunction)
            }
            model.groupBy = try groups.map { QueryBuilderModel.Field(table: try owner(of: $0), column: $0.column) }
            model.having = try having.map {
                QueryBuilderModel.Condition(
                    table: try owner(of: $0.ref), column: $0.ref.column, op: $0.op, values: $0.values,
                    conjunction: $0.conjunction)
            }
            model.orderBy = try orderings.map {
                QueryBuilderModel.Ordering(table: try owner(of: $0.0), column: $0.0.column, ascending: $0.1)
            }
            return model
        }

        // MARK: Select list

        mutating func selectList() throws -> [SelectItem] {
            var items: [SelectItem] = []
            repeat {
                items.append(try selectItem())
            } while take(symbol: ",")
            return items
        }

        mutating func selectItem() throws -> SelectItem {
            guard let word = current else { throw Failure.unsupported("an empty select list") }
            if word.isSymbol("*") {
                advance()
                return SelectItem(ref: nil, star: true)
            }
            var item = SelectItem()
            if word.kind == .word, let aggregate = QueryBuilderModel.Aggregate(rawValue: word.upper),
                aggregate != .none, peek()?.isSymbol("(") == true
            {
                advance()
                advance()
                if take(word: "DISTINCT") { throw Failure.unsupported("\(aggregate.rawValue)(DISTINCT …)") }
                if take(symbol: "*") {
                    item.ref = nil
                    item.star = true
                } else {
                    item.ref = try columnRef()
                }
                guard take(symbol: ")") else {
                    throw Failure.unsupported("an expression inside \(aggregate.rawValue)()")
                }
                item.aggregate = aggregate
                if item.star {
                    // COUNT(*) belongs to no column; the builder writes it against the first table.
                    item.ref = ColumnRef(owner: nil, column: "*")
                }
            } else if word.kind == .word, peek()?.isSymbol("(") == true {
                throw Failure.unsupported("the function \(word.text)()")
            } else if word.isSymbol("(") {
                throw Failure.unsupported("a subquery or expression in the select list")
            } else if word.kind == .string || word.kind == .number {
                throw Failure.unsupported("a literal in the select list")
            } else if word.isWord("CASE") {
                throw Failure.unsupported("a CASE expression")
            } else {
                let ref = try columnRef()
                if ref.column == "*" {
                    item.star = true
                    item.ref = ref
                } else {
                    item.ref = ref
                }
                if current?.isSymbol("::") == true { throw Failure.unsupported("a cast in the select list") }
            }
            // Alias: `AS name`, or a bare name that is not a clause keyword.
            if take(word: "AS") {
                guard let alias = current, alias.isName else { throw Failure.unsupported("an alias without a name") }
                item.alias = alias.text
                advance()
            } else if let alias = current, alias.isName, !atClauseStart(), !Self.joinWords.contains(alias.upper) {
                item.alias = alias.text
                advance()
            }
            return item
        }

        // MARK: From

        mutating func fromClause(
            into tables: inout [(ref: TableRef, alias: String)],
            joins: inout [(kind: QueryBuilderModel.JoinKind, left: ColumnRef, right: ColumnRef)]
        ) throws {
            // Servers wrap join chains in parentheses; they carry no meaning the canvas needs.
            _ = skip(symbol: "(")
            tables.append(try tableItem())
            _ = skip(symbol: ")")
            while true {
                if take(symbol: ",") {
                    _ = skip(symbol: "(")
                    tables.append(try tableItem())
                    _ = skip(symbol: ")")
                    continue
                }
                var kind: QueryBuilderModel.JoinKind
                if take(word: "JOIN") || take(word: "INNER") {
                    kind = .inner
                    _ = take(word: "JOIN")
                } else if take(word: "LEFT") {
                    kind = .left
                    _ = take(word: "OUTER")
                    guard take(word: "JOIN") else { throw Failure.unsupported("LEFT without JOIN") }
                } else if take(word: "RIGHT") {
                    kind = .right
                    _ = take(word: "OUTER")
                    guard take(word: "JOIN") else { throw Failure.unsupported("RIGHT without JOIN") }
                } else if take(word: "FULL") {
                    kind = .full
                    _ = take(word: "OUTER")
                    guard take(word: "JOIN") else { throw Failure.unsupported("FULL without JOIN") }
                } else if take(word: "CROSS") {
                    kind = .cross
                    guard take(word: "JOIN") else { throw Failure.unsupported("CROSS without JOIN") }
                } else if current?.isWord("NATURAL") == true {
                    throw Failure.unsupported("NATURAL JOIN")
                } else {
                    break
                }
                _ = skip(symbol: "(")
                tables.append(try tableItem())
                _ = skip(symbol: ")")
                if kind == .cross {
                    continue
                }
                guard take(word: "ON") else {
                    if current?.isWord("USING") == true { throw Failure.unsupported("JOIN … USING") }
                    throw Failure.unsupported("a JOIN without ON")
                }
                _ = skip(symbol: "(")
                let left = try columnRef()
                guard take(symbol: "=") else { throw Failure.unsupported("a join condition that is not an equality") }
                let right = try columnRef()
                _ = skip(symbol: ")")
                if current?.isWord("AND") == true || current?.isWord("OR") == true {
                    throw Failure.unsupported("a join on more than one column")
                }
                joins.append((kind, left, right))
            }
        }

        mutating func tableItem() throws -> (ref: TableRef, alias: String) {
            guard let first = current, first.isName else {
                if current?.isSymbol("(") == true || current?.isWord("SELECT") == true {
                    throw Failure.unsupported("a subquery in FROM")
                }
                throw Failure.unsupported("a table name was expected")
            }
            advance()
            var qualifier: String?
            var name = first.text
            // `schema.table` / `database.table`, possibly three deep.
            while take(symbol: ".") {
                guard let next = current, next.isName else { throw Failure.unsupported("a name after \".\"") }
                qualifier = qualifier.map { "\($0).\(name)" } ?? name
                name = next.text
                advance()
            }
            if current?.isSymbol("(") == true { throw Failure.unsupported("the function \(name)() in FROM") }
            guard let ref = resolveTable(name, qualifier) else { throw Failure.unknownTable(name) }
            var alias = name
            if take(word: "AS") {
                guard let word = current, word.isName else { throw Failure.unsupported("an alias without a name") }
                alias = word.text
                advance()
            } else if let word = current, word.isName, !atClauseStart(), !Self.joinWords.contains(word.upper) {
                alias = word.text
                advance()
            }
            return (ref, alias)
        }

        // MARK: Columns

        mutating func columnRef() throws -> ColumnRef {
            guard let first = current, first.isName || first.isSymbol("*") else {
                throw Failure.unsupported("a column name was expected, not \"\(current?.text ?? "")\"")
            }
            advance()
            if first.isSymbol("*") { return ColumnRef(owner: nil, column: "*") }
            var parts = [first.text]
            while take(symbol: ".") {
                if take(symbol: "*") {
                    parts.append("*")
                    break
                }
                guard let next = current, next.isName else { throw Failure.unsupported("a name after \".\"") }
                parts.append(next.text)
                advance()
            }
            // `schema.table.column` keeps the table as owner; the schema is implied.
            let column = parts.removeLast()
            return ColumnRef(owner: parts.last, column: column)
        }

        mutating func columnList() throws -> [ColumnRef] {
            var refs: [ColumnRef] = []
            repeat {
                if current?.kind == .number { throw Failure.unsupported("a column given by number") }
                refs.append(try columnRef())
            } while take(symbol: ",")
            return refs
        }

        // MARK: Conditions

        /// Removes the parentheses that wrap an entire clause — PostgreSQL writes
        /// `WHERE ((a = 1) AND (b = 2))` — which group nothing the canvas cares about.
        mutating func stripClauseWrapping() {
            while current?.isSymbol("(") == true {
                var depth = 0
                var index = position
                var closes = -1
                scan: while index < tokens.count {
                    let word = tokens[index]
                    if word.isSymbol("(") {
                        depth += 1
                    } else if word.isSymbol(")") {
                        depth -= 1
                        if depth == 0 {
                            closes = index
                            break scan
                        }
                    } else if depth == 0 {
                        break scan
                    }
                    index += 1
                }
                guard closes > position else { return }
                // Wrapping only when the clause ends right after the matching parenthesis.
                let after = closes + 1
                let endsClause =
                    after >= tokens.count || tokens[after].isSymbol(";")
                    || (tokens[after].kind == .word && Self.clauseStarters.contains(tokens[after].upper))
                guard endsClause else { return }
                tokens.remove(at: closes)
                tokens.remove(at: position)
            }
        }

        mutating func conditionList() throws -> [ConditionItem] {
            stripClauseWrapping()
            var items: [ConditionItem] = []
            var conjunction: QueryBuilderModel.Condition.Conjunction = .and
            var depth = 0
            repeat {
                // Parentheses around a single comparison carry nothing; a group holding
                // several does, and the canvas has no rows for it.
                let opened = skip(symbol: "(")
                depth += opened
                var item = try conditionAtom()
                item.conjunction = conjunction
                items.append(item)
                let closed = skip(symbol: ")")
                depth -= closed
                if depth < 0 {
                    // Closing a paren the clause did not open: the whole clause was wrapped.
                    depth = 0
                }
                if current?.isWord("AND") == true || current?.isWord("OR") == true {
                    if depth > 0 { throw Failure.unsupported("grouped conditions (parentheses around AND/OR)") }
                    conjunction = take(word: "AND") ? .and : (take(word: "OR") ? .or : .and)
                    continue
                }
                break
            } while true
            return items
        }

        mutating func conditionAtom() throws -> ConditionItem {
            if current?.isWord("NOT") == true { throw Failure.unsupported("NOT") }
            if current?.isWord("EXISTS") == true { throw Failure.unsupported("EXISTS") }
            let ref = try columnRef()
            if current?.isSymbol("::") == true { throw Failure.unsupported("a cast on a column in a condition") }
            if take(word: "IS") {
                if take(word: "NOT") {
                    guard take(word: "NULL") else { throw Failure.unsupported("IS NOT …") }
                    return ConditionItem(ref: ref, op: .isNotNull, values: [], conjunction: .and)
                }
                guard take(word: "NULL") else { throw Failure.unsupported("IS …") }
                return ConditionItem(ref: ref, op: .isNull, values: [], conjunction: .and)
            }
            if take(word: "NOT") { throw Failure.unsupported("NOT LIKE / NOT IN / NOT BETWEEN") }
            if take(word: "IN") {
                guard take(symbol: "(") else { throw Failure.unsupported("IN without a list") }
                if current?.isWord("SELECT") == true { throw Failure.unsupported("IN (SELECT …)") }
                var values: [DBValue] = []
                repeat { values.append(try literal()) } while take(symbol: ",")
                guard take(symbol: ")") else { throw Failure.unsupported("an unclosed IN list") }
                return ConditionItem(ref: ref, op: .inList, values: values, conjunction: .and)
            }
            if take(word: "BETWEEN") {
                let low = try literal()
                guard take(word: "AND") else { throw Failure.unsupported("BETWEEN without AND") }
                let high = try literal()
                return ConditionItem(ref: ref, op: .between, values: [low, high], conjunction: .and)
            }
            if take(word: "LIKE") || take(word: "ILIKE") {
                let pattern = try literal()
                var escape: Character = "\\"
                if take(word: "ESCAPE") {
                    let text = try literal().text ?? ""
                    if let character = text.first { escape = character }
                }
                guard let text = pattern.text else { throw Failure.unsupported("a LIKE pattern that is not text") }
                let (op, needle) = try Self.likeOperator(text, escape: escape)
                return ConditionItem(ref: ref, op: op, values: [.string(needle)], conjunction: .and)
            }
            guard let symbol = current, symbol.kind == .symbol else {
                throw Failure.unsupported("the operator \"\(current?.text ?? "")\"")
            }
            let op: FilterOperator
            switch symbol.text {
            case "=": op = .equal
            case "<>", "!=": op = .notEqual
            case "<": op = .lessThan
            case "<=": op = .lessOrEqual
            case ">": op = .greaterThan
            case ">=": op = .greaterOrEqual
            default: throw Failure.unsupported("the operator \"\(symbol.text)\"")
            }
            advance()
            if let next = current, next.isName, peek()?.isSymbol(".") == true || next.kind == .quoted {
                throw Failure.unsupported("a comparison between two columns")
            }
            return ConditionItem(ref: ref, op: op, values: [try literal()], conjunction: .and)
        }

        /// A LIKE pattern as one of the builder's three text operators, with the wildcards
        /// stripped and the escapes undone; anything else has no row on the canvas.
        static func likeOperator(_ pattern: String, escape: Character) throws -> (FilterOperator, String) {
            var body = pattern
            let leading = body.hasPrefix("%")
            let trailing = body.hasSuffix("%") && !body.hasSuffix("\(escape)%")
            if leading { body.removeFirst() }
            if trailing { body.removeLast() }
            // Unescape, and refuse a wildcard that is not escaped in the middle.
            var needle = ""
            var characters = body.makeIterator()
            while let character = characters.next() {
                if character == escape, let escaped = characters.next() {
                    needle.append(escaped)
                } else if character == "%" || character == "_" {
                    throw Failure.unsupported("a LIKE pattern with a wildcard in the middle")
                } else {
                    needle.append(character)
                }
            }
            switch (leading, trailing) {
            case (true, true): return (.contains, needle)
            case (false, true): return (.startsWith, needle)
            case (true, false): return (.endsWith, needle)
            case (false, false): return (.equal, needle)
            }
        }

        mutating func literal() throws -> DBValue {
            guard let word = current else { throw Failure.unsupported("a missing value") }
            var value: DBValue
            switch word.kind {
            case .string:
                value = .string(word.text)
                advance()
            case .number:
                value = Int64(word.text).map(DBValue.int) ?? .decimal(word.text)
                advance()
            case .symbol where word.text == "-" && peek()?.kind == .number:
                advance()
                let number = current?.text ?? ""
                value = Int64("-" + number).map(DBValue.int) ?? .decimal("-" + number)
                advance()
            case .word where word.upper == "TRUE" || word.upper == "FALSE":
                value = .bool(word.upper == "TRUE")
                advance()
            case .word where word.upper == "NULL":
                value = .null
                advance()
            case .symbol where word.text == "(":
                throw Failure.unsupported("a subquery or expression as a value")
            default:
                if word.isName, peek()?.isSymbol("(") == true {
                    throw Failure.unsupported("the function \(word.text)()")
                }
                throw Failure.unsupported("a comparison between two columns")
            }
            // PostgreSQL spells out the type of a literal: 'ok'::mood, 5::numeric(10,2).
            if take(symbol: "::") {
                guard let type = current, type.isName else { throw Failure.unsupported("a cast without a type") }
                advance()
                while let next = current, next.isName, !next.isWord("AND"), !next.isWord("OR"), !atClauseStart() {
                    advance()  // multi-word types: character varying, double precision
                }
                if take(symbol: "(") {
                    while let inner = current, !inner.isSymbol(")") { advance() }
                    _ = take(symbol: ")")
                }
                if take(symbol: "[") { _ = take(symbol: "]") }
            }
            return value
        }
    }
}
