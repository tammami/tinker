import DBCore
import Foundation

/// What the server says a running structure statement is doing.
public struct DDLProgress: Sendable, Hashable {
    /// The server's own description, verbatim: MySQL's `STATE` (“copy to tmp table”,
    /// “Waiting for table metadata lock”), PostgreSQL's wait event or index-build phase.
    public var state: String?
    /// Fraction done, 0…1, only when the server estimates one.
    public var fraction: Double?

    public init(state: String? = nil, fraction: Double? = nil) {
        self.state = state
        self.fraction = fraction
    }
}

/// Reads what a running ALTER is doing from a second connection of the same session.
///
/// Every source it reads is optional: a user without access to `performance_schema`, a
/// server that does not report progress for this kind of statement, or a catalog that
/// differs by version just leaves that part of the answer empty. A probe never fails
/// the run it watches.
public enum DDLProgressProbe {
    public static func sample(
        session: ConnectionSession, dialect: SQLDialect, backendID: String
    ) async -> DDLProgress? {
        // The id is interpolated rather than bound, so it must be a plain number.
        guard let id = Int(backendID), id > 0 else { return nil }
        switch dialect {
        case .mysql:
            return try? await session.withLease { connection in
                await mysql(connection, threadID: id)
            }
        case .postgresql:
            return try? await session.withLease { connection in
                await postgres(connection, pid: id)
            }
        default:
            return nil
        }
    }

    private static func mysql(_ connection: any SQLConnection, threadID: Int) async -> DDLProgress? {
        // MariaDB reports its own progress in the process list; MySQL has no such column.
        let withProgress = try? await connection.executeCollecting(
            "SELECT STATE, PROGRESS FROM information_schema.PROCESSLIST WHERE ID = \(threadID)"
        )
        let row: [DBValue]?
        if let withProgress {
            row = withProgress.rows.first
        } else {
            row = try? await connection.executeCollecting(
                "SELECT STATE FROM information_schema.PROCESSLIST WHERE ID = \(threadID)"
            ).rows.first
        }
        guard let row else { return nil }
        var progress = DDLProgress(state: text(row.first))
        if row.count > 1, let percent = number(row[1]), percent > 0 {
            progress.fraction = min(percent / 100, 1)
        } else if let stage = try? await connection.executeCollecting(
            """
            SELECT s.WORK_COMPLETED, s.WORK_ESTIMATED
            FROM performance_schema.events_stages_current s
            JOIN performance_schema.threads t ON t.THREAD_ID = s.THREAD_ID
            WHERE t.PROCESSLIST_ID = \(threadID)
            """
        ).rows.first {
            progress.fraction = fraction(done: number(stage.first), total: number(stage.dropFirst().first))
        }
        return progress
    }

    private static func postgres(_ connection: any SQLConnection, pid: Int) async -> DDLProgress? {
        guard
            let row = try? await connection.executeCollecting(
                "SELECT wait_event_type, wait_event FROM pg_stat_activity WHERE pid = \(pid)"
            ).rows.first
        else { return nil }
        var progress = DDLProgress()
        if let type = text(row.first), let event = text(row.dropFirst().first) {
            progress.state = type == "Lock" ? "Waiting for lock (\(event))" : "\(type): \(event)"
        }
        // Only index builds report progress; a table rewrite does not.
        if let index = try? await connection.executeCollecting(
            """
            SELECT phase, blocks_done, blocks_total, tuples_done, tuples_total
            FROM pg_stat_progress_create_index WHERE pid = \(pid)
            """
        ).rows.first {
            if progress.state == nil { progress.state = text(index.first) }
            let values = index.map(number)
            progress.fraction =
                fraction(done: values[safe: 1] ?? nil, total: values[safe: 2] ?? nil)
                ?? fraction(done: values[safe: 3] ?? nil, total: values[safe: 4] ?? nil)
        }
        return progress
    }

    static func fraction(done: Double?, total: Double?) -> Double? {
        guard let done, let total, total > 0 else { return nil }
        return min(max(done / total, 0), 1)
    }

    private static func text(_ value: DBValue?) -> String? {
        guard let value, let string = value.text, !string.isEmpty else { return nil }
        return string
    }

    private static func number(_ value: DBValue?) -> Double? {
        text(value).flatMap(Double.init)
    }
}

extension Array {
    fileprivate subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
