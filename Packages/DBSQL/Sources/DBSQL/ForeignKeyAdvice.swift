import DBCore
import Foundation

/// What the designer says about a foreign key before the server is asked: which actions
/// the engine has, what each one does, and what about the key the server will refuse.
///
/// Nothing here stops a key being sent. The server is the judge and its message is shown
/// as it wrote it; this is the explanation that makes the message unnecessary.
public enum ForeignKeyAdvice {
    /// The referential actions `dialect` carries out.
    ///
    /// MySQL parses `SET DEFAULT` and InnoDB then refuses the table, so it is not offered
    /// there. PostgreSQL and SQLite have all five.
    public static func actions(for dialect: SQLDialect) -> [ForeignKeyAction] {
        switch dialect {
        case .mysql: [.noAction, .restrict, .cascade, .setNull]
        case .postgresql, .sqlite: ForeignKeyAction.allCases
        }
    }

    /// True when the engine can put a key's check off to the end of the transaction.
    public static func supportsDeferral(_ dialect: SQLDialect) -> Bool { dialect != .mysql }

    /// What happens to this table's rows when the row they point at is deleted, or its
    /// key changed.
    public static func explanation(of action: ForeignKeyAction, onDelete: Bool, dialect: SQLDialect) -> String {
        let event = onDelete ? "deleted" : "given another key"
        let verb = onDelete ? "delete" : "update"
        switch action {
        case .noAction:
            switch dialect {
            case .postgresql:
                return "The \(verb) is refused while rows here still point at the row. "
                    + "The check can be put off to the end of the transaction if the key is deferrable."
            case .mysql:
                return "The \(verb) is refused while rows here still point at the row. In MySQL this is RESTRICT."
            case .sqlite:
                return "The \(verb) is refused, when the statement ends, if rows here still point at the row."
            }
        case .restrict:
            return dialect == .mysql
                ? "The \(verb) is refused while rows here still point at the row."
                : "The \(verb) is refused at once while rows here still point at the row; "
                    + "the check cannot be deferred."
        case .cascade:
            return onDelete
                ? "Rows here that point at the row are deleted with it."
                : "Rows here that point at the row are given its new key."
        case .setNull:
            return "Rows here that point at a row that is \(event) have their columns set to NULL. "
                + "The columns must allow NULL."
        case .setDefault:
            return "Rows here that point at a row that is \(event) have their columns set to their defaults. "
                + "The defaults must themselves point at a row."
        }
    }

    /// The name the engine itself would give, so a key made here reads like its others.
    public static func suggestedName(table: String, columns: [String], dialect: SQLDialect) -> String {
        let joined = columns.isEmpty ? "" : columns.joined(separator: "_") + "_"
        // PostgreSQL names a key `table_column_fkey`; an identifier holds 63 bytes there
        // and 64 characters in MySQL, and the server truncates past that.
        let name = dialect == .postgresql ? "\(table)_\(joined)fkey" : "fk_\(table)_\(joined.dropLast())"
        return String(name.prefix(63))
    }

    /// One thing about a key the server will refuse, or may.
    public struct Problem: Sendable, Hashable, Identifiable {
        public enum Severity: Sendable, Hashable { case error, warning }

        public let severity: Severity
        public let message: String

        public var id: String { message }

        public init(_ severity: Severity, _ message: String) {
            self.severity = severity
            self.message = message
        }
    }

    /// A column as the check needs it.
    public struct Column: Sendable, Hashable {
        public let name: String
        public let type: String
        public let isNullable: Bool

        public init(name: String, type: String, isNullable: Bool = true) {
            self.name = name
            self.type = type
            self.isNullable = isNullable
        }
    }

    /// What is wrong with `key`, most serious first. Empty when nothing is.
    ///
    /// - Parameters:
    ///   - columns: the columns of the table the key is on.
    ///   - referenced: the columns of the table it points at, or nil when not read yet.
    ///   - referencedKeys: the column sets that are unique there, the primary key first.
    public static func problems(
        with key: ForeignKeyDefinition,
        columns: [Column],
        referenced: [Column]?,
        referencedKeys: [[String]],
        dialect: SQLDialect
    ) -> [Problem] {
        var problems: [Problem] = []
        if key.columns.isEmpty { problems.append(Problem(.error, "Choose the column the key is on.")) }
        if key.referencedTable.name.isEmpty {
            problems.append(Problem(.error, "Choose the table the key points at."))
        }
        let missing = key.columns.filter { name in !columns.contains { $0.name == name } }
        if !missing.isEmpty {
            problems.append(Problem(.error, "This table has no column \(list(missing))."))
        }
        if !key.columns.isEmpty,
            key.referencedColumns.count != key.columns.count
                || key.referencedColumns.contains(where: \.isEmpty)
        {
            problems.append(Problem(.error, "Every column needs the column it points at."))
        }
        guard let referenced else { return problems }

        let chosen = key.referencedColumns.filter { !$0.isEmpty }
        let absent = chosen.filter { name in !referenced.contains { $0.name == name } }
        if !absent.isEmpty {
            problems.append(Problem(.error, "\(key.referencedTable.name) has no column \(list(absent))."))
        }
        if !chosen.isEmpty, absent.isEmpty, chosen.count == key.columns.count,
            !referencedKeys.contains(where: { Set($0) == Set(chosen) })
        {
            let what =
                dialect == .mysql
                ? "MySQL needs an index there that starts with them, and only a unique one keeps the key meaningful."
                : "A key can only point at a primary key or a unique constraint."
            problems.append(
                Problem(
                    dialect == .mysql ? .warning : .error,
                    "\(list(chosen)) \(chosen.count == 1 ? "is" : "are") not unique in \(key.referencedTable.name). \(what)"
                ))
        }
        for (local, remote) in zip(key.columns, key.referencedColumns) {
            guard let here = columns.first(where: { $0.name == local }),
                let there = referenced.first(where: { $0.name == remote })
            else { continue }
            let mine = comparable(here.type, dialect: dialect)
            let theirs = comparable(there.type, dialect: dialect)
            if mine != theirs {
                // MySQL insists on the same type and sign; PostgreSQL only on types it
                // can compare, which it may or may not be able to.
                problems.append(
                    Problem(
                        dialect == .mysql ? .error : .warning,
                        "\(local) is \(here.type) but \(key.referencedTable.name).\(remote) is \(there.type)."
                            + (dialect == .mysql
                                ? " MySQL needs the same type, size and sign on both."
                                : " The types must be comparable; the same type is the safe choice.")))
            }
        }
        let notNull = key.columns.filter { name in columns.first { $0.name == name }?.isNullable == false }
        if !notNull.isEmpty, key.onDelete == .setNull || key.onUpdate == .setNull {
            problems.append(
                Problem(
                    dialect == .mysql ? .error : .warning,
                    "SET NULL cannot work while \(list(notNull)) \(notNull.count == 1 ? "is" : "are") NOT NULL."))
        }
        return problems.sorted { $0.severity == .error && $1.severity != .error }
    }

    /// A type reduced to what two ends of a key have to share: the documented name of its
    /// base, and on MySQL its sign. Lengths of strings and display widths are left out.
    static func comparable(_ type: String, dialect: SQLDialect) -> String {
        let spec = ColumnTypeSpec.parse(type)
        var base =
            ColumnTypeCatalog.choice(named: spec.base, dialect: dialect)?.name.lowercased() ?? spec.base.lowercased()
        switch base {
        case "smallserial": base = "smallint"
        case "serial": base = dialect == .mysql ? "bigint" : "integer"
        case "bigserial": base = "bigint"
        case "timestamptz": return "timestamp with time zone"
        case "timetz": return "time with time zone"
        default: break
        }
        let suffix = spec.suffix.lowercased()
        if dialect == .mysql {
            let unsigned = suffix.contains("unsigned") || spec.base.lowercased() == "serial"
            return unsigned ? "\(base) unsigned" : base
        }
        if suffix == "with time zone" { return "\(base) with time zone" }
        return base + spec.array
    }

    private static func list(_ names: [String]) -> String {
        names.joined(separator: ", ")
    }
}
