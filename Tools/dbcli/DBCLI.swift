// dbcli — a CLI harness that exercises DBCore and the drivers without any UI.
//
//   dbcli <url> "<sql>"              stream the result as TSV
//   dbcli <url> --introspect         dump the schema as JSON
//   dbcli <url> "<sql>" --cancel-after 2s
//   dbcli <url> --ping
//
// URLs look like postgresql://user:password@host:port/database or mysql://…
import DBCore
import DBMySQL
import DBPostgres
import DBSQLite
import DBSQL
import DBTunnel
import Foundation
import Logging

@main
struct DBCLI {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard !arguments.isEmpty else {
            printUsage()
            exit(2)
        }

        var options = Options()
        var positional: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--introspect": options.introspect = true
            case "--ping": options.ping = true
            case "-v", "--verbose": options.verbose = true
            case "--no-header": options.header = false
            case "--ssh":
                index += 1
                guard index < arguments.count else { fail("--ssh needs user@host[:port]") }
                options.ssh = arguments[index]
            case "--ssh-key":
                index += 1
                guard index < arguments.count else { fail("--ssh-key needs a path") }
                options.sshKey = arguments[index]
            case "--ssh-password":
                index += 1
                guard index < arguments.count else { fail("--ssh-password needs a password") }
                options.sshPassword = arguments[index]
            case "--cancel-after":
                index += 1
                guard index < arguments.count, let seconds = parseDuration(arguments[index]) else {
                    fail("--cancel-after needs a duration such as 2s or 500ms")
                }
                options.cancelAfter = seconds
            case "-h", "--help":
                printUsage()
                exit(0)
            default:
                positional.append(argument)
            }
            index += 1
        }

        guard let urlText = positional.first else {
            fail("A connection URL is required")
        }
        options.sql = positional.count > 1 ? positional[1] : nil
        if options.sshPassword == nil {
            options.sshPassword = ProcessInfo.processInfo.environment["TINKER_SSH_PASSWORD"]
        }

        var logger = Logger(label: "dbcli")
        logger.logLevel = options.verbose ? .debug : .warning

        do {
            var config = try parseURL(urlText)
            var tunnel: (any Tunnel)?
            if let sshTarget = options.ssh {
                let (sshConfig, secrets) = try await makeSSHConfig(sshTarget, options: options)
                standardError("opening SSH tunnel through \(sshConfig.user)@\(sshConfig.host):\(sshConfig.port)…\n")
                let forward = try await SSHTunnelProvider().openTunnel(
                    sshConfig, to: config.host, port: config.port, secrets: secrets, logger: logger
                )
                tunnel = forward
                standardError("forwarding 127.0.0.1:\(forward.localPort) → \(config.host):\(config.port)\n")
                config.tlsServerName = config.host
                config.host = "127.0.0.1"
                config.port = forward.localPort
            }
            defer { if let tunnel { Task { await tunnel.close() } } }
            let connection: any SQLConnection =
                switch config.dialect {
                case .postgresql: try await PostgresDriver.connect(config, logger: logger)
                case .mysql: try await MySQLDriver.connect(config, logger: logger)
                case .sqlite: try await SQLiteDriver.connect(config, logger: logger)
                }
            defer { Task { await connection.close() } }

            let version = await connection.serverVersion
            standardError("connected to \(version.rawString) [backend \(connection.backendID)]\n")

            if options.ping {
                try await connection.ping()
                print("ok")
            } else if options.introspect {
                try await dumpSchema(connection, config: config)
            } else if let sql = options.sql {
                try await run(sql: sql, on: connection, options: options)
            } else {
                fail("Nothing to do: pass a statement, --introspect or --ping")
            }
            await connection.close()
        } catch {
            standardError("error: \(describe(error))\n")
            exit(1)
        }
    }

    struct Options {
        var introspect = false
        var ping = false
        var verbose = false
        var header = true
        var cancelAfter: Duration?
        var sql: String?
        var ssh: String?
        var sshKey: String?
        var sshPassword: String?
    }

    // MARK: - Running statements

    static func run(sql: String, on connection: any SQLConnection, options: Options) async throws {
        let dialect: SQLDialect =
            switch await connection.serverVersion.flavor {
            case .postgresql: .postgresql
            case .sqlite: .sqlite
            case .mysql, .mariadb, .percona, .aurora, .unknown: .mysql
            }
        let statements = StatementSplitter.split(sql, dialect: dialect)
        guard !statements.isEmpty else {
            standardError("no statements to run\n")
            return
        }

        for statement in statements {
            let task = Task { try await stream(statement.text, on: connection, options: options) }
            if let delay = options.cancelAfter {
                let canceller = Task {
                    try? await Task.sleep(for: delay)
                    standardError("cancelling after \(delay)…\n")
                    task.cancel()
                }
                defer { canceller.cancel() }
                try await task.value
            } else {
                try await task.value
            }
        }
    }

    static func stream(_ sql: String, on connection: any SQLConnection, options: Options) async throws {
        var columns: [ColumnMeta] = []
        var rowCount = 0
        var completed = false
        for try await event in connection.execute(sql, parameters: []) {
            switch event {
            case let .columns(value):
                columns = value
                if options.header, !value.isEmpty {
                    print(value.map(\.name).joined(separator: "\t"))
                }
            case let .rows(batch):
                for row in batch.rows {
                    print(row.map(tsvField).joined(separator: "\t"))
                    rowCount += 1
                }
            case let .complete(completion):
                completed = true
                let tag = completion.serverTag ?? "OK"
                let milliseconds =
                    Double(completion.durationTotal.components.attoseconds) / 1e15
                    + Double(completion.durationTotal.components.seconds) * 1_000
                standardError(
                    String(
                        format: "%@ • %d column(s) • %d row(s) • %.1f ms\n",
                        tag, columns.count, rowCount, milliseconds
                    ))
                for notice in completion.notices { standardError("notice: \(notice)\n") }
            }
        }
        // A cancelled task ends the stream without a completion event; the caller learns
        // why from its own cancellation state (see `SQLConnection.execute`).
        if !completed, Task.isCancelled { throw DBError.cancelled }
    }

    /// TSV cannot carry tabs or newlines, so they are escaped the way `COPY` does.
    static func tsvField(_ value: DBValue) -> String {
        switch value {
        case .null: return "\\N"
        case let .bytes(data): return "\\x" + data.map { String(format: "%02x", $0) }.joined()
        case let .array(items): return "{" + items.map { $0.text ?? "NULL" }.joined(separator: ",") + "}"
        default:
            let text = value.text ?? ""
            return
                text
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\t", with: "\\t")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
        }
    }

    // MARK: - Introspection

    static func dumpSchema(_ connection: any SQLConnection, config: ResolvedConnectionConfig) async throws {
        let introspector = connection.introspector
        // A SQLite connection's `database` is the file; the catalog calls it `main`.
        let database = config.dialect == .sqlite ? SchemaRef.sqliteMainSchema : (config.database ?? "")
        var output: [String: Any] = [:]
        output["server"] = await connection.serverVersion.rawString
        output["databases"] = try await introspector.databases().map(\.name)

        var schemaDumps: [[String: Any]] = []
        for schema in try await introspector.schemas(in: database) where !schema.isSystem {
            var tableDumps: [[String: Any]] = []
            for table in try await introspector.tables(in: schema.ref) {
                let columns = try await introspector.columns(of: table.ref)
                let indexes = try await introspector.indexes(of: table.ref)
                let foreignKeys = try await introspector.foreignKeys(of: table.ref)
                tableDumps.append([
                    "name": table.name,
                    "kind": table.kind.rawValue,
                    "approximateRowCount": table.approximateRowCount ?? -1,
                    "primaryKey": try await introspector.primaryKey(of: table.ref) ?? [],
                    "columns": columns.map { column in
                        [
                            "ordinal": column.ordinal,
                            "name": column.name,
                            "type": column.nativeType,
                            "kind": column.kind.rawValue,
                            "nullable": column.isNullable,
                            "default": column.defaultExpression ?? NSNull(),
                            "primaryKey": column.isPrimaryKey,
                            "autoIncrement": column.isAutoIncrement,
                            "generated": column.isGenerated,
                            "enumLabels": column.enumLabels ?? [],
                        ] as [String: Any]
                    },
                    "indexes": indexes.map { ["name": $0.name, "columns": $0.columns, "unique": $0.isUnique] },
                    "foreignKeys": foreignKeys.map {
                        [
                            "name": $0.name, "columns": $0.columns,
                            "references": "\($0.referencedTable.schema).\($0.referencedTable.name)",
                            "referencedColumns": $0.referencedColumns,
                        ]
                    },
                ])
            }
            schemaDumps.append([
                "name": schema.name,
                "tables": tableDumps,
                "routines": try await introspector.routines(in: schema.ref).map {
                    ["name": $0.name, "kind": $0.kind.rawValue, "signature": $0.signature]
                },
            ])
        }
        output["schemas"] = schemaDumps

        let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }

    // MARK: - Input parsing

    static func parseURL(_ text: String) throws -> ResolvedConnectionConfig {
        guard let components = URLComponents(string: text), let scheme = components.scheme?.lowercased() else {
            throw CLIError("Cannot parse \(text) as a URL")
        }
        let dialect: SQLDialect =
            switch scheme {
            case "postgres", "postgresql", "pg": .postgresql
            case "mysql", "mariadb": .mysql
            case "sqlite", "sqlite3", "file": .sqlite
            default: throw CLIError("Unsupported scheme \(scheme)")
            }
        var database = components.path
        if dialect == .sqlite {
            // `sqlite:///absolute/path.db` or `sqlite:relative.db`: the path is the database.
            guard !database.isEmpty else { throw CLIError("A SQLite URL needs a file path: sqlite:///path/to/file.db") }
            return ResolvedConnectionConfig(
                configID: UUID(), dialect: .sqlite, host: "", port: 0, user: "", database: database,
                tls: TLSConfig(mode: .disable))
        }
        if database.hasPrefix("/") { database.removeFirst() }

        var options: [String: String] = [:]
        var tls = TLSConfig(mode: .prefer)
        for item in components.queryItems ?? [] {
            switch item.name {
            case "sslmode", "tls":
                if let mode = TLSMode(rawValue: item.value ?? "") { tls.mode = mode }
            case "sslrootcert":
                tls.caFile = item.value
            default:
                options[item.name] = item.value ?? ""
            }
        }

        return ResolvedConnectionConfig(
            configID: UUID(),
            dialect: dialect,
            host: components.host ?? "localhost",
            port: components.port ?? (dialect == .postgresql ? 5_432 : 3_306),
            user: components.user ?? NSUserName(),
            // The password belongs in the environment, not in the URL: an argument is in
            // `ps` output and the shell history for everyone on the machine. The URL form
            // still works, for a one-off against a scratch server.
            password: components.password ?? Self.passwordFromEnvironment(for: dialect),
            database: database.isEmpty ? nil : database,
            tls: tls,
            options: options
        )
    }

    /// Builds an SSH config from `--ssh user@host[:port]`, choosing key or password auth.
    static func makeSSHConfig(
        _ target: String,
        options: Options
    ) async throws -> (SSHConfig, any SecretStore) {
        let parts = target.split(separator: "@", maxSplits: 1)
        let user = parts.count == 2 ? String(parts[0]) : NSUserName()
        let hostPart = String(parts.last ?? "localhost")
        let hostPieces = hostPart.split(separator: ":", maxSplits: 1)
        let host = String(hostPieces[0])
        let port = hostPieces.count == 2 ? Int(hostPieces[1]) ?? 22 : 22

        let secrets = EphemeralSecretStore()
        let auth: SSHAuth
        if let password = options.sshPassword {
            let reference = SecretRef(account: "dbcli.ssh.password")
            try await secrets.setSecret(password, for: reference)
            auth = .password(reference)
        } else {
            let path =
                options.sshKey
                ?? (NSHomeDirectory() as NSString).appendingPathComponent(".ssh/id_ed25519")
            auth = .privateKey(path: path, passphrase: nil)
        }
        return (
            SSHConfig(host: host, port: port, user: user, auth: auth, knownHostsPolicy: .acceptNew),
            secrets
        )
    }

    static func parseDuration(_ text: String) -> Duration? {
        if text.hasSuffix("ms"), let value = Double(text.dropLast(2)) {
            return .milliseconds(Int(value))
        }
        if text.hasSuffix("s"), let value = Double(text.dropLast()) {
            return .milliseconds(Int(value * 1_000))
        }
        return Double(text).map { .milliseconds(Int($0 * 1_000)) }
    }

    // MARK: - Output

    struct CLIError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    static func describe(_ error: any Error) -> String {
        guard let dbError = error as? DBError else { return String(describing: error) }
        switch dbError {
        case let .server(serverError):
            var text = serverError.message
            if let sqlState = serverError.sqlState { text = "[\(sqlState)] \(text)" }
            if let detail = serverError.detail { text += "\nDETAIL: \(detail)" }
            if let hint = serverError.hint { text += "\nHINT: \(hint)" }
            if let position = serverError.position { text += "\nPOSITION: \(position)" }
            return text
        default:
            return dbError.errorDescription ?? String(describing: dbError)
        }
    }

    static func standardError(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
    }

    static func fail(_ message: String) -> Never {
        standardError("error: \(message)\n")
        exit(2)
    }

    /// The database password from the environment, the way `psql` and `mysql` read it:
    /// `PGPASSWORD` or `MYSQL_PWD` for the engine, `TINKER_DB_PASSWORD` for either.
    static func passwordFromEnvironment(for dialect: SQLDialect) -> String? {
        let environment = ProcessInfo.processInfo.environment
        let specific: String? =
            switch dialect {
            case .postgresql: environment["PGPASSWORD"]
            case .mysql: environment["MYSQL_PWD"]
            case .sqlite: nil
            }
        return specific ?? environment["TINKER_DB_PASSWORD"]
    }

    static func printUsage() {
        print(
            """
            dbcli — Tinker's driver harness

            USAGE
              dbcli <url> "<sql>"          run statements, printing rows as TSV
              dbcli <url> --introspect     dump the schema as JSON
              dbcli <url> --ping           check the connection

            OPTIONS
              --ssh <user@host[:port]>     tunnel the connection over SSH
              --ssh-key <path>             private key to use (default ~/.ssh/id_ed25519)
              --ssh-password <password>    use password authentication instead of a key
                                           (prefer TINKER_SSH_PASSWORD in the environment)
              --cancel-after <duration>    cancel the running statement (e.g. 2s, 500ms)
              --no-header                  omit the column-name row
              -v, --verbose                debug logging — the drivers log statement text
                                           and bound values at this level; keep it off a
                                           shared terminal
              -h, --help                   this text

            URL
              postgresql://user@host:5432/database?sslmode=require
              mysql://user@host:3306/database
              sqlite:///path/to/file.db

            PASSWORDS
              Read from PGPASSWORD, MYSQL_PWD or TINKER_DB_PASSWORD when the URL has none.
              A password in the URL works but is visible in `ps` and the shell history.
            """)
    }
}
