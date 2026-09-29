import DBCore
import DBMySQL
import DBPostgres
import DBSQL
import DBSQLite
import DBTestKit
import Logging
import XCTest

/// The designer's type list against the real servers: every type it offers must be one
/// the server accepts, and whatever the server writes back must be a type the list knows,
/// so a column made in the designer never comes back as "unknown".
final class TypeCatalogIntegrationTests: XCTestCase {
    static var registry: DriverRegistry {
        DriverRegistry([.postgresql: PostgresDriver.self, .mysql: MySQLDriver.self, .sqlite: SQLiteDriver.self])
    }

    /// Every server of every engine, MariaDB included: its list is its own.
    func everyServer() async throws -> [TestServer] {
        let sqlite = try TestEnvironment.servers(for: .sqlite)
        if !sqlite.isEmpty { try await SQLiteFixtures.prepare() }
        let all =
            (try TestEnvironment.servers(for: .postgresql)) + (try TestEnvironment.servers(for: .mysql)) + sqlite
        if all.isEmpty { throw XCTSkip("no test server is configured and SQLite is disabled") }
        return all
    }

    func session(for server: TestServer) async throws -> ConnectionSession {
        var logger = Logger(label: "test.types")
        logger.logLevel = .critical
        var config = ConnectionConfig(
            name: "types-test", dialect: server.engine.dialect, host: server.host, port: server.port,
            user: server.user, database: server.database)
        let secrets = EphemeralSecretStore()
        if let password = server.password {
            let reference = SecretRef.forConnection(config.id, field: "password")
            try await secrets.setSecret(password, for: reference)
            config.passwordRef = reference
        }
        return ConnectionSession(config: config, registry: Self.registry, secrets: secrets, logger: logger)
    }

    /// The type as the designer would write it, with the sizes a first pick would have.
    static func spelling(of choice: ColumnTypeChoice, named name: String, dialect: SQLDialect) -> String {
        var spec = ColumnTypeSpec(base: name)
        if ColumnTypeSpec.isEnumeration(name) { spec.values = ["a", "b"] }
        if choice.takesDecimals {
            spec.length = 10
            spec.decimals = 2
        } else if choice.takesLength {
            let temporal = ["time", "timetz", "timestamp", "timestamptz", "datetime", "interval"]
            spec.length = temporal.contains(choice.name.lowercased()) ? 3 : 8
        }
        return spec.render(dialect: dialect)
    }

    func testEveryOfferedTypeIsAcceptedAndReadBackAsAKnownType() async throws {
        var reached = 0
        for server in try await everyServer() {
            let dialect = server.engine.dialect
            let session = try await session(for: server)
            let version = try await session.connect()
            let schema = server.fixtureSchema
            let table = TableRef(database: schema.database, schema: schema.schema, name: "tinker_type_probe")
            let qualified = Identifier.qualified(table, dialect: dialect)
            let choices = ColumnTypeCatalog.choices(for: dialect, version: version)
            XCTAssertGreaterThan(choices.count, 20, "\(version)")
            var failures: [String] = []
            var checked = 0
            try await session.withLease { connection in
                for choice in choices where !choice.group.contains("extension") {
                    for name in [choice.name] + choice.aliases {
                        let type = Self.spelling(of: choice, named: name, dialect: dialect)
                        _ = try? await connection.executeCollecting("DROP TABLE IF EXISTS \(qualified)")
                        do {
                            _ = try await connection.executeCollecting("CREATE TABLE \(qualified) (c \(type))")
                        } catch {
                            failures.append("\(type): \((error as? DBError)?.errorDescription ?? "\(error)")")
                            continue
                        }
                        let columns = try await connection.introspector.columns(of: table)
                        let written = columns.first?.nativeType ?? ""
                        let base = ColumnTypeSpec.parse(written).base
                        if ColumnTypeCatalog.choice(named: base, dialect: dialect, version: version) == nil {
                            failures.append("\(type) came back as \(written), which the list does not know")
                        }
                        checked += 1
                    }
                }
                _ = try? await connection.executeCollecting("DROP TABLE IF EXISTS \(qualified)")
            }
            await session.disconnect()
            XCTAssertTrue(
                failures.isEmpty, "\(version) on port \(server.port):\n" + failures.joined(separator: "\n"))
            XCTAssertGreaterThan(checked, 20)
            reached += 1
        }
        XCTAssertGreaterThan(reached, 0)
    }
}
