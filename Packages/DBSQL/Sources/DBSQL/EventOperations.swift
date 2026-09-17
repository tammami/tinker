import DBCore
import Foundation

/// The unit in `EVERY <value> <field>`.
public enum EventIntervalField: String, Sendable, Hashable, CaseIterable, Codable {
    case year = "YEAR"
    case quarter = "QUARTER"
    case month = "MONTH"
    case week = "WEEK"
    case day = "DAY"
    case hour = "HOUR"
    case minute = "MINUTE"
    case second = "SECOND"
    case yearMonth = "YEAR_MONTH"
    case dayHour = "DAY_HOUR"
    case dayMinute = "DAY_MINUTE"
    case daySecond = "DAY_SECOND"
    case hourMinute = "HOUR_MINUTE"
    case hourSecond = "HOUR_SECOND"
    case minuteSecond = "MINUTE_SECOND"

    /// True for units whose value is a composite like `'1:30'` rather than a count.
    public var takesCompoundValue: Bool {
        switch self {
        case .year, .quarter, .month, .week, .day, .hour, .minute, .second: false
        default: true
        }
    }

    /// What the editor's pop-up shows.
    public var title: String { rawValue.replacingOccurrences(of: "_", with: " ").capitalized }
}

/// When an event runs.
public enum EventSchedule: Sendable, Hashable {
    /// `ON SCHEDULE AT <timestamp>` — runs once.
    case at(String)
    /// `ON SCHEDULE EVERY <value> <field>` — repeats.
    case every(value: String, field: EventIntervalField)
}

/// What the event editor asks for, rendered by `EventOperations`.
public struct EventRequest: Sendable, Hashable {
    /// The database the event belongs to. MySQL events are database-scoped.
    public var database: String
    public var name: String
    public var schedule: EventSchedule
    /// `STARTS` for a recurring event. Nil leaves it to the server, which means now.
    public var starts: String?
    /// `ENDS` for a recurring event. Nil means it never stops.
    public var ends: String?
    /// `ON COMPLETION PRESERVE` when true. False lets the event delete itself after its
    /// last run — MySQL's default, and a common surprise.
    public var preserveOnCompletion: Bool
    /// `ENABLE` when true, `DISABLE` when false.
    public var isEnabled: Bool
    public var comment: String?
    /// The statement after `DO`, written by the person.
    public var body: String

    public init(
        database: String,
        name: String,
        schedule: EventSchedule,
        starts: String? = nil,
        ends: String? = nil,
        preserveOnCompletion: Bool = true,
        isEnabled: Bool = true,
        comment: String? = nil,
        body: String
    ) {
        self.database = database
        self.name = name
        self.schedule = schedule
        self.starts = starts
        self.ends = ends
        self.preserveOnCompletion = preserveOnCompletion
        self.isEnabled = isEnabled
        self.comment = comment
        self.body = body
    }
}

/// What the generator refuses to render, with the words the sheet shows.
public enum EventOperationsError: Error, Hashable, CustomStringConvertible {
    case noScheduler(SQLDialect)
    case emptyName
    case emptyBody
    case emptyTimestamp
    case intervalNotAWholeNumber(String)
    case intervalNotPositive(String)
    case compoundIntervalNeedsQuoting(String)
    case oneTimeTakesNoWindow

    public var description: String {
        switch self {
        case let .noScheduler(dialect):
            switch dialect {
            case .postgresql:
                "PostgreSQL has no built-in event scheduler; pg_cron or an external scheduler runs statements on a timer"
            case .sqlite:
                "SQLite has no server to run a schedule; a database file is only read when something opens it"
            case .mysql:
                "This server has no event scheduler"
            }
        case .emptyName: "The event needs a name"
        case .emptyBody: "The event needs a statement to run"
        case .emptyTimestamp: "The event needs a time to run at"
        case let .intervalNotAWholeNumber(value):
            "The interval must be a whole number of units, not \(value)"
        case let .intervalNotPositive(value):
            "The interval must be greater than zero, not \(value)"
        case let .compoundIntervalNeedsQuoting(value):
            "A compound interval looks like 1:30, not \(value)"
        case .oneTimeTakesNoWindow:
            "An event that runs once has no start or end; clear them or make it repeat"
        }
    }
}

/// Generates CREATE / ALTER / DROP EVENT for the MySQL event scheduler.
///
/// Names are quoted as identifiers; timestamps, comments and interval values go through
/// `SQLLiteral`, so a quote cannot break out. The body is written through unchanged.
/// `DEFINER` is never written — setting one needs `SUPER`, so an ordinary account would
/// just be refused.
public enum EventOperations {
    /// One `CREATE EVENT`, sent whole: the body may hold semicolons and MySQL's splitter
    /// does not track `BEGIN … END`.
    public static func create(_ request: EventRequest, dialect: SQLDialect) throws -> String {
        let name = try validated(request, dialect: dialect)
        var sql = "CREATE EVENT \(qualified(request.database, name, dialect))\n"
        sql += try scheduleClause(request, dialect: dialect)
        sql += "\nON COMPLETION\(request.preserveOnCompletion ? "" : " NOT") PRESERVE"
        sql += request.isEnabled ? "\nENABLE" : "\nDISABLE"
        if let comment = trimmedComment(request) {
            sql += "\nCOMMENT \(SQLLiteral.quoteString(comment, dialect: dialect))"
        }
        sql += "\nDO \(request.body.trimmingCharacters(in: .whitespacesAndNewlines))"
        return sql
    }

    /// The `ALTER EVENT` that turns `current` into `request`, rename included. Altering
    /// rather than dropping and recreating means a failed second half cannot lose it.
    /// `includingSchedule` false leaves `ON SCHEDULE` out entirely, which is what an edit
    /// that changed only a comment or the enabled flag should send: re-stating the schedule
    /// makes the server read its timestamps in *this* session's time zone, and an event
    /// created in another zone would silently move.
    public static func alter(
        _ request: EventRequest, renamedFrom current: String? = nil, includingSchedule: Bool = true,
        dialect: SQLDialect
    ) throws -> String {
        let name = try validated(request, dialect: dialect)
        // A `current` of spaces is not nil but names nothing; falling back to `name` keeps
        // the statement addressed at a real event rather than at ``.
        let trimmedCurrent = current?.trimmingCharacters(in: .whitespaces)
        let target = (trimmedCurrent?.isEmpty == false ? trimmedCurrent : nil) ?? name
        var sql = "ALTER EVENT \(qualified(request.database, target, dialect))"
        if includingSchedule { sql += "\n" + (try scheduleClause(request, dialect: dialect)) }
        sql += "\nON COMPLETION\(request.preserveOnCompletion ? "" : " NOT") PRESERVE"
        if target != name {
            sql += "\nRENAME TO \(qualified(request.database, name, dialect))"
        }
        sql += request.isEnabled ? "\nENABLE" : "\nDISABLE"
        if let comment = trimmedComment(request) {
            sql += "\nCOMMENT \(SQLLiteral.quoteString(comment, dialect: dialect))"
        }
        sql += "\nDO \(request.body.trimmingCharacters(in: .whitespacesAndNewlines))"
        return sql
    }

    /// Turns one event on or off without touching its schedule or body.
    public static func setEnabled(
        _ enabled: Bool, database: String, name: String, dialect: SQLDialect
    ) throws -> String {
        guard dialect.hasScheduledEvents else { throw EventOperationsError.noScheduler(dialect) }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw EventOperationsError.emptyName }
        return "ALTER EVENT \(qualified(database, trimmed, dialect)) \(enabled ? "ENABLE" : "DISABLE")"
    }

    /// Removes an event. The server forgets the schedule; nothing already running is stopped.
    public static func drop(database: String, name: String, dialect: SQLDialect) throws -> String {
        guard dialect.hasScheduledEvents else { throw EventOperationsError.noScheduler(dialect) }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw EventOperationsError.emptyName }
        return "DROP EVENT IF EXISTS \(qualified(database, trimmed, dialect))"
    }

    /// Starts the server's scheduler thread. `SET PERSIST` survives a restart but needs
    /// MySQL 8.0+; elsewhere `SET GLOBAL` is forgotten when the server stops.
    public static func setScheduler(
        on enabled: Bool, dialect: SQLDialect, persists: Bool
    ) throws -> String {
        guard dialect.hasScheduledEvents else { throw EventOperationsError.noScheduler(dialect) }
        return "SET \(persists ? "PERSIST" : "GLOBAL") event_scheduler = \(enabled ? "ON" : "OFF")"
    }

    /// Whether this server understands `SET PERSIST`, which is MySQL 8.0 and later only.
    public static func schedulerChangePersists(_ version: ServerVersion) -> Bool {
        switch version.flavor {
        case .mariadb: false
        default: version.isAtLeast(8, 0)
        }
    }

    // MARK: - Rendering

    private static func qualified(_ database: String, _ name: String, _ dialect: SQLDialect) -> String {
        Identifier.qualify([database, name], dialect: dialect)
    }

    private static func trimmedComment(_ request: EventRequest) -> String? {
        guard let comment = request.comment?.trimmingCharacters(in: .whitespacesAndNewlines),
            !comment.isEmpty
        else { return nil }
        return comment
    }

    private static func validated(_ request: EventRequest, dialect: SQLDialect) throws -> String {
        guard dialect.hasScheduledEvents else { throw EventOperationsError.noScheduler(dialect) }
        let name = request.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw EventOperationsError.emptyName }
        guard !request.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EventOperationsError.emptyBody
        }
        return name
    }

    private static func scheduleClause(_ request: EventRequest, dialect: SQLDialect) throws -> String {
        switch request.schedule {
        case let .at(timestamp):
            let trimmed = timestamp.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { throw EventOperationsError.emptyTimestamp }
            // A one-time event has no window; carrying STARTS or ENDS into one would drop
            // them silently, so the request is refused instead.
            guard request.starts?.isEmpty ?? true, request.ends?.isEmpty ?? true else {
                throw EventOperationsError.oneTimeTakesNoWindow
            }
            return "ON SCHEDULE AT \(SQLLiteral.quoteString(trimmed, dialect: dialect))"
        case let .every(value, field):
            var clause =
                "ON SCHEDULE EVERY \(try intervalValue(value, field: field, dialect: dialect)) \(field.rawValue)"
            if let starts = request.starts?.trimmingCharacters(in: .whitespaces), !starts.isEmpty {
                clause += "\nSTARTS \(SQLLiteral.quoteString(starts, dialect: dialect))"
            }
            if let ends = request.ends?.trimmingCharacters(in: .whitespaces), !ends.isEmpty {
                clause += "\nENDS \(SQLLiteral.quoteString(ends, dialect: dialect))"
            }
            return clause
        }
    }

    /// A simple unit takes a bare integer, a compound one a quoted literal. Both are
    /// checked here, so nothing arbitrary reaches the statement through the interval.
    private static func intervalValue(
        _ value: String, field: EventIntervalField, dialect: SQLDialect
    ) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw EventOperationsError.intervalNotAWholeNumber(value) }
        if field.takesCompoundValue {
            // Digits and separators only, and no sign: `EVERY '-5:30' HOUR_MINUTE` is
            // refused by the server, and the point of checking here is that the editor
            // says so first.
            let allowed = CharacterSet(charactersIn: "0123456789:.")
            guard trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
                throw EventOperationsError.compoundIntervalNeedsQuoting(value)
            }
            guard trimmed.contains(where: { $0.isNumber && $0 != "0" }) else {
                throw EventOperationsError.intervalNotPositive(value)
            }
            return SQLLiteral.quoteString(trimmed, dialect: dialect)
        }
        guard let number = Int(trimmed) else {
            throw EventOperationsError.intervalNotAWholeNumber(value)
        }
        guard number > 0 else { throw EventOperationsError.intervalNotPositive(value) }
        return String(number)
    }
}
