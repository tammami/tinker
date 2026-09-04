import DBCore
import Foundation

/// One piece of a script: a statement to run, or part of a PostgreSQL `COPY` block.
///
/// Both a dump being written and a script being imported are streams of these, so the
/// file writer, the file reader and the executor all speak one language.
public enum ScriptChunk: Sendable, Equatable {
    case statement(String, line: Int)
    /// `COPY table (columns) FROM stdin` — the rows follow as ``copyLines(_:)`` until ``copyEnd``.
    case copyBegin(table: TableRef, columns: [String], sql: String)
    /// Whole lines in PostgreSQL's text format, each ending in `\n`.
    case copyLines(Data)
    case copyEnd
}

/// Splits a script into statements as its bytes arrive, in any size of piece.
///
/// It is the streaming counterpart of `DBSQL.StatementSplitter` and follows the same
/// rules — string literals, quoted identifiers, backslash escapes on MySQL, line and
/// block comments, nested block comments and dollar-quoted bodies on PostgreSQL, the
/// MySQL client's `DELIMITER` directive — plus the two things dumps add: psql
/// meta-commands, which are dropped, and `COPY … FROM stdin` blocks, whose rows are
/// passed through as they are. Only the statement being gathered is held in memory.
public struct IncrementalStatementSplitter: Sendable {
    public let dialect: SQLDialect
    /// One-based line on which the statement being gathered started.
    public private(set) var statementLine = 1
    /// Absolute byte offset at which the statement being gathered started.
    public private(set) var statementOffset: Int64 = 0

    private var buffer: [UInt8] = []
    /// Bytes before `base` belong to statements already emitted or dropped.
    private var base = 0
    private var cursor = 0
    private var state = State.code
    private var hasCode = false
    private var delimiter: [UInt8] = [UInt8(ascii: ";")]
    /// Absolute offset of `buffer[0]`.
    private var bufferOffset: Int64 = 0
    private var line = 1
    private var copyBatch = Data()
    private var copyAwaitingLineEnd = false

    private static let copyBatchSize = 64 * 1_024

    private enum State: Sendable {
        case code
        case singleQuoted
        case doubleQuoted
        case backticked
        case lineComment
        case blockComment(depth: Int)
        case dollarQuoted(tag: [UInt8])
        case copyData
    }

    public init(dialect: SQLDialect) {
        self.dialect = dialect
    }

    /// Feeds the next piece of the script and returns every chunk it completed.
    public mutating func feed(_ data: Data) -> [ScriptChunk] {
        buffer.append(contentsOf: data)
        let chunks = scan(atEnd: false)
        compact()
        return chunks
    }

    /// Flushes whatever the end of the script left unterminated.
    public mutating func finish() -> [ScriptChunk] {
        var chunks = scan(atEnd: true)
        switch state {
        case .copyData:
            if !copyBatch.isEmpty { chunks.append(.copyLines(copyBatch)) }
            copyBatch = Data()
            chunks.append(.copyEnd)
        default:
            if let chunk = flushStatement(end: buffer.count) { chunks.append(chunk) }
        }
        buffer.removeAll()
        base = 0
        cursor = 0
        state = .code
        hasCode = false
        return chunks
    }

    // MARK: - Scanning

    private mutating func scan(atEnd: Bool) -> [ScriptChunk] {
        var out: [ScriptChunk] = []
        let end = buffer.count

        /// True when `count` more bytes are in hand, or the script has ended so no more
        /// will come. False means: stop and wait for the next piece.
        func have(_ count: Int) -> Bool { cursor + count <= end || atEnd }

        scanning: while cursor < end {
            let byte = buffer[cursor]
            switch state {
            case .copyData:
                if copyAwaitingLineEnd {
                    // The rest of the `COPY … FROM stdin;` line, normally empty.
                    guard let newline = indexOfNewline(from: cursor) else { break scanning }
                    cursor = newline + 1
                    line += 1
                    base = cursor
                    copyAwaitingLineEnd = false
                    continue
                }
                guard let newline = indexOfNewline(from: cursor) ?? (atEnd ? end : nil) else { break scanning }
                let lineEnd = newline > cursor && buffer[newline - 1] == UInt8(ascii: "\r") ? newline - 1 : newline
                if lineEnd - cursor == 2, buffer[cursor] == UInt8(ascii: "\\"), buffer[cursor + 1] == UInt8(ascii: ".")
                {
                    if !copyBatch.isEmpty { out.append(.copyLines(copyBatch)) }
                    copyBatch = Data()
                    out.append(.copyEnd)
                    state = .code
                    cursor = min(newline + 1, end)
                    line += 1
                    base = cursor
                    beginStatement()
                    continue
                }
                copyBatch.append(contentsOf: buffer[cursor ..< lineEnd])
                copyBatch.append(UInt8(ascii: "\n"))
                if copyBatch.count >= Self.copyBatchSize {
                    out.append(.copyLines(copyBatch))
                    copyBatch = Data()
                }
                cursor = min(newline + 1, end)
                line += 1
                // The rows are handed on, not kept.
                base = cursor

            case .singleQuoted, .doubleQuoted, .backticked:
                let quote: UInt8 =
                    switch state {
                    case .singleQuoted: UInt8(ascii: "'")
                    case .doubleQuoted: UInt8(ascii: "\"")
                    default: UInt8(ascii: "`")
                    }
                if dialect == .mysql, byte == UInt8(ascii: "\\") {
                    guard have(2) else { break scanning }
                    if cursor + 1 < end, buffer[cursor + 1] == UInt8(ascii: "\n") { line += 1 }
                    cursor += 2
                    continue
                }
                if byte == quote {
                    guard have(2) else { break scanning }
                    if cursor + 1 < end, buffer[cursor + 1] == quote {
                        cursor += 2
                        continue
                    }
                    state = .code
                }
                if byte == UInt8(ascii: "\n") { line += 1 }
                cursor += 1

            case .lineComment:
                if byte == UInt8(ascii: "\n") {
                    line += 1
                    state = .code
                    cursor += 1
                    if !hasCode { base = cursor }
                    continue
                }
                cursor += 1

            case let .blockComment(depth):
                guard have(2) else { break scanning }
                if dialect == .postgresql, byte == UInt8(ascii: "/"), cursor + 1 < end,
                    buffer[cursor + 1] == UInt8(ascii: "*")
                {
                    state = .blockComment(depth: depth + 1)
                    cursor += 2
                    continue
                }
                if byte == UInt8(ascii: "*"), cursor + 1 < end, buffer[cursor + 1] == UInt8(ascii: "/") {
                    cursor += 2
                    if depth == 1 {
                        state = .code
                        if !hasCode { base = cursor }
                    } else {
                        state = .blockComment(depth: depth - 1)
                    }
                    continue
                }
                if byte == UInt8(ascii: "\n") { line += 1 }
                cursor += 1

            case let .dollarQuoted(tag):
                guard have(tag.count) else { break scanning }
                if byte == UInt8(ascii: "$"), matches(tag, at: cursor) {
                    cursor += tag.count
                    state = .code
                    continue
                }
                if byte == UInt8(ascii: "\n") { line += 1 }
                cursor += 1

            case .code:
                if !hasCode {
                    // Between statements: whitespace, comments, directives and psql
                    // meta-commands are dropped rather than gathered.
                    if byte == UInt8(ascii: "\n") || byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t")
                        || byte == UInt8(ascii: "\r")
                    {
                        if byte == UInt8(ascii: "\n") { line += 1 }
                        cursor += 1
                        base = cursor
                        continue
                    }
                    if byte == UInt8(ascii: "\\") {
                        guard let newline = indexOfNewline(from: cursor) ?? (atEnd ? end : nil) else { break scanning }
                        cursor = min(newline + 1, end)
                        line += 1
                        base = cursor
                        continue
                    }
                    if dialect == .mysql, byte == UInt8(ascii: "D") || byte == UInt8(ascii: "d") {
                        guard have(10) else { break scanning }
                        if matchesKeyword("DELIMITER", at: cursor) {
                            guard let newline = indexOfNewline(from: cursor) ?? (atEnd ? end : nil) else {
                                break scanning
                            }
                            let token = buffer[(cursor + 9) ..< newline]
                                .drop { $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\t") }
                                .prefix {
                                    $0 != UInt8(ascii: " ") && $0 != UInt8(ascii: "\t") && $0 != UInt8(ascii: "\r")
                                }
                            if !token.isEmpty { delimiter = Array(token) }
                            cursor = min(newline + 1, end)
                            line += 1
                            base = cursor
                            continue
                        }
                    }
                }

                if byte == delimiter[0] {
                    guard have(delimiter.count) else { break scanning }
                    if matches(delimiter, at: cursor) {
                        let statementEnd = cursor
                        cursor += delimiter.count
                        let chunk = flushStatement(end: statementEnd)
                        base = cursor
                        beginStatement()
                        if let chunk {
                            out.append(chunk)
                            if case .copyBegin = chunk {
                                state = .copyData
                                copyAwaitingLineEnd = true
                            }
                        }
                        continue
                    }
                }

                switch byte {
                case UInt8(ascii: "'"):
                    noteCode()
                    state = .singleQuoted
                    cursor += 1
                case UInt8(ascii: "\""):
                    noteCode()
                    state = .doubleQuoted
                    cursor += 1
                case UInt8(ascii: "`") where dialect == .mysql:
                    noteCode()
                    state = .backticked
                    cursor += 1
                case UInt8(ascii: "-"):
                    guard have(2) else { break scanning }
                    if cursor + 1 < end, buffer[cursor + 1] == UInt8(ascii: "-") {
                        state = .lineComment
                        cursor += 2
                    } else {
                        noteCode()
                        cursor += 1
                    }
                case UInt8(ascii: "#") where dialect == .mysql:
                    state = .lineComment
                    cursor += 1
                case UInt8(ascii: "/"):
                    guard have(3) else { break scanning }
                    if cursor + 1 < end, buffer[cursor + 1] == UInt8(ascii: "*") {
                        // `/*! … */` is a conditional comment: MySQL runs what is inside,
                        // so it is part of the statement rather than dropped.
                        if dialect == .mysql, cursor + 2 < end, buffer[cursor + 2] == UInt8(ascii: "!") { noteCode() }
                        state = .blockComment(depth: 1)
                        cursor += 2
                    } else {
                        noteCode()
                        cursor += 1
                    }
                case UInt8(ascii: "$") where dialect == .postgresql:
                    guard let tag = dollarTag(at: cursor, atEnd: atEnd) else {
                        if cursor + 1 >= end, !atEnd { break scanning }
                        noteCode()
                        cursor += 1
                        continue
                    }
                    if tag.isEmpty {
                        // Needs more bytes to know whether a tag closes.
                        break scanning
                    }
                    noteCode()
                    state = .dollarQuoted(tag: tag)
                    cursor += tag.count
                case UInt8(ascii: "\n"):
                    line += 1
                    cursor += 1
                case UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\r"):
                    cursor += 1
                default:
                    noteCode()
                    cursor += 1
                }
            }
        }
        return out
    }

    /// Marks the statement as holding something to run, recording where it began.
    private mutating func noteCode() {
        guard !hasCode else { return }
        hasCode = true
        statementLine = line
        statementOffset = bufferOffset + Int64(base)
    }

    private mutating func beginStatement() {
        hasCode = false
        state = .code
    }

    /// The statement gathered so far, or nil when it holds nothing to run.
    private mutating func flushStatement(end: Int) -> ScriptChunk? {
        defer { hasCode = false }
        guard hasCode, end > base else { return nil }
        let text = String(decoding: buffer[base ..< end], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if dialect == .postgresql, let copy = Self.copyFromStdin(text) {
            return .copyBegin(table: copy.table, columns: copy.columns, sql: text)
        }
        return .statement(text, line: statementLine)
    }

    private mutating func compact() {
        guard base > 0, base >= buffer.count / 2 || buffer.count > ScriptByteSource.chunkSize else { return }
        buffer.removeFirst(base)
        bufferOffset += Int64(base)
        cursor -= base
        base = 0
    }

    private func indexOfNewline(from start: Int) -> Int? {
        var index = start
        while index < buffer.count {
            if buffer[index] == UInt8(ascii: "\n") { return index }
            index += 1
        }
        return nil
    }

    private func matches(_ bytes: [UInt8], at position: Int) -> Bool {
        guard position + bytes.count <= buffer.count else { return false }
        for (offset, expected) in bytes.enumerated() where buffer[position + offset] != expected { return false }
        return true
    }

    /// Case-insensitive ASCII keyword followed by a blank.
    private func matchesKeyword(_ keyword: String, at position: Int) -> Bool {
        let bytes = Array(keyword.utf8)
        guard position + bytes.count < buffer.count else { return false }
        for (offset, expected) in bytes.enumerated() {
            let actual = buffer[position + offset]
            let upper = actual >= 0x61 && actual <= 0x7A ? actual - 0x20 : actual
            if upper != expected { return false }
        }
        let next = buffer[position + bytes.count]
        return next == UInt8(ascii: " ") || next == UInt8(ascii: "\t")
    }

    /// The `$tag$` at `position`, or nil when the `$` is a placeholder or part of a name.
    /// An empty array means the bytes in hand are not enough to tell.
    private func dollarTag(at position: Int, atEnd: Bool) -> [UInt8]? {
        var index = position + 1
        while index < buffer.count {
            let byte = buffer[index]
            if byte == UInt8(ascii: "$") { return Array(buffer[position ... index]) }
            let isTagByte =
                (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
                || byte == UInt8(ascii: "_") || byte >= 0x80
            guard isTagByte else { return nil }
            // `$1` is a placeholder, not a tag.
            if index == position + 1, byte >= 0x30, byte <= 0x39 { return nil }
            index += 1
        }
        return atEnd ? nil : []
    }

    // MARK: - COPY

    /// The target of a `COPY … FROM stdin` statement, or nil for any other statement.
    static func copyFromStdin(_ text: String) -> (table: TableRef, columns: [String])? {
        let scalars = Array(text.unicodeScalars)
        var index = 0
        func skipBlanks() {
            while index < scalars.count, scalars[index].properties.isWhitespace { index += 1 }
        }
        func word() -> String {
            let start = index
            while index < scalars.count, !scalars[index].properties.isWhitespace, scalars[index] != "(" {
                index += 1
            }
            return String(String.UnicodeScalarView(scalars[start ..< index]))
        }
        /// One identifier, quoted or bare, without moving past what follows it.
        func identifier() -> String? {
            guard index < scalars.count else { return nil }
            if scalars[index] == "\"" {
                index += 1
                var name = String.UnicodeScalarView()
                while index < scalars.count {
                    if scalars[index] == "\"" {
                        if index + 1 < scalars.count, scalars[index + 1] == "\"" {
                            name.append("\"")
                            index += 2
                            continue
                        }
                        index += 1
                        return String(name)
                    }
                    name.append(scalars[index])
                    index += 1
                }
                return nil
            }
            let start = index
            while index < scalars.count, scalars[index] != ".", scalars[index] != "(", scalars[index] != ",",
                scalars[index] != ")", !scalars[index].properties.isWhitespace
            {
                index += 1
            }
            guard index > start else { return nil }
            return String(String.UnicodeScalarView(scalars[start ..< index])).lowercased()
        }

        skipBlanks()
        guard word().uppercased() == "COPY" else { return nil }
        skipBlanks()
        var parts: [String] = []
        while let part = identifier() {
            parts.append(part)
            guard index < scalars.count, scalars[index] == "." else { break }
            index += 1
        }
        guard let name = parts.last, parts.count <= 3 else { return nil }
        let schema = parts.count >= 2 ? parts[parts.count - 2] : "public"
        skipBlanks()
        var columns: [String] = []
        if index < scalars.count, scalars[index] == "(" {
            index += 1
            while true {
                skipBlanks()
                guard let column = identifier() else { return nil }
                columns.append(column)
                skipBlanks()
                guard index < scalars.count else { return nil }
                if scalars[index] == "," {
                    index += 1
                    continue
                }
                if scalars[index] == ")" {
                    index += 1
                    break
                }
                return nil
            }
        }
        skipBlanks()
        guard word().uppercased() == "FROM" else { return nil }
        skipBlanks()
        guard word().uppercased() == "STDIN" else { return nil }
        return (TableRef(database: "", schema: schema, name: name), columns)
    }
}
