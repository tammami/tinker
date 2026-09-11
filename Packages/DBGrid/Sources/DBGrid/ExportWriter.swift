import DBCore
import Foundation

/// A ``RowExporter`` behind an actor, so the encoding and the file writes happen off the
/// main actor (SPEC §14: "export runs off the main thread").
///
/// The export sheet used to call the exporter from its `@MainActor` streaming closure,
/// which put every byte of a million-row CSV through the main thread and froze the app
/// for the length of the export. Batches are handed over by value; the actor owns the
/// exporter and is the only thing that touches it.
public actor ExportWriter {
    private let exporter: RowExporter

    public init(url: URL, options: ExportOptions) throws {
        exporter = try RowExporter(url: url, options: options)
    }

    public func begin(columns: [ColumnMeta]) throws {
        try exporter.begin(columns: columns)
    }

    /// Writes a batch and returns the rows written so far, for the sheet's progress line.
    @discardableResult
    public func write(rows: [[DBValue]]) -> Int64 {
        exporter.write(rows: rows)
        return exporter.writtenRowCount
    }

    public var writtenRowCount: Int64 { exporter.writtenRowCount }

    public func finish() throws {
        try exporter.finish()
    }
}
