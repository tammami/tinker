import DBCore
import Foundation
import XCTest

/// Database engines the integration suite can target.
public enum TestEngine: String, Sendable, Hashable, CaseIterable {
    case postgresql
    case mysql

    /// Environment variable holding the single primary test URL (SPEC §17.1).
    public var primaryVariable: String {
        switch self {
        case .postgresql: "DBSTUDIO_TEST_PG_URL"
        case .mysql: "DBSTUDIO_TEST_MYSQL_URL"
        }
    }

    /// Environment variable holding a comma-separated list of additional test URLs.
    public var additionalVariable: String {
        switch self {
        case .postgresql: "DBSTUDIO_TEST_PG_URLS"
        case .mysql: "DBSTUDIO_TEST_MYSQL_URLS"
        }
    }

    /// URL schemes accepted for this engine.
    public var acceptedSchemes: Set<String> {
        switch self {
        case .postgresql: ["postgres", "postgresql"]
        case .mysql: ["mysql", "mariadb"]
        }
    }
}

/// One resolved, validated test server.
public struct TestServer: Sendable, Hashable {
    public let engine: TestEngine
    public let url: URL
    /// Which environment variable supplied this URL (for log output).
    public let source: String

    public var host: String { url.host ?? "" }
    public var port: Int { url.port ?? (engine == .postgresql ? 5432 : 3306) }
    public var user: String { url.user ?? "" }
    public var password: String? { url.password }
    public var database: String { TestEnvironment.databaseName(in: url) }

    /// URL with the password replaced by `***`, safe for logs.
    public var redactedDescription: String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if components?.password != nil { components?.password = "***" }
        return components?.string ?? "<unparseable url>"
    }
}

/// A test-environment misconfiguration. These are *failures*, never skips:
/// the only protection for the developer's real local data is refusing to run.
public enum TestEnvironmentError: Error, Hashable, CustomStringConvertible {
    case invalidURL(variable: String, value: String)
    case wrongScheme(variable: String, scheme: String, expected: Set<String>)
    case wrongDatabase(variable: String, database: String, expected: String)
    case adminUser(variable: String, user: String)

    public var description: String {
        switch self {
        case let .invalidURL(variable, value):
            "\(variable) is not a valid URL: \(value)"
        case let .wrongScheme(variable, scheme, expected):
            "\(variable) has scheme '\(scheme)'; expected one of \(expected.sorted())"
        case let .wrongDatabase(variable, database, expected):
            "\(variable) points at database '\(database)'; integration tests only run against '\(expected)'. Refusing."
        case let .adminUser(variable, user):
            "\(variable) uses user '\(user)', which looks like an admin account. Admin URLs are for testenv/prepare.sh only. Refusing."
        }
    }
}

/// Resolves integration-test servers from `DBSTUDIO_TEST_*` environment variables (SPEC §17.1).
public enum TestEnvironment {
    /// The only database name integration tests may touch.
    public static let requiredDatabaseName = "dbstudio_test"

    /// User names that are refused outright. The definitive privilege check
    /// (PG: not superuser; MySQL: no global grants) runs once a driver exists (Phase 1).
    public static let refusedUserNames: Set<String> = ["root", "postgres", "admin", "mysql"]

    /// All configured servers for `engine`, primary first, then additional ones in order.
    /// Returns an empty array when nothing is configured. Throws on any invalid entry.
    public static func servers(
        for engine: TestEngine,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> [TestServer] {
        var result: [TestServer] = []
        if let primary = environment[engine.primaryVariable]?.trimmingCharacters(in: .whitespaces), !primary.isEmpty {
            result.append(try validate(primary, variable: engine.primaryVariable, engine: engine))
        }
        if let list = environment[engine.additionalVariable] {
            for raw in list.split(separator: ",") {
                let value = raw.trimmingCharacters(in: .whitespaces)
                if value.isEmpty { continue }
                result.append(try validate(value, variable: engine.additionalVariable, engine: engine))
            }
        }
        return result
    }

    /// Servers for `engine`, or an `XCTSkip` when none are configured.
    /// Misconfiguration still throws `TestEnvironmentError` and fails the test.
    public static func requireServers(
        for engine: TestEngine,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> [TestServer] {
        let servers = try servers(for: engine, environment: environment)
        if servers.isEmpty {
            throw XCTSkip("\(engine.primaryVariable) not set — skipping \(engine.rawValue) integration tests")
        }
        return servers
    }

    /// Human-readable summary of what is configured, for the CI log.
    public static func summary(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        var lines: [String] = []
        for engine in TestEngine.allCases {
            do {
                let servers = try servers(for: engine, environment: environment)
                if servers.isEmpty {
                    lines.append("\(engine.rawValue): not configured (\(engine.primaryVariable) unset)")
                } else {
                    for server in servers {
                        lines.append("\(engine.rawValue): \(server.redactedDescription) [\(server.source)]")
                    }
                }
            } catch {
                lines.append("\(engine.rawValue): INVALID — \(error)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Database name is the URL path without its leading slash.
    static func databaseName(in url: URL) -> String {
        var path = url.path
        if path.hasPrefix("/") { path.removeFirst() }
        return path
    }

    static func validate(_ value: String, variable: String, engine: TestEngine) throws -> TestServer {
        guard let url = URL(string: value), let scheme = url.scheme, url.host != nil else {
            throw TestEnvironmentError.invalidURL(variable: variable, value: value)
        }
        guard engine.acceptedSchemes.contains(scheme.lowercased()) else {
            throw TestEnvironmentError.wrongScheme(variable: variable, scheme: scheme, expected: engine.acceptedSchemes)
        }
        let database = databaseName(in: url)
        guard database == requiredDatabaseName else {
            throw TestEnvironmentError.wrongDatabase(variable: variable, database: database, expected: requiredDatabaseName)
        }
        let user = url.user ?? ""
        if refusedUserNames.contains(user.lowercased()) {
            throw TestEnvironmentError.adminUser(variable: variable, user: user)
        }
        return TestServer(engine: engine, url: url, source: variable)
    }
}

extension TestServer {
    /// A resolved config pointing at this server, ready to hand to a driver.
    public func resolvedConfig(
        connectTimeout: Duration = .seconds(10),
        statementTimeout: Duration? = nil,
        tls: TLSConfig = TLSConfig(mode: .prefer),
        options: [String: String] = [:]
    ) -> ResolvedConnectionConfig {
        ResolvedConnectionConfig(
            configID: UUID(),
            dialect: engine == .postgresql ? .postgresql : .mysql,
            host: host,
            port: port,
            user: user,
            password: password,
            database: database,
            tls: tls,
            options: options,
            connectTimeout: connectTimeout,
            statementTimeout: statementTimeout
        )
    }
}

/// Assertions that keep integration tests off servers they must not touch.
public enum TestGuards {
    /// Fails the test unless the connected user is unprivileged.
    ///
    /// SPEC §17.1 requires this at run time and not only from the URL, because a URL can
    /// name any account. The value comes from the caller, which is the only component that
    /// can run a query.
    ///
    /// - Parameters:
    ///   - isSuperuser: PostgreSQL `rolsuper`, or MySQL "has a global grant".
    ///   - database: the database the connection actually landed in.
    public static func requireUnprivileged(
        isSuperuser: Bool,
        database: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        if isSuperuser {
            XCTFail(
                "Refusing to run integration tests as a privileged user. "
                + "Admin URLs are for testenv/prepare.sh only (SPEC §17.1).",
                file: file, line: line
            )
            throw TestEnvironmentError.adminUser(variable: "runtime check", user: "<privileged>")
        }
        if database != TestEnvironment.requiredDatabaseName {
            XCTFail(
                "Refusing to run integration tests against database '\(database)'; "
                + "only '\(TestEnvironment.requiredDatabaseName)' is allowed.",
                file: file, line: line
            )
            throw TestEnvironmentError.wrongDatabase(
                variable: "runtime check", database: database,
                expected: TestEnvironment.requiredDatabaseName
            )
        }
    }
}

/// Notes that must show up in the CI log, such as which server version actually ran.
///
/// `XCTContext.runActivity` is main-actor isolated and therefore unusable from the async
/// bodies of integration tests, so notes go to standard error, where `Scripts/ci.sh`
/// collects them into its coverage summary.
public enum TestLog {
    public static func note(_ message: String) {
        FileHandle.standardError.write(Data("[dbstudio-test] \(message)\n".utf8))
    }
}
