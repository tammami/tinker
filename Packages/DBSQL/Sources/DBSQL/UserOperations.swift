import DBCore
import Foundation

/// A privilege the user editor can grant on a database, in each engine's spelling.
public enum DatabasePrivilege: String, Sendable, Hashable, CaseIterable, Codable {
    case all = "ALL"
    case select = "SELECT"
    case insert = "INSERT"
    case update = "UPDATE"
    case delete = "DELETE"

    public var title: String {
        switch self {
        case .all: "All privileges"
        default: rawValue.capitalized
        }
    }
}

/// What the user editor asks for. Rendered by `UserOperations` into the statements the
/// server runs; nothing is sent until the person has read them.
public struct UserRequest: Sendable, Hashable {
    public var name: String
    /// MySQL accounts are `user@host`; `%` is any host. Ignored on PostgreSQL.
    public var host: String
    /// Nil leaves the password alone; an empty string is refused by the generator.
    public var password: String?
    public var canLogin: Bool
    public var isSuperuser: Bool
    public var canCreateDatabase: Bool
    public var canCreateRole: Bool
    /// The database the privileges below apply to, when any are chosen.
    public var database: String?
    public var privileges: Set<DatabasePrivilege>
    public var grantOption: Bool

    public init(
        name: String,
        host: String = "%",
        password: String? = nil,
        canLogin: Bool = true,
        isSuperuser: Bool = false,
        canCreateDatabase: Bool = false,
        canCreateRole: Bool = false,
        database: String? = nil,
        privileges: Set<DatabasePrivilege> = [],
        grantOption: Bool = false
    ) {
        self.name = name
        self.host = host
        self.password = password
        self.canLogin = canLogin
        self.isSuperuser = isSuperuser
        self.canCreateDatabase = canCreateDatabase
        self.canCreateRole = canCreateRole
        self.database = database
        self.privileges = privileges
        self.grantOption = grantOption
    }
}

public enum UserOperationsError: Error, Hashable, CustomStringConvertible {
    case emptyName
    case emptyPassword

    public var description: String {
        switch self {
        case .emptyName: "The user needs a name"
        case .emptyPassword: "A new user needs a password"
        }
    }
}

/// Generates CREATE / ALTER / DROP USER and GRANT statements.
///
/// Names are quoted as identifiers (or as MySQL account strings), passwords as string
/// literals through `SQLLiteral`, so a quote in either cannot break out of the statement.
public enum UserOperations {
    /// The statements that create the user and grant what was asked for.
    public static func create(_ request: UserRequest, dialect: SQLDialect) throws -> [String] {
        let name = request.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw UserOperationsError.emptyName }
        guard let password = request.password, !password.isEmpty else { throw UserOperationsError.emptyPassword }
        var statements: [String] = []
        switch dialect {
        case .postgresql:
            var options = [request.canLogin ? "LOGIN" : "NOLOGIN"]
            if request.isSuperuser { options.append("SUPERUSER") }
            if request.canCreateDatabase { options.append("CREATEDB") }
            if request.canCreateRole { options.append("CREATEROLE") }
            options.append("PASSWORD \(SQLLiteral.quoteString(password, dialect: dialect))")
            statements.append("CREATE ROLE \(Identifier.quote(name, dialect: dialect)) \(options.joined(separator: " "))")
        case .mysql:
            statements.append("CREATE USER \(account(request, dialect: dialect)) IDENTIFIED BY \(SQLLiteral.quoteString(password, dialect: dialect))")
            if request.isSuperuser {
                statements.append("GRANT ALL PRIVILEGES ON *.* TO \(account(request, dialect: dialect)) WITH GRANT OPTION")
            }
        }
        statements.append(contentsOf: grants(request, dialect: dialect))
        return statements
    }

    /// Changes a password and, where asked, the attributes and grants of an existing user.
    public static func alter(_ request: UserRequest, dialect: SQLDialect) throws -> [String] {
        let name = request.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw UserOperationsError.emptyName }
        var statements: [String] = []
        switch dialect {
        case .postgresql:
            var options = [request.canLogin ? "LOGIN" : "NOLOGIN"]
            options.append(request.isSuperuser ? "SUPERUSER" : "NOSUPERUSER")
            options.append(request.canCreateDatabase ? "CREATEDB" : "NOCREATEDB")
            options.append(request.canCreateRole ? "CREATEROLE" : "NOCREATEROLE")
            if let password = request.password, !password.isEmpty {
                options.append("PASSWORD \(SQLLiteral.quoteString(password, dialect: dialect))")
            }
            statements.append("ALTER ROLE \(Identifier.quote(name, dialect: dialect)) \(options.joined(separator: " "))")
        case .mysql:
            if let password = request.password, !password.isEmpty {
                statements.append("ALTER USER \(account(request, dialect: dialect)) IDENTIFIED BY \(SQLLiteral.quoteString(password, dialect: dialect))")
            }
        }
        statements.append(contentsOf: grants(request, dialect: dialect))
        return statements
    }

    public static func drop(_ request: UserRequest, dialect: SQLDialect) -> String {
        switch dialect {
        case .postgresql: "DROP ROLE \(Identifier.quote(request.name, dialect: dialect))"
        case .mysql: "DROP USER \(account(request, dialect: dialect))"
        }
    }

    /// The GRANT statements for the chosen database, or none when nothing was chosen.
    public static func grants(_ request: UserRequest, dialect: SQLDialect) -> [String] {
        guard let database = request.database, !database.isEmpty, !request.privileges.isEmpty else { return [] }
        let list = request.privileges.contains(.all)
            ? "ALL PRIVILEGES"
            : request.privileges.map(\.rawValue).sorted().joined(separator: ", ")
        let option = request.grantOption ? " WITH GRANT OPTION" : ""
        switch dialect {
        case .postgresql:
            let role = Identifier.quote(request.name, dialect: dialect)
            let db = Identifier.quote(database, dialect: dialect)
            // Tables live in schemas on PostgreSQL; `public` is where a database's tables
            // are unless the person has arranged otherwise, and CONNECT is what lets the
            // role reach the database at all.
            var statements = ["GRANT CONNECT ON DATABASE \(db) TO \(role)"]
            statements.append("GRANT USAGE ON SCHEMA public TO \(role)")
            statements.append("GRANT \(list) ON ALL TABLES IN SCHEMA public TO \(role)\(option)")
            statements.append("ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT \(list) ON TABLES TO \(role)")
            return statements
        case .mysql:
            return ["GRANT \(list) ON \(Identifier.quote(database, dialect: dialect)).* TO \(account(request, dialect: dialect))\(option)"]
        }
    }

    /// `'name'@'host'`, each part a string literal.
    public static func account(_ request: UserRequest, dialect: SQLDialect) -> String {
        let host = request.host.isEmpty ? "%" : request.host
        return "\(SQLLiteral.quoteString(request.name, dialect: dialect))@\(SQLLiteral.quoteString(host, dialect: dialect))"
    }
}
