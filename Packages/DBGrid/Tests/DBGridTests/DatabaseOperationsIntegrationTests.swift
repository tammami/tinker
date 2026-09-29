import DBCore
import DBSQL
import DBTestKit
import XCTest

@testable import DBGrid

/// New Database… and Drop Database… against the real servers. The test user may not
/// create databases (it is kept unprivileged on purpose), so what is proven is that each
/// server parses the statements Tinker writes and refuses them only for lack of rights —
/// never for syntax — and that the refusal comes back verbatim.
extension ScriptTransferIntegrationTests {
    func testDatabaseStatementsParseOnEveryServer() async throws {
        let servers = try await everyServer().filter { $0.engine != .sqlite }
        guard !servers.isEmpty else { throw XCTSkip("no PostgreSQL or MySQL server is configured") }
        var reached = 0
        try await withSession(on: servers) { session, server, dialect in
            _ = try await session.connect()
            let (lease, connection) = try await session.lease()
            defer { Task { await session.release(lease) } }
            reached += 1
            let options =
                dialect == .mysql
                ? DatabaseOperations.CreateOptions(characterSet: "utf8mb4", collation: "utf8mb4_general_ci")
                : DatabaseOperations.CreateOptions(encoding: "UTF8")
            let name = "tinker_scratch_\(Int.random(in: 1_000 ... 9_999))"
            let statements = [
                try XCTUnwrap(DatabaseOperations.create(name, dialect: dialect, options: options)),
                try XCTUnwrap(DatabaseOperations.drop(name, dialect: dialect)),
            ]
            for statement in statements {
                do {
                    _ = try await connection.executeCollecting(statement)
                    XCTFail("\(server.engine): the unprivileged test user ran \(statement)")
                } catch let DBError.server(error) {
                    // 42501 insufficient privilege / 3D000 no such database (PostgreSQL);
                    // 1044 access denied, 1008 no such database (MySQL). Never 42601 or 1064.
                    let refusal =
                        ["42501", "3D000"].contains(error.sqlState ?? "") || [1_044, 1_008, 1_045].contains(error.code ?? 0)
                    XCTAssertTrue(refusal, "\(server.engine) \(statement): \(error.sqlState ?? "") \(error.code ?? 0) \(error.message)")
                    XCTAssertFalse(error.message.isEmpty)
                }
            }
        }
        XCTAssertEqual(reached, servers.count)
    }
}
