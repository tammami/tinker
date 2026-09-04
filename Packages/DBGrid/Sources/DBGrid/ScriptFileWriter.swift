import DBCore
import Foundation

/// Writes a script's chunks to a `.sql` or `.sql.gz` file as they come.
///
/// Statements are terminated the way the dialect's own client reads them back — on
/// MySQL a statement with semicolons inside, a routine or a trigger, is fenced with
/// `DELIMITER` — and `COPY` blocks are laid out exactly as `pg_dump` lays them out, so
/// the file opens in `psql`, `mysql` and Tinker's own importer alike.
public final class ScriptFileWriter {
    public let url: URL
    public let dialect: SQLDialect
    public let isCompressed: Bool
    /// Bytes on disk so far.
    public private(set) var bytesWritten: Int64 = 0
    private let handle: FileHandle
    private var deflater: GzipDeflater?
    private var buffer = Data()
    private var isFinished = false

    private static let flushThreshold = 256 * 1_024

    public init(url: URL, dialect: SQLDialect, compress: Bool) throws {
        self.url = url
        self.dialect = dialect
        isCompressed = compress
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        if compress { deflater = try GzipDeflater() }
    }

    deinit {
        try? handle.close()
    }

    public func write(_ chunk: ScriptChunk) throws {
        switch chunk {
        case let .statement(sql, _):
            if dialect == .mysql, sql.contains(";") {
                append("DELIMITER ;;\n\(sql);;\nDELIMITER ;\n")
            } else {
                append("\(sql);\n")
            }
        case let .copyBegin(_, _, sql):
            append("\(sql);\n")
        case let .copyLines(data):
            append(data)
        case .copyEnd:
            append("\\.\n\n")
        }
        try flushIfNeeded()
    }

    /// A `-- ` comment line, or a blank line for empty text.
    public func writeComment(_ text: String) throws {
        if text.isEmpty {
            append("\n")
        } else {
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                append("-- \(line)\n")
            }
        }
        try flushIfNeeded()
    }

    public func writeRaw(_ text: String) throws {
        append(text)
        try flushIfNeeded()
    }

    /// Flushes and closes. The gzip trailer is written here, so a file whose writer
    /// never finished is recognisably truncated rather than silently short.
    public func finish() throws {
        guard !isFinished else { return }
        isFinished = true
        if let deflater {
            let tail = try deflater.compress(buffer, finish: true)
            buffer.removeAll()
            try handle.write(contentsOf: tail)
            bytesWritten += Int64(tail.count)
        } else {
            try flush()
        }
        try handle.close()
    }

    private func append(_ text: String) {
        buffer.append(contentsOf: text.utf8)
    }

    private func append(_ data: Data) {
        buffer.append(data)
    }

    private func flushIfNeeded() throws {
        if buffer.count >= Self.flushThreshold { try flush() }
    }

    private func flush() throws {
        guard !buffer.isEmpty else { return }
        let out = try deflater?.compress(buffer, finish: false) ?? buffer
        buffer.removeAll(keepingCapacity: true)
        guard !out.isEmpty else { return }
        try handle.write(contentsOf: out)
        bytesWritten += Int64(out.count)
    }
}
