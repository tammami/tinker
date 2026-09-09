/// The SQL dialect a driver speaks. Used to select quoting, paging, DML generation
/// and introspection strategies without the caller knowing the concrete driver.
public enum SQLDialect: String, Sendable, Hashable, Codable, CaseIterable {
    case postgresql
    case mysql
    case sqlite

    /// The engine's name as it is written in the UI.
    public var displayName: String {
        switch self {
        case .postgresql: "PostgreSQL"
        case .mysql: "MySQL / MariaDB"
        case .sqlite: "SQLite"
        }
    }

    /// True when a database holds named schemas of its own (PostgreSQL). MySQL and
    /// SQLite have one level fewer: their pseudo-schema carries the database's name.
    public var hasSchemaLayer: Bool { self == .postgresql }

    /// True when the database is a file on disk rather than a server: no host, port,
    /// user, password, TLS or SSH, and the connection's `database` is the file's path.
    public var isFileBased: Bool { self == .sqlite }

    /// True when a server holds several databases the client can list and switch
    /// between. A SQLite connection is one file, and that file is the database.
    public var hasMultipleDatabases: Bool { self != .sqlite }

    /// True when the server has login accounts to list and manage.
    public var hasUserAccounts: Bool { self != .sqlite }

    /// The name of the one schema every table lives in for a dialect without a schema
    /// layer of its own, or nil when the schema comes from the catalog.
    public var fixedSchemaName: String? { self == .sqlite ? SchemaRef.sqliteMainSchema : nil }
}
